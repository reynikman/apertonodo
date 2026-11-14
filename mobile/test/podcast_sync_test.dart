// FT-659 (P-A93, block B-5): podcast progress synchronization with server.
//
// Device buffers records in `PodcastProgressStore` (FT-656); server stores one
// record per episode (FT-658). Here — sync order: flush queued batches, dequeue
// sent items, process server response, then pull remote changes since cursor.
// No network here: port provides it.
//
// Contract `lib/podcast_sync.dart`:
// - `PodcastChanges(items, mark)`;
// - `abstract class PodcastSyncPort { put(items), changes(after) }`;
// - `enum PodcastSyncResult { done, failed, stale }`;
// - `podcastToWire(items)`, `podcastFromWire(raw)`;
// - `PodcastSync(store, port, markBox)`: `run()`, `reset()`;
//   `batch = 500`, `maxPages = 50`.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/podcast_progress.dart';
import 'package:music_stream/podcast_sync.dart';

class MemoryBox implements PodcastProgressBox {
  String? data;
  bool failWrite = false;
  bool failRead = false;
  int reads = 0;
  List<String> written = [];

  @override
  Future<String?> read() async {
    reads++;
    if (failRead) throw const FileSystemException('no');
    return data;
  }

  @override
  Future<void> write(String value) async {
    if (failWrite) throw const FileSystemException('full');
    written.add(value);
    data = value;
  }
}

/// In-memory server: same "newer" rule, cursor advances on each accepted record.
class FakeServer implements PodcastSyncPort {
  final Map<String, EpisodeProgress> rows = {};
  final Map<String, int> seq = {};
  int next = 0;
  int pageSize = 1000;
  List<Map<String, EpisodeProgress>> puts = [];
  List<int> asked = [];
  bool failPut = false;
  bool failChanges = false;
  int failPutAfter = -1;
  Completer<void>? putGate;
  Completer<void>? changesGate;
  final Set<String> refuse = {};
  final List<String> log = [];

  void seed(String key, EpisodeProgress p) {
    rows[key] = p;
    seq[key] = ++next;
  }

  @override
  Future<Map<String, EpisodeProgress>> put(
    Map<String, EpisodeProgress> items,
  ) async {
    log.add('put');
    puts.add(Map.of(items));
    if (putGate != null) await putGate!.future;
    if (failPut || (failPutAfter >= 0 && puts.length > failPutAfter)) {
      throw const SocketException('down');
    }
    final answer = <String, EpisodeProgress>{};
    for (final e in items.entries) {
      if (refuse.contains(e.key)) continue;
      final was = rows[e.key];
      if (was == null ||
          (was != e.value && newerProgress(was, e.value) == e.value)) {
        seed(e.key, e.value);
      }
      answer[e.key] = rows[e.key]!;
    }
    return answer;
  }

  @override
  Future<PodcastChanges> changes(int after) async {
    log.add('changes');
    asked.add(after);
    if (changesGate != null) await changesGate!.future;
    if (failChanges) throw const SocketException('down');
    final keys = seq.keys.where((k) => seq[k]! > after).toList()
      ..sort((a, b) => seq[a]!.compareTo(seq[b]!));
    final page = keys.take(pageSize).toList();
    return PodcastChanges({
      for (final k in page) k: rows[k]!,
    }, page.isEmpty ? after : seq[page.last]!);
  }
}

class Clock {
  DateTime now = DateTime.utc(2026, 10, 7, 12);
  DateTime call() => now;
  void tick(Duration d) => now = now.add(d);
}

const hour = 3600000;
const feed = 'https://pod.example.org/feed.xml';
String k(String guid) => podcastEpisodeKey(feed, guid);

EpisodeProgress at(int ms, {bool done = false, int minute = 0}) =>
    EpisodeProgress(
      positionMs: ms,
      done: done,
      updatedAt: DateTime.utc(2026, 10, 7, 11, minute),
    );

void main() {
  late MemoryBox disk;
  late MemoryBox markBox;
  late Clock clock;
  late PodcastProgressStore store;
  late FakeServer server;
  late PodcastSync sync;

  setUp(() {
    disk = MemoryBox();
    markBox = MemoryBox();
    clock = Clock();
    store = PodcastProgressStore(disk, clock: clock.call);
    server = FakeServer();
    sync = PodcastSync(store, server, markBox);
  });

  group('wire format', () {
    test('request: URL and guid from key, rest matches record', () {
      expect(podcastToWire({k('ep-1'): at(60000, done: true, minute: 5)}), {
        'items': [
          {
            'feed_url': feed,
            'guid': 'ep-1',
            'position_ms': 60000,
            'done': true,
            'updated_at': '2026-10-07T11:05:00.000Z',
          },
        ],
      });
      expect(podcastToWire({}), {'items': <Object?>[]});
    });

    test('newline in episode id: trimmed at first newline', () {
      final wire = podcastToWire({podcastEpisodeKey(feed, 'a\nb'): at(1)});
      final item = (wire['items']! as List).single as Map;
      expect(item['feed_url'], feed);
      expect(item['guid'], 'a\nb');
    });

    test('key without URL or guid is not included in request', () {
      final wire = podcastToWire({
        'нет-перевода-строки': at(1),
        '\nguid': at(2),
        '$feed\n': at(3),
        k('ok'): at(4),
      });
      expect((wire['items']! as List).length, 1);
    });

    test('response: round trip', () {
      final items = {k('a'): at(5), k('b'): at(7, done: true, minute: 3)};
      expect(podcastFromWire(podcastToWire(items)), items);
    });

    test('malformed response: empty, no exceptions', () {
      for (final raw in <Object?>[
        null,
        'x',
        5,
        <Object?>[],
        <String, Object?>{},
        {'items': null},
        {'items': 'ab'},
        {'items': <String, Object?>{}},
      ]) {
        expect(podcastFromWire(raw), isEmpty, reason: '$raw');
      }
    });

    test('malformed record is skipped, remaining kept', () {
      Map<String, Object?> item(String guid, [Map<String, Object?>? over]) => {
        'feed_url': feed,
        'guid': guid,
        'position_ms': 5,
        'done': false,
        'updated_at': '2026-10-07T11:00:00.000Z',
        ...?over,
      };
      final got = podcastFromWire({
        'items': [
          item('first'),
          null,
          'x',
          item('', null),
          item('g1', {'feed_url': ''}),
          item('g2', {'feed_url': 7}),
          item('g3', {'feed_url': 'a\nb'}),
          item('g4', {'guid': 7}),
          item('g5', {'position_ms': -1}),
          item('g6', {'position_ms': '5'}),
          item('g7', {'done': 1}),
          item('g8', {'updated_at': '2026-10-07T11:00:00'}),
          item('g9', {'updated_at': 'вчера'}),
          item('last'),
        ],
      });
      expect(got.keys, [k('first'), k('last')]);
    });

    test('same episode twice in response: newer record kept', () {
      final got = podcastFromWire({
        'items': [
          ...(podcastToWire({k('a'): at(5, minute: 9)})['items']! as List),
          ...(podcastToWire({k('a'): at(7, minute: 2)})['items']! as List),
        ],
      });
      expect(got, {k('a'): at(5, minute: 9)});
    });

    test('...even when newer record is listed second', () {
      final got = podcastFromWire({
        'items': [
          ...(podcastToWire({k('a'): at(7, minute: 2)})['items']! as List),
          ...(podcastToWire({k('a'): at(5, minute: 9)})['items']! as List),
        ],
      });
      expect(got, {k('a'): at(5, minute: 9)});
    });
  });

  group('sync push', () {
    test('accumulated changes sent and dequeued', () async {
      await store.report(k('a'), 60000, durationMs: hour);
      await store.report(k('b'), 90000, durationMs: hour);
      expect(await sync.run(), PodcastSyncResult.done);
      expect(server.rows.keys.toSet(), {k('a'), k('b')});
      expect(server.rows[k('a')], store.of(k('a')));
      expect(store.pending(), isEmpty);
      expect(server.puts.length, 1);
    });

    test('nothing to send: no push request', () async {
      expect(await sync.run(), PodcastSyncResult.done);
      expect(server.puts, isEmpty);
      expect(server.asked, [0]);
    });

    test('push first, then pull changes', () async {
      await store.report(k('a'), 60000, durationMs: hour);
      await sync.run();
      expect(server.log.first, 'put');
      expect(server.log.last, 'changes');
    });

    test('larger than batch: multiple requests up to 500', () async {
      final many = {
        for (var n = 0; n < 1201; n++) k('g$n'): at(n + 1, minute: n % 50),
      };
      await store.applyRemote(many);
      for (final key in many.keys) {
        await store.markDone(key);
      }
      expect(store.pending().length, 1201);
      expect(await sync.run(), PodcastSyncResult.done);
      expect(server.puts.map((p) => p.length), [500, 500, 201]);
      expect(server.rows.length, 1201);
      expect(store.pending(), isEmpty);
      expect(PodcastSync.batch, 500);
    });

    test('network error: queue untouched, result failed', () async {
      await store.report(k('a'), 60000, durationMs: hour);
      server.failPut = true;
      expect(await sync.run(), PodcastSyncResult.failed);
      expect(store.pending().keys, [k('a')]);
      expect(server.asked, isEmpty);
      server.failPut = false;
      expect(await sync.run(), PodcastSyncResult.done);
      expect(store.pending(), isEmpty);
    });

    test('failure on second batch: first dequeued, second queued', () async {
      final many = {for (var n = 0; n < 700; n++) k('g$n'): at(n + 1)};
      await store.applyRemote(many);
      for (final key in many.keys) {
        await store.markDone(key);
      }
      server.failPutAfter = 1;
      expect(await sync.run(), PodcastSyncResult.failed);
      expect(store.pending().length, 200);
      expect(server.rows.length, 500);
    });

    test('record changed during push remains in queue', () async {
      await store.report(k('a'), 60000, durationMs: hour);
      server.putGate = Completer<void>();
      final running = sync.run();
      await pumpEventQueue();
      clock.tick(const Duration(seconds: 30));
      await store.report(k('a'), 90000, durationMs: hour, force: true);
      server.putGate!.complete();
      expect(await running, PodcastSyncResult.done);
      expect(store.of(k('a'))!.positionMs, 90000);
      expect(store.pending().keys, [k('a')]);
      server.putGate = null;
      await sync.run();
      expect(server.rows[k('a')]!.positionMs, 90000);
      expect(store.pending(), isEmpty);
    });

    test('server has newer record: device adopts it', () async {
      await store.report(k('a'), 60000, durationMs: hour);
      final theirs = EpisodeProgress(
        positionMs: 1800000,
        done: false,
        updatedAt: clock.now.add(const Duration(minutes: 1)),
      );
      server.seed(k('a'), theirs);
      expect(await sync.run(), PodcastSyncResult.done);
      expect(store.of(k('a')), theirs);
      expect(store.pending(), isEmpty);
    });

    test('push response is applied directly without pull', () async {
      await store.report(k('a'), 60000, durationMs: hour);
      final theirs = EpisodeProgress(
        positionMs: 1800000,
        done: false,
        updatedAt: clock.now.add(const Duration(minutes: 1)),
      );
      server.seed(k('a'), theirs);
      server.failChanges = true;
      expect(await sync.run(), PodcastSyncResult.failed);
      expect(store.of(k('a')), theirs);
      expect(store.pending(), isEmpty);
    });

    test('server rejected record: still dequeued', () async {
      await store.report(k('a'), 60000, durationMs: hour);
      await store.report(k('b'), 60000, durationMs: hour);
      server.refuse.add(k('a'));
      expect(await sync.run(), PodcastSyncResult.done);
      expect(store.pending(), isEmpty);
      expect(store.of(k('a'))!.positionMs, 60000);
      await sync.run();
      expect(server.puts.length, 1);
    });
  });

  group('pull changes', () {
    test('foreign records arrive without entering push queue', () async {
      server.seed(k('a'), at(5));
      server.seed(k('b'), at(7, done: true));
      expect(await sync.run(), PodcastSyncResult.done);
      expect(store.of(k('a')), at(5));
      expect(store.of(k('b')), at(7, done: true));
      expect(store.pending(), isEmpty);
    });

    test('cursor remembered, subsequent sync requests after it', () async {
      server.seed(k('a'), at(5));
      server.seed(k('b'), at(7));
      await sync.run();
      expect(markBox.data, '2');
      await sync.run();
      expect(server.asked.last, 2);
    });

    test('cursor read from disk once and survives restart', () async {
      markBox.data = '41';
      server.next = 41;
      server.seed(k('new'), at(5));
      await sync.run();
      await sync.run();
      expect(server.asked.first, 41);
      expect(markBox.reads, 1);
      final again = PodcastSync(store, server, markBox);
      await again.run();
      expect(server.asked.last, 42);
    });

    test('malformed cursor on disk: starts from zero', () async {
      for (final bad in ['', 'x', '-5', '1.5', ' ']) {
        markBox.data = bad;
        server.asked.clear();
        await PodcastSync(store, server, MemoryBox()..data = bad).run();
        expect(server.asked.first, 0, reason: bad);
      }
      final broken = MemoryBox()..failRead = true;
      server.asked.clear();
      expect(
        await PodcastSync(store, server, broken).run(),
        PodcastSyncResult.done,
      );
      expect(server.asked.first, 0);
    });

    test('changes arrive page by page until empty', () async {
      for (var n = 0; n < 7; n++) {
        server.seed(k('g$n'), at(n + 1));
      }
      server.pageSize = 3;
      expect(await sync.run(), PodcastSyncResult.done);
      expect(server.asked, [0, 3, 6, 7]);
      expect(store.of(k('g6')), at(7));
      expect(markBox.data, '7');
    });

    test('pages per sync capped at maxPages', () async {
      for (var n = 0; n < 60; n++) {
        server.seed(k('g$n'), at(n + 1));
      }
      server.pageSize = 1;
      expect(await sync.run(), PodcastSyncResult.done);
      expect(server.asked.length, PodcastSync.maxPages);
      expect(PodcastSync.maxPages, 50);
      await sync.run();
      expect(store.of(k('g59')), at(60));
    });

    test('server returns same cursor with records: no infinite loop', () async {
      final stuck = _StuckPort({k('a'): at(5)});
      expect(
        await PodcastSync(store, stuck, markBox).run(),
        PodcastSyncResult.done,
      );
      expect(stuck.calls, 1);
      expect(store.of(k('a')), at(5));
    });

    test('page where everything was dropped does not stop receiving', () async {
      // Server returned page, client failed to parse any records:
      // no records parsed but cursor advanced. Next page must arrive.
      final port = _ScriptPort([
        PodcastChanges(const {}, 120),
        PodcastChanges({k('a'): at(5)}, 121),
        PodcastChanges(const {}, 121),
      ]);
      expect(
        await PodcastSync(store, port, markBox).run(),
        PodcastSyncResult.done,
      );
      expect(port.asked, [0, 120, 121]);
      expect(store.of(k('a')), at(5));
      expect(markBox.data, '121');
    });

    test('equal change sets are equal as keys', () {
      final a = PodcastChanges({k('a'): at(5)}, 7);
      final b = PodcastChanges({k('a'): at(5)}, 7);
      if (a == b) expect(a.hashCode, b.hashCode);
    });

    test(
      'read failure: received data kept, cursor is last successful',
      () async {
        for (var n = 0; n < 4; n++) {
          server.seed(k('g$n'), at(n + 1));
        }
        server.pageSize = 2;
        final flaky = _FailOnCall(server, 2);
        expect(
          await PodcastSync(store, flaky, markBox).run(),
          PodcastSyncResult.failed,
        );
        expect(store.of(k('g1')), at(2));
        expect(store.of(k('g2')), isNull);
        expect(markBox.data, '2');
      },
    );

    test('cursor disk write failed: sync still done', () async {
      server.seed(k('a'), at(5));
      markBox.failWrite = true;
      expect(await sync.run(), PodcastSyncResult.done);
      expect(store.of(k('a')), at(5));
      await sync.run();
      expect(server.asked.last, 1);
    });

    test('local record newer than remote: local kept and sent', () async {
      server.seed(k('a'), at(5, minute: 1));
      await store.report(k('a'), 60000, durationMs: hour);
      await sync.run();
      expect(store.of(k('a'))!.positionMs, 60000);
      expect(server.rows[k('a')]!.positionMs, 60000);
    });
  });

  group('concurrency and logout', () {
    test('second run while first runs: reuses same sync', () async {
      await store.report(k('a'), 60000, durationMs: hour);
      server.putGate = Completer<void>();
      final first = sync.run();
      final second = sync.run();
      await pumpEventQueue();
      server.putGate!.complete();
      expect(await first, PodcastSyncResult.done);
      expect(await second, PodcastSyncResult.done);
      expect(server.puts.length, 1);
      server.putGate = null;
      final asked = server.asked.length;
      await sync.run();
      expect(server.asked.length, greaterThan(asked));
      expect(server.puts.length, 1);
    });

    test('after failure next run starts over', () async {
      server.failChanges = true;
      expect(await sync.run(), PodcastSyncResult.failed);
      server.failChanges = false;
      expect(await sync.run(), PodcastSyncResult.done);
    });

    test('reset clears cursor', () async {
      server.seed(k('a'), at(5));
      await sync.run();
      expect(markBox.data, '1');
      await sync.reset();
      expect(markBox.data, '0');
      final asked = server.asked.length;
      await sync.run();
      expect(server.asked[asked], 0);
    });

    test('reset on disk failure does not throw', () async {
      markBox.failWrite = true;
      await sync.reset();
      await sync.run();
      expect(server.asked.last, 0);
    });

    test('logout during push: server response not applied', () async {
      await store.report(k('a'), 60000, durationMs: hour);
      server.seed(k('other'), at(5));
      server.putGate = Completer<void>();
      final running = sync.run();
      await pumpEventQueue();
      await store.clear();
      await sync.reset();
      await store.restore();
      server.putGate!.complete();
      expect(await running, PodcastSyncResult.stale);
      expect(store.of(k('a')), isNull);
      expect(store.of(k('other')), isNull);
      expect(server.asked, isEmpty);
      expect(markBox.data, '0');
    });

    test(
      'logout during pull: page not applied, cursor resets to zero',
      () async {
        server.seed(k('a'), at(5));
        server.changesGate = Completer<void>();
        final running = sync.run();
        await pumpEventQueue();
        await store.clear();
        await sync.reset();
        await store.restore();
        server.changesGate!.complete();
        expect(await running, PodcastSyncResult.stale);
        expect(store.of(k('a')), isNull);
        expect(markBox.data, '0');
        server.changesGate = null;
        final asked = server.asked.length;
        await sync.run();
        expect(server.asked[asked], 0);
        expect(store.of(k('a')), at(5));
      },
    );

    test('simultaneous logout and network failure: stale not failed', () async {
      await store.report(k('a'), 60000, durationMs: hour);
      server.putGate = Completer<void>();
      server.failPut = true;
      final running = sync.run();
      await pumpEventQueue();
      await sync.reset();
      server.putGate!.complete();
      expect(await running, PodcastSyncResult.stale);
    });

    test('new sync works after logout', () async {
      server.changesGate = Completer<void>();
      final running = sync.run();
      await pumpEventQueue();
      await sync.reset();
      server.changesGate!.complete();
      await running;
      server.changesGate = null;
      server.seed(k('a'), at(5));
      expect(await sync.run(), PodcastSyncResult.done);
      expect(store.of(k('a')), at(5));
    });
  });

  test('module makes no direct network calls and writes no logs', () {
    final src = File('lib/podcast_sync.dart').readAsStringSync();
    for (final word in [
      'package:http',
      'dart:io',
      'print(',
      'debugPrint',
      'developer',
      'server_api',
    ]) {
      expect(src.contains(word), isFalse, reason: word);
    }
  });
}

class _StuckPort implements PodcastSyncPort {
  _StuckPort(this.items);
  final Map<String, EpisodeProgress> items;
  int calls = 0;

  @override
  Future<Map<String, EpisodeProgress>> put(
    Map<String, EpisodeProgress> items,
  ) async => items;

  @override
  Future<PodcastChanges> changes(int after) async {
    calls++;
    return PodcastChanges(items, after);
  }
}

class _ScriptPort implements PodcastSyncPort {
  _ScriptPort(this.pages);
  final List<PodcastChanges> pages;
  final List<int> asked = [];

  @override
  Future<Map<String, EpisodeProgress>> put(
    Map<String, EpisodeProgress> items,
  ) async => items;

  @override
  Future<PodcastChanges> changes(int after) async {
    asked.add(after);
    return asked.length <= pages.length
        ? pages[asked.length - 1]
        : PodcastChanges(const {}, after);
  }
}

class _FailOnCall implements PodcastSyncPort {
  _FailOnCall(this.inner, this.failOn);
  final PodcastSyncPort inner;
  final int failOn;
  int calls = 0;

  @override
  Future<Map<String, EpisodeProgress>> put(
    Map<String, EpisodeProgress> items,
  ) => inner.put(items);

  @override
  Future<PodcastChanges> changes(int after) {
    if (++calls == failOn) throw const SocketException('down');
    return inner.changes(after);
  }
}
