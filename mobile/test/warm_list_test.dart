// Lead check FT-563 (P-A76 "instant sound"): opened list pre-
// preloads source for 3 closest tracks (`Services.prepare` —
// `Player.prepare`), strictly within quota and non-duplicative.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/screens/catalog_screens.dart';
import 'package:music_stream/screens/library_screens.dart';

import 'fake_server.dart';

const albumId = '7ff1eff0-a8c8-37dc-807e-eea5a9e173b5';
const playlistId = '11111111-2222-4333-8444-555555555555';

Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('album: first three playable, unplayable skipped', (
    tester,
  ) async {
    final rig = Rig();
    rig.server.on(
      'GET /v1/albums/*',
      (_) => answer(
        200,
        albumOf(['Раз', 'Нет', 'Два', 'Три', 'Четыре'], dead: {'Нет'}),
      ),
    );
    await rig.screen(
      tester,
      (s) => AlbumScreen(services: s, id: albumId, title: 'Альбом'),
    );
    await settle(tester);
    expect(rig.prepared, [songId('Раз'), songId('Два'), songId('Три')]);

    // Repainting same list — no new actions.
    await tester.pump(const Duration(seconds: 1));
    expect(rig.prepared, hasLength(3));
  });

  testWidgets('short list prewarms available items', (tester) async {
    final rig = Rig();
    rig.server.on('GET /v1/albums/*', (_) => answer(200, albumOf(['Один'])));
    await rig.screen(
      tester,
      (s) => AlbumScreen(services: s, id: albumId, title: 'Альбом'),
    );
    await settle(tester);
    expect(rig.prepared, [songId('Один')]);
  });

  testWidgets('playlist prewarms available items', (tester) async {
    final rig = Rig();
    rig.server.on(
      'GET /v1/playlists/*',
      (_) => answer(200, playlistOf(['A', 'B', 'C', 'D'])),
    );
    await rig.screen(
      tester,
      (s) => PlaylistScreen(services: s, id: playlistId, name: 'Мой'),
    );
    await settle(tester);
    expect(rig.prepared, [songId('A'), songId('B'), songId('C')]);
  });

  testWidgets('artist top tracks prewarms available', (tester) async {
    tester.view.physicalSize = const Size(400, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final page = sample('catalog-artist-lastfm');
    final first = (page['top_tracks'] as List<dynamic>).first as Map;
    page['top_tracks'] = [
      for (final title in ['P1', 'P2', 'P3', 'P4'])
        {...first, 'id': songId(title), 'title': title, 'playable': true},
    ];
    final rig = Rig();
    rig.server.on('GET /v1/artist', (_) => answer(200, page));
    await rig.screen(
      tester,
      (s) => ArtistScreen(services: s, name: 'Metallica'),
    );
    await settle(tester);
    expect(rig.prepared, [songId('P1'), songId('P2'), songId('P3')]);
  });
}
