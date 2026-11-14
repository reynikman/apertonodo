import 'dart:io';

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
import 'package:music_stream/screens/mini_player.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screen_dump.dart';
import 'test_session.dart';

/// FT-782: phone scenario "network dropped and returned" (P-A85, Beta requirement Бт-1).
///
/// Phone remains connected to Wi-Fi during the run (test does not touch phone settings),
/// so system connectivity_plus "network returned" signal
/// (FT-691) does not trigger here: the test checks specifically the automatic
/// scheduled retry (reconnectDelays in Player) when tunnel to server drops.
///
/// Test prints `NET_ASK=offline` and `NET_ASK=online`, and `scripts/device_network.sh`
/// tears down and restores USB tunnel `adb reverse`.
void say(String line) {
  // ignore: avoid_print
  print(line);
}

Future<bool> appear(WidgetTester tester, Finder finder, Duration limit) async {
  final deadline = DateTime.now().add(limit);
  while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 200));
  }
  final found = finder.evaluate().isNotEmpty;
  if (!found) say('FLOWTUNE_SCREEN=${screenTexts()}');
  return found;
}

Future<void> tap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder.first);
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await (await SharedPreferences.getInstance()).clear();
    final music = Directory(
      '${(await getApplicationSupportDirectory()).path}/music',
    );
    if (music.existsSync()) await music.delete(recursive: true);
  });

  testWidgets('music resumes automatically after drop and return of network', (
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

    // Find "Flowtune — Test Tone Long" and "Test Tone Short" via search.
    await tap(tester, find.byKey(const Key('tab-search')));
    await tester.enterText(
      find.byKey(const Key('search-field')),
      'flowtune test tone',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();

    expect(
      await appear(
        tester,
        find.text('Test Tone Long'),
        const Duration(seconds: 25),
      ),
      isTrue,
      reason: 'search did not find Test Tone Long',
    );
    expect(
      await appear(
        tester,
        find.text('Test Tone Short'),
        const Duration(seconds: 10),
      ),
      isTrue,
      reason: 'search did not find Test Tone Short',
    );

    // Tap Play on Test Tone Long: track selection queues all search results,
    // including Test Tone Short, and starts playback immediately.
    await tap(tester, find.text('Test Tone Long').first);
    expect(
      await appear(
        tester,
        find.byKey(const Key('mini-player')),
        const Duration(seconds: 25),
      ),
      isTrue,
      reason: 'mini-player did not appear after selecting track',
    );

    final player = tester.widget<MiniPlayer>(find.byType(MiniPlayer)).player;

    // Wait for first track audio.
    final playDeadline = DateTime.now().add(const Duration(seconds: 25));
    while (phase != AudioPhase.playing &&
        DateTime.now().isBefore(playDeadline)) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(phase, AudioPhase.playing, reason: 'sound did not start');

    final initialStart = audio.position;
    final soundDeadline = DateTime.now().add(const Duration(seconds: 15));
    while ((audio.position - initialStart).inMilliseconds < 1000 &&
        DateTime.now().isBefore(soundDeadline)) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(
      (audio.position - initialStart).inMilliseconds,
      greaterThanOrEqualTo(1000),
      reason: 'sound did not play',
    );

    // Save queue length and print request to disconnect network.
    final rememberedQueueLength = player.queue.length;
    expect(
      rememberedQueueLength,
      greaterThanOrEqualTo(2),
      reason: 'queue does not have Test Tone Short',
    );

    say('NET_ASK=offline');
    await Future<void>.delayed(const Duration(seconds: 2));

    // Prove drop: skip to next song in queue. Without server,
    // playback stops (waiting/retrying).
    await player.next();
    await tester.pump();

    // Track transition even on live network goes through "preparing audio", so
    // "not playing" alone is not enough: drop means silence for eight seconds straight.
    final breakDeadline = DateTime.now().add(const Duration(seconds: 30));
    var broke = false;
    DateTime? silentSince;
    while (DateTime.now().isBefore(breakDeadline)) {
      await tester.pump(const Duration(milliseconds: 200));
      if (phase == AudioPhase.playing) {
        silentSince = null;
        continue;
      }
      silentSince ??= DateTime.now();
      if (DateTime.now().difference(silentSince) >=
          const Duration(seconds: 8)) {
        broke = true;
        break;
      }
    }
    expect(broke, isTrue, reason: 'network break did not occur');
    say('NET_BREAK_SEEN');

    // Print request to restore network. Do not tap anything!
    say('NET_ASK=online');

    // Wait for audio for up to 90 s.
    final resumeDeadline = DateTime.now().add(const Duration(seconds: 90));
    while (phase != AudioPhase.playing &&
        DateTime.now().isBefore(resumeDeadline)) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(
      phase,
      AudioPhase.playing,
      reason: 'playback did not resume after network returned',
    );

    final resumeStart = audio.position;
    final resumeSoundDeadline = DateTime.now().add(const Duration(seconds: 15));
    while ((audio.position - resumeStart).inMilliseconds < 1000 &&
        DateTime.now().isBefore(resumeSoundDeadline)) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(
      (audio.position - resumeStart).inMilliseconds,
      greaterThanOrEqualTo(1000),
      reason: 'sound does not play after network returned',
    );

    // Verify: queue length unchanged, next song in queue is playing.
    expect(
      player.queue.length,
      rememberedQueueLength,
      reason: 'queue length changed',
    );
    expect(
      player.current?.title,
      'Test Tone Short',
      reason: 'not playing the next song in queue',
    );

    say('NET_RESUMED');

    await audio.pause();
    expect(
      find.textContaining(
        'tor'
        'rent',
      ),
      findsNothing,
    );
  });
}
