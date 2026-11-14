// FT-640 (P-A96, contract D1, pp. 1, 2, 4, 9; feature B6, step P6v): listen outbox.
//
// Today app sends "song played for N seconds" once and ignores response: no network — report
// lost, and song played offline never enters history. Here — app half under
// contract D1: each song launch has its own number, report is saved to phone outbox first and removed
// once server accepts it.
//
// Guarded:
// - each launch has own number and start time; new launch of same song — new number;
// - report is stored on phone BEFORE dispatch and survives app restart;
// - accumulated count: outbox retains largest, no second row for same number;
// - accepted report leaves outbox; "no network" — remains and sending stops; "server will never
//   accept this" — dropped without blocking subsequent;
// - reports dispatched one by one, from old to new; two concurrent drains don't send duplicate;
// - report that grew during sending is not lost;
// - outbox capped at 200 reports and at most 14 days old;
// - when "do not record" listening is not created, and clear wipes outbox on phone;
// - corrupted outbox and storage failure do not crash app.
//
// What test does not prove: that player calls `begin` and `report` (lead integration, B6), real
// server requests and real storage (provided by lead via `ListenPort` and `ListenBox`), and that
// server distinguishes numbers (FT-639).
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/listen_outbox.dart';

const _song = '33333333-3333-4333-8333-333333333333';
const _other = '44444444-4444-4444-8444-444444444444';

class _Port implements ListenPort {
  final sent = <ListenReport>[];
  ListenSent answer = ListenSent.accepted;

  /// Response for specific song takes priority over general.
  final answers = <String, ListenSent>{};
  bool throws = false;
  bool hold = false;
  final holds = <Completer<void>>[];

  @override
  Future<ListenSent> send(ListenReport report) async {
    sent.add(report);
    final result = answers[report.trackId] ?? answer;
    final fail = throws;
    if (hold) {
      final gate = Completer<void>();
      holds.add(gate);
      await gate.future;
    }
    if (fail) throw StateError('нет сети');
    return result;
  }
}

class _Box implements ListenBox {
  String? stored;
  int writes = 0;
  bool failRead = false;
  bool failWrite = false;
  Completer<void>? holdRead;

  /// Own gate for each write: can release in any order.
  bool holdWrites = false;
  final gates = <Completer<void>>[];

  @override
  Future<String?> read() async {
    final value = stored;
    if (holdRead != null) await holdRead!.future;
    if (failRead) throw StateError('хранилище недоступно');
    return value;
  }

  @override
  Future<void> write(String value) async {
    if (holdWrites) {
      final gate = Completer<void>();
      gates.add(gate);
      await gate.future;
    }
    if (failWrite) throw StateError('нет места');
    writes++;
    stored = value;
  }

  List<Map<String, Object?>> get rows =>
      (jsonDecode(stored ?? '[]') as List).cast<Map<String, Object?>>();
}

class _World {
  _World({String? stored}) {
    box.stored = stored;
    outbox = _make();
  }

  final port = _Port();
  final box = _Box();
  DateTime now = DateTime.utc(2026, 10, 6, 12);
  int ids = 0;
  late ListenOutbox outbox;

  ListenOutbox _make() => ListenOutbox(
    port: port,
    box: box,
    now: () => now,
    newId: () => 'listen-${++ids}',
  );

  /// App restarted: memory cleared, storage preserved.
  Future<void> restart() async {
    outbox = _make();
    await outbox.restore();
  }
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('listen id', () {
    test('each launch has its own id, track, and start time', () {
      final w = _World();
      final listen = w.outbox.begin(_song, paused: false)!;
      expect(listen.id, 'listen-1');
      expect(listen.trackId, _song);
      expect(listen.startedAt, DateTime.utc(2026, 10, 6, 12));
      expect(listen.startedAt.isUtc, isTrue);
    });

    test('new launch of same track — new id', () {
      final w = _World();
      final first = w.outbox.begin(_song, paused: false)!;
      w.now = w.now.add(const Duration(minutes: 4));
      final second = w.outbox.begin(_song, paused: false)!;
      expect(second.id, isNot(first.id));
      expect(second.startedAt, isNot(first.startedAt));
    });

    test('when «do not record», listen is not created', () async {
      final w = _World();
      expect(w.outbox.begin(_song, paused: true), isNull);
      await _settle();
      expect(w.port.sent, isEmpty);
      expect(w.box.writes, 0);
    });

    test('start time with local clock is sent as UTC', () {
      final local = DateTime(2026, 10, 6, 15, 30);
      final outbox = ListenOutbox(
        port: _Port(),
        box: _Box(),
        now: () => local,
        newId: () => 'x',
      );
      final listen = outbox.begin(_song, paused: false)!;
      expect(listen.startedAt.isUtc, isTrue);
      expect(listen.startedAt, local.toUtc());
    });

    test('default id is a random version 4 UUID', () {
      final seen = <String>{};
      final shape = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      );
      for (var i = 0; i < 200; i++) {
        final id = newListenId();
        expect(id, matches(shape));
        seen.add(id);
      }
      expect(seen.length, 200);
      expect(newListenId(Random(7)), newListenId(Random(7)));
      expect(newListenId(Random(7)), isNot(newListenId(Random(8))));
      final outbox = ListenOutbox(port: _Port(), box: _Box());
      expect(outbox.begin(_song, paused: false)!.id, matches(shape));
    });
  });

  group('report', () {
    test('sent to server with all four fields', () async {
      final w = _World();
      final listen = w.outbox.begin(_song, paused: false)!;
      await w.outbox.report(listen, 95000);
      final sent = w.port.sent.single;
      expect(sent.toJson(), {
        'listen_id': 'listen-1',
        'track_id': _song,
        'started_at': '2026-10-06T12:00:00.000Z',
        'listened_ms': 95000,
      });
      expect(w.outbox.pending, 0);
      expect(w.box.rows, isEmpty, reason: 'accepted not kept in outbox');
    });

    test('saved on phone before sending', () async {
      final w = _World()..port.hold = true;
      final listen = w.outbox.begin(_song, paused: false)!;
      final reporting = w.outbox.report(listen, 95000);
      await _settle();
      expect(w.port.sent, hasLength(1));
      expect(
        w.box.rows.single['listen_id'],
        'listen-1',
        reason: 'app killed mid-request — report not lost',
      );
      w.port.holds.single.complete();
      await reporting;
      expect(w.box.rows, isEmpty);
    });

    test('zero and negative number are not reports', () async {
      final w = _World();
      final listen = w.outbox.begin(_song, paused: false)!;
      await w.outbox.report(listen, 0);
      await w.outbox.report(listen, -5);
      expect(w.port.sent, isEmpty);
      expect(w.box.writes, 0);
    });

    test('no network — report kept and sent on next flush', () async {
      final w = _World()..port.answer = ListenSent.retry;
      final listen = w.outbox.begin(_song, paused: false)!;
      await w.outbox.report(listen, 95000);
      expect(w.outbox.pending, 1);
      expect(w.box.rows, hasLength(1));

      w.port.answer = ListenSent.accepted;
      await w.outbox.flush();
      expect(w.port.sent, hasLength(2));
      expect(w.port.sent.last.listenId, 'listen-1');
      expect(w.outbox.pending, 0);
      expect(w.box.rows, isEmpty);
    });

    test('port exception is treated as «no network»', () async {
      final w = _World()..port.throws = true;
      final listen = w.outbox.begin(_song, paused: false)!;
      await w.outbox.report(listen, 95000);
      expect(w.outbox.pending, 1);
      w.port.throws = false;
      await w.outbox.flush();
      expect(w.outbox.pending, 0);
    });

    test(
      'cumulative count: outbox keeps single listen with maximum duration',
      () async {
        final w = _World()..port.answer = ListenSent.retry;
        final listen = w.outbox.begin(_song, paused: false)!;
        await w.outbox.report(listen, 40000);
        await w.outbox.report(listen, 95000);
        await w.outbox.report(listen, 60000);
        expect(w.outbox.pending, 1);
        expect(w.box.rows.single['listened_ms'], 95000);
        w.port.sent.clear();
        w.port.answer = ListenSent.accepted;
        await w.outbox.flush();
        expect(w.port.sent.single.listenedMs, 95000);
      },
    );

    test('report after accepted is resent with same id', () async {
      final w = _World();
      final listen = w.outbox.begin(_song, paused: false)!;
      await w.outbox.report(listen, 40000);
      await w.outbox.report(listen, 95000);
      expect(w.port.sent.map((r) => (r.listenId, r.listenedMs)), [
        ('listen-1', 40000),
        ('listen-1', 95000),
      ]);
      expect(w.port.sent.last.startedAt, w.port.sent.first.startedAt);
    });

    test(
      'report with same count keeps outbox unchanged, attempts send again',
      () async {
        final w = _World()..port.answer = ListenSent.retry;
        final listen = w.outbox.begin(_song, paused: false)!;
        await w.outbox.report(listen, 95000);
        final writes = w.box.writes;
        w.port.answer = ListenSent.accepted;
        // Pause, then stop at same position: count same, network restored.
        await w.outbox.report(listen, 95000);
        expect(w.outbox.pending, 0);
        expect(w.port.sent, hasLength(2));
        expect(
          w.box.writes,
          writes + 1,
          reason: 'only removal from outbox is written',
        );
      },
    );

    test('server will never accept — report is dropped', () async {
      final w = _World()..port.answer = ListenSent.rejected;
      final listen = w.outbox.begin(_song, paused: false)!;
      await w.outbox.report(listen, 95000);
      expect(w.outbox.pending, 0);
      expect(w.box.rows, isEmpty);
      await w.outbox.flush();
      expect(w.port.sent, hasLength(1), reason: 'not retried');
    });
  });

  group('outbox flush', () {
    Future<_World> offline(int count) async {
      final w = _World()..port.answer = ListenSent.retry;
      for (var i = 0; i < count; i++) {
        final listen = w.outbox.begin(
          i.isEven ? _song : _other,
          paused: false,
        )!;
        w.now = w.now.add(const Duration(minutes: 4));
        await w.outbox.report(listen, 100000 + i);
      }
      w.port.sent.clear();
      return w;
    }

    test('from oldest to newest, one by one', () async {
      final w = await offline(3);
      w.port
        ..answer = ListenSent.accepted
        ..hold = true;
      final flushing = w.outbox.flush();
      await _settle();
      expect(w.port.sent.map((r) => r.listenId), ['listen-1']);
      w.port.holds[0].complete();
      await _settle();
      expect(w.port.sent.map((r) => r.listenId), ['listen-1', 'listen-2']);
      expect(w.box.rows.map((r) => r['listen_id']), ['listen-2', 'listen-3']);
      w.port.holds[1].complete();
      await _settle();
      w.port.holds[2].complete();
      await flushing;
      expect(w.outbox.pending, 0);
    });

    test('«no network» stops flush: rest not touched', () async {
      final w = await offline(3);
      await w.outbox.flush();
      expect(w.port.sent.map((r) => r.listenId), ['listen-1']);
      expect(w.outbox.pending, 3);
    });

    test('rejected report does not block next ones', () async {
      final w = await offline(3);
      w.port
        ..answer = ListenSent.accepted
        ..answers[_song] = ListenSent.rejected;
      await w.outbox.flush();
      expect(w.port.sent.map((r) => r.listenId), [
        'listen-1',
        'listen-2',
        'listen-3',
      ]);
      expect(w.outbox.pending, 0);
      expect(w.box.rows, isEmpty);
    });

    test('concurrent flushes do not send duplicates', () async {
      final w = await offline(2);
      w.port
        ..answer = ListenSent.accepted
        ..hold = true;
      final first = w.outbox.flush();
      final second = w.outbox.flush();
      await _settle();
      expect(w.port.sent, hasLength(1));
      w.port.holds[0].complete();
      await _settle();
      w.port.holds[1].complete();
      await Future.wait([first, second]);
      expect(w.port.sent.map((r) => r.listenId), ['listen-1', 'listen-2']);
    });

    test('after flush next flush restarts afresh', () async {
      final w = await offline(1);
      await w.outbox.flush();
      w.port.answer = ListenSent.accepted;
      await w.outbox.flush();
      expect(w.outbox.pending, 0);
    });

    test('report grown during send is not lost', () async {
      final w = _World()..port.hold = true;
      final listen = w.outbox.begin(_song, paused: false)!;
      final first = w.outbox.report(listen, 40000);
      await _settle();
      final second = w.outbox.report(listen, 95000);
      await _settle();
      expect(w.port.sent, hasLength(1), reason: 'one by one');
      w.port.holds[0].complete();
      await _settle();
      expect(
        w.box.rows.single['listened_ms'],
        95000,
        reason: 'server took 40s, 95 played — outbox still needed',
      );
      expect(w.port.sent.map((r) => r.listenedMs), [40000, 95000]);
      w.port.holds[1].complete();
      await Future.wait([first, second]);
      expect(w.outbox.pending, 0);
      expect(w.box.rows, isEmpty);
    });

    test(
      'new report during send of old report joins the same outgoing queue',
      () async {
        final w = _World()..port.hold = true;
        final one = w.outbox.begin(_song, paused: false)!;
        final first = w.outbox.report(one, 40000);
        await _settle();
        final two = w.outbox.begin(_other, paused: false)!;
        final second = w.outbox.report(two, 50000);
        await _settle();
        expect(w.port.sent, hasLength(1));
        w.port.holds[0].complete();
        await _settle();
        expect(w.port.sent.map((r) => r.trackId), [_song, _other]);
        w.port.holds[1].complete();
        await Future.wait([first, second]);
        expect(w.outbox.pending, 0);
      },
    );
  });

  group('app restart', () {
    test('undelivered is restored and sent', () async {
      final w = _World()..port.answer = ListenSent.retry;
      final listen = w.outbox.begin(_song, paused: false)!;
      await w.outbox.report(listen, 95000);
      w.port.sent.clear();

      await w.restart();
      expect(w.outbox.pending, 1);
      expect(w.port.sent, isEmpty, reason: 'restore alone does not send');
      w.port.answer = ListenSent.accepted;
      await w.outbox.flush();
      expect(w.port.sent.single.toJson(), {
        'listen_id': 'listen-1',
        'track_id': _song,
        'started_at': '2026-10-06T12:00:00.000Z',
        'listened_ms': 95000,
      });
    });

    test(
      'report arriving before read ends is preserved and goes after old ones',
      () async {
        final w = _World()..port.answer = ListenSent.retry;
        await w.outbox.report(w.outbox.begin(_song, paused: false)!, 95000);
        w.outbox = w._make();
        w.box.holdRead = Completer<void>();
        final restoring = w.outbox.restore();
        final fresh = w.outbox.begin(_other, paused: false)!;
        await w.outbox.report(fresh, 50000);
        w.box.holdRead!.complete();
        await restoring;
        expect(w.outbox.pending, 2);
        w.port.sent.clear();
        w.port.answer = ListenSent.accepted;
        await w.outbox.flush();
        expect(w.port.sent.map((r) => r.trackId), [_song, _other]);
      },
    );

    test('single id keeps maximum after restore', () async {
      final w = _World()..port.answer = ListenSent.retry;
      final listen = w.outbox.begin(_song, paused: false)!;
      await w.outbox.report(listen, 40000);
      // App restarted, player resumed same launch and reported
      // before outbox finished reading.
      w.outbox = w._make();
      w.box.holdRead = Completer<void>();
      final restoring = w.outbox.restore();
      await w.outbox.report(listen, 95000);
      w.box.holdRead!.complete();
      await restoring;
      expect(w.outbox.pending, 1);
      expect(w.box.rows.single['listened_ms'], 95000);
    });

    test('repeated restore does not duplicate outbox', () async {
      final w = _World()..port.answer = ListenSent.retry;
      await w.outbox.report(w.outbox.begin(_song, paused: false)!, 95000);
      await w.restart();
      await w.outbox.restore();
      expect(w.outbox.pending, 1);
    });

    for (final (name, stored) in [
      ('не JSON', '{{{'),
      ('не список', '{"listen_id": "a"}'),
      ('пустая строка', ''),
    ]) {
      test('corrupted outbox ($name) — empty, no exceptions', () async {
        final w = _World(stored: stored);
        await w.outbox.restore();
        expect(w.outbox.pending, 0);
        await w.outbox.report(w.outbox.begin(_song, paused: false)!, 95000);
        expect(w.port.sent, hasLength(1));
      });
    }

    test('malformed outbox rows skipped, valid kept', () async {
      final good = {
        'listen_id': 'kept',
        'track_id': _song,
        'started_at': '2026-10-06T11:00:00.000Z',
        'listened_ms': 70000,
      };
      final w = _World(
        stored: jsonEncode([
          'строка',
          {...good, 'listen_id': ''},
          {...good, 'listen_id': 7},
          {...good, 'track_id': null},
          {...good, 'started_at': 'вчера'},
          {...good, 'started_at': '2026-10-06T11:00:00.000'},
          {...good, 'listened_ms': 0},
          {...good, 'listened_ms': '70000'},
          {...good, 'listened_ms': 70000.5},
          good,
          {...good, 'listened_ms': 99999},
        ]),
      );
      await w.outbox.restore();
      expect(w.outbox.pending, 1, reason: 'second with same id is duplicate');
      await w.outbox.flush();
      expect(w.port.sent.single.toJson(), {
        ...good,
        'listened_ms': 99999,
      }, reason: 'duplicate keeps largest value');
    });

    test('unreadable store — empty, no exceptions', () async {
      final w = _World(stored: '[]')..box.failRead = true;
      await w.outbox.restore();
      expect(w.outbox.pending, 0);
    });
  });

  group('limits', () {
    test('at most 200: oldest entries dropped', () async {
      final w = _World()..port.answer = ListenSent.retry;
      for (var i = 0; i < 203; i++) {
        await w.outbox.report(w.outbox.begin(_song, paused: false)!, 60000);
      }
      expect(w.outbox.pending, 200);
      expect(w.box.rows, hasLength(200));
      expect(w.box.rows.first['listen_id'], 'listen-4');
      expect(w.box.rows.last['listen_id'], 'listen-203');
    });

    test('older than 14 days not sent', () async {
      final w = _World()..port.answer = ListenSent.retry;
      await w.outbox.report(w.outbox.begin(_song, paused: false)!, 60000);
      w.now = w.now.add(const Duration(days: 7));
      await w.outbox.report(w.outbox.begin(_other, paused: false)!, 60000);
      w.port.sent.clear();

      w.now = DateTime.utc(2026, 10, 20, 12);
      w.port.answer = ListenSent.accepted;
      await w.restart();
      expect(w.outbox.pending, 2, reason: 'exactly 14 days — still valid');

      w.now = DateTime.utc(2026, 10, 20, 12, 0, 1);
      await w.outbox.flush();
      expect(w.port.sent.map((r) => r.trackId), [_other]);
      expect(w.outbox.pending, 0);
      expect(w.box.rows, isEmpty, reason: 'expired purged from phone too');
    });

    test('expired is discarded on restore as well', () async {
      final w = _World()..port.answer = ListenSent.retry;
      await w.outbox.report(w.outbox.begin(_song, paused: false)!, 60000);
      w.now = w.now.add(const Duration(days: 15));
      await w.restart();
      expect(w.outbox.pending, 0);
    });
  });

  group('clear («do not record», logout)', () {
    test('clears outbox in memory and on phone', () async {
      final w = _World()..port.answer = ListenSent.retry;
      await w.outbox.report(w.outbox.begin(_song, paused: false)!, 60000);
      await w.outbox.clear();
      expect(w.outbox.pending, 0);
      expect(w.box.rows, isEmpty);
      w.port.sent.clear();
      await w.outbox.flush();
      expect(w.port.sent, isEmpty);
      await w.restart();
      expect(w.outbox.pending, 0);
    });

    test('in-flight request does not restore cleared', () async {
      final w = _World()..port.hold = true;
      final listen = w.outbox.begin(_song, paused: false)!;
      final reporting = w.outbox.report(listen, 60000);
      await _settle();
      w.port.throws = true;
      await w.outbox.clear();
      w.port.holds[0].complete();
      await reporting;
      expect(w.outbox.pending, 0);
      expect(w.box.rows, isEmpty);
    });

    test('read started before clear does not restore it', () async {
      final w = _World()..port.answer = ListenSent.retry;
      await w.outbox.report(w.outbox.begin(_song, paused: false)!, 60000);
      w.outbox = w._make();
      w.box.holdRead = Completer<void>();
      final restoring = w.outbox.restore();
      await w.outbox.clear();
      w.box.holdRead!.complete();
      await restoring;
      expect(w.outbox.pending, 0);
      expect(w.box.rows, isEmpty);
    });

    test('track playing during clear is not reported', () async {
      final w = _World();
      final playing = w.outbox.begin(_song, paused: false)!;
      await w.outbox.report(playing, 40000);
      w.port.sent.clear();
      await w.outbox.clear();
      // "Do not record" enabled mid-song; player will report at its end.
      await w.outbox.report(playing, 180000);
      expect(w.port.sent, isEmpty);
      expect(w.outbox.pending, 0);
      expect(w.box.rows, isEmpty);
    });

    test('launch started outside this outbox is reported', () async {
      final w = _World();
      await w.outbox.clear();
      // Player restored launch after app restart.
      final restored = Listen(
        id: 'kept-by-player',
        trackId: _song,
        startedAt: DateTime.utc(2026, 10, 6, 11),
      );
      await w.outbox.report(restored, 60000);
      expect(w.port.sent.single.listenId, 'kept-by-player');
    });

    test('after clear new reports sent normally', () async {
      final w = _World()..port.hold = true;
      final old = w.outbox.report(w.outbox.begin(_song, paused: false)!, 60000);
      await _settle();
      await w.outbox.clear();
      final fresh = w.outbox.report(
        w.outbox.begin(_other, paused: false)!,
        50000,
      );
      await _settle();
      w.port.holds[0].complete();
      await _settle();
      const why = 'новый доклад не должен ждать следующего случая';
      final want = [_song, _other];
      expect(w.port.sent.map((r) => r.trackId), want, reason: why);
      w.port.holds[1].complete();
      await Future.wait([old, fresh]);
      expect(w.outbox.pending, 0);
    });
  });

  group('storage', () {
    test('write failure does not crash or block send', () async {
      final w = _World()..box.failWrite = true;
      await w.outbox.report(w.outbox.begin(_song, paused: false)!, 60000);
      expect(w.port.sent, hasLength(1));
      expect(w.outbox.pending, 0);
    });

    test('failed phone purge is retried on flush', () async {
      final w = _World()..port.answer = ListenSent.retry;
      await w.outbox.report(w.outbox.begin(_song, paused: false)!, 60000);
      w.box.failWrite = true;
      await w.outbox.clear();
      expect(w.box.rows, hasLength(1), reason: 'write failed');
      w.box.failWrite = false;
      await w.outbox.flush();
      expect(
        w.box.rows,
        isEmpty,
        reason: 'otherwise erased items would return after restart',
      );
      final writes = w.box.writes;
      await w.outbox.flush();
      expect(w.box.writes, writes, reason: 'no redundant writes');
    });

    test(
      'writes are queued in order: phone retains the latest persistent state',
      () async {
        final w = _World()
          ..port.answer = ListenSent.retry
          ..box.holdWrites = true;
        final first = w.outbox.report(
          w.outbox.begin(_song, paused: false)!,
          60000,
        );
        await _settle();
        final second = w.outbox.report(
          w.outbox.begin(_other, paused: false)!,
          50000,
        );
        await _settle();
        expect(w.box.gates, hasLength(1), reason: '2nd write waits for 1st');
        w.box.gates[0].complete();
        await _settle();
        w.box.gates[1].complete();
        await Future.wait([first, second]);
        expect(w.box.rows.map((r) => r['track_id']), [_song, _other]);
      },
    );
  });
}
