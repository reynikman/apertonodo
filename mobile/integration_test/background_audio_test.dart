import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:music_stream/auth/session_store.dart';
import 'package:music_stream/auth/token_provider.dart';
import 'package:music_stream/device_audio.dart';
import 'package:music_stream/env.dart';
import 'package:music_stream/main.dart'
    show buildProductionApp, initBackgroundAudio;
import 'package:music_stream/playback.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screen_dump.dart';
import 'test_session.dart';

/// Background playback, notification, and system media controls on a real phone.
///
/// The work is split between two sides because neither side sees everything.
/// Android renders no frames for a minimized app: there is nothing for `tester.pump()`
/// to wait for in the background, and the screen ceases to be a witness. On the other hand,
/// the real player — its position and state — is visible from inside the process.
/// But the process cannot minimize itself, press the system pause button, or ask Android
/// whether the notification is visible.
///
/// Therefore the test prints a `BG_ASK=<action>` line, and
/// `scripts/device_background.sh` sees it and performs the action via adb. It also
/// asks Android about the service and notification. A failure on either side
/// fails the run.
///
/// A long test tone plays ("Flowtune — Test Tone Long", 90 seconds).
/// The four-second "Test Tone Short" would end before the phone had time to
/// minimize. Previously the tone was named "Nothing Else Matters" and with the live catalog
/// replaced the real song — the owner heard it as "ultrasound".

void say(String line) {
  // ignore: avoid_print
  print(line);
}

/// Wait without `pump`: there are no frames in the background, but Dart timers still run.
Future<void> waitUntil(bool Function() done, Duration limit) async {
  final deadline = DateTime.now().add(limit);
  while (!done() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  if (!done()) {
    // ignore: avoid_print
    print('FLOWTUNE_SCREEN=${screenTexts()}');
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // The mini-player after launch shows the song from the previous run (LastPlayed),
  // and "Test Tone Long" was found in it earlier than in search results. Each run
  // starts with a clean phone state.
  setUp(() async => (await SharedPreferences.getInstance()).clear());

  testWidgets('minimized app plays and responds to system buttons', (
    tester,
  ) async {
    await seedTestSession();
    final tokens = TokenProvider(
      SessionStore(),
      server: Uri.parse(AppEnv.apiBaseUrl),
    );
    await tokens.load();
    await initBackgroundAudio();
    final audio = DeviceAudio();
    var phase = AudioPhase.idle;
    final states = audio.states.listen((status) => phase = status.phase);
    addTearDown(states.cancel);

    await tester.pumpWidget(buildProductionApp(audio: audio, tokens: tokens));
    await tester.pump();
    await tester.tap(find.byKey(const Key('tab-search')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('search-field')),
      // Both tones: search results are the queue, and short follows long. The system
      // "next" button is tested on it.
      'flowtune test tone',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    final searchDeadline = DateTime.now().add(const Duration(seconds: 25));
    while (find.text('Test Tone Long').evaluate().isEmpty &&
        DateTime.now().isBefore(searchDeadline)) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    if (find.text('Test Tone Long').evaluate().isEmpty) {
      // ignore: avoid_print
      print('FLOWTUNE_SCREEN=${screenTexts()}');
    }
    expect(
      find.text('Test Tone Long'),
      findsWidgets,
      reason: 'search did not find long fixture',
    );
    // Tapping a track immediately plays it.
    await tester.tap(find.text('Test Tone Long').first);
    await tester.pump();
    final playDeadline = DateTime.now().add(const Duration(seconds: 25));
    while (phase != AudioPhase.playing &&
        DateTime.now().isBefore(playDeadline)) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(
      phase,
      AudioPhase.playing,
      reason: 'sound did not start before minimizing - nothing to check',
    );

    // Next the app goes to background, and throwing exceptions from there is forbidden:
    // a failed `expect` would abort test in the middle, leaving the phone with
    // an app playing in the background, and next `pump` would wait for a frame
    // that no one will render for a minimized window. Therefore discrepancies
    // are collected into a list and checked once back in foreground.
    final problems = <String>[];

    say('BG_ASK=home');
    await Future<void>.delayed(const Duration(seconds: 3));
    final backgroundStart = audio.position;
    await Future<void>.delayed(const Duration(seconds: 20));
    final playedMs = (audio.position - backgroundStart).inMilliseconds;
    say('BG_BACKGROUND_MS=$playedMs');
    say('BG_BACKGROUND_PHASE=$phase');
    if (playedMs < 16000) {
      problems.add('в фоне проиграно $playedMs мс за 20 секунд');
    }

    say('BG_ASK=pause');
    await waitUntil(
      () => phase == AudioPhase.paused,
      const Duration(seconds: 15),
    );
    if (phase != AudioPhase.paused) {
      problems.add('системная пауза не остановила звук: состояние $phase');
    }
    // Position — one second after pause, not immediately. System pause
    // comes from native side: just_audio first updates `playing`, while
    // position during pause is returned from player's last event — in the background it was
    // ~24 seconds ago. The event with real position arrives right after, and
    // a snapshot caught in that gap gave "position drifted by 24012 ms"
    // while audio was stopped (docs/troubleshooting.md, section 16).
    await Future<void>.delayed(const Duration(seconds: 1));
    final atPause = audio.position;
    await Future<void>.delayed(const Duration(seconds: 3));
    final driftMs = (audio.position - atPause).inMilliseconds;
    if (driftMs.abs() > 500) {
      problems.add('на паузе позиция уехала на $driftMs мс');
    }

    say('BG_ASK=play');
    await waitUntil(
      () => phase == AudioPhase.playing,
      const Duration(seconds: 15),
    );
    if (phase != AudioPhase.playing) {
      problems.add('системный play не вернул звук: состояние $phase');
    }
    // Wait not for "five seconds by the clock", but "until three seconds of audio have played".
    // After pause the player refills buffer, and reaching a real server over network takes
    // longer than reaching the server on Mac: a fixed five-second window
    // failed at 1868 ms even though sound was playing. We verify what we intended to verify —
    // that system play actually resumed playback.
    final resumeStart = audio.position;
    final resumeAskedAt = DateTime.now();
    final resumeDeadline = resumeAskedAt.add(const Duration(seconds: 20));
    while ((audio.position - resumeStart).inMilliseconds < 3000 &&
        DateTime.now().isBefore(resumeDeadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    final resumedMs = (audio.position - resumeStart).inMilliseconds;
    final resumeWaitMs = DateTime.now()
        .difference(resumeAskedAt)
        .inMilliseconds;
    say('BG_RESUMED_MS=$resumedMs BG_RESUME_WAIT_MS=$resumeWaitMs');
    if (resumedMs < 3000) {
      problems.add(
        'после системного play проиграно $resumedMs мс за $resumeWaitMs мс ожидания',
      );
    }

    // System "next" — same session as button in notification shade, lock
    // screen, and headset. It must start next song in queue
    // rather than stay silent: there is no playlist in player, queue belongs to [Player].
    say('BG_ASK=next');
    String? shown() => systemSession?.mediaItem.value?.title;
    await waitUntil(
      () => shown() == 'Test Tone Short' && phase == AudioPhase.playing,
      const Duration(seconds: 25),
    );
    say('BG_NEXT=${shown()} $phase');
    if (shown() != 'Test Tone Short' || phase != AudioPhase.playing) {
      problems.add(
        'системная «вперёд» не включила следующую: ${shown()}, $phase',
      );
    }

    // The short test tone lasts four seconds. Stop it after verifying the
    // system skip, before the foreground handoff can outlast it and trigger
    // another automatic queue advance during test teardown.
    await audio.pause();
    say('BG_ASK=foreground');
    await Future<void>.delayed(const Duration(seconds: 5));
    await tester.pump();

    expect(problems, isEmpty, reason: problems.join('; '));
    expect(
      find.textContaining(
        'tor'
        'rent',
      ),
      findsNothing,
    );
    say('BG_OK');
  });
}
