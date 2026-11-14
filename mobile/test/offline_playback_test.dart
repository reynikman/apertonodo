// LockCachingAudioSource in just_audio marked experimental — verifying it specifically.
// ignore_for_file: experimental_member_use

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:just_audio/just_audio.dart';
import 'package:music_stream/auth/login.dart';
import 'package:music_stream/auth/token_provider.dart';
import 'package:music_stream/device_audio.dart';
import 'package:music_stream/models/track.dart';
import 'package:music_stream/offline/offline_playback.dart';
import 'package:music_stream/offline/track_store.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/player.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fakes.dart';

/// What to play and what to keep on device (FT-527, P-A60, rules 1 and 7).
///
/// Source order: local copy (downloaded or from cache) -> ready Opus on
/// server if metered network -> original as before. Played audio stays in
/// cache, next two tracks in queue preloaded. Cache 0 — next tracks
/// still prepare, but get discarded after playback.
const base = 'https://music.example';
const account = 'account/https%3A%2F%2Fmusic.example/42';
const gib = 1024 * 1024 * 1024;

late Directory root;
late TrackStore store;
late DateTime clock;

Future<TrackStore> openStore() => TrackStore.open(
  root: root,
  namespace: account,
  databaseFactory: databaseFactoryFfi,
  now: () => clock,
  freeBytes: () async => 50 * gib,
);

TokenProvider signedIn() => TokenProvider(
  EmptySessionStore()..cachedToken = 'secret-session-token-0123456789',
  server: Uri.parse(base),
);

Future<File> put(
  String id, {
  Hold hold = Hold.reserve,
  int size = 1000,
  String format = 'opus',
}) async {
  final part = store.partFile(id, format: format);
  await part.parent.create(recursive: true);
  await part.writeAsBytes(List.filled(size, 7));
  return store.commit(id, format: format, hold: hold);
}

void later() => clock = clock.add(const Duration(minutes: 1));

/// Stream server: serves bytes with requested content type.
class StreamServer {
  final requests = <http.Request>[];
  var type = 'audio/ogg';
  var size = 3000;

  late final client = MockClient((request) async {
    requests.add(request);
    return http.Response.bytes(
      List.filled(size, 9),
      200,
      headers: {'content-type': type},
    );
  });
}

late StreamServer streams;
late FakePlayback server;

OfflinePlayback offline() => OfflinePlayback(
  inner: server,
  store: Future.value(store),
  tokens: signedIn(),
  client: streams.client,
);

Track song(int n) => Track(
  id: '00000000-0000-4000-8000-00000000000$n',
  title: 'Song $n',
  artist: 'Band',
  durationMs: 200000,
  artworkUrl: '',
);

void main() {
  sqfliteFfiInit();

  setUp(() async {
    root = await Directory.systemTemp.createTemp('offline_playback_test');
    clock = DateTime.utc(2026, 10, 2, 12);
    store = await openStore();
    streams = StreamServer();
    server = FakePlayback(['$base/v1/stream/play-token']);
    server.onPrepare = (id) => '$base/v1/stream/ahead-$id';
  });

  tearDown(() async {
    await store.close();
    if (root.existsSync()) await root.delete(recursive: true);
  });

  group('playback source priority', () {
    test('downloaded copy — device file, server not needed', () async {
      final file = await put('a', hold: Hold.download);
      final url = await offline().start('a');
      expect(Uri.parse(url).scheme, 'file');
      expect(Uri.parse(url).toFilePath(), file.path);
      expect(server.started, isEmpty);
    });

    test('cached copy also plays and is marked as played', () async {
      await put('old');
      later();
      await put('new');
      later();
      await offline().start('old');
      await store.setReserveLimitBytes(1000);
      expect(await store.evict(), ['new'], reason: 'least played evicted');
    });

    test('no local copy — hits server as before', () async {
      final url = await offline().start('a');
      expect(url, '$base/v1/stream/play-token');
      expect(server.started, ['a']);
    });

    test('preloading also uses local copy', () async {
      await put('a');
      final url = await offline().start('a', prepare: true);
      expect(Uri.parse(url).scheme, 'file');
      expect(server.prepared, isEmpty);
    });
  });

  group('Opus on metered network', () {
    late List<Map<String, dynamic>> bodies;
    late MockClient client;

    setUp(() {
      bodies = [];
      client = MockClient((request) async {
        bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response(jsonEncode({'token': 't'}), 200);
      });
    });

    test('metered — requests pre-encoded Opus', () async {
      await HttpPlayback(
        base,
        tokens: tokensFor(base),
        client: client,
        preferOpus: () async => true,
      ).start('a');
      expect(bodies.single['prefer'], 'opus');
    });

    test('unmetered — original, without prefer', () async {
      await HttpPlayback(
        base,
        tokens: tokensFor(base),
        client: client,
        preferOpus: () async => false,
      ).start('a');
      expect(bodies.single.containsKey('prefer'), isFalse);
    });

    test('without network check — as before', () async {
      await HttpPlayback(
        base,
        tokens: tokensFor(base),
        client: client,
      ).start('a', prepare: true);
      expect(bodies.single, {'track_id': 'a', 'prepare': true});
    });
  });

  group('next two tracks preloaded', () {
    test('preloads two, not third; auth token in header', () async {
      await offline().ahead(['a', 'b', 'c']);
      expect(server.prepared, ['a', 'b']);
      expect(streams.requests, hasLength(2));
      for (final request in streams.requests) {
        expect(request.headers['authorization'], contains('secret-session'));
        expect(request.url.toString(), isNot(contains('secret-session')));
      }
      expect((await store.fileFor('a'))!.path, endsWith('.opus'));
      expect(await (await store.fileFor('b'))!.length(), 3000);
      expect(await store.fileFor('c'), isNull);
    });

    test('tracks already on device are not downloaded', () async {
      await put('a');
      await offline().ahead(['a', 'b']);
      expect(server.prepared, ['b']);
      expect(streams.requests, hasLength(1));
    });

    test('format inferred from server response type', () async {
      streams.type = 'audio/flac';
      await offline().ahead(['a']);
      expect((await store.fileFor('a'))!.path, endsWith('.flac'));
    });

    test('unexpected response writes nothing, no .part left', () async {
      streams.type = 'text/html';
      await offline().ahead(['a']);
      expect(await store.fileFor('a'), isNull);
      final parts = root
          .listSync(recursive: true)
          .where((item) => item.path.endsWith('.part'));
      expect(parts, isEmpty);
    });

    test('server 404 is silent, without exception', () async {
      server.onPrepare = (_) => PlayFailure.noSource;
      await offline().ahead(['a', 'b']);
      expect(await store.fileFor('a'), isNull);
      expect(streams.requests, isEmpty);
    });

    test('reserve 0: played tracks pruned, next retained', () async {
      await store.setReserveLimitBytes(0);
      await offline().ahead(['a', 'b']);
      expect(await store.fileFor('a'), isNotNull, reason: 'audio not lost');
      await offline().ahead(['c', 'd']);
      expect(await store.fileFor('a'), isNull);
      expect(await store.fileFor('b'), isNull);
      expect(await store.fileFor('c'), isNotNull);
      expect(await store.fileFor('d'), isNotNull);
    });

    test('reserve eviction never evicts downloads', () async {
      await put('mine', hold: Hold.download);
      await store.setReserveLimitBytes(0);
      await offline().ahead(['a']);
      expect(await store.fileFor('mine'), isNotNull);
    });
  });

  group('played tracks to cache reserve', () {
    Future<File> cached(String id, String? mime) async {
      final file = (await offline().cacheFileFor(id))!;
      await file.parent.create(recursive: true);
      await file.writeAsBytes(List.filled(4000, 5));
      if (mime != null) await File('${file.path}.mime').writeAsString(mime);
      return file;
    }

    test('streamed file adopted into cache reserve', () async {
      final file = await cached('a', 'audio/ogg');
      await offline().adopt('a', file);
      expect((await store.fileFor('a'))!.path, endsWith('.opus'));
      expect((await store.usage()).reserveBytes, 4000);
      expect(file.existsSync(), isFalse);
      expect(File('${file.path}.mime').existsSync(), isFalse);
    });

    test('missing mime or file: ignored without exception', () async {
      final file = await cached('a', null);
      await offline().adopt('a', file);
      expect(await store.fileFor('a'), isNull);
      await offline().adopt('b', File('${root.path}/nothing'));
      expect(await store.fileFor('b'), isNull);
    });

    test('cache file is internal and hides track id', () async {
      final a = (await offline().cacheFileFor('track-a'))!;
      final b = (await offline().cacheFileFor('track-b'))!;
      expect(a.path, startsWith(root.path));
      expect(a.path, isNot(b.path));
      expect(a.path, isNot(contains('track-a')));
    });

    test('reserve 0 — play without disk cache', () async {
      await store.setReserveLimitBytes(0);
      expect(await offline().cacheFileFor('a'), isNull);
    });
  });

  group('player triggers preloading of next two', () {
    test('on each track — next two in queue prepared', () async {
      final calls = <List<String>>[];
      final player = Player(
        playback: FakePlayback(),
        audio: FakeAudio(),
        upcoming: calls.add,
      );
      final four = [song(0), song(1), song(2), song(3)];
      await player.playQueue(four);
      expect(calls.last, [song(1).id, song(2).id]);
      await player.next();
      expect(calls.last, [song(2).id, song(3).id]);
      await player.next();
      expect(calls.last, [song(3).id]);
    });
  });

  group('sound', () {
    const meta = AudioMetadata(
      id: 'a',
      title: 'Song',
      artist: 'Band',
      artworkUrl: '',
    );

    test('device file — no headers, no network call', () {
      final file = File('${Directory.systemTemp.path}/x.opus');
      final source = buildAudioSource(
        Uri.file(file.path).toString(),
        meta,
        tokens: signedIn(),
      );
      expect(source, isA<UriAudioSource>());
      final uri = (source as UriAudioSource).uri;
      expect(uri.scheme, 'file');
      expect(source.headers, isNull);
    });

    test('stream with reserve writes cache, token in header', () async {
      final cache = File('${Directory.systemTemp.path}/cache-a');
      final source = buildAudioSource(
        '$base/v1/stream/t',
        meta,
        tokens: signedIn(),
        cacheFile: cache,
      );
      expect(source, isA<LockCachingAudioSource>());
      final caching = source as LockCachingAudioSource;
      expect((await caching.cacheFile).path, cache.path);
      expect(caching.headers?['authorization'], contains('secret-session'));
    });

    test('stream without reserve — as before', () {
      final source = buildAudioSource(
        '$base/v1/stream/t',
        meta,
        tokens: signedIn(),
      );
      expect(source, isA<UriAudioSource>());
    });

    test('cache completed — player commits to reserve', () {
      final code = File('lib/device_audio.dart').readAsStringSync();
      expect(code, contains('downloadProgressStream'));
    });

    test(
      'player local proxy skipped, cleartext http — only allowed on home LAN',
      () {
        final manifest = File(
          'android/app/src/main/AndroidManifest.xml',
        ).readAsStringSync();
        expect(manifest, contains('@xml/network_security_config'));
        final config = File(
          'android/app/src/main/res/xml/network_security_config.xml',
        ).readAsStringSync();
        expect(config, contains('127.0.0.1'));
        expect(
          config,
          contains('<domain-config cleartextTrafficPermitted="true"'),
        );
        // Owner directive 12.10: home Navidrome/Jellyfin runs on plain
        // http. Android IP ranges are unsupported in this file, so guard is —
        // serverOrigin: plain http allowed only for localhost and home network.
        expect(serverOrigin('http://192.168.1.10:4533'), isNotNull);
        expect(serverOrigin('http://music.example'), isNull);
        expect(serverOrigin('http://8.8.8.8'), isNull);
      },
    );

    test('app plays through OfflinePlayback', () {
      final code = File('lib/main.dart').readAsStringSync();
      expect(code, contains('OfflinePlayback('));
      expect(code, contains('upcoming:'));
    });
  });
}
