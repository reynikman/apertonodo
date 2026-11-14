// FT-676 (P-A99, contracts D5 and D5a): audiobooks — progress sync
// between phone and server.
//
// Phone store (FT-674) queues records that have not been sent yet. This module
// runs one sync cycle: first uploads queued records, then fetches
// server changes page by page while cursor advances. No network inside: wired
// by lead via `BookSyncPort`.
//
// Contract `lib/book_sync.dart`:
// - `BookSyncPage(items, mark)`;
// - `abstract class BookSyncPort { put(batch); changes(after); }`;
// - `enum BookSyncResult { done, failed, stale }`;
// - `BookSync(store, port, markBox)`: `run()`, `reset()`, `mark`;
//   `BookSync.batch == 500`, `BookSync.maxPages == 50`.
//
// Guarded:
// - record modified by player while batch was in flight remains in queue;
// - logout in the middle of sync: no records of previous user enter
//   local store afterwards, cursor does not revert;
// - server restored from backup (cursor lower than phone cursor): phone
//   restarts from zero automatically rather than staying silent forever;
// - server returning the same page repeatedly does not loop sync forever;
// - no exceptions escape `run()`.
//
// What test does not prove: real network, server, and disk are absent; when
// to trigger sync (pause, backgrounding, timer) is decided by wiring.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/book_position.dart';
import 'package:music_stream/book_progress.dart';
import 'package:music_stream/book_sync.dart';

class MemoryBox implements BookProgressBox {
  String? data;
  int writes = 0;
  bool failWrite = false;
  bool failRead = false;
  Completer<void>? readGate;
  Completer<void>? writeGate;

  MemoryBox([this.data]);

  @override
  Future<String?> read() async {
    final snapshot = data;
    if (readGate != null) await readGate!.future;
    if (failRead) throw const FileSystemException('no');
    return snapshot;
  }

  @override
  Future<void> write(String value) async {
    if (writeGate != null) await writeGate!.future;
    if (failWrite) throw const FileSystemException('full');
    writes++;
    data = value;
  }
}

class FakePort implements BookSyncPort {
  final List<Map<String, BookPosition>> sent = [];
  final List<int> asked = [];

  /// Responses to `changes` in sequence; when exhausted — empty page with same cursor.
  final List<BookSyncPage> pages = [];

  /// What server replies on upload; `null` — echoes uploaded items.
  Map<String, BookPosition>? stored;
  bool failPut = false;
  bool failChanges = false;
  int failPutFromCall = 0;
  Completer<void>? putGate;
  Completer<void>? changesGate;
  BookSyncPage Function(int after)? answer;

  @override
  Future<Map<String, BookPosition>> put(Map<String, BookPosition> batch) async {
    sent.add(Map.of(batch));
    if (putGate != null) await putGate!.future;
    if (failPut) throw const SocketException('down');
    if (failPutFromCall > 0 && sent.length >= failPutFromCall) {
      throw const SocketException('down');
    }
    return stored ?? Map.of(batch);
  }

  @override
  Future<BookSyncPage> changes(int after) async {
    asked.add(after);
    if (changesGate != null) await changesGate!.future;
    if (failChanges) throw StateError('broken');
    if (answer != null) return answer!(after);
    if (pages.isEmpty) return BookSyncPage(const {}, after);
    return pages.removeAt(0);
  }
}

String book(int n) =>
    '0b0c1d2e-0000-4000-8000-${n.toString().padLeft(12, '0')}';

final id1 = book(1);
final id2 = book(2);

BookPosition at(int part, int ms, {bool finished = false, int minute = 0}) =>
    BookPosition(
      part: part,
      positionMs: ms,
      finished: finished,
      updatedAt: DateTime.utc(2026, 10, 1, 12, minute),
    );

void main() {
  late MemoryBox disk;
  late MemoryBox markBox;
  late FakePort port;
  late BookProgressStore store;
  late BookSync sync;
  late DateTime now;

  setUp(() async {
    disk = MemoryBox();
    markBox = MemoryBox();
    port = FakePort();
    now = DateTime.utc(2026, 10, 1, 12);
    store = BookProgressStore(disk, clock: () => now);
    await store.restore();
    sync = BookSync(store, port, markBox);
  });

  test('limits match contract', () {
    expect(BookSync.batch, 500);
    expect(BookSync.maxPages, 50);
  });

  group('send', () {
    test('nothing to send: server not contacted for upload', () async {
      expect(await sync.run(), BookSyncResult.done);
      expect(port.sent, isEmpty);
      expect(port.asked, [0]);
    });

    test('accumulated items are sent and leave queue', () async {
      await store.report(id1, 3, 4000, force: true);
      await store.finish(id2);
      expect(await sync.run(), BookSyncResult.done);
      expect(port.sent.single.keys.toSet(), {id1, id2});
      expect(port.sent.single[id1], store.of(id1));
      expect(store.pending(), isEmpty);
    });

    test('send occurs before receive', () async {
      final order = <String>[];
      await store.report(id1, 3, 4000, force: true);
      port.answer = (after) {
        order.add('changes after ${port.sent.length} put');
        return BookSyncPage(const {}, after);
      };
      await sync.run();
      expect(order, ['changes after 1 put']);
    });

    test('server response is newer: phone adopts it', () async {
      await store.report(id1, 3, 4000, force: true);
      final theirs = at(7, 100, minute: 30);
      port.stored = {id1: theirs};
      expect(await sync.run(), BookSyncResult.done);
      expect(store.of(id1), theirs);
      expect(store.pending(), isEmpty);
    });

    test(
      'server did not return record: still treated as sent to cloud',
      () async {
        await store.report(id1, 3, 4000, force: true);
        port.stored = const {};
        expect(await sync.run(), BookSyncResult.done);
        expect(store.pending(), isEmpty);
        expect(store.of(id1)!.part, 3);
      },
    );

    test('send error: failed, queue remains intact, no receive', () async {
      await store.report(id1, 3, 4000, force: true);
      port.failPut = true;
      expect(await sync.run(), BookSyncResult.failed);
      expect(store.pending().keys, [id1]);
      expect(port.asked, isEmpty);
      port.failPut = false;
      expect(await sync.run(), BookSyncResult.done);
      expect(store.pending(), isEmpty);
    });

    test('player advanced during batch transit: new entry waits', () async {
      await store.report(id1, 3, 4000, force: true);
      port.putGate = Completer<void>();
      final running = sync.run();
      await Future<void>.delayed(Duration.zero);
      now = now.add(const Duration(minutes: 1));
      await store.report(id1, 4, 0);
      port.putGate!.complete();
      port.putGate = null;
      expect(await running, BookSyncResult.done);
      expect(store.pending().keys, [id1]);
      expect(store.of(id1)!.part, 4);
      expect(await sync.run(), BookSyncResult.done);
      expect(port.sent.last[id1]!.part, 4);
      expect(store.pending(), isEmpty);
    });

    test('large queue is sent in batches up to limit', () async {
      await store.applyRemote({for (var n = 0; n < 10; n++) book(n): at(1, 0)});
      for (var n = 0; n < BookSync.batch + 20; n++) {
        await store.finish(book(n));
      }
      expect(await sync.run(), BookSyncResult.done);
      expect(port.sent.map((batch) => batch.length), [BookSync.batch, 20]);
      expect(store.pending(), isEmpty);
    });

    test('second batch failed: first is already removed', () async {
      for (var n = 0; n < BookSync.batch + 20; n++) {
        await store.finish(book(n));
      }
      port.failPutFromCall = 2;
      expect(await sync.run(), BookSyncResult.failed);
      expect(store.pending(), hasLength(20));
      expect(port.asked, isEmpty);
    });
  });

  group('receive', () {
    test('changes applied to cache, timestamp remembered', () async {
      port.pages.add(BookSyncPage({id1: at(5, 9000)}, 42));
      expect(await sync.run(), BookSyncResult.done);
      expect(store.of(id1), at(5, 9000));
      expect(store.pending(), isEmpty);
      expect(sync.mark, 42);
      expect(markBox.data, '42');
      expect(port.asked, [0, 42]);
    });

    test('pages fetched while timestamp increases', () async {
      port.pages.addAll([
        BookSyncPage({id1: at(1, 10)}, 10),
        BookSyncPage({id2: at(2, 20)}, 20),
        BookSyncPage(const {}, 20),
      ]);
      expect(await sync.run(), BookSyncResult.done);
      expect(port.asked, [0, 10, 20]);
      expect(store.of(id1), at(1, 10));
      expect(store.of(id2), at(2, 20));
      expect(markBox.data, '20');
    });

    test('empty page with advanced timestamp is not end', () async {
      port.pages.addAll([
        BookSyncPage(const {}, 10),
        BookSyncPage({id1: at(1, 10)}, 20),
      ]);
      expect(await sync.run(), BookSyncResult.done);
      expect(store.of(id1), at(1, 10));
      expect(sync.mark, 20);
    });

    test('entries with same timestamp are also accepted', () async {
      port.pages.add(BookSyncPage({id1: at(1, 10)}, 0));
      expect(await sync.run(), BookSyncResult.done);
      expect(store.of(id1), at(1, 10));
      expect(port.asked, [0]);
      expect(markBox.writes, 0);
    });

    test('local entry newer than server: local is kept', () async {
      now = DateTime.utc(2026, 10, 1, 13);
      await store.report(id1, 8, 0, force: true);
      port.failPut = true;
      await sync.run();
      port.failPut = false;
      port.stored = const {};
      port.pages.add(BookSyncPage({id1: at(2, 0)}, 5));
      expect(await sync.run(), BookSyncResult.done);
      expect(store.of(id1)!.part, 8);
    });

    test('receive failure: failed, timestamp unchanged', () async {
      port.pages.add(BookSyncPage({id1: at(1, 10)}, 10));
      await sync.run();
      port.failChanges = true;
      expect(await sync.run(), BookSyncResult.failed);
      expect(sync.mark, 10);
      expect(markBox.data, '10');
    });

    test('server repeats same page: sync loop terminates', () async {
      port.answer = (after) => BookSyncPage({id1: at(1, 10)}, 10);
      expect(await sync.run(), BookSyncResult.done);
      expect(port.asked, [0, 10]);
    });

    test(
      'pages per round capped at limit: continuation in next cycle',
      () async {
        port.answer = (after) => BookSyncPage(const {}, after + 1);
        expect(await sync.run(), BookSyncResult.done);
        expect(port.asked, hasLength(BookSync.maxPages));
        expect(sync.mark, BookSync.maxPages);
        expect(await sync.run(), BookSyncResult.done);
        expect(port.asked[BookSync.maxPages], BookSync.maxPages);
      },
    );

    test('timestamp disk write failed: sync still succeeds', () async {
      markBox.failWrite = true;
      port.pages.add(BookSyncPage({id1: at(1, 10)}, 10));
      expect(await sync.run(), BookSyncResult.done);
      expect(sync.mark, 10);
      expect(port.asked, [0, 10]);
    });
  });

  group('mark', () {
    test('read from disk exactly once', () async {
      markBox.data = ' 17\n';
      expect(await sync.run(), BookSyncResult.done);
      expect(port.asked, [17]);
      markBox.data = '99';
      await sync.run();
      expect(port.asked, [17, 17]);
    });

    test('corrupted, negative or read error starts from zero', () async {
      for (final raw in ['abc', '-5', '', '1.5']) {
        final fresh = FakePort();
        await BookSync(store, fresh, MemoryBox(raw)).run();
        expect(fresh.asked, [0], reason: raw);
      }
      final fresh = FakePort();
      final broken = MemoryBox('7')..failRead = true;
      expect(await BookSync(store, fresh, broken).run(), BookSyncResult.done);
      expect(fresh.asked, [0]);
    });

    test(
      'server rolled back: timestamp below client starts from zero',
      () async {
        markBox.data = '100';
        port.answer = (after) => after == 100
            ? const BookSyncPage({}, 30)
            : BookSyncPage({id1: at(6, 0)}, 30);
        expect(await sync.run(), BookSyncResult.done);
        expect(port.asked, [100, 0, 30]);
        expect(store.of(id1), at(6, 0));
        expect(sync.mark, 30);
        expect(markBox.data, '30');
      },
    );

    test(
      'timestamp always below requested: failed rather than infinite loop',
      () async {
        markBox.data = '100';
        port.answer = (after) => BookSyncPage(const {}, after - 1);
        expect(await sync.run(), BookSyncResult.failed);
        expect(port.asked, [100, 0]);
      },
    );
  });

  group('single sync at a time', () {
    test('second call during first shares identical sync', () async {
      port.changesGate = Completer<void>();
      final first = sync.run();
      final second = sync.run();
      expect(identical(first, second), isTrue);
      port.changesGate!.complete();
      port.changesGate = null;
      expect(await first, BookSyncResult.done);
      expect(port.asked, [0]);
    });

    test('after completion initiates new sync', () async {
      await sync.run();
      await sync.run();
      expect(port.asked, [0, 0]);
    });

    test('exceptions are not escaped outwards', () async {
      port.failChanges = true;
      expect(await sync.run(), BookSyncResult.failed);
      await store.report(id1, 1, 0, force: true);
      port.failPut = true;
      expect(await sync.run(), BookSyncResult.failed);
    });
  });

  group('account sign out', () {
    test('reset clears timestamp in memory and on disk', () async {
      port.pages.add(BookSyncPage({id1: at(1, 10)}, 10));
      await sync.run();
      await sync.reset();
      expect(sync.mark, 0);
      expect(markBox.data, '0');
      await sync.run();
      expect(port.asked.last, 0);
    });

    test('reset does not fail when disk write fails', () async {
      markBox.failWrite = true;
      await sync.reset();
      expect(sync.mark, 0);
    });

    test(
      'reset before first sync: old timestamp from disk is not read',
      () async {
        markBox.data = '55';
        markBox.failWrite = true;
        await sync.reset();
        await sync.run();
        expect(port.asked, [0]);
      },
    );

    test(
      'sign out during receive is stale: foreign items not cached',
      () async {
        port.changesGate = Completer<void>();
        port.pages.add(BookSyncPage({id1: at(5, 9000)}, 42));
        final running = sync.run();
        await Future<void>.delayed(Duration.zero);
        await store.clear();
        await sync.reset();
        await store.restore();
        port.changesGate!.complete();
        port.changesGate = null;
        expect(await running, BookSyncResult.stale);
        expect(store.of(id1), isNull);
        expect(sync.mark, 0);
        expect(markBox.data, '0');
      },
    );

    test('sign out during send is stale: no receive initiated', () async {
      await store.report(id1, 3, 4000, force: true);
      port.putGate = Completer<void>();
      port.stored = {id2: at(9, 0)};
      final running = sync.run();
      await Future<void>.delayed(Duration.zero);
      await store.clear();
      await sync.reset();
      await store.restore();
      port.putGate!.complete();
      port.putGate = null;
      expect(await running, BookSyncResult.stale);
      expect(store.of(id2), isNull);
      expect(port.asked, isEmpty);
    });

    test('sign out during failed request: stale rather than failed', () async {
      port.changesGate = Completer<void>();
      port.failChanges = true;
      final running = sync.run();
      await Future<void>.delayed(Duration.zero);
      await sync.reset();
      port.changesGate!.complete();
      expect(await running, BookSyncResult.stale);
    });

    test(
      'sign out during timestamp read: old timestamp not restored',
      () async {
        markBox.data = '77';
        markBox.readGate = Completer<void>();
        final running = sync.run();
        await Future<void>.delayed(Duration.zero);
        await sync.reset();
        markBox.readGate!.complete();
        markBox.readGate = null;
        expect(await running, BookSyncResult.stale);
        expect(sync.mark, 0);
        expect(port.asked, isEmpty);
      },
    );

    test('after sign out new sync does not wait for old', () async {
      port.changesGate = Completer<void>();
      final old = sync.run();
      await Future<void>.delayed(Duration.zero);
      await sync.reset();
      final gate = port.changesGate!;
      port.changesGate = null;
      final fresh = sync.run();
      expect(identical(old, fresh), isFalse);
      expect(await fresh, BookSyncResult.done);
      gate.complete();
      expect(await old, BookSyncResult.stale);
      final again = sync.run();
      expect(await again, BookSyncResult.done);
    });

    test('completed old sync does not cancel running new sync', () async {
      port.changesGate = Completer<void>();
      final old = sync.run();
      await Future<void>.delayed(Duration.zero);
      await sync.reset();
      final oldGate = port.changesGate!;
      port.changesGate = Completer<void>();
      final fresh = sync.run();
      await Future<void>.delayed(Duration.zero);
      oldGate.complete();
      await old;
      expect(identical(sync.run(), fresh), isTrue);
      port.changesGate!.complete();
      port.changesGate = null;
      await fresh;
    });
  });

  group('no unnecessary side effects', () {
    test('page does not print raw payload data', () {
      expect(BookSyncPage({id1: at(1, 1)}, 5).toString(), 'BookSyncPage');
    });

    test('module does not access network directly or log', () {
      final source = File('lib/book_sync.dart').readAsStringSync();
      for (final banned in [
        'dart:io',
        'package:http',
        'print(',
        'debugPrint',
        'dart:developer',
      ]) {
        expect(source.contains(banned), isFalse, reason: banned);
      }
    });
  });
}
