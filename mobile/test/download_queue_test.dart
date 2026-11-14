import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_stream/auth/token_provider.dart';
import 'package:music_stream/offline/download_queue.dart';
import 'package:music_stream/offline/track_store.dart';
import 'package:music_stream/server_api.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fakes.dart';

/// Downloading to device (FT-526, P-A60, rules 3, 4, 5, 9).
///
/// Phone tells server "download" as a list and polls progress of everything
/// downloading in a single request per cycle (proxy rate limit is 2 requests per second).
/// Completed files are fetched via system download into app folder: token only in
/// header. Only intact file enters storage, and only then server
/// receives "fetched". Downloads only on unmetered network until user
/// allows cellular; pauses and explains reason when free space under 1 GB.
///
/// System downloader here is mocked ([FakeTransfer]): real one, with
/// screen off, is tested by phone scenario FT-530.
const base = 'https://music.example';
const account = 'account/https%3A%2F%2Fmusic.example/42';
const gib = 1024 * 1024 * 1024;
const a = '11111111-1111-4111-8111-111111111111';
const b = '22222222-2222-4222-8222-222222222222';
const c = '33333333-3333-4333-8333-333333333333';

/// Queue server per contract `contracts/downloads.*.json`.
class QueueServer {
  final items = <String, Map<String, Object?>>{};
  final asked = <List<String>>[];
  final removed = <List<String>>[];
  final requests = <http.Request>[];
  var down = false;

  void ready(String id, {String format = 'opus', int bytes = 1000}) =>
      items[id] = {
        'track_id': id,
        'state': 'ready',
        'format': format,
        'bytes': bytes,
      };

  void state(String id, String state) => items[id] = {
    'track_id': id,
    'state': state,
    'format': null,
    'bytes': null,
  };

  int get polls => [
    for (final r in requests)
      if (r.method == 'GET' && r.url.path == '/v1/downloads') r,
  ].length;

  late final client = MockClient((request) async {
    requests.add(request);
    if (down) return http.Response('{}', 503);
    final path = request.url.path;
    if (request.method == 'POST' && path == '/v1/downloads') {
      final ids = [
        for (final id in jsonDecode(request.body)['track_ids'] as List) '$id',
      ];
      asked.add(ids);
      for (final id in ids) {
        items.putIfAbsent(
          id,
          () => {
            'track_id': id,
            'state': 'queued',
            'format': null,
            'bytes': null,
          },
        );
      }
      return http.Response(
        jsonEncode({
          'items': [for (final id in ids) items[id]],
        }),
        202,
      );
    }
    if (request.method == 'GET' && path == '/v1/downloads') {
      return http.Response(jsonEncode({'items': items.values.toList()}), 200);
    }
    if (request.method == 'POST' && path == '/v1/downloads/remove') {
      final ids = [
        for (final id in jsonDecode(request.body)['track_ids'] as List) '$id',
      ];
      removed.add(ids);
      ids.forEach(items.remove);
      return http.Response('', 204);
    }
    return http.Response('{}', 404);
  });
}

/// System download: writes to file as many bytes as instructed.
class FakeTransfer implements FileTransfer {
  final jobs = <TransferJob>[];

  /// How many bytes will finish downloading; `null` — expected length.
  int? short;
  var fails = false;

  @override
  Future<bool> fetch(TransferJob job) async {
    jobs.add(job);
    if (fails) return false;
    await job.file.parent.create(recursive: true);
    await job.file.writeAsBytes(List.filled(short ?? job.expectedBytes, 7));
    return true;
  }

  @override
  Future<void> cancel(String trackId) async {}
}

late Directory root;
late QueueServer server;
late FakeTransfer transfer;
late TrackStore store;
var metered = false;
var free = 50 * gib;

TokenProvider signedIn() => TokenProvider(
  EmptySessionStore()..cachedToken = 'secret-session-token-0123456789',
  server: Uri.parse(base),
);

Future<TrackStore> openStore() => TrackStore.open(
  root: root,
  namespace: account,
  databaseFactory: databaseFactoryFfi,
  now: DateTime.now,
  freeBytes: () async => free,
);

DownloadQueue queue() => DownloadQueue(
  server: ServerApi(base, tokens: signedIn(), client: server.client),
  store: store,
  transfer: transfer,
  isMetered: () async => metered,
);

void main() {
  sqfliteFfiInit();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('download_queue_test');
    server = QueueServer();
    transfer = FakeTransfer();
    metered = false;
    free = 50 * gib;
    store = await openStore();
  });

  tearDown(() async {
    await store.close();
    if (root.existsSync()) await root.delete(recursive: true);
  });

  test('requests list and polls progress in one call per cycle', () async {
    final q = queue();
    await q.add([a, b, c]);
    expect(server.asked, [
      [a, b, c],
    ]);
    await q.tick();
    expect(server.polls, 1, reason: 'three songs: single poll');
    await q.tick();
    expect(server.polls, 2);
  });

  test(
    'ready goes to app dir, token in header only, then acknowledged',
    () async {
      final q = queue();
      await q.add([a]);
      server.ready(a, format: 'opus', bytes: 1000);
      await q.tick();

      final [job] = transfer.jobs;
      expect(job.url.toString(), '$base/v1/downloads/$a/file');
      expect(job.url.query, isEmpty, reason: 'no token in url');
      expect(job.headers['authorization'], startsWith('Bearer '));
      expect(job.file.path, store.partFile(a, format: 'opus').path);
      expect(job.expectedBytes, 1000);

      final file = await store.fileFor(a);
      expect(file, isNotNull);
      expect(file!.path.endsWith('.opus'), isTrue);
      expect((await store.usage()).downloadBytes, 1000, reason: 'downloaded');
      expect(server.removed, [
        [a],
      ]);
      expect(q.statusOf(a), DownloadStatus.done);
    },
  );

  test('server still preparing: wait and do not download', () async {
    final q = queue();
    await q.add([a]);
    server.state(a, 'preparing');
    await q.tick();
    expect(transfer.jobs, isEmpty);
    expect(q.statusOf(a), DownloadStatus.preparing);
  });

  test(
    'partially downloaded file stays out of store, server not told',
    () async {
      final q = queue();
      await q.add([a]);
      server.ready(a, bytes: 1000);
      transfer.short = 999;
      await q.tick();
      expect(await store.fileFor(a), isNull);
      expect(server.removed, isEmpty, reason: 'the release remains pinned');
      expect(q.statusOf(a), isNot(DownloadStatus.done));

      transfer.short = null;
      await q.tick();
      expect(transfer.jobs, hasLength(2), reason: 'next cycle retries');
      expect(await store.fileFor(a), isNotNull);
    },
  );

  test('download failed: retry on next cycle', () async {
    final q = queue();
    await q.add([a]);
    server.ready(a);
    transfer.fails = true;
    await q.tick();
    expect(await store.fileFor(a), isNull);
    transfer.fails = false;
    await q.tick();
    expect(await store.fileFor(a), isNotNull);
  });

  test('server error on this song, remaining proceed', () async {
    final q = queue();
    await q.add([a, b]);
    server.state(a, 'failed');
    server.ready(b);
    await q.tick();
    expect(q.statusOf(a), DownloadStatus.failed);
    expect(q.statusOf(b), DownloadStatus.done);
  });

  test('progress: 1 of 3 complete', () async {
    final q = queue();
    await q.add([a, b, c]);
    server.ready(a);
    server.state(b, 'preparing');
    await q.tick();
    expect(q.progress, (done: 1, total: 3));
  });

  group('network', () {
    test('does not download over cellular by default', () async {
      expect(await queue().allowMobile(), isFalse);
    });

    test('metered pauses with reason until allowed', () async {
      metered = true;
      final q = queue();
      await q.add([a]);
      server.ready(a);
      await q.tick();
      expect(transfer.jobs, isEmpty);
      expect(q.hold, QueueHold.metered);

      await q.setAllowMobile(true);
      await q.tick();
      expect(transfer.jobs, hasLength(1));
      expect(transfer.jobs.single.unmeteredOnly, isFalse);
      expect(q.hold, QueueHold.none);
    });

    test(
      'on Wi-Fi download still requests unmetered network from OS',
      () async {
        final q = queue();
        await q.add([a]);
        server.ready(a);
        await q.tick();
        expect(
          transfer.jobs.single.unmeteredOnly,
          isTrue,
          reason: 'left Wi-Fi mid-album: OS waits instead of using data',
        );
      },
    );

    test('permission survives restart', () async {
      await queue().setAllowMobile(true);
      expect(await queue().allowMobile(), isTrue);
    });
  });

  test('under 1 GB disk free: paused with reason', () async {
    free = gib - 1;
    final q = queue();
    await q.add([a]);
    server.ready(a);
    await q.tick();
    expect(transfer.jobs, isEmpty);
    expect(q.hold, QueueHold.noRoom);

    free = 2 * gib;
    await q.tick();
    expect(transfer.jobs, hasLength(1));
  });

  test('already cached file marked downloaded without server', () async {
    final part = store.partFile(a, format: 'opus');
    await part.parent.create(recursive: true);
    await part.writeAsBytes(List.filled(500, 1));
    await store.commit(a, format: 'opus', hold: Hold.reserve);

    final q = queue();
    await q.add([a, b]);
    expect(server.asked, [
      [b],
    ], reason: 'server does not prepare cached song');
    expect(q.statusOf(a), DownloadStatus.done);
    expect((await store.usage()).downloadBytes, 500);
  });

  test('app restart preserves download queue', () async {
    await queue().add([a]);
    server.ready(a);
    final again = queue(); // new launch, same storage
    await again.tick();
    expect(await store.fileFor(a), isNotNull);
    expect(again.progress, (done: 1, total: 1));
  });

  test('server timeout: no crash, retries on next cycle', () async {
    final q = queue();
    await q.add([a]);
    server.ready(a);
    server.down = true;
    await q.tick();
    expect(transfer.jobs, isEmpty);
    server.down = false;
    await q.tick();
    expect(await store.fileFor(a), isNotNull);
  });

  test('delete removes from device and server queue', () async {
    final q = queue();
    await q.add([a, b]);
    server.ready(a);
    server.state(b, 'preparing');
    await q.tick();
    await q.remove([a, b]);
    expect(await store.fileFor(a), isNull);
    expect(server.removed.last, containsAll([b]));
    expect(q.statusOf(a), isNull);
    expect(q.statusOf(b), isNull);
    expect(q.progress, (done: 0, total: 0));
  });

  group('real background downloader', () {
    String code() =>
        File('lib/offline/background_transfer.dart').readAsStringSync();

    test('via background_downloader with progress notification', () {
      expect(code(), contains('package:background_downloader/'));
      expect(code(), contains('implements FileTransfer'));
      expect(code(), contains('requiresWiFi'));
      expect(code(), contains('downloadsNotificationProgress'));
    });

    test('package version is pinned', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(
        RegExp(
          r'^\s+background_downloader:\s+\d+\.\d+\.\d+\s*$',
          multiLine: true,
        ).hasMatch(pubspec),
        isTrue,
        reason: 'exact version without caret',
      );
    });

    test('store queries Android for free disk space', () {
      final store = File('lib/offline/track_store.dart').readAsStringSync();
      expect(store, contains('DeviceInfo.freeBytes'));
      expect(store, isNot(contains('TODO(FT-526)')));
    });
  });
}
