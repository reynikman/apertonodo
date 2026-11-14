import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/screens/artist_avatar.dart';
import 'package:music_stream/screens/catalog_screens.dart';

import 'fake_server.dart';

Map<String, dynamic> pageWith({
  required String bio,
  required List<String> songs,
  required List<String> similar,
}) {
  final page = sample('catalog-artist-lastfm');
  page['bio'] = bio;
  page['top_tracks'] = [
    for (final title in songs) {'title': title, 'playable': true},
  ];
  page['similar'] = [
    for (final name in similar) {'name': name},
  ];
  return page;
}

void main() {
  test('biography is truncated at sentence boundary', () {
    expect(bioPreview('One. Two. Three. Four. Five.'), 'One. Two. Three.');
    expect(bioPreview('Only one sentence.'), 'Only one sentence.');
    expect(bioPreview('No punctuation at all'), 'No punctuation at all');
  });

  testWidgets('biography is clipped and expands', (tester) async {
    tester.view.physicalSize = const Size(400, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final rig = Rig();
    rig.server.on(
      'GET /v1/artist',
      (_) => answer(
        200,
        pageWith(
          bio:
              'First sentence. Second sentence. Third sentence. Fourth leftover.',
          songs: const ['Enter Sandman'],
          similar: const ['Megadeth'],
        ),
      ),
    );
    await rig.screen(
      tester,
      (services) => ArtistScreen(services: services, name: 'Metallica'),
    );

    expect(find.textContaining('First sentence.'), findsOneWidget);
    expect(find.textContaining('Fourth leftover'), findsNothing);
    expect(find.text('Раскрыть'), findsOneWidget);

    await tapAndSettle(tester, find.text('Раскрыть'));
    expect(find.textContaining('Fourth leftover'), findsOneWidget);
  });

  testWidgets('five songs and arrow, similar in horizontal row (R-A51)', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final songs = ['Song 1', 'Song 2', 'Song 3', 'Song 4', 'Song 5', 'Song 6'];
    final similar = [
      'Band 1',
      'Band 2',
      'Band 3',
      'Band 4',
      'Band 5',
      'Band 6',
    ];
    final rig = Rig();
    rig.server.on(
      'GET /v1/artist',
      (_) =>
          answer(200, pageWith(bio: 'Short.', songs: songs, similar: similar)),
    );
    await rig.screen(
      tester,
      (services) => ArtistScreen(services: services, name: 'Metallica'),
    );

    expect(find.text('Song 5'), findsOneWidget);
    expect(find.text('Song 6'), findsNothing);
    expect(find.text('Показать все'), findsNothing);

    // Arrow to window with all tracks instead of "More" (FT-553).
    expect(find.byKey(const Key('popular-more')), findsOneWidget);
    expect(find.text('Ещё'), findsNothing);

    final row = find.byKey(const Key('artist-similar'));
    await tester.drag(row, const Offset(-2000, 0));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: row, matching: find.text('Band 6')),
      findsOneWidget,
    );
  });

  testWidgets('similar artists have photos as in the genre list', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final page = pageWith(bio: 'Short.', songs: const [], similar: const []);
    page['similar'] = [
      {'name': 'Megadeth', 'photo': '/v1/photos/megadeth'},
      {'name': 'Slayer', 'photo': null},
    ];
    final rig = Rig();
    rig.server.on('GET /v1/artist', (_) => answer(200, page));
    await rig.screen(
      tester,
      (services) => ArtistScreen(services: services, name: 'Metallica'),
    );

    ArtistAvatar avatar(String name) => tester.widget<ArtistAvatar>(
      find.byWidgetPredicate((w) => w is ArtistAvatar && w.name == name),
    );
    expect(avatar('Megadeth').photo, '/v1/photos/megadeth');
    expect(avatar('Slayer').photo, isNull);
  });
  // Where name is — on photo or in header without photo — is tested by
  // artist_design_test.dart (FT-486): AppBar on artist screen is gone.
}
