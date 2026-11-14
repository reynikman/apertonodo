// FT-696: "preparing audio" only after threshold (H6-5). Check written by lead before work.
//
// Contract:
// - `preparingDelay` = 1.5 s;
// - `showPreparing`: no rebuffering (`since == null`) — false; before first audio — immediately true;
//   after first audio — true only when rebuffering lasts strictly longer than `preparingDelay`;
// - `preparingRecheck`: when label not yet shown, but will be shown — how long until recheck
//   (remainder until threshold plus 1 ms, so recheck falls past threshold); otherwise `null`.
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/buffering_notice.dart';

final t0 = DateTime.utc(2026, 10, 9, 12);
DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

void main() {
  test('threshold is one and a half seconds', () {
    expect(preparingDelay, const Duration(milliseconds: 1500));
  });

  group('showPreparing', () {
    for (final (since, nowMs, played, want) in <(DateTime?, int, bool, bool)>[
      (null, 0, false, false),
      (null, 5000, true, false),
      (t0, 0, false, true),
      (t0, 10, false, true),
      (t0, 5000, false, true),
      (t0, 0, true, false),
      (t0, 1000, true, false),
      (t0, 1499, true, false),
      (t0, 1500, true, false),
      (t0, 1501, true, true),
      (t0, 60000, true, true),
      (t0, -500, true, false),
    ]) {
      test(
        'since=${since == null ? 'none' : 't0'} now=+$nowMs played=$played → $want',
        () {
          expect(
            showPreparing(since: since, now: at(nowMs), playedOnce: played),
            want,
          );
        },
      );
    }
  });

  group('preparingRecheck', () {
    test('no buffering: null', () {
      expect(preparingRecheck(since: null, now: t0, playedOnce: true), isNull);
      expect(preparingRecheck(since: null, now: t0, playedOnce: false), isNull);
    });

    test('before first sound: null (notice already visible)', () {
      expect(
        preparingRecheck(since: t0, now: at(100), playedOnce: false),
        isNull,
      );
    });

    test('just started: remainder to threshold + 1 ms', () {
      expect(
        preparingRecheck(since: t0, now: t0, playedOnce: true),
        const Duration(milliseconds: 1501),
      );
    });

    test('one second elapsed: 501 ms', () {
      expect(
        preparingRecheck(since: t0, now: at(1000), playedOnce: true),
        const Duration(milliseconds: 501),
      );
    });

    test('exactly at threshold: 1 ms', () {
      expect(
        preparingRecheck(since: t0, now: at(1500), playedOnce: true),
        const Duration(milliseconds: 1),
      );
    });

    test('past threshold: null (notice already shown)', () {
      expect(
        preparingRecheck(since: t0, now: at(1501), playedOnce: true),
        isNull,
      );
      expect(
        preparingRecheck(since: t0, now: at(9000), playedOnce: true),
        isNull,
      );
    });

    test('recheck at scheduled time displays notice', () {
      for (final startMs in [0, 1, 700, 1499, 1500]) {
        final wait = preparingRecheck(
          since: t0,
          now: at(startMs),
          playedOnce: true,
        )!;
        final later = at(startMs).add(wait);
        expect(
          showPreparing(since: t0, now: later, playedOnce: true),
          isTrue,
          reason: 'start +$startMs',
        );
        expect(
          showPreparing(
            since: t0,
            now: later.subtract(const Duration(milliseconds: 1)),
            playedOnce: true,
          ),
          isFalse,
          reason: '1 ms earlier is too early, start +$startMs',
        );
      }
    });

    test('clock jumped back: recheck not shorter than threshold', () {
      final wait = preparingRecheck(
        since: t0,
        now: at(-500),
        playedOnce: true,
      )!;
      expect(wait, greaterThanOrEqualTo(preparingDelay));
    });
  });
}
