import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:music_stream/auth/login.dart' show serverOrigin;
import 'package:music_stream/auth/session_store.dart';
import 'package:music_stream/env.dart';
import 'package:music_stream/main.dart' show buildProductionApp;
import 'package:shared_preferences/shared_preferences.dart';
import 'screen_dump.dart';
import 'test_session.dart';

/// String for negative control (scripts/unlazy/mutation_control.mjs): indicates
/// which step the test reached, so stream breakage failure is not
/// confused with search failure.
void stage(String name) {
  // ignore: avoid_print
  print('FLOWTUNE_STAGE=$name');
}

Future<void> waitFor(WidgetTester tester, Finder finder, Duration limit) async {
  final deadline = DateTime.now().add(limit);
  while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 200));
  }
  if (finder.evaluate().isEmpty) {
    // ignore: avoid_print
    print('FLOWTUNE_SCREEN=${screenTexts()}');
  }
}

Finder playing(String title) => find.descendant(
  of: find.byKey(const Key('mini-player')),
  matching: find.text(title),
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Mini-player after launch shows song from previous run (LastPlayed),
  // and "Test Tone Long" was found in it earlier than in search results. Each run
  // starts with a clean phone state.
  setUp(() async => (await SharedPreferences.getInstance()).clear());

  // Test tones, not songs: on live address "duality" finds real
  // recording, and test would pull a real release. A tone under real
  // song title was the "ultrasound" heard by owner on September 18.
  testWidgets('tapping track plays immediately, track change plays new', (
    tester,
  ) async {
    // Launch like a returning user (FT-537): token and account
    // are saved, app loads them itself, like `main()`. Previously test
    // provided ready login, account was known from first frame, and robot did not
    // catch breakage on 03.10: DB was opened twice — for `unknown` and for
    // account, — and Play never reached server (FT-535).
    await seedTestSession();
    final server = Uri.parse(AppEnv.apiBaseUrl).origin;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('active-server', server);
    await prefs.setString('active-user', 'device-cold-start');
    // `main()` reads token before first frame; account — only after.
    final sessions = SessionStore();
    await sessions.readToken();
    await tester.pumpWidget(
      buildProductionApp(
        sessions: sessions,
        initialServer: serverOrigin(server),
      ),
    );
    // Account loads after first frame, like for a human: tabs
    // do not appear immediately. If they did not appear — app stuck on login,
    // and screen will be dumped to log.
    await waitFor(
      tester,
      find.byKey(const Key('tab-search')),
      const Duration(seconds: 15),
    );
    // Arrived account opens its DB and rebuilds screens — tab
    // resets to Home. Tap "Search" until field appears.
    final field = find.byKey(const Key('search-field'));
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (field.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
      if (find.byKey(const Key('tab-search')).evaluate().isNotEmpty) {
        await tester.tap(find.byKey(const Key('tab-search')));
      }
      await tester.pump(const Duration(milliseconds: 300));
    }
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('search-field')),
      'flowtune test tone',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await waitFor(
      tester,
      find.text('Test Tone Long'),
      const Duration(seconds: 25),
    );
    expect(find.text('Test Tone Long'), findsWidgets);
    expect(find.text('Test Tone Short'), findsWidgets);
    stage('found');

    // Selection means play: second tap not needed (owner bug on September 18).
    await tester.tap(find.text('Test Tone Long').first);
    await tester.pump();
    await waitFor(
      tester,
      find.byKey(const Key('pause-button')),
      const Duration(seconds: 25),
    );
    expect(playing('Test Tone Long'), findsOneWidget);
    expect(find.byKey(const Key('pause-button')), findsOneWidget);
    stage('playing');

    // Another song during playback plays, does not pause.
    await tester.tap(find.text('Test Tone Short').first);
    await tester.pump();
    await waitFor(
      tester,
      playing('Test Tone Short'),
      const Duration(seconds: 5),
    );
    await waitFor(
      tester,
      find.byKey(const Key('pause-button')),
      const Duration(seconds: 25),
    );
    expect(playing('Test Tone Short'), findsOneWidget);
    expect(find.byKey(const Key('pause-button')), findsOneWidget);
    expect(find.byKey(const Key('play-button')), findsNothing);
    stage('switched');

    expect(
      find.textContaining(
        'tor'
        'rent',
      ),
      findsNothing,
    );
  });
}
