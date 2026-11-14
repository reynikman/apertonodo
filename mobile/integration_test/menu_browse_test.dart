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

/// Phase I test on a real phone: genre → artist → album → plays.
///
///   MUSIC_API_BASE_URL=https://music.example.org \
///     bash scripts/device_run.sh integration_test/menu_browse_test.dart 900
///
/// Needs server with catalog (F, F2, H on production address): branch server
/// has no genres — they are built from the source dump, not fixtures. Therefore CI
/// lacks this test: `device-smoke` in MR plays from branch server and would fail
/// incorrectly.
///
/// First album of first artist may not play (dead release) — this is not
/// broken screens, so test tries next ones, as a human would,
/// and fails only if none played.
void stage(String name) {
  // ignore: avoid_print
  print('FLOWTUNE_STAGE=$name');
}

/// Titles are printed by test, not app: neither song nor artist
/// enters app's own log (`integration_test` is not part of build).
void chose(String what, String name) {
  // ignore: avoid_print
  print('FLOWTUNE_PICK $what=$name');
}

/// Top screen: previous page remains under open page, without this
/// search would find cards of both at once — test previously
/// "navigated" from genres back into genres because of this.
Finder get page => find.byType(Scaffold).last;

/// Cards, rows, and tiles are found by keys, not widget type:
/// in Phase M genres became cards, albums became tiles, and test
/// searching for list rows stopped seeing them.
Finder keyed(String prefix) => find.descendant(
  of: page,
  matching: find.byWidgetPredicate((widget) {
    final key = widget.key;
    return key is ValueKey<String> && key.value.startsWith(prefix);
  }),
);

/// What follows prefix in key: artist name, genre id, or album id.
String labelOf(WidgetTester tester, Finder found, String prefix) =>
    (tester.widget(found).key! as ValueKey<String>).value.substring(
      prefix.length,
    );

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

/// Tap and wait until [next] appears on new top page.
/// Cannot wait for header name: artist with photo no longer has it in header.
Future<bool> openAndWait(
  WidgetTester tester,
  Finder target,
  Finder next,
) async {
  final pages = find.byType(Scaffold).evaluate().length;
  await tester.tap(target);
  await tester.pump();
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  while (find.byType(Scaffold).evaluate().length <= pages &&
      DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 200));
  }
  if (find.byType(Scaffold).evaluate().length <= pages) {
    // ignore: avoid_print
    print('FLOWTUNE_SCREEN=${screenTexts()}');
  }
  return appear(tester, next, const Duration(seconds: 60));
}

Future<void> back(WidgetTester tester) async {
  await tapBack(tester);
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('genre -> artist -> album -> plays', (tester) async {
    await seedTestSession();
    final tokens = TokenProvider(
      SessionStore(),
      server: Uri.parse(AppEnv.apiBaseUrl),
    );
    await tokens.load();
    await tester.pumpWidget(buildProductionApp(tokens: tokens));
    await tester.pump();

    await tester.tap(find.byKey(const Key('tab-browse')));
    await tester.pump();
    final genres = keyed('genre-card-');
    expect(
      await appear(tester, genres, const Duration(seconds: 40)),
      isTrue,
      reason: 'genres did not arrive',
    );
    chose('genre', labelOf(tester, genres.first, 'genre-card-'));
    final artists = keyed('artist-row-');
    expect(
      await openAndWait(tester, genres.first, artists),
      isTrue,
      reason: 'genre artists did not arrive',
    );
    stage('genre');
    stage('artists');

    // Artists are ordered by popularity, popular on top: take first
    // three — an album by one of them must play.
    for (var artist = 0; artist < 3; artist++) {
      final row = artists.at(artist);
      chose('artist', labelOf(tester, row, 'artist-row-'));
      final albums = keyed('album-tile-');
      if (!await openAndWait(tester, row, albums)) {
        // Artist page did not load (MusicBrainz timed out) or artist has no
        // albums — return to list.
        await back(tester);
        continue;
      }
      final count = albums.evaluate().length;
      stage('artist albums=$count');

      for (var album = 0; album < (count < 3 ? count : 3); album++) {
        final tile = albums.at(album);
        await tester.ensureVisible(tile);
        await tester.pump();
        chose('album', labelOf(tester, tile, 'album-tile-'));
        final button = find.widgetWithText(FilledButton, 'Играть альбом');
        final playable =
            await openAndWait(tester, tile, button) &&
            tester.widget<FilledButton>(button).onPressed != null;
        if (playable) {
          stage('album');
          await tester.tap(button);
          await tester.pump();
          if (await appear(
            tester,
            find.byKey(const Key('pause-button')),
            const Duration(seconds: 90),
          )) {
            expect(find.byKey(const Key('pause-button')), findsOneWidget);
            expect(
              find.textContaining(
                'tor'
                'rent',
              ),
              findsNothing,
            );
            expect(
              find.textContaining(
                'раз'
                'дач',
              ),
              findsNothing,
            );
            stage('playing');
            return;
          }
        }
        await back(tester);
      }
      await back(tester);
    }
    fail('no album of the first three artists played');
  });
}
