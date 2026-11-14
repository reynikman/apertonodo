import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/l10n/l10n.dart';
import 'package:music_stream/models/track.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/player.dart';
import 'package:music_stream/screens/sleep_timer_sheet.dart';
import 'package:music_stream/sleep_timer.dart';

import 'fakes.dart';

/// FT-619 (P-A85, beta requirement): sleep timer. User falls asleep to music —
/// playback pauses automatically after chosen duration or at track end.
/// Pause rather than stop: morning Play resumes from same position.
///
/// What tests do not prove: smooth fade-out (out of scope for this card)
/// and Android process lifecycle killing — verified on owner device.
void main() {
  late FakeAudio audio;

  setUp(() => audio = FakeAudio());
  tearDown(() => audio.close());

  Future<Player> playing(FakePlayback playback, List<Track> queue) async {
    final player = Player(playback: playback, audio: audio);
    addTearDown(player.dispose);
    await player.playQueue(queue);
    audio.emit(AudioPhase.playing);
    await settle();
    return player;
  }

  Future<void> until(bool Function() done, {String reason = ''}) async {
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('timeout after 3s: $reason');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test('time is up - playback paused, timer cleared', () async {
    final p = await playing(FakePlayback(), [sandman]);
    final timer = SleepTimer(player: p);
    addTearDown(timer.dispose);
    // Track start mutes previous track (`audio.pause()` in `_play`) — measure from here.
    final before = audio.pauses;

    timer.start(const Duration(milliseconds: 80));
    expect(timer.active, isTrue);
    expect(audio.pauses, before);

    await until(() => audio.pauses == before + 1, reason: 'timer pause');
    expect(timer.active, isFalse);
    expect(audio.stops, 0, reason: 'pause not stop - resume from here');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(audio.pauses, before + 1, reason: 'single pause, no more');
  });

  test('remaining time by clock, not tick count', () async {
    var now = DateTime(2026, 10, 6, 23);
    final p = await playing(FakePlayback(), [sandman]);
    final timer = SleepTimer(player: p, clock: () => now);
    addTearDown(timer.dispose);

    timer.start(const Duration(minutes: 30));
    expect(timer.left, const Duration(minutes: 30));
    now = now.add(const Duration(minutes: 12));
    expect(timer.left, const Duration(minutes: 18));
    expect(timer.endOfTrack, isFalse);
  });

  test('disabled: no pause; new duration replaces old', () async {
    final p = await playing(FakePlayback(), [sandman]);
    final timer = SleepTimer(player: p);
    addTearDown(timer.dispose);
    final before = audio.pauses;

    timer.start(const Duration(milliseconds: 60));
    timer.cancel();
    expect(timer.active, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(audio.pauses, before);

    timer.start(const Duration(milliseconds: 60));
    timer.start(const Duration(milliseconds: 250));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(audio.pauses, before, reason: 'old timer did not fire');
    await until(() => audio.pauses == before + 1, reason: 'new timer');
  });

  test('music already paused - timer does not resume', () async {
    final p = await playing(FakePlayback(), [sandman]);
    final timer = SleepTimer(player: p);
    addTearDown(timer.dispose);
    await p.toggle();
    audio.emit(AudioPhase.paused, position: const Duration(seconds: 40));
    await settle();
    final resumes = audio.resumes;

    timer.start(const Duration(milliseconds: 40));
    await until(() => !timer.active, reason: 'timer inactive');
    await settle();
    expect(audio.resumes, resumes, reason: 'pause instead of skip');
    expect(p.phase, AudioPhase.paused);
  });

  test('end of track - next track does not start', () async {
    final playback = FakePlayback(['https://example.test/s/first']);
    playback.onPrepare = (id) => 'https://example.test/s/ahead-$id';
    final p = await playing(playback, [sandman, duality]);
    final timer = SleepTimer(player: p);
    addTearDown(timer.dispose);
    expect(audio.queuedNow, isNotNull, reason: 'next queued in advance');

    timer.untilEndOfTrack();
    await settle();
    expect(timer.active, isTrue);
    expect(timer.endOfTrack, isTrue);
    expect(audio.queuedNow, isNull, reason: 'unqueue next track');

    audio.tick(const Duration(seconds: 200));
    audio.emit(AudioPhase.playing, position: const Duration(seconds: 200));
    await settle();
    expect(audio.queuedNow, isNull, reason: 'still not queued');

    audio.finish();
    await settle();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(audio.played, hasLength(1), reason: 'second track did not play');
    expect(playback.started, [sandman.id]);
    expect(p.current, sandman);
    expect(timer.active, isFalse);
  });

  test('"end of track" disabled - playback advances', () async {
    final playback = FakePlayback(['https://example.test/s/first']);
    playback.onPrepare = (id) => 'https://example.test/s/ahead-$id';
    final p = await playing(playback, [sandman, duality]);
    final timer = SleepTimer(player: p);
    addTearDown(timer.dispose);

    timer.untilEndOfTrack();
    await settle();
    timer.cancel();
    audio.emit(AudioPhase.playing, position: const Duration(seconds: 10));
    await settle();
    expect(audio.queuedNow, isNotNull, reason: 'next track requeued');
  });

  test('timer changes notified to UI', () async {
    final p = await playing(FakePlayback(), [sandman]);
    final timer = SleepTimer(player: p);
    addTearDown(timer.dispose);
    var heard = 0;
    timer.addListener(() => heard++);
    timer.start(const Duration(minutes: 15));
    timer.untilEndOfTrack();
    timer.cancel();
    expect(heard, greaterThanOrEqualTo(3));
  });

  for (final (locale, left, endLabel) in [
    (const Locale('ru'), 'Осталось 30 мин', 'До конца песни'),
    (const Locale('en'), '30 min left', 'End of song'),
  ]) {
    testWidgets('selection screen - $locale', (tester) async {
      final p = Player(playback: FakePlayback(), audio: audio);
      addTearDown(p.dispose);
      final timer = SleepTimer(player: p);
      addTearDown(timer.dispose);

      await tester.pumpWidget(
        MaterialApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: SleepTimerSheet(timer: timer)),
        ),
      );
      for (final key in [
        'sleep-15',
        'sleep-30',
        'sleep-45',
        'sleep-60',
        'sleep-end-of-track',
      ]) {
        expect(find.byKey(Key(key)), findsOneWidget, reason: key);
        expect(
          tester.getSize(find.byKey(Key(key))).height,
          greaterThanOrEqualTo(48),
          reason: 'touch target at least 48 dp',
        );
      }
      expect(find.text(endLabel), findsOneWidget);
      expect(find.byKey(const Key('sleep-off')), findsNothing);

      await tester.tap(find.byKey(const Key('sleep-30')));
      await tester.pump();
      expect(timer.active, isTrue);
      expect(find.textContaining(left), findsOneWidget);
      expect(find.byKey(const Key('sleep-off')), findsOneWidget);

      await tester.tap(find.byKey(const Key('sleep-off')));
      await tester.pump();
      expect(timer.active, isFalse);
      timer.cancel();
    });
  }
}
