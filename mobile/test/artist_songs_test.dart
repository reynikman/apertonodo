import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/screens/catalog_screens.dart';

import 'fake_server.dart';

// FT-553: artist page has five popular songs, arrow in header
// opens modal with all — ordered by popularity, as served by server.

Map<String, dynamic> song(int n, {bool playable = true}) => {
  'id': 'c0ffee00-0000-4000-8000-${n.toString().padLeft(12, '0')}',
  'title': 'Song $n',
  'artist': 'Metallica',
  'duration_ms': 200000,
  'artwork_url': '',
  'playable': playable,
};

Map<String, dynamic> pageWithSongs(int count) {
  final page = sample('catalog-artist-lastfm');
  page['top_tracks'] = [for (var n = 1; n <= count; n++) song(n)];
  page['similar'] = <Map<String, dynamic>>[];
  return page;
}

Future<Rig> openArtist(WidgetTester tester, int count) async {
  tester.view.physicalSize = const Size(400, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final rig = Rig();
  rig.server.on('GET /v1/artist', (_) => answer(200, pageWithSongs(count)));
  rig.server.on(
    'GET /v1/artist/songs',
    (_) => answer(200, {
      'tracks': [for (var n = 1; n <= 12; n++) song(n, playable: n != 4)],
    }),
  );
  await rig.screen(
    tester,
    (services) => ArtistScreen(services: services, name: 'Metallica'),
  );
  return rig;
}

const more = Key('popular-more');

void main() {
  testWidgets('five songs and arrow instead of more', (tester) async {
    await openArtist(tester, 10);

    expect(find.text('Song 5'), findsOneWidget);
    expect(find.text('Song 6'), findsNothing);
    expect(find.text('Ещё'), findsNothing);
    expect(find.byKey(more), findsOneWidget);
    final arrow = find.descendant(
      of: find.byKey(more),
      matching: find.byIcon(Icons.chevron_right),
    );
    expect(arrow, findsOneWidget);
  });

  testWidgets('at most five songs: no arrow', (tester) async {
    await openArtist(tester, 5);

    expect(find.text('Song 5'), findsOneWidget);
    expect(find.byKey(more), findsNothing);
  });

  testWidgets('arrow opens all songs in order', (tester) async {
    final rig = await openArtist(tester, 10);

    await tapAndSettle(tester, find.byKey(more));

    final asked = rig.server.requests.where(
      (r) => r.url.path == '/v1/artist/songs',
    );
    expect(asked, hasLength(1));
    expect(asked.single.url.queryParameters['name'], 'Metallica');
    for (var n = 1; n <= 12; n++) {
      expect(find.text('Song $n'), findsOneWidget);
    }
    final top = tester.getTopLeft(find.text('Song 1')).dy;
    final last = tester.getTopLeft(find.text('Song 12')).dy;
    expect(top, lessThan(last));
  });

  testWidgets('tap plays from this song, unplayable absent', (tester) async {
    final rig = await openArtist(tester, 10);
    await tapAndSettle(tester, find.byKey(more));

    await tapAndSettle(tester, find.text('Song 7'));

    final (queue, start) = rig.played.single;
    expect(queue[start].title, 'Song 7');
    expect(queue.map((t) => t.title), isNot(contains('Song 4')));
    expect(queue.map((t) => t.title), contains('Song 12'));
  });
}
