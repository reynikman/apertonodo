import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/screens/catalog_screens.dart';

import 'fake_server.dart';

/// Owner 02.10 (J 14, option b, P-A54): genre artists ordered alphabetically,
/// Latin first, with alphabet strip on side so in rock (38,843 names)
/// user doesn't scroll down to "К". Server returns genre letters and index where each
/// starts (`/v1/letters?genre=…`, FT-514); phone jumps to that
/// position on letter tap.
final names = [
  for (var i = 1; i <= 120; i++) 'Alpha $i',
  for (var i = 1; i <= 60; i++) 'Kilo $i',
  for (var i = 1; i <= 70; i++) 'Кино $i',
];

/// Latin "K" and Cyrillic "К" are distinct letters on the strip.
const letters = [
  {'letter': 'A', 'artists': 120, 'offset': 0},
  {'letter': 'K', 'artists': 60, 'offset': 120},
  {'letter': 'К', 'artists': 70, 'offset': 180},
];

Rig rigWith({Object? lettersBody, int lettersStatus = 200}) {
  final rig = Rig();
  rig.server.on('GET /v1/artists', (request) {
    final offset = int.parse(request.url.queryParameters['offset']!);
    final limit = int.parse(request.url.queryParameters['limit']!);
    return answer(200, {
      'artists': [
        for (final name in names.skip(offset).take(limit)) {'name': name},
      ],
      'total': names.length,
    });
  });
  rig.server.on(
    'GET /v1/letters',
    (_) => answer(lettersStatus, lettersBody ?? {'letters': letters}),
  );
  return rig;
}

Future<void> openRock(WidgetTester tester, Rig rig) => rig.screen(
  tester,
  (services) => ArtistsScreen(
    services: services,
    title: 'Рок',
    load: (offset) =>
        services.server.artistCatalog(genre: 'rock', offset: offset),
    letters: () => services.server.genreLetters('rock'),
  ),
);

List<String?> artistOffsets(Rig rig) => [
  for (final request in rig.server.calls('GET /v1/artists'))
    request.url.queryParameters['offset'],
];

void main() {
  testWidgets('genre letter bar requests letters for this genre', (
    tester,
  ) async {
    final rig = rigWith();
    await openRock(tester, rig);

    expect(find.byKey(const Key('letter-strip')), findsOneWidget);
    for (final letter in ['A', 'K', 'К']) {
      expect(find.byKey(Key('letter-$letter')), findsOneWidget, reason: letter);
    }
    expect(
      [
        for (final request in rig.server.calls('GET /v1/letters'))
          request.url.queryParameters['genre'],
      ],
      ['rock'],
    );
  });

  testWidgets('letter opens list at its position and back', (tester) async {
    final rig = rigWith();
    await openRock(tester, rig);
    expect(find.text('Alpha 1'), findsOneWidget);

    await tester.tap(find.byKey(const Key('letter-К')));
    await tester.pumpAndSettle();
    expect(artistOffsets(rig).last, '180');
    expect(find.text('Кино 1'), findsOneWidget);
    expect(find.text('Alpha 1'), findsNothing);

    await tester.tap(find.byKey(const Key('letter-K')));
    await tester.pumpAndSettle();
    expect(artistOffsets(rig).last, '120');
    expect(find.text('Kilo 1'), findsOneWidget);

    await tester.tap(find.byKey(const Key('letter-A')));
    await tester.pumpAndSettle();
    expect(artistOffsets(rig).last, '0');
    expect(find.text('Alpha 1'), findsOneWidget);
  });

  testWidgets('after jump list continues loading past the same letter', (
    tester,
  ) async {
    final rig = rigWith();
    await openRock(tester, rig);
    await tester.tap(find.byKey(const Key('letter-K')));
    await tester.pumpAndSettle();

    // List scrolls, not strip: strip has its own scrolling.
    final list = tester.element(
      find
          .ancestor(of: find.text('Kilo 1'), matching: find.byType(Scrollable))
          .first,
    );
    await tester.scrollUntilVisible(
      find.text('Кино 50'),
      500,
      scrollable: find.byElementPredicate((element) => element == list),
    );
    await tester.pumpAndSettle();
    expect(find.text('Кино 50'), findsOneWidget);
    expect(artistOffsets(rig), ['0', '120', '220']);
  });

  testWidgets('no letters or just one: no letter bar, list works', (
    tester,
  ) async {
    for (final rig in [
      rigWith(lettersStatus: 500, lettersBody: const {}),
      rigWith(
        lettersBody: const {
          'letters': [
            {'letter': 'A', 'artists': 250, 'offset': 0},
          ],
        },
      ),
    ]) {
      await openRock(tester, rig);
      expect(find.text('Alpha 1'), findsOneWidget);
      expect(find.byKey(const Key('letter-strip')), findsNothing);
    }
  });

  for (final (where, genre, open) in [
    (
      'карточка на экране жанров',
      'rock',
      (WidgetTester tester, Rig rig) async {
        rig.server.on(
          'GET /v1/genres',
          (_) => answer(200, {
            'genres': [
              {'id': 'rock', 'name': 'Рок', 'artists': 250},
            ],
          }),
        );
        await rig.screen(
          tester,
          (services) => GenresScreen(services: services),
        );
        await tester.tap(find.byKey(const ValueKey('genre-card-rock')));
      },
    ),
    (
      'строка во всех жанрах',
      'classic-rock',
      (WidgetTester tester, Rig rig) async {
        await rig.screen(
          tester,
          (services) => Material(
            child: GenreRow(
              services: services,
              genre: (
                id: 'classic-rock',
                name: 'Классический рок',
                artists: 250,
              ),
            ),
          ),
        );
        await tester.tap(find.byKey(const ValueKey('genre-row-classic-rock')));
      },
    ),
  ]) {
    testWidgets('genre opens with letter bar of its letters: $where', (
      tester,
    ) async {
      final rig = rigWith();
      await open(tester, rig);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('letter-strip')), findsOneWidget);
      expect(
        [
          for (final request in rig.server.calls('GET /v1/letters'))
            request.url.queryParameters['genre'],
        ],
        [genre],
      );
    });
  }
}
