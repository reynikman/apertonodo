import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:music_stream/auth/session_store.dart';
import 'package:music_stream/auth/token_provider.dart';
import 'package:music_stream/env.dart';
import 'package:music_stream/main.dart' show buildProductionApp;
import 'screen_dump.dart';
import 'test_session.dart';
import '../test/back.dart';

/// "My music" on live server, from phone:
///
///   MUSIC_API_BASE_URL=https://music.example.org \
///     bash scripts/device_run.sh integration_test/library_live_test.dart 900
///
/// Screen tests talk to fake server and miss what stands in front of
/// the real one: NPM allows only GET, HEAD, and POST, and on production address
/// renaming playlist failed (Phase H, docs/troubleshooting.md item 27).
/// Here the same path goes through NPM for real.
///
/// Test cleans up after itself: creates its playlist from test tones,
/// reorders, renames, and deletes it. Favorites and history are
/// not touched, no songs play — nothing enters history.
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

const name = 'Проба Apertono';
const renamed = 'Проба Apertono 2';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('live server playlist: create, add, reorder, delete', (
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

    // Favorites and history must open: these are GET, but they would also bypass
    // fake server.
    await tap(tester, find.byKey(const Key('tab-library')));
    await tap(tester, find.byKey(const Key('library-favorites')));
    expect(
      await appear(
        tester,
        find.widgetWithText(AppBar, 'Любимые песни'),
        const Duration(seconds: 30),
      ),
      isTrue,
    );
    expect(find.text('Сервер недоступен'), findsNothing);
    await tapBack(tester);
    await tester.pump(const Duration(milliseconds: 600));

    await tap(tester, find.text('История'));
    expect(
      await appear(
        tester,
        find.widgetWithText(AppBar, 'История'),
        const Duration(seconds: 30),
      ),
      isTrue,
    );
    expect(find.text('Сервер недоступен'), findsNothing);
    await tapBack(tester);
    await tester.pump(const Duration(milliseconds: 600));
    stage('library');

    // Custom playlist.
    await tap(tester, find.text('Плейлисты'));
    expect(
      await appear(
        tester,
        find.text('Новый плейлист'),
        const Duration(seconds: 30),
      ),
      isTrue,
    );
    await tap(tester, find.text('Новый плейлист'));
    await tester.enterText(find.byKey(const Key('name-field')), name);
    await tester.pump();
    await tap(tester, find.text('Сохранить'));
    expect(
      await appear(tester, find.text(name), const Duration(seconds: 30)),
      isTrue,
      reason: 'playlist did not appear in list',
    );
    stage('created');

    // Playlist list overlays menu — back first, otherwise lower
    // menu items cannot be tapped.
    await tapBack(tester);
    await tester.pump(const Duration(milliseconds: 600));

    // Two songs from search — test tones, not third-party music.
    await tester.tap(find.byKey(const Key('tab-search')));
    await tester.pumpAndSettle();
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
        const Duration(seconds: 30),
      ),
      isTrue,
    );
    for (final song in ['Test Tone Long', 'Test Tone Short']) {
      // Menu is in row of this exact song: result order is not guaranteed.
      final row = find.ancestor(
        of: find.text(song),
        matching: find.byType(ListTile),
      );
      await tap(
        tester,
        find.descendant(of: row, matching: find.byTooltip('Ещё')),
      );
      await tap(tester, find.text('Добавить в плейлист'));
      expect(
        await appear(tester, find.text(name), const Duration(seconds: 30)),
        isTrue,
        reason: 'own playlist not in playlists list',
      );
      await tap(tester, find.text(name));
      expect(
        await appear(
          tester,
          find.textContaining('Добавлено'),
          const Duration(seconds: 30),
        ),
        isTrue,
        reason: 'server rejected song in playlist',
      );
      await tester.pump(const Duration(seconds: 4));
    }
    stage('tracks');

    // Search is a tab (FT-472): nav bar in place, back not needed.
    // Order: `POST .../order` with full list — the very path that NPM
    // rejected while it was PUT.
    await tap(tester, find.byKey(const Key('tab-library')));
    await tap(tester, find.text('Плейлисты'));
    expect(
      await appear(tester, find.text(name), const Duration(seconds: 30)),
      isTrue,
    );
    await tap(tester, find.text(name));
    expect(
      await appear(
        tester,
        find.byType(ReorderableListView),
        const Duration(seconds: 30),
      ),
      isTrue,
    );
    tester
        .widget<ReorderableListView>(find.byType(ReorderableListView))
        .onReorderItem!(0, 1);
    await tester.pump(const Duration(seconds: 3));
    expect(
      find.text('Плейлист изменился — показан текущий'),
      findsNothing,
      reason: 'server rejected new order',
    );
    expect(find.text('Сервер недоступен'), findsNothing);
    final top = tester.getTopLeft(find.text('Test Tone Short')).dy;
    expect(
      tester.getTopLeft(find.text('Test Tone Long')).dy,
      greaterThan(top),
      reason: 'order on screen did not change',
    );
    stage('order');

    // Rename — `POST .../rename`.
    await tap(tester, find.byTooltip('Переименовать'));
    await tester.enterText(find.byKey(const Key('name-field')), renamed);
    await tester.pump();
    await tap(tester, find.text('Сохранить'));
    expect(
      await appear(
        tester,
        find.widgetWithText(AppBar, renamed),
        const Duration(seconds: 30),
      ),
      isTrue,
    );
    stage('renamed');

    // Delete — `POST .../delete`; after this custom playlist is gone from list.
    await tap(tester, find.byTooltip('Удалить плейлист'));
    await tap(tester, find.text('Удалить'));
    expect(
      await gone(tester, find.text(renamed), const Duration(seconds: 30)),
      isTrue,
      reason: 'playlist remained - cleanup failed',
    );
    expect(find.text('Новый плейлист'), findsOneWidget);
    stage('deleted');
  });
}
