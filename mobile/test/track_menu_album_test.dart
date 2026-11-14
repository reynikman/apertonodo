import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/models/track.dart';
import 'package:music_stream/screens/catalog_screens.dart';
import 'package:music_stream/screens/parts.dart';
import 'package:music_stream/theme.dart';

import 'fake_server.dart';

/// P-A74 "now" (FT-562): track menu — "Go to album". Server resolves album
/// via local MusicBrainz replica (`GET /v1/tracks/{id}/album`); if not found —
/// "Album not found", screen remains unchanged.
const _song = Track(
  id: '00000000-0000-4000-8000-000000000071',
  title: 'Northern Lights',
  artist: 'Glass Harbor',
  durationMs: 240000,
  artworkUrl: '',
);
const _album = 'aaaaaaaa-0000-4000-8000-000000000071';

void main() {
  late FakeServer server;

  Future<void> pump(WidgetTester tester) async {
    final services = Services(
      server: server.api(),
      search: server.catalog().search,
      play: (_, _) {},
      prepare: (_) {},
    );
    final hearts = Hearts(services.server)..show([_song]);
    addTearDown(hearts.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: apertonoTheme(),
        home: Scaffold(
          body: TrackTile(
            track: _song,
            onTap: () {},
            services: services,
            hearts: hearts,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Ещё'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('К альбому'));
    await tester.pumpAndSettle();
  }

  List<String> asked() => [
    for (final request in server.calls('GET /v1/tracks/*/album'))
      request.url.path,
  ];

  setUp(() => server = FakeServer());

  testWidgets('"Go to album" opens track album', (tester) async {
    server.on(
      'GET /v1/tracks/*/album',
      (_) => answer(200, {
        'album': {'id': _album, 'title': 'Low Tide'},
      }),
    );
    await pump(tester);
    await choose(tester);
    expect(asked(), ['/v1/tracks/${_song.id}/album']);
    final screen = tester.widget<AlbumScreen>(find.byType(AlbumScreen));
    expect(screen.id, _album);
  });

  testWidgets('album not found shows message and keeps screen', (tester) async {
    server.on(
      'GET /v1/tracks/*/album',
      (_) => answer(404, {'status': 'not_found'}),
    );
    await pump(tester);
    await choose(tester);
    expect(find.byType(AlbumScreen), findsNothing);
    expect(find.text('Альбом не нашёлся'), findsOneWidget);
    expect(find.byType(TrackTile), findsOneWidget);
  });
}
