import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/screens/catalog_screens.dart';
import 'package:music_stream/screens/home_screen.dart';
import 'package:music_stream/screens/nav_bar.dart';
import 'package:music_stream/screens/parts.dart';
import 'package:music_stream/screens/search_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';

void expectHomeAlive(WidgetTester tester) {
  expect(find.byKey(const Key('tab-search')), findsOneWidget);
  expect(find.byType(ErrorWidget), findsNothing);
  expect(find.byKey(const Key('search-error')), findsNothing);
  expect(find.text('Сервер недоступен'), findsNothing);
  expect(find.text('Сервер не ответил'), findsNothing);
}

final homeArtists = find.byKey(const Key('home-artists'));
final homeRecent = find.byKey(const Key('home-recent'));

/// Main screen: artists, recent, mini-player with bar. Search is own
/// tab (FT-472); blocks layout per Figma export — home_blocks_test.dart (FT-474).
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'recent song plays with whole row queue: shade shows next button',
    (tester) async {
      final rig = Rig();
      final row =
          sample('library-history')['tracks'][0] as Map<String, dynamic>;
      rig.server.on(
        'GET /v1/history',
        (_) => answer(200, {
          'tracks': [
            for (final (id, title) in [
              ('33333333-3333-3333-3333-333333333331', 'Duality'),
              ('33333333-3333-3333-3333-333333333332', 'Before I Forget'),
              ('33333333-3333-3333-3333-333333333333', 'Psychosocial'),
            ])
              {...row, 'id': id, 'title': title},
          ],
          'total': 3,
        }),
      );
      await rig.screen(
        tester,
        (services) => Scaffold(body: HomeScreen(services: services)),
      );

      await tester.ensureVisible(find.text('Before I Forget'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Before I Forget'));

      final (queue, start) = rig.played.single;
      expect(
        [for (final track in queue) track.title],
        ['Duality', 'Before I Forget', 'Psychosocial'],
      );
      expect(start, 1);
    },
  );

  testWidgets(
    'home shows artists, albums, mini-player with progress bar, and search',
    (tester) async {
      final rig = Rig();
      await rig.start(tester);

      expect(homeArtists, findsNothing);
      expect(find.byKey(const Key('tab-search')), findsOneWidget);
      expect(rig.server.requests, isEmpty);

      await tester.pumpAndSettle();

      expect(homeArtists, findsOneWidget);
      expect(find.text('Slipknot'), findsWidgets);
      expect(homeRecent, findsOneWidget);
      expect(find.text('Duality'), findsOneWidget);
      expect(find.byKey(const Key('mini-player')), findsNothing);
      expect(find.byKey(const Key('tab-search')), findsOneWidget);
      expect(find.widgetWithText(Heading, 'Жанры'), findsNothing);
      expect(find.text('Рок'), findsNothing);

      await typeSearch(tester, 'metallica');
      await tester.tap(find.text('Nothing Else Matters'));
      await tester.pump();
      rig.audio.emit(AudioPhase.playing);
      await tester.pump();
      await openTab(tester, 'home');

      expect(find.byKey(const Key('mini-player')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('mini-player')),
          matching: find.byType(LinearProgressIndicator),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('search results on home screen do not expand', (tester) async {
    final rig = Rig();
    await rig.start(tester);
    await tester.pumpAndSettle();

    expect(find.text('Nothing Else Matters'), findsNothing);
    expect(find.byType(SearchScreen), findsNothing);
    expect(rig.server.calls('GET /v1/search'), isEmpty);
  });

  testWidgets('no history: home shows beginning of artists catalog', (
    tester,
  ) async {
    final rig = Rig();
    rig.server.on(
      'GET /v1/history',
      (_) => answer(200, {'tracks': const [], 'total': 0}),
    );
    await rig.start(tester);
    await tester.pumpAndSettle();

    expect(find.text('Кино'), findsOneWidget);
    expect(homeRecent, findsNothing);
    expect(rig.server.calls('GET /v1/artists'), hasLength(1));
  });

  testWidgets('history failure: search field and mini player in place', (
    tester,
  ) async {
    final rig = Rig();
    rig.server.fail('GET /v1/history', 503, 'library_unavailable');
    await rig.start(tester);
    await tester.pumpAndSettle();

    expectHomeAlive(tester);
    expect(find.text('Кино'), findsOneWidget);
  });

  testWidgets('catalog failure: search field and mini player in place', (
    tester,
  ) async {
    final rig = Rig();
    rig.server.on(
      'GET /v1/history',
      (_) => answer(200, {'tracks': const [], 'total': 0}),
    );
    rig.server.fail('GET /v1/artists', 503, 'catalog_unavailable');
    await rig.start(tester);
    await tester.pumpAndSettle();

    expectHomeAlive(tester);
    expect(homeArtists, findsNothing);
  });

  testWidgets('history and catalog failure — screen alive, no bare error', (
    tester,
  ) async {
    final rig = Rig();
    rig.server.fail('GET /v1/history', 503, 'library_unavailable');
    rig.server.fail('GET /v1/artists', 503, 'catalog_unavailable');
    await rig.start(tester);
    await tester.pumpAndSettle();

    expectHomeAlive(tester);
    expect(homeArtists, findsNothing);
    expect(homeRecent, findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('history failed, catalog arrived: artists on screen', (
    tester,
  ) async {
    final rig = Rig();
    rig.server.fail('GET /v1/history', 503, 'library_unavailable');
    await rig.start(tester);
    await tester.pumpAndSettle();

    expectHomeAlive(tester);
    expect(homeArtists, findsOneWidget);
    expect(find.text('Кино'), findsOneWidget);
    expect(homeRecent, findsNothing);
  });

  testWidgets('artist from home opens same page as artists section', (
    tester,
  ) async {
    final rig = Rig();
    await rig.start(tester);
    await tester.pumpAndSettle();

    await tapAndSettle(
      tester,
      find.descendant(of: homeArtists, matching: find.text('Slipknot')),
    );

    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('Slipknot')),
      findsNothing,
    );
    expect(find.byType(ArtistScreen), findsOneWidget);
    expect(find.text('Альбомы'), findsOneWidget);
    expect(rig.server.calls('GET /v1/artist'), hasLength(1));
  });

  testWidgets('no current song — no mini-player', (tester) async {
    final rig = Rig();
    await rig.start(tester);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('mini-player')), findsNothing);
    expect(find.byKey(const Key('tab-search')), findsOneWidget);
  });

  testWidgets('mini-player shows artist while playing', (tester) async {
    final rig = Rig();
    await rig.start(tester);
    await tester.pumpAndSettle();
    await typeSearch(tester, 'metallica');
    await tester.tap(find.text('Nothing Else Matters'));
    await tester.pump();
    rig.audio.emit(AudioPhase.playing);
    await tester.pump();
    await openTab(tester, 'home');

    expect(
      find.descendant(
        of: find.byKey(const Key('mini-player')),
        matching: find.text('Metallica'),
      ),
      findsOneWidget,
    );
    expect(find.text('Играет'), findsNothing);
    expect(find.text('Пауза'), findsNothing);
  });

  testWidgets('status bar inset does not enter the tab bar', (tester) async {
    tester.view.padding = const FakeViewPadding(top: 120);
    tester.view.viewPadding = const FakeViewPadding(top: 120);
    addTearDown(tester.view.reset);

    final rig = Rig();
    await rig.start(tester);
    await tester.pumpAndSettle();

    final whole = tester.getRect(find.byType(ApertonoNavBar));
    final island = tester.getRect(find.byKey(const Key('nav-bar')));
    expect(
      island.top - whole.top,
      lessThan(1),
      reason:
          'gap above tab bar ${island.top - whole.top}: '
          'tab SafeArea ate status bar inset again',
    );
  });

  testWidgets('test_tone does not reach home', (tester) async {
    final rig = Rig();
    rig.server.on('GET /v1/history', (_) {
      return answer(200, {
        'tracks': [
          songLike(
              'library-history',
              songId('Test Tone Short'),
              'Test Tone Short',
            )
            ..['artist'] = 'Flowtune'
            ..['test_tone'] = true
            ..['artwork_url'] = '',
          songLike('library-history', songId('Duality'), 'Duality')
            ..['artist'] = 'Slipknot'
            ..['artist_photo'] = '/v1/photos/slipknot'
            ..['artwork_url'] = '/v1/covers/meteora',
        ],
        'total': 2,
      });
    });
    await rig.start(tester);
    await tester.pumpAndSettle();

    expect(find.text('Flowtune'), findsNothing);
    expect(find.text('Test Tone Short'), findsNothing);
    expect(find.text('Slipknot'), findsWidgets);
    expect(find.text('Duality'), findsOneWidget);
    expect(
      tester
          .widgetList<Image>(find.byType(Image))
          .map((image) => image.image)
          .whereType<NetworkImage>()
          .map((image) => image.url),
      containsAll(['$base/v1/photos/slipknot', '$base/v1/covers/meteora']),
    );
  });
}
