// Lead check FT-563 (remainder of FT-554): cache file has single writer.
//
// Played track moves to cache from player cache (`cacheFileFor` -> `adopt`),
// next two preloaded (`ahead`). Previously `cacheFileFor` returned same
// path: A -> B -> A again — two downloads of A wrote to same file, and
// download of abandoned source continues after track change.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_stream/auth/token_provider.dart';
import 'package:music_stream/offline/offline_playback.dart';
import 'package:music_stream/offline/track_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fakes.dart';

const base = 'https://music.example';
const account = 'account/https%3A%2F%2Fmusic.example/42';
const gib = 1024 * 1024 * 1024;

late Directory root;
late TrackStore store;
late FakePlayback server;
late List<String> asked;
late Completer<void> gate;

OfflinePlayback offline() => OfflinePlayback(
  inner: server,
  store: Future.value(store),
  tokens: TokenProvider(
    EmptySessionStore()..cachedToken = 'secret-session-token-0123456789',
    server: Uri.parse(base),
  ),
  // Preloaded file arrives while [gate] is not yet opened.
  client: MockClient.streaming((request, _) async {
    asked.add(request.url.path);
    final body = StreamController<List<int>>();
    unawaited(() async {
      body.add(List.filled(1000, 9));
      await gate.future;
      await body.close();
    }());
    return http.StreamedResponse(
      body.stream,
      200,
      headers: {'content-type': 'audio/ogg'},
    );
  }),
);

/// Player cache finished writing: bytes and type as left by `DeviceAudio`.
Future<void> fill(File cache, int byte, int size) async {
  await cache.parent.create(recursive: true);
  await cache.writeAsBytes(List.filled(size, byte));
  await File('${cache.path}.mime').writeAsString('audio/ogg');
}

Future<void> until(bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(done(), isTrue);
}

void main() {
  sqfliteFfiInit();

  setUp(() async {
    root = await Directory.systemTemp.createTemp('one_writer_test');
    store = await TrackStore.open(
      root: root,
      namespace: account,
      databaseFactory: databaseFactoryFfi,
      now: () => DateTime.utc(2026, 10, 5, 12),
      freeBytes: () async => 50 * gib,
    );
    server = FakePlayback(['$base/v1/stream/play-token']);
    server.onPrepare = (id) => '$base/v1/stream/ahead-$id';
    asked = [];
    gate = Completer<void>()..complete();
  });

  tearDown(() async {
    await store.close();
    if (root.existsSync()) await root.delete(recursive: true);
  });

  test('A → B → A again: second playback of A gets own file', () async {
    final o = offline();
    final first = await o.cacheFileFor('a');
    await o.cacheFileFor('b');
    final second = await o.cacheFileFor('a');
    expect(first, isNotNull);
    expect(second, isNotNull);
    expect(second!.path, isNot(first!.path));
  });

  test('both A downloads arrive — first kept, second deleted', () async {
    final o = offline();
    final first = (await o.cacheFileFor('a'))!;
    final second = (await o.cacheFileFor('a'))!;
    await fill(first, 1, 100);
    await fill(second, 2, 200);
    await o.adopt('a', first);
    await o.adopt('a', second);

    final kept = await store.fileFor('a');
    expect(kept, isNotNull);
    expect(kept!.readAsBytesSync(), List.filled(100, 1));
    expect(second.existsSync(), isFalse);
    expect(File('${second.path}.mime').existsSync(), isFalse);
  });

  test('while preloading A — player does not write A to cache', () async {
    gate = Completer<void>();
    final o = offline();
    final going = o.ahead(['a']);
    await until(() => asked.isNotEmpty);
    expect(await o.cacheFileFor('a'), isNull);
    expect(await o.cacheFileFor('b'), isNotNull);

    gate.complete();
    await going;
    expect(await store.fileFor('a'), isNotNull);
  });

  test('player writing A to cache — preloading of A skipped', () async {
    final o = offline();
    expect(await o.cacheFileFor('a'), isNotNull);
    await o.ahead(['a', 'b']);
    expect(asked, ['/v1/stream/ahead-b']);
    expect(await store.fileFor('a'), isNull);
  });

  test('player finished A — preloading of A allowed again', () async {
    final o = offline();
    final cache = (await o.cacheFileFor('a'))!;
    await fill(cache, 1, 100);
    await o.adopt('a', cache);
    await store.remove('a');
    await o.ahead(['a']);
    expect(asked, ['/v1/stream/ahead-a']);
  });
}
