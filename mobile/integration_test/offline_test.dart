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
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screen_dump.dart';
import 'test_session.dart';
import '../test/back.dart';

/// P6 exit on real phone: download → screen off → file intact → plays
/// without server.
///
/// Like background scenario, work is split between two sides. Test prints
/// `OFF_ASK=<action>`, and `scripts/device_offline.sh` sees line and performs
/// action via adb: minimizes app and turns screen off, wakes it and
/// removes USB tunnel to branch server — after this phone has no server.
/// Phone settings (airplane mode, Wi-Fi) are not touched: tunnel is
/// adb on Mac, not phone.
///
/// Long test tone is downloaded via "Favorites", not from player: played
/// song caches automatically (FT-527), and "download" after playback would finish
/// instantly without downloading anything. Test plays nothing before download.
///
/// Minimize app right after "download", not after checkmark: tone
/// is short and can finish downloading in a second, but if it didn'''t — background
/// must finish it. HiOS on TECNO kills background work more aggressively than pure
/// Android (plan/p6-offline.md, risks).
const toneId = 'f1070000-0000-4000-8000-000000000090';

/// Wait for app state change with timer, without `pump`: no frames in background.
Future<bool> lifecycle(
  bool Function(AppLifecycleState?) done,
  Duration limit,
) async {
  final deadline = DateTime.now().add(limit);
  while (!done(WidgetsBinding.instance.lifecycleState) &&
      DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  return done(WidgetsBinding.instance.lifecycleState);
}

void say(String line) {
  // ignore: avoid_print
  print(line);
}

void stage(String name) => say('FLOWTUNE_STAGE=$name');

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

  // Previous run downloads would survive reinstall, and "download" would finish
  // without downloading anything. Each run starts without music on phone.
  setUp(() async {
    await (await SharedPreferences.getInstance()).clear();
    final music = Directory(
      '${(await getApplicationSupportDirectory()).path}/music',
    );
    if (music.existsSync()) await music.delete(recursive: true);
  });

  testWidgets('downloads survive screen off and play without server', (
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

    // Tone to "Favorites": branch server has fresh database each time, no other songs
    // exist there.
    await tap(tester, find.byKey(const Key('tab-search')));
    await tester.enterText(
      find.byKey(const Key('search-field')),
      'flowtune test tone',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    final heart = find.byKey(const ValueKey('heart-$toneId'));
    expect(
      await appear(tester, heart, const Duration(seconds: 25)),
      isTrue,
      reason: 'search did not find long tone with heart',
    );
    // Heart is a toggle, and branch server lives for whole control run:
    // a run on broken code already added tone to "Favorites", and second tap
    // removed it from there — "download" did not appear (jobs 16975, 16788).
    bool liked() => tester.widget<IconButton>(heart.first).isSelected == true;
    if (!liked()) await tap(tester, heart);
    expect(liked(), isTrue, reason: 'tone was not added to Favorites');
    stage('found');

    // First "download" prompts for notification permission, and download waits
    // for answer. Test cannot click system dialog, and unclicked dialog stays on top
    // across subsequent runs (MR !247, jobs 16690 and 16708). Permission is granted
    // by script before tapping — just like a human would grant it.
    say('OFF_ASK=grant');
    await Future<void>.delayed(const Duration(seconds: 3));
    // While waiting without frames, search keyboard dismissed: tree must be repumped,
    // otherwise tabs are not in it yet (job 16726).
    final library = find.byKey(const Key('tab-library'));
    expect(
      await appear(tester, library, const Duration(seconds: 10)),
      isTrue,
      reason: 'no Library tab after granting permission',
    );
    await tap(tester, library);
    await tap(tester, find.byKey(const Key('library-favorites')));
    final download = find.byKey(const Key('download-favorites'));
    expect(
      await appear(tester, download, const Duration(seconds: 20)),
      isTrue,
      reason: 'no download button in Favorites',
    );
    await tap(tester, download);
    stage('asked');

    // How long screen is off is counted by script on Mac, which also wakes
    // phone: Android 14 freezes minimized app that is not
    // playing, and timer inside it stops (MR !247, job 16690 — test
    // was silent for 14 minutes instead of five). Download is handled by system downloader,
    // freeze does not affect it. Test only waits: went to background — returned.
    say('OFF_ASK=sleep');
    final left = await lifecycle(
      (state) => state != AppLifecycleState.resumed,
      const Duration(seconds: 30),
    );
    expect(left, isTrue, reason: 'app did not go to background');
    final back = await lifecycle(
      (state) => state == AppLifecycleState.resumed,
      const Duration(minutes: 12),
    );
    expect(back, isTrue, reason: 'app did not return to foreground');
    await Future<void>.delayed(const Duration(seconds: 2));
    await tester.pump();

    final done = find.descendant(
      of: download,
      matching: find.byKey(const Key('download-state-done')),
    );
    expect(
      await appear(tester, done, const Duration(seconds: 60)),
      isTrue,
      reason: 'tone not downloaded after screen off',
    );
    stage('downloaded');

    // Without server: screen needing server must navigate to downloaded music.
    say('OFF_ASK=offline');
    await Future<void>.delayed(const Duration(seconds: 2));
    await tapBack(tester);
    await tester.pump(const Duration(milliseconds: 600));
    await tap(tester, find.byKey(const Key('library-favorites')));
    final offline = find.byKey(const Key('offline-downloads'));
    expect(
      await appear(tester, offline, const Duration(seconds: 30)),
      isTrue,
      reason: 'Favorites did not offer Downloads without server',
    );
    await tap(tester, offline);
    final row = find.byKey(const Key('download-row-$toneId'));
    expect(
      await appear(tester, row, const Duration(seconds: 10)),
      isTrue,
      reason: 'no downloaded tone in Downloads',
    );
    await tap(tester, row);

    // Audio via real player: position must advance by three seconds.
    final playDeadline = DateTime.now().add(const Duration(seconds: 20));
    while (phase != AudioPhase.playing &&
        DateTime.now().isBefore(playDeadline)) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    final start = audio.position;
    final soundDeadline = DateTime.now().add(const Duration(seconds: 15));
    while ((audio.position - start).inMilliseconds < 3000 &&
        DateTime.now().isBefore(soundDeadline)) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    final playedMs = (audio.position - start).inMilliseconds;
    say('OFF_PLAYED_MS=$playedMs OFF_PHASE=$phase');
    if (playedMs < 3000) say('FLOWTUNE_SCREEN=${screenTexts()}');
    expect(
      playedMs,
      greaterThanOrEqualTo(3000),
      reason: 'downloaded tone does not play without server',
    );
    stage('playing');

    await audio.pause();
    say('OFF_ASK=online');
    expect(
      find.textContaining(
        'tor'
        'rent',
      ),
      findsNothing,
    );
    stage('offline-done');
  });
}
