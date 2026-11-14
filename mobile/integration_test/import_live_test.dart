import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:music_stream/auth/session_store.dart';
import 'package:music_stream/auth/token_provider.dart';
import 'package:music_stream/env.dart';
import 'package:music_stream/main.dart' show buildProductionApp;
import 'package:music_stream/screens/library_screens.dart' show PlaylistScreen;
import 'package:music_stream/screens/parts.dart' show TrackTile;
import 'screen_dump.dart';
import 'test_session.dart';

/// P5 exit (`plan/p5-import.md`, step 7): import from phone to playlist —
/// text → report → "Save" → playlist, where missing line sits in
/// its place dimmed with "not found" label. Runs in `device_ci.sh`: in MR —
/// against branch server, on `main` — against live https address via NPM
/// (import body is POST with base64, passed through same proxy).
///
/// File cannot be picked here: system file picker is inaccessible to test. Text
/// paste takes same path: same bytes in base64, same `POST /v1/imports`.
/// Test cleans up after itself: "Import" playlist is deleted; import report
/// is pruned automatically by server after 24h. No songs play — nothing goes to history.
void stage(String name) {
  // ignore: avoid_print
  print('FLOWTUNE_STAGE=$name');
}

Future<bool> appear(WidgetTester tester, Finder finder, Duration limit) async {
  final deadline = DateTime.now().add(limit);
  while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 200));
  }
  final found = finder.evaluate().isNotEmpty;
  if (!found) {
    // ignore: avoid_print
    print('FLOWTUNE_SCREEN=${screenTexts()}');
  }
  return found;
}

Future<bool> gone(WidgetTester tester, Finder finder, Duration limit) async {
  final deadline = DateTime.now().add(limit);
  while (finder.evaluate().isNotEmpty && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 200));
  }
  return finder.evaluate().isEmpty;
}

Future<void> tap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 600));
}

/// Second line will not be found anywhere: no such song in catalog or releases.
const lost = 'No Such Song Apertono';
const text = 'Flowtune — Test Tone Long\nNobody Band Apertono — $lost\n';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('import: text -> report -> playlist with missing row kept', (
    tester,
  ) async {
    await seedTestSession();
    final tokens = TokenProvider(
      SessionStore(),
      server: Uri.parse(AppEnv.apiBaseUrl),
    );
    await tokens.load();
    await tester.pumpWidget(buildProductionApp(tokens: tokens));
    await tester.pump();

    await tap(tester, find.byKey(const Key('tab-library')));
    await tap(tester, find.byKey(const Key('library-import')));
    expect(
      await appear(
        tester,
        find.byKey(const Key('import-paste')),
        const Duration(seconds: 30),
      ),
      isTrue,
    );
    await tap(tester, find.byKey(const Key('import-paste')));
    await tester.enterText(find.byKey(const Key('import-text')), text);
    await tester.pump();
    await tap(tester, find.byKey(const Key('import-send')));
    stage('sent');

    // Single list — report opens immediately, without overview.
    final summary = find.byKey(const Key('import-summary'));
    expect(
      await appear(tester, summary, const Duration(seconds: 60)),
      isTrue,
      reason: 'import report not received',
    );
    expect(
      tester.widget<Text>(summary).data,
      contains('из 2'),
      reason: 'report does not have two rows',
    );
    expect(find.text('Сервер недоступен'), findsNothing);
    stage('report');

    await tap(tester, find.byKey(const Key('import-save')));
    // Report has same title "Import" and same lines — wait specifically
    // for playlist screen, otherwise test would pass without reaching it.
    final playlist = find.byType(PlaylistScreen);
    expect(
      await appear(tester, playlist, const Duration(seconds: 30)),
      isTrue,
      reason: 'import playlist did not open',
    );
    // Playlist screen slides in over report: during transition both are visible.
    // Wait until report is gone, rather than checking first frame (main 2149: failed
    // at this exact spot, green in MR).
    expect(
      await gone(
        tester,
        find.byKey(const Key('import-summary')),
        const Duration(seconds: 5),
      ),
      isTrue,
      reason: 'after save report stayed instead of playlist',
    );
    final row = find.descendant(of: playlist, matching: find.text(lost));
    expect(
      await appear(tester, row, const Duration(seconds: 30)),
      isTrue,
      reason: 'missing track not in playlist',
    );
    // Test tone might be found or might not (not in catalog copy):
    // verify badge on line that is definitely missing.
    final tile = find.ancestor(of: row, matching: find.byType(TrackTile));
    expect(
      find.descendant(of: tile, matching: find.textContaining('не нашлось')),
      findsOneWidget,
    );
    stage('playlist');

    // Clean up after itself. Import screen was replaced by playlist, so after
    // deletion — back to "My music" menu.
    await tap(tester, find.byTooltip('Удалить плейлист'));
    await tap(tester, find.text('Удалить'));
    expect(
      await appear(
        tester,
        find.byKey(const Key('library-import')),
        const Duration(seconds: 30),
      ),
      isTrue,
      reason: 'playlist was not deleted - cleanup failed',
    );
    // Menu appears while playlist screen is still sliding away (main 2153).
    expect(
      await gone(
        tester,
        find.widgetWithText(AppBar, 'Импорт'),
        const Duration(seconds: 5),
      ),
      isTrue,
      reason: 'playlist screen remained after deletion',
    );
    stage('deleted');
  });
}
