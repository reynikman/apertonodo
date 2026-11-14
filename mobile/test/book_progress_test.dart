// FT-674 (P-A99, contract D5): local store of book progress positions and playback speeds.
//
// Single record rules already exist (FT-670, `lib/book_position.dart`). Here is
// store on top of them: remembers position and speed of each book, survives
// restart, works offline, and holds queue of records waiting to be synced to
// server. Designed like podcast progress store (FT-656), with different key and payload.
//
// Contract `lib/book_progress.dart`:
// - `bookSpeeds`, `nearestBookSpeed(v)`;
// - `BookProgressBox { read(), write(data) }`;
// - `BookProgressStore(box, clock:)` — `ChangeNotifier`: `restore`, `of`,
//   `report(bookId, part, positionMs, force:)`, `finish`, `restart`, `speedOf`,
//   `setSpeed`, `pending`, `ack`, `applyRemote`, `flush`, `clear`;
//   `maxBooks = 5000`, `saveEvery = 5 s`.
//
// Guarded:
// - position in memory — immediately, to disk — at most once every five seconds, but pause,
//   part change, and "finished" write immediately;
// - out of two records for same book, later one wins (`newerBookPosition`);
// - phone clock set backwards — newer position is still considered newer;
// - logout (`clear`) resets store: delayed player report does not restore
//   records of previous user;
// - disk write failure does not crash player and is retried.
//
// What test does not prove: real disk and real player are absent; when to
// trigger sync (pause, backgrounding, timer) is decided by wiring.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/book_position.dart';
import 'package:music_stream/book_progress.dart';

class MemoryBox implements BookProgressBox {
  String? data;
  int writes = 0;
  bool failWrite = false;
  bool failRead = false;
  Completer<void>? gate;
  Completer<void>? readGate;

  @override
  Future<String?> read() async {
    // Disk returns what was on it at read time, even if response was delayed.
    final snapshot = data;
    if (readGate != null) await readGate!.future;
    if (failRead) throw const FileSystemException('no');
    return snapshot;
  }

  @override
  Future<void> write(String value) async {
    if (gate != null) await gate!.future;
    if (failWrite) throw const FileSystemException('full');
    writes++;
    data = value;
  }
}

/// First write waits for gate, subsequent ones pass immediately.
class SlowFirstBox implements BookProgressBox {
  final Completer<void> gate = Completer<void>();
  String? data;
  int calls = 0;

  @override
  Future<String?> read() async => data;

  @override
  Future<void> write(String value) async {
    if (calls++ == 0) await gate.future;
    data = value;
  }
}

class Clock {
  DateTime now = DateTime.utc(2026, 10, 7, 12);
  DateTime call() => now;
  void tick(Duration d) => now = now.add(d);
}

BookPosition at(int part, int ms, {bool finished = false, int minute = 0}) =>
    BookPosition(
      part: part,
      positionMs: ms,
      finished: finished,
      updatedAt: DateTime.utc(2026, 10, 7, 12, minute),
    );

const book = '0b0c1d2e-0000-4000-8000-000000000001';
const other = '0b0c1d2e-0000-4000-8000-000000000002';

void main() {
  late MemoryBox box;
  late Clock clock;
  late BookProgressStore store;

  setUp(() {
    box = MemoryBox();
    clock = Clock();
    store = BookProgressStore(box, clock: clock.call);
  });

  Map<String, Object?> saved() => jsonDecode(box.data!) as Map<String, Object?>;
  Map savedBook(String id) => (saved()['books'] as Map)[id] as Map;
  BookProgressStore reopened() => BookProgressStore(box, clock: clock.call);

  group('speed', () {
    test('the same steps as podcasts', () {
      expect(bookSpeeds, [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]);
    });

    test('nearest allowed', () {
      expect(nearestBookSpeed(1.3), 1.25);
      expect(nearestBookSpeed(1.0), 1.0);
      expect(nearestBookSpeed(0.1), 0.5);
      expect(nearestBookSpeed(-4), 0.5);
      expect(nearestBookSpeed(9), 3.0);
      expect(nearestBookSpeed(2.2), 2.0);
      expect(nearestBookSpeed(2.3), 2.5);
      expect(nearestBookSpeed(1.125), 1.0);
      expect(nearestBookSpeed(double.nan), 1.0);
      expect(nearestBookSpeed(double.infinity), 1.0);
      expect(nearestBookSpeed(double.negativeInfinity), 1.0);
    });

    test('each book has distinct speed, default is normal', () async {
      expect(store.speedOf(book), 1.0);
      await store.setSpeed(book, 1.6);
      expect(store.speedOf(book), 1.5);
      expect(store.speedOf(other), 1.0);
    });

    test('speed persists across restarts', () async {
      await store.setSpeed(book, 2.0);
      final again = reopened();
      await again.restore();
      expect(again.speedOf(book), 2.0);
    });

    test('same speed: neither disk write nor notification', () async {
      var notified = 0;
      store.addListener(() => notified++);
      await store.setSpeed(book, 1.0);
      expect(box.writes, 0);
      expect(notified, 0);
      await store.setSpeed(book, 1.5);
      await store.setSpeed(book, 1.5);
      expect(box.writes, 1);
      expect(notified, 1);
    });

    test('resetting to normal speed writes to disk', () async {
      await store.setSpeed(book, 2.0);
      await store.setSpeed(book, 1.0);
      expect(saved()['speeds'], isEmpty);
      final again = reopened();
      await again.restore();
      expect(again.speedOf(book), 1.0);
    });

    test('playback speed change does not enqueue sync item', () async {
      await store.setSpeed(book, 2.0);
      expect(store.pending(), isEmpty);
      expect(store.of(book), isNull);
    });

    test('invalid speed in cache normalized or discarded', () async {
      box.data = jsonEncode({
        'v': 1,
        'books': <String, Object?>{},
        'speeds': {book: 1.6, other: 'быстро', 'x': 1.0, 'y': 99},
        'dirty': <Object?>[],
      });
      await store.restore();
      expect(store.speedOf(book), 1.5);
      expect(store.speedOf(other), 1.0);
      expect(store.speedOf('y'), 3.0);
    });
  });

  group('progress report', () {
    test('saved in memory and enqueued for sync', () async {
      await store.report(book, 3, 60000);
      expect(
        store.of(book),
        BookPosition(
          part: 3,
          positionMs: 60000,
          finished: false,
          updatedAt: clock.now,
        ),
      );
      expect(store.pending(), {book: store.of(book)});
      expect(store.of(other), isNull);
    });

    test('persists across restart alongside sync queue', () async {
      await store.report(book, 3, 60000);
      final again = reopened();
      await again.restore();
      expect(again.of(book), store.of(book));
      expect(again.pending().keys, [book]);
    });

    test('invalid part index and offset are rejected', () async {
      await store.report(book, 0, 1000);
      await store.report(book, -1, 1000);
      await store.report(book, maxBookParts + 1, 1000);
      await store.report(book, 1, -1);
      await store.report(book, 1, maxBookPartMs + 1);
      expect(store.of(book), isNull);
      expect(store.pending(), isEmpty);
      expect(box.writes, 0);
    });

    test('boundary values accepted', () async {
      await store.report(book, maxBookParts, maxBookPartMs);
      expect(store.of(book)!.part, maxBookParts);
      expect(store.of(book)!.positionMs, maxBookPartMs);
      await store.report(other, 1, 0);
      expect(store.of(other)!.positionMs, 0);
    });

    test(
      'flush to disk at most every five seconds, memory updated at once',
      () async {
        await store.report(book, 2, 60000);
        expect(box.writes, 1);
        for (var s = 1; s <= 4; s++) {
          clock.tick(const Duration(seconds: 1));
          await store.report(book, 2, 60000 + s * 1000);
        }
        expect(box.writes, 1);
        expect(store.of(book)!.positionMs, 64000);
        clock.tick(const Duration(seconds: 1));
        await store.report(book, 2, 65000);
        expect(box.writes, 2);
        expect(savedBook(book)['position_ms'], 65000);
      },
    );

    test(
      'five second throttle measured from disk write across all books',
      () async {
        await store.report(book, 1, 1000);
        clock.tick(const Duration(seconds: 3));
        await store.report(book, 1, 4000, force: true);
        expect(box.writes, 2);
        clock.tick(const Duration(seconds: 3));
        await store.report(book, 1, 7000);
        expect(box.writes, 2);
        clock.tick(const Duration(seconds: 2));
        await store.report(book, 1, 9000);
        expect(box.writes, 3);
      },
    );

    test('first progress report after launch writes immediately', () async {
      await store.report(book, 2, 60000);
      final again = reopened();
      await again.restore();
      final writes = box.writes;
      clock.tick(const Duration(seconds: 1));
      await again.report(book, 2, 61000);
      expect(box.writes, writes + 1);
      expect(savedBook(book)['position_ms'], 61000);
    });

    test('pause (force) and flush trigger immediate write', () async {
      await store.report(book, 2, 60000);
      clock.tick(const Duration(seconds: 1));
      await store.report(book, 2, 61000, force: true);
      expect(box.writes, 2);
      clock.tick(const Duration(seconds: 1));
      await store.report(book, 2, 62000);
      expect(box.writes, 2);
      expect(await store.flush(), isTrue);
      expect(box.writes, 3);
      expect(savedBook(book)['position_ms'], 62000);
      expect(await store.flush(), isTrue);
      expect(box.writes, 3);
    });

    test('part transition writes immediately without waiting 5s', () async {
      await store.report(book, 2, 60000);
      clock.tick(const Duration(seconds: 1));
      await store.report(book, 3, 0);
      expect(box.writes, 2);
      expect(savedBook(book)['part'], 3);
      clock.tick(const Duration(seconds: 1));
      await store.report(book, 2, 500);
      expect(box.writes, 3);
      expect(savedBook(book)['part'], 2);
    });

    test(
      'notifies on new book and part transition, not on every second',
      () async {
        var notified = 0;
        store.addListener(() => notified++);
        await store.report(book, 2, 60000);
        expect(notified, 1);
        clock.tick(const Duration(seconds: 10));
        await store.report(book, 2, 70000);
        expect(notified, 1);
        await store.report(book, 3, 0);
        expect(notified, 2);
        await store.report(other, 1, 0);
        expect(notified, 3);
      },
    );

    test('write error does not drop report, retried on flush', () async {
      box.failWrite = true;
      await store.report(book, 2, 60000);
      expect(store.of(book)!.positionMs, 60000);
      expect(box.data, isNull);
      expect(await store.flush(), isFalse);
      box.failWrite = false;
      expect(await store.flush(), isTrue);
      expect(savedBook(book)['position_ms'], 60000);
    });

    test('consecutive reports batched into single disk write', () async {
      final first = store.report(book, 1, 1000, force: true);
      final second = store.report(other, 1, 2000, force: true);
      await Future.wait([first, second]);
      expect(box.writes, 1);
      expect((saved()['books'] as Map).keys.toSet(), {book, other});
    });

    test('flush awaits in-flight write and notifies if it failed', () async {
      box.gate = Completer<void>();
      box.failWrite = true;
      final report = store.report(book, 1, 1000, force: true);
      await Future<void>.delayed(Duration.zero);
      final flushed = store.flush();
      box.gate!.complete();
      box.gate = null;
      expect(await flushed, isFalse);
      await report;
      box.failWrite = false;
      expect(await store.flush(), isTrue);
      expect(savedBook(book)['position_ms'], 1000);
    });

    test('reporting during failed disk write does not hang', () async {
      box.gate = Completer<void>();
      box.failWrite = true;
      final first = store.report(book, 1, 1000, force: true);
      await Future<void>.delayed(Duration.zero);
      final second = store.report(other, 1, 2000, force: true);
      final flushed = store.flush();
      box.gate!.complete();
      box.gate = null;
      await Future.wait([first, second]).timeout(const Duration(seconds: 2));
      expect(await flushed.timeout(const Duration(seconds: 2)), isFalse);
      box.failWrite = false;
      expect(await store.flush(), isTrue);
      expect((saved()['books'] as Map).keys.toSet(), {book, other});
    });

    test('sign out during failing write does not hang', () async {
      await store.report(book, 1, 1000, force: true);
      box.gate = Completer<void>();
      box.failWrite = true;
      final report = store.report(book, 2, 0);
      await Future<void>.delayed(Duration.zero);
      final cleared = store.clear();
      box.gate!.complete();
      box.gate = null;
      expect(await cleared.timeout(const Duration(seconds: 2)), isFalse);
      await report.timeout(const Duration(seconds: 2));
      box.failWrite = false;
      expect(await store.flush(), isTrue);
      expect(saved()['books'], isEmpty);
    });

    test('disk writes do not overtake each other', () async {
      box.gate = Completer<void>();
      final first = store.report(book, 2, 60000, force: true);
      clock.tick(const Duration(seconds: 1));
      final second = store.report(book, 2, 61000, force: true);
      box.gate!.complete();
      box.gate = null;
      await Future.wait([first, second]);
      expect(savedBook(book)['position_ms'], 61000);
    });

    test('slow initial write does not overwrite subsequent write', () async {
      final slow = SlowFirstBox();
      final mine = BookProgressStore(slow, clock: clock.call);
      final first = mine.report(book, 2, 60000, force: true);
      await Future<void>.delayed(Duration.zero);
      clock.tick(const Duration(seconds: 1));
      final second = mine.report(book, 2, 61000, force: true);
      await Future<void>.delayed(Duration.zero);
      slow.gate.complete();
      await Future.wait([first, second]);
      final data = jsonDecode(slow.data!) as Map<String, Object?>;
      expect(((data['books'] as Map)[book] as Map)['position_ms'], 61000);
    });
  });

  group('completed and restart', () {
    test('completed: offset retained, writes immediately', () async {
      await store.report(book, 7, 60000);
      clock.tick(const Duration(seconds: 1));
      var notified = 0;
      store.addListener(() => notified++);
      await store.finish(book);
      expect(
        store.of(book),
        BookPosition(
          part: 7,
          positionMs: 60000,
          finished: true,
          updatedAt: clock.now,
        ),
      );
      expect(notified, 1);
      expect(box.writes, 2);
      expect(savedBook(book)['finished'], isTrue);
      expect(store.pending().keys, [book]);
    });

    test('completed without prior record: part 1 from zero', () async {
      await store.finish(other);
      expect(
        store.of(other),
        BookPosition(
          part: 1,
          positionMs: 0,
          finished: true,
          updatedAt: clock.now,
        ),
      );
    });

    test('new playback clears completed and writes right away', () async {
      await store.report(book, 7, 60000);
      await store.finish(book);
      clock.tick(const Duration(seconds: 1));
      var notified = 0;
      store.addListener(() => notified++);
      await store.report(book, 7, 61000);
      expect(store.of(book)!.finished, isFalse);
      expect(store.of(book)!.positionMs, 61000);
      expect(notified, 1);
      expect(box.writes, 3);
      expect(savedBook(book)['finished'], isFalse);
    });

    test('restart: resets to part 1 from zero offset', () async {
      await store.report(book, 7, 60000);
      await store.finish(book);
      clock.tick(const Duration(minutes: 1));
      var notified = 0;
      store.addListener(() => notified++);
      await store.restart(book);
      expect(
        store.of(book),
        BookPosition(
          part: 1,
          positionMs: 0,
          finished: false,
          updatedAt: clock.now,
        ),
      );
      expect(notified, 1);
      expect(box.writes, 3);
      expect(store.pending().keys, [book]);
    });

    test('restart without existing record is written', () async {
      await store.restart(other);
      expect(store.of(other)!.part, 1);
      expect(store.pending().keys, [other]);
      expect(box.writes, 1);
    });
  });

  group('server sync dispatch', () {
    test('server ack removes item from sync queue', () async {
      await store.report(book, 2, 60000);
      await store.ack(book, store.of(book)!);
      expect(store.pending(), isEmpty);
      expect(store.of(book)!.positionMs, 60000);
      final again = reopened();
      await again.restore();
      expect(again.pending(), isEmpty);
      expect(again.of(book), store.of(book));
    });

    test('ack of stale entry does not remove newer pending item', () async {
      await store.report(book, 2, 60000);
      final sent = store.of(book)!;
      clock.tick(const Duration(seconds: 1));
      await store.report(book, 2, 61000);
      await store.ack(book, sent);
      expect(store.pending(), {book: store.of(book)});
    });

    test('ack for unknown or non-pending book is ignored', () async {
      await store.ack(other, at(1, 0));
      expect(box.writes, 0);
      await store.report(book, 2, 60000);
      await store.ack(book, store.of(book)!);
      final writes = box.writes;
      await store.ack(book, store.of(book)!);
      expect(box.writes, writes);
    });

    test('sync queue cannot be modified externally', () async {
      await store.report(book, 2, 60000);
      store.pending().clear();
      expect(store.pending().keys, [book]);
    });

    test('from server: newer entry wins without re-syncing', () async {
      await store.report(book, 2, 60000);
      var notified = 0;
      store.addListener(() => notified++);
      final remote = BookPosition(
        part: 5,
        positionMs: 1000,
        finished: false,
        updatedAt: clock.now.add(const Duration(minutes: 5)),
      );
      await store.applyRemote({book: remote});
      expect(store.of(book), remote);
      expect(store.pending(), isEmpty);
      expect(notified, 1);
      expect(savedBook(book)['part'], 5);
      expect(saved()['dirty'], isEmpty);
    });

    test('from server: older entry leaves local record intact', () async {
      await store.report(book, 2, 60000);
      final mine = store.of(book);
      final writes = box.writes;
      var notified = 0;
      store.addListener(() => notified++);
      await store.applyRemote({
        book: BookPosition(
          part: 9,
          positionMs: 1,
          finished: true,
          updatedAt: clock.now.subtract(const Duration(minutes: 5)),
        ),
      });
      expect(store.of(book), mine);
      expect(store.pending().keys, [book]);
      expect(notified, 0);
      expect(box.writes, writes);
    });

    test('from server: identical record skips write and notify', () async {
      await store.report(book, 2, 60000);
      final writes = box.writes;
      var notified = 0;
      store.addListener(() => notified++);
      await store.applyRemote({book: store.of(book)!});
      expect(store.pending().keys, [book]);
      expect(notified, 0);
      expect(box.writes, writes);
    });

    test('from server: unknown book added without queueing', () async {
      await store.applyRemote({other: at(4, 5000)});
      expect(store.of(other), at(4, 5000));
      expect(store.pending(), isEmpty);
      final again = reopened();
      await again.restore();
      expect(again.of(other), at(4, 5000));
    });

    test(
      'from server: equal timestamp uses entry rule, not foreign win',
      () async {
        await store.report(book, 2, 60000);
        final mine = store.of(book)!;
        await store.applyRemote({
          book: BookPosition(
            part: 2,
            positionMs: 100,
            finished: false,
            updatedAt: mine.updatedAt,
          ),
        });
        expect(store.of(book), mine);
        final done = BookPosition(
          part: 1,
          positionMs: 0,
          finished: true,
          updatedAt: mine.updatedAt,
        );
        await store.applyRemote({book: done});
        expect(store.of(book), done);
      },
    );
  });

  group('progress restore', () {
    test('empty and corrupted cache yields empty without errors', () async {
      for (final raw in [
        null,
        '',
        'не json',
        '[]',
        '42',
        '{"books": 5, "speeds": [], "dirty": {}}',
        '{"books": {"a": 5}, "dirty": ["a", 7]}',
      ]) {
        box.data = raw;
        final mine = reopened();
        await mine.restore();
        expect(mine.of('a'), isNull, reason: '$raw');
        expect(mine.pending(), isEmpty, reason: '$raw');
      }
    });

    test('read failure yields empty without throwing', () async {
      box.failRead = true;
      await store.restore();
      expect(store.pending(), isEmpty);
      box.failRead = false;
      await store.report(book, 1, 1000);
      expect(store.of(book)!.positionMs, 1000);
    });

    test('single corrupt line does not drop valid entries', () async {
      box.data = jsonEncode({
        'v': 1,
        'books': {
          book: at(2, 5000).toJson(),
          other: {'part': 0, 'position_ms': 1},
          'x': 'мусор',
        },
        'speeds': <String, Object?>{},
        'dirty': [book, other, 'нет такой', 5],
      });
      await store.restore();
      expect(store.of(book), at(2, 5000));
      expect(store.of(other), isNull);
      expect(store.pending().keys, [book]);
    });

    test('report before restore not overwritten by stale cache', () async {
      clock.tick(const Duration(hours: 1));
      await store.report(book, 3, 100);
      box.data = jsonEncode({
        'v': 1,
        'books': {book: at(2, 5000).toJson(), other: at(1, 7).toJson()},
        'speeds': <String, Object?>{},
        'dirty': <Object?>[],
      });
      await store.restore();
      expect(store.of(book)!.part, 3);
      expect(store.of(other), at(1, 7));
      expect(store.pending().keys, [book]);
    });

    test('cache newer than report: cache is retained', () async {
      await store.report(book, 3, 100);
      box.data = jsonEncode({
        'v': 1,
        'books': {book: at(2, 5000, minute: 30).toJson()},
        'speeds': <String, Object?>{},
        'dirty': <Object?>[],
      });
      await store.restore();
      expect(store.of(book), at(2, 5000, minute: 30));
    });

    test('restore notifies listeners', () async {
      box.data = jsonEncode({
        'v': 1,
        'books': {book: at(2, 5000).toJson()},
        'speeds': <String, Object?>{},
        'dirty': <Object?>[],
      });
      var notified = 0;
      store.addListener(() => notified++);
      await store.restore();
      expect(notified, 1);
    });

    test('speed 1.0 chosen before restore finishes is kept', () async {
      await store.setSpeed(book, 2.0);
      final again = reopened();
      box.readGate = Completer<void>();
      final restoring = again.restore();
      await again.setSpeed(book, 1.0);
      box.readGate!.complete();
      await restoring;
      expect(again.speedOf(book), 1.0);
    });

    test('restore after dispose does not notify listeners', () async {
      await store.report(book, 1, 1000);
      final again = reopened();
      box.readGate = Completer<void>();
      final restoring = again.restore();
      again.dispose();
      box.readGate!.complete();
      await restoring;
    });
  });

  group('capacity and sign out', () {
    test('storage limits', () {
      expect(BookProgressStore.maxBooks, 5000);
      expect(BookProgressStore.saveEvery, const Duration(seconds: 5));
    });

    test(
      'exceeding limit: oldest synced entries dropped, pending retained',
      () async {
        final books = <String, Object?>{};
        for (var i = 0; i < BookProgressStore.maxBooks; i++) {
          books['b${i.toString().padLeft(5, '0')}'] = BookPosition(
            part: 1,
            positionMs: i,
            finished: false,
            updatedAt: DateTime.utc(2026, 1, 1).add(Duration(minutes: i)),
          ).toJson();
        }
        box.data = jsonEncode({
          'v': 1,
          'books': books,
          'speeds': {'b00001': 2.0, 'b00000': 1.5},
          'dirty': ['b00000'],
        });
        await store.restore();
        await store.report(book, 1, 1000);
        expect(store.of('b00000'), isNotNull);
        expect(store.of('b00001'), isNull);
        expect(store.speedOf('b00001'), 1.0);
        expect(store.speedOf('b00000'), 1.5);
        expect(store.of('b00002'), isNotNull);
        expect(store.of(book), isNotNull);
        await store.applyRemote({other: at(1, 1)});
        expect(store.of('b00002'), isNull);
        expect(store.of(other), isNotNull);
        expect((saved()['books'] as Map).length, BookProgressStore.maxBooks);
      },
    );

    test('clear purges all records including disk', () async {
      await store.report(book, 2, 60000);
      await store.setSpeed(book, 2.0);
      var notified = 0;
      store.addListener(() => notified++);
      expect(await store.clear(), isTrue);
      expect(store.of(book), isNull);
      expect(store.speedOf(book), 1.0);
      expect(store.pending(), isEmpty);
      expect(notified, 1);
      expect(saved()['books'], isEmpty);
      expect(saved()['speeds'], isEmpty);
      expect(saved()['dirty'], isEmpty);
    });

    test('after clear store is closed: delayed writes dropped', () async {
      await store.report(book, 2, 60000);
      await store.clear();
      final writes = box.writes;
      await store.report(book, 2, 61000, force: true);
      await store.finish(book);
      await store.restart(book);
      await store.setSpeed(book, 2.0);
      await store.applyRemote({book: at(3, 1)});
      expect(store.of(book), isNull);
      expect(store.speedOf(book), 1.0);
      expect(store.pending(), isEmpty);
      expect(box.writes, writes);
    });

    test('after clear restore reopens the storage', () async {
      await store.clear();
      await store.restore();
      await store.report(book, 2, 60000);
      expect(store.of(book)!.positionMs, 60000);
    });

    test('clear during restore: old cache is not restored', () async {
      await store.report(book, 2, 60000);
      final again = reopened();
      box.readGate = Completer<void>();
      final restoring = again.restore();
      final clearing = again.clear();
      box.readGate!.complete();
      await restoring;
      await clearing;
      expect(again.of(book), isNull);
      expect(again.pending(), isEmpty);
    });

    test(
      'after sign out next user receives separate progress store fully',
      () async {
        await store.report(book, 2, 60000);
        await store.setSpeed(book, 2.0);
        await store.clear();
        box.data = jsonEncode({
          'v': 1,
          'books': {book: at(4, 7000).toJson()},
          'speeds': {book: 1.5},
          'dirty': <Object?>[],
        });
        await store.restore();
        expect(store.of(book), at(4, 7000));
        expect(store.speedOf(book), 1.5);
        expect(store.pending(), isEmpty);
      },
    );

    test('clear indicates whether disk write succeeded', () async {
      await store.report(book, 2, 60000);
      box.failWrite = true;
      expect(await store.clear(), isFalse);
      expect(savedBook(book)['position_ms'], 60000);
      box.failWrite = false;
      expect(await store.flush(), isTrue);
      expect(saved()['books'], isEmpty);
    });
  });

  group('clock handling', () {
    test('timestamp sampled from clock and stored in UTC', () async {
      clock.now = DateTime(2026, 10, 7, 15, 30);
      await store.report(book, 1, 1000);
      expect(store.of(book)!.updatedAt.isUtc, isTrue);
      expect(store.of(book)!.updatedAt, clock.now.toUtc());
      expect(savedBook(book)['updated_at'], endsWith('Z'));
    });

    test('clock set back: later position is still newer', () async {
      await store.report(book, 2, 60000);
      final before = store.of(book)!;
      clock.tick(const Duration(hours: -1));
      await store.report(book, 2, 90000);
      final after = store.of(book)!;
      expect(after.positionMs, 90000);
      expect(after.updatedAt.isAfter(before.updatedAt), isTrue);
      expect(newerBookPosition(before, after), after);
    });

    test('clock set back: completed and restarted are still newer', () async {
      await store.report(book, 2, 60000);
      clock.tick(const Duration(hours: -1));
      final a = store.of(book)!;
      await store.finish(book);
      final b = store.of(book)!;
      expect(b.updatedAt.isAfter(a.updatedAt), isTrue);
      await store.restart(book);
      expect(store.of(book)!.updatedAt.isAfter(b.updatedAt), isTrue);
    });

    test('clock set back: disk throttle does not stall for 1h', () async {
      await store.report(book, 2, 60000);
      clock.tick(const Duration(hours: -1));
      await store.report(book, 2, 61000);
      expect(box.writes, 2);
    });
  });

  test('disk record is single line of JSON version 1', () async {
    await store.report(book, 2, 60000);
    await store.setSpeed(book, 1.5);
    expect(saved(), {
      'v': 1,
      'books': {book: store.of(book)!.toJson()},
      'speeds': {book: 1.5},
      'dirty': [book],
    });
  });

  test('module does not access network or write to logs', () {
    final source = File('lib/book_progress.dart').readAsStringSync();
    for (final word in [
      'dart:io',
      'package:http',
      'print(',
      'debugPrint',
      'developer.log',
      'podcast',
    ]) {
      expect(source.contains(word), isFalse, reason: word);
    }
  });
}
