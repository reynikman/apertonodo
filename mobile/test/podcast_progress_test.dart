// FT-656 (P-A93, block B-5): podcast progress and playback speed on device.
//
// Tracks are listened to entirely, podcast episodes in 40-minute chunks. Thus
// playback position and completed state saved per episode, speed per podcast.
// Record stored locally (works offline) awaiting sync to server; between two
// records for same episode latest timestamp wins.
//
// Contract `lib/podcast_progress.dart`:
// - `podcastSpeeds`, `nearestPodcastSpeed(v)`, `podcastEpisodeKey(feed, guid)`;
// - `podcastFinished(positionMs, durationMs)`, `podcastResumeMs(p, durationMs:)`;
// - `EpisodeProgress(positionMs, done, updatedAt)` + `toJson`/`fromJson`, `==`;
// - `newerProgress(a, b)`;
// - `PodcastProgressBox { read(), write(data) }`;
// - `PodcastProgressStore(box, clock:)`: `restore`, `of`, `report`, `markDone`,
//   `markNew`, `speedOf`, `setSpeed`, `pending`, `ack`, `applyRemote`, `flush`,
//   `clear`; `maxEpisodes = 5000`, `saveEvery = 5 s`.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:music_stream/podcast_progress.dart';
import 'package:flutter_test/flutter_test.dart';

class MemoryBox implements PodcastProgressBox {
  String? data;
  int writes = 0;
  bool failWrite = false;
  bool failRead = false;
  Completer<void>? gate;

  @override
  Future<String?> read() async {
    if (failRead) throw const FileSystemException('no');
    return data;
  }

  @override
  Future<void> write(String value) async {
    if (gate != null) await gate!.future;
    if (failWrite) throw const FileSystemException('full');
    writes++;
    data = value;
  }
}

/// First write awaits gate, subsequent ones pass immediately.
class SlowFirstBox implements PodcastProgressBox {
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

EpisodeProgress at(int ms, {bool done = false, int minute = 0}) =>
    EpisodeProgress(
      positionMs: ms,
      done: done,
      updatedAt: DateTime.utc(2026, 10, 7, 12, minute),
    );

const hour = 3600000;
const feed = 'https://pod.example.org/feed.xml';
final key = podcastEpisodeKey(feed, 'ep-1');

void main() {
  late MemoryBox box;
  late Clock clock;
  late PodcastProgressStore store;

  setUp(() {
    box = MemoryBox();
    clock = Clock();
    store = PodcastProgressStore(box, clock: clock.call);
  });

  Map<String, Object?> saved() => jsonDecode(box.data!) as Map<String, Object?>;

  group('playback speed', () {
    test('speed list', () {
      expect(podcastSpeeds, [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]);
    });

    test('closest allowed speed', () {
      expect(nearestPodcastSpeed(1.3), 1.25);
      expect(nearestPodcastSpeed(1.0), 1.0);
      expect(nearestPodcastSpeed(0.1), 0.5);
      expect(nearestPodcastSpeed(-4), 0.5);
      expect(nearestPodcastSpeed(9), 3.0);
      expect(nearestPodcastSpeed(2.2), 2.0);
      expect(nearestPodcastSpeed(2.3), 2.5);
      expect(nearestPodcastSpeed(double.nan), 1.0);
      expect(nearestPodcastSpeed(double.infinity), 1.0);
      expect(nearestPodcastSpeed(double.negativeInfinity), 1.0);
    });

    test('each podcast has its own, default is normal', () async {
      expect(store.speedOf(feed), 1.0);
      await store.setSpeed(feed, 1.6);
      expect(store.speedOf(feed), 1.5);
      expect(store.speedOf('https://other.example.org/f'), 1.0);
    });

    test('speed survives restart', () async {
      await store.setSpeed(feed, 2.0);
      final again = PodcastProgressStore(box, clock: clock.call);
      await again.restore();
      expect(again.speedOf(feed), 2.0);
    });

    test('same speed: no write, no notification', () async {
      var notified = 0;
      store.addListener(() => notified++);
      await store.setSpeed(feed, 1.0);
      expect(box.writes, 0);
      expect(notified, 0);
      await store.setSpeed(feed, 1.5);
      await store.setSpeed(feed, 1.5);
      expect(box.writes, 1);
      expect(notified, 1);
    });

    test('reset to normal speed is saved', () async {
      await store.setSpeed(feed, 2.0);
      await store.setSpeed(feed, 1.0);
      final again = PodcastProgressStore(box, clock: clock.call);
      await again.restore();
      expect(again.speedOf(feed), 1.0);
    });
  });

  group('completed', () {
    test('one hour: 30 seconds before end', () {
      expect(podcastFinished(hour - 30001, hour), isFalse);
      expect(podcastFinished(hour - 30000, hour), isTrue);
      expect(podcastFinished(hour, hour), isTrue);
      expect(podcastFinished(hour + 5000, hour), isTrue);
    });

    test('short episode: last 5 percent rather than 30 seconds', () {
      const twoMin = 120000;
      expect(podcastFinished(twoMin - 30000, twoMin), isFalse);
      expect(podcastFinished(twoMin - 6001, twoMin), isFalse);
      expect(podcastFinished(twoMin - 6000, twoMin), isTrue);
    });

    test('unknown length: never marked completed', () {
      expect(podcastFinished(hour, null), isFalse);
      expect(podcastFinished(hour, 0), isFalse);
      expect(podcastFinished(hour, -1), isFalse);
    });
  });

  group('resume position', () {
    test('three seconds back', () {
      expect(podcastResumeMs(at(600000)), 597000);
      expect(podcastResumeMs(at(10000)), 7000);
    });

    test('at start, completed, no record: from zero', () {
      expect(podcastResumeMs(null), 0);
      expect(podcastResumeMs(at(9999)), 0);
      expect(podcastResumeMs(at(600000, done: true)), 0);
    });

    test('position past episode end: from zero', () {
      expect(podcastResumeMs(at(700000), durationMs: 600000), 0);
      expect(podcastResumeMs(at(600000), durationMs: 600000), 0);
      expect(podcastResumeMs(at(500000), durationMs: 600000), 497000);
      expect(podcastResumeMs(at(500000), durationMs: 0), 497000);
    });
  });

  group('record', () {
    test('key distinguishes feeds and episodes', () {
      expect(podcastEpisodeKey('a', 'b'), isNot(podcastEpisodeKey('a', 'c')));
      expect(podcastEpisodeKey('a', 'b'), isNot(podcastEpisodeKey('c', 'b')));
      expect(podcastEpisodeKey('a', 'b'), podcastEpisodeKey('a', 'b'));
      expect(podcastEpisodeKey('ab', 'c'), isNot(podcastEpisodeKey('a', 'bc')));
    });

    test('round trip', () {
      final value = at(123456, done: true, minute: 7);
      final json = jsonDecode(jsonEncode(value.toJson()));
      expect(json, {
        'position_ms': 123456,
        'done': true,
        'updated_at': '2026-10-07T12:07:00.000Z',
      });
      expect(EpisodeProgress.fromJson(json), value);
    });

    test('equality checks position, completed, and time', () {
      expect(at(5000), at(5000));
      expect(at(5000) == at(5001), isFalse);
      expect(at(5000) == at(5000, done: true), isFalse);
      expect(at(5000) == at(5000, minute: 1), isFalse);
    });

    test('local time is serialized as UTC', () {
      final local = DateTime.utc(2026, 10, 7, 12).toLocal();
      final value = EpisodeProgress(
        positionMs: 1,
        done: false,
        updatedAt: local,
      );
      expect(value.toJson()['updated_at'], '2026-10-07T12:00:00.000Z');
      expect(value, at(1));
    });

    test('malformed string: null, no exceptions', () {
      final good = at(5).toJson();
      for (final bad in <Object?>[
        null,
        'x',
        7,
        <Object?>[],
        <String, Object?>{},
        {...good, 'position_ms': -1},
        {...good, 'position_ms': '5'},
        {...good, 'position_ms': 5.5},
        {...good, 'done': 1},
        {...good, 'done': null},
        {...good, 'updated_at': 'вчера'},
        {...good, 'updated_at': 5},
        {...good, 'updated_at': '2026-10-07T12:00:00'},
      ]) {
        expect(EpisodeProgress.fromJson(bad), isNull, reason: '$bad');
      }
    });

    test('toString omits position and time', () {
      expect(at(123456).toString(), isNot(contains('123456')));
    });
  });

  group('which record is newer', () {
    test('later timestamp in any order', () {
      final old = at(900000, done: true, minute: 1);
      final fresh = at(5000, minute: 2);
      expect(newerProgress(old, fresh), fresh);
      expect(newerProgress(fresh, old), fresh);
    });

    test('same timestamp: completed wins, then larger position', () {
      expect(newerProgress(at(5, done: true), at(900)), at(5, done: true));
      expect(newerProgress(at(900), at(5, done: true)), at(5, done: true));
      expect(newerProgress(at(5), at(900)), at(900));
      expect(newerProgress(at(900), at(5)), at(900));
    });
  });

  group('storage', () {
    test('report is remembered and queued for sync', () async {
      await store.report(key, 60000, durationMs: hour);
      expect(
        store.of(key),
        EpisodeProgress(positionMs: 60000, done: false, updatedAt: clock.now),
      );
      expect(store.pending(), {key: store.of(key)});
      expect(store.of('нет такого'), isNull);
    });

    test('survives restart along with sync queue', () async {
      await store.report(key, 60000, durationMs: hour);
      final again = PodcastProgressStore(box, clock: clock.call);
      await again.restore();
      expect(again.of(key), store.of(key));
      expect(again.pending().keys, [key]);
    });

    test('episode end marks completed, new playback unmarks it', () async {
      await store.report(key, hour - 1000, durationMs: hour);
      expect(store.of(key)!.done, isTrue);
      clock.tick(const Duration(minutes: 1));
      await store.report(key, 20000, durationMs: hour);
      expect(store.of(key)!.done, isFalse);
      expect(store.of(key)!.positionMs, 20000);
    });

    test('negative position is rejected', () async {
      await store.report(key, -1, durationMs: hour);
      expect(store.of(key), isNull);
      expect(box.writes, 0);
    });

    test(
      'disk write at most once per 5 seconds, memory updated immediately',
      () async {
        await store.report(key, 60000, durationMs: hour);
        expect(box.writes, 1);
        for (var s = 1; s <= 4; s++) {
          clock.tick(const Duration(seconds: 1));
          await store.report(key, 60000 + s * 1000, durationMs: hour);
        }
        expect(box.writes, 1);
        expect(store.of(key)!.positionMs, 64000);
        clock.tick(const Duration(seconds: 1));
        await store.report(key, 65000, durationMs: hour);
        expect(box.writes, 2);
        expect((saved()['episodes'] as Map)[key]['position_ms'], 65000);
      },
    );

    test('pause (force) and flush write immediately', () async {
      await store.report(key, 60000, durationMs: hour);
      clock.tick(const Duration(seconds: 1));
      await store.report(key, 61000, durationMs: hour, force: true);
      expect(box.writes, 2);
      clock.tick(const Duration(seconds: 1));
      await store.report(key, 62000, durationMs: hour);
      expect(box.writes, 2);
      await store.flush();
      expect(box.writes, 3);
      expect((saved()['episodes'] as Map)[key]['position_ms'], 62000);
      await store.flush();
      expect(box.writes, 3);
    });

    test('completed is written immediately without 5s delay', () async {
      await store.report(key, 60000, durationMs: hour);
      clock.tick(const Duration(seconds: 1));
      await store.report(key, hour - 1000, durationMs: hour);
      expect(box.writes, 2);
      expect((saved()['episodes'] as Map)[key]['done'], isTrue);
    });

    test('notifies on completed change, not every second', () async {
      var notified = 0;
      store.addListener(() => notified++);
      await store.report(key, 60000, durationMs: hour);
      expect(notified, 1);
      clock.tick(const Duration(seconds: 10));
      await store.report(key, 70000, durationMs: hour);
      expect(notified, 1);
      await store.report(key, hour, durationMs: hour);
      expect(notified, 2);
    });

    test('mark as completed and as new', () async {
      await store.report(key, 60000, durationMs: hour);
      clock.tick(const Duration(minutes: 1));
      await store.markDone(key);
      expect(
        store.of(key),
        EpisodeProgress(positionMs: 60000, done: true, updatedAt: clock.now),
      );
      clock.tick(const Duration(minutes: 1));
      await store.markNew(key);
      expect(
        store.of(key),
        EpisodeProgress(positionMs: 0, done: false, updatedAt: clock.now),
      );
      expect(box.writes, 3);
      final other = podcastEpisodeKey(feed, 'ep-2');
      await store.markDone(other);
      expect(store.of(other)!.done, isTrue);
      expect(store.of(other)!.positionMs, 0);
      expect(store.pending().keys.toSet(), {key, other});
    });

    test('write error does not drop report, retried on flush', () async {
      box.failWrite = true;
      await store.report(key, 60000, durationMs: hour);
      expect(store.of(key)!.positionMs, 60000);
      expect(box.data, isNull);
      box.failWrite = false;
      await store.flush();
      expect((saved()['episodes'] as Map)[key]['position_ms'], 60000);
    });

    test('writes do not overtake each other', () async {
      box.gate = Completer<void>();
      final first = store.report(key, 60000, durationMs: hour, force: true);
      clock.tick(const Duration(seconds: 1));
      final second = store.report(key, 61000, durationMs: hour, force: true);
      box.gate!.complete();
      box.gate = null;
      await Future.wait([first, second]);
      expect((saved()['episodes'] as Map)[key]['position_ms'], 61000);
    });

    test('slow first write does not overwrite second', () async {
      final slow = SlowFirstBox();
      final mine = PodcastProgressStore(slow, clock: clock.call);
      final first = mine.report(key, 60000, durationMs: hour, force: true);
      await Future<void>.delayed(Duration.zero);
      clock.tick(const Duration(seconds: 1));
      final second = mine.report(key, 61000, durationMs: hour, force: true);
      await Future<void>.delayed(Duration.zero);
      slow.gate.complete();
      await Future.wait([first, second]);
      final data = jsonDecode(slow.data!) as Map<String, Object?>;
      expect((data['episodes'] as Map)[key]['position_ms'], 61000);
    });
  });

  group('sync to server', () {
    test('acknowledgement dequeues record', () async {
      await store.report(key, 60000, durationMs: hour);
      await store.ack(key, store.of(key)!);
      expect(store.pending(), isEmpty);
      final again = PodcastProgressStore(box, clock: clock.call);
      await again.restore();
      expect(again.pending(), isEmpty);
      expect(again.of(key)!.positionMs, 60000);
    });

    test('record changed during sync remains in queue', () async {
      await store.report(key, 60000, durationMs: hour);
      final sent = store.of(key)!;
      clock.tick(const Duration(seconds: 30));
      await store.report(key, 90000, durationMs: hour);
      await store.ack(key, sent);
      expect(store.pending().keys, [key]);
      expect(store.pending()[key]!.positionMs, 90000);
    });

    test('acknowledging unknown or foreign key does nothing', () async {
      await store.report(key, 60000, durationMs: hour);
      final writes = box.writes;
      await store.ack('нет такого', at(1));
      expect(store.pending().keys, [key]);
      expect(box.writes, writes);
    });

    test('from server: later wins and is not queued', () async {
      await store.report(key, 60000, durationMs: hour);
      final newer = EpisodeProgress(
        positionMs: 900000,
        done: false,
        updatedAt: clock.now.add(const Duration(minutes: 5)),
      );
      var notified = 0;
      store.addListener(() => notified++);
      await store.applyRemote({key: newer});
      expect(store.of(key), newer);
      expect(store.pending(), isEmpty);
      expect(notified, 1);
      final again = PodcastProgressStore(box, clock: clock.call);
      await again.restore();
      expect(again.of(key), newer);
    });

    test('from server: older does not touch local', () async {
      await store.report(key, 60000, durationMs: hour);
      final mine = store.of(key)!;
      final older = EpisodeProgress(
        positionMs: 900000,
        done: true,
        updatedAt: clock.now.subtract(const Duration(minutes: 5)),
      );
      final writes = box.writes;
      var notified = 0;
      store.addListener(() => notified++);
      await store.applyRemote({key: older});
      expect(store.of(key), mine);
      expect(store.pending().keys, [key]);
      expect(box.writes, writes);
      expect(notified, 0);
    });

    test('from server: unknown episode is added', () async {
      final other = podcastEpisodeKey(feed, 'ep-9');
      await store.applyRemote({other: at(5000)});
      expect(store.of(other), at(5000));
      expect(store.pending(), isEmpty);
    });

    test(
      'from server: identical record produces no disk write and no notify',
      () async {
        await store.applyRemote({key: at(5000)});
        final writes = box.writes;
        var notified = 0;
        store.addListener(() => notified++);
        await store.applyRemote({key: at(5000)});
        expect(box.writes, writes);
        expect(notified, 0);
      },
    );
  });

  group('restoration', () {
    test('empty or corrupt backup: empty, no exceptions', () async {
      for (final raw in <String?>[
        null,
        '',
        'не json',
        '[]',
        '7',
        '{"episodes": 5, "speeds": [], "dirty": {}}',
        '{"episodes": {"k": 5}, "speeds": {"f": "быстро"}, "dirty": [1, "нет"]}',
      ]) {
        box.data = raw;
        final fresh = PodcastProgressStore(box, clock: clock.call);
        await fresh.restore();
        expect(fresh.pending(), isEmpty, reason: '$raw');
        expect(fresh.of('k'), isNull, reason: '$raw');
        expect(fresh.speedOf('f'), 1.0, reason: '$raw');
      }
    });

    test('read failure yields empty without exceptions', () async {
      box.failRead = true;
      await store.restore();
      expect(store.pending(), isEmpty);
    });

    test('single corrupt line does not drop the rest', () async {
      box.data = jsonEncode({
        'v': 1,
        'episodes': {
          'bad': {'position_ms': -5, 'done': false, 'updated_at': 'x'},
          key: at(60000).toJson(),
        },
        'speeds': {feed: 1.6, 'bad': 'x'},
        'dirty': [key, 'bad', 'ghost'],
      });
      await store.restore();
      expect(store.of(key), at(60000));
      expect(store.of('bad'), isNull);
      expect(store.speedOf(feed), 1.5);
      expect(store.pending().keys, [key]);
    });

    test('report before restore is not overwritten by old backup', () async {
      box.data = jsonEncode({
        'v': 1,
        'episodes': {key: at(60000).toJson()},
        'speeds': {feed: 2.0},
        'dirty': <String>[],
      });
      clock.tick(const Duration(hours: 1));
      // Disk write fails: cached store retains old state.
      box.failWrite = true;
      await store.setSpeed(feed, 1.5);
      await store.report(key, 120000, durationMs: hour);
      await store.restore();
      expect(store.of(key)!.positionMs, 120000);
      expect(store.speedOf(feed), 1.5);
      expect(store.pending().keys, [key]);
    });

    test('restore notifies listeners', () async {
      box.data = jsonEncode({
        'v': 1,
        'episodes': {key: at(60000).toJson()},
      });
      var notified = 0;
      store.addListener(() => notified++);
      await store.restore();
      expect(notified, 1);
    });
  });

  group('capacity and cleanup', () {
    test('max 5000 episodes: oldest synced are evicted', () async {
      expect(PodcastProgressStore.maxEpisodes, 5000);
      final remote = <String, EpisodeProgress>{
        for (var n = 0; n < 5000; n++)
          'k$n': EpisodeProgress(
            positionMs: n,
            done: false,
            updatedAt: DateTime.utc(2026, 1, 1).add(Duration(minutes: n)),
          ),
      };
      await store.applyRemote(remote);
      clock.now = DateTime.utc(2025, 1, 1);
      await store.report('mine-old', 60000, durationMs: hour);
      expect(
        store.of('mine-old'),
        isNotNull,
        reason: 'unsent records are not discarded',
      );
      expect(store.of('k0'), isNull);
      expect(store.of('k1'), isNotNull);
      clock.now = DateTime.utc(2026, 10, 7);
      await store.report('mine-new', 60000, durationMs: hour);
      expect(store.of('k1'), isNull);
      expect(store.of('k2'), isNotNull);
      expect(store.of('k4999'), isNotNull);
      expect(store.pending().keys.toSet(), {'mine-old', 'mine-new'});
    });

    test('clear wipes everything including disk', () async {
      await store.report(key, 60000, durationMs: hour);
      await store.setSpeed(feed, 2.0);
      var notified = 0;
      store.addListener(() => notified++);
      await store.clear();
      expect(store.of(key), isNull);
      expect(store.speedOf(feed), 1.0);
      expect(store.pending(), isEmpty);
      expect(notified, 1);
      final again = PodcastProgressStore(box, clock: clock.call);
      await again.restore();
      expect(again.of(key), isNull);
      expect(again.speedOf(feed), 1.0);
    });

    test('time is taken from clock and stored in UTC', () async {
      final local = PodcastProgressStore(
        box,
        clock: () => DateTime.utc(2026, 10, 7, 12).toLocal(),
      );
      await local.report(key, 60000, durationMs: hour);
      expect(local.of(key)!.updatedAt.isUtc, isTrue);
      expect(
        (saved()['episodes'] as Map)[key]['updated_at'],
        '2026-10-07T12:00:00.000Z',
      );
    });
  });

  test('module makes no network calls and writes no logs', () {
    final source = File('lib/podcast_progress.dart').readAsStringSync();
    for (final word in [
      'package:http',
      'dart:io',
      'print(',
      'debugPrint',
      'developer.log',
    ]) {
      expect(source.contains(word), isFalse, reason: word);
    }
  });

  group('acceptance: clock, exit, write failure', () {
    test('clock moved back: fresh position is newer than old', () async {
      await store.report(key, 600000, durationMs: hour);
      final sent = store.of(key)!;
      await store.ack(key, sent);
      clock.tick(const Duration(hours: -1));
      await store.report(key, 900000, durationMs: hour, force: true);
      expect(store.of(key)!.updatedAt.isAfter(sent.updatedAt), isTrue);
      await store.applyRemote({key: sent});
      expect(store.of(key)!.positionMs, 900000);
      expect(store.pending().keys, [key]);
    });

    test('clock moved back: completed and new are also newer', () async {
      await store.report(key, 600000, durationMs: hour);
      final first = store.of(key)!;
      clock.tick(const Duration(hours: -1));
      await store.markDone(key);
      final done = store.of(key)!;
      expect(done.updatedAt.isAfter(first.updatedAt), isTrue);
      await store.markNew(key);
      expect(store.of(key)!.updatedAt.isAfter(done.updatedAt), isTrue);
    });

    test('clock moved back: disk write is not delayed by an hour', () async {
      await store.report(key, 1000, durationMs: hour);
      final before = box.writes;
      clock.tick(const Duration(hours: -1));
      await store.report(key, 2000, durationMs: hour);
      expect(box.writes, before + 1);
    });

    test(
      'after clear: player report and server response do not restore records',
      () async {
        await store.report(key, 60000, durationMs: hour);
        await store.clear();
        await store.report(key, 70000, durationMs: hour, force: true);
        await store.markDone(key);
        await store.markNew(key);
        await store.setSpeed(feed, 2.0);
        await store.applyRemote({key: at(5000, minute: 30)});
        expect(store.of(key), isNull);
        expect(store.pending(), isEmpty);
        expect(store.speedOf(feed), 1.0);
        expect(jsonDecode(box.data!)['episodes'], isEmpty);
      },
    );

    test('after clear: backup opens restore', () async {
      await store.clear();
      await store.restore();
      await store.report(key, 60000, durationMs: hour);
      expect(store.of(key)!.positionMs, 60000);
    });

    test('clear during restore: old backup is not restored', () async {
      await store.report(key, 60000, durationMs: hour);
      await store.setSpeed(feed, 2.0);
      final slow = _SlowReadBox(box.data!);
      final other = PodcastProgressStore(slow, clock: clock.call);
      final reading = other.restore();
      await other.clear();
      slow.gate.complete();
      await reading;
      expect(other.of(key), isNull);
      expect(other.speedOf(feed), 1.0);
      expect(other.pending(), isEmpty);
    });

    test('speed 1.0 chosen before restore finishes remains', () async {
      await store.setSpeed(feed, 1.5);
      final slow = _SlowReadBox(box.data!);
      final other = PodcastProgressStore(slow, clock: clock.call);
      final reading = other.restore();
      await other.setSpeed(feed, 1.0);
      slow.gate.complete();
      await reading;
      expect(other.speedOf(feed), 1.0);
    });

    test('clear and flush report whether record hit disk', () async {
      await store.report(key, 60000, durationMs: hour);
      expect(await store.flush(), isTrue);
      box.failWrite = true;
      expect(await store.clear(), isFalse);
      expect(await store.flush(), isFalse);
      box.failWrite = false;
      expect(await store.flush(), isTrue);
      expect(jsonDecode(box.data!)['episodes'], isEmpty);
    });

    test('restore after dispose does not notify listeners', () async {
      await store.report(key, 60000, durationMs: hour);
      final slow = _SlowReadBox(box.data!);
      final other = PodcastProgressStore(slow, clock: clock.call);
      final reading = other.restore();
      other.dispose();
      slow.gate.complete();
      await reading;
    });
  });
}

class _SlowReadBox implements PodcastProgressBox {
  _SlowReadBox(this.data);
  final Completer<void> gate = Completer<void>();
  String data;

  @override
  Future<String?> read() async {
    // Disk returns content present at query time.
    final was = data;
    await gate.future;
    return was;
  }

  @override
  Future<void> write(String value) async => data = value;
}
