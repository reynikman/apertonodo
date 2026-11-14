import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/models/track.dart';
import 'package:music_stream/screens/catalog_screens.dart';
import 'package:music_stream/screens/player_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'back.dart';
import 'fake_server.dart';
import 'player_fixes_test.dart' show openPlayer, playing;

/// H6-7 (FT-743): artist link was hidden in name tap, album link
/// from player was unavailable. Now both are first in player menu and open inside
/// shell like artist by name (FT-739): with bottom bar and mini player,
/// "back" returns to player.
const albumId = 'b0000000-0000-4000-8000-000000000001';
final player = find.byKey(const Key('player-screen'));
final mini = find.byKey(const Key('mini-player'));
final navBar = find.byKey(const Key('nav-bar'));
final menu = find.byKey(const Key('player-menu'));

Future<Rig> withAlbum(WidgetTester tester, {int status = 200}) async {
  final rig = await playing(tester);
  rig.server.on(
    'GET /v1/tracks/*/album',
    (_) => status == 200
        ? answer(200, {
            'album': {'id': albumId, 'title': 'Metallica'},
          })
        : answer(status, {'status': 'not_found'}),
  );
  await openPlayer(tester);
  return rig;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // FT-807: menu became a bottom sheet with sections (owner 12.10). Navigation items in
  // their own "Go to" section, artist above album.
  testWidgets('in «Go to» section — «To artist» and «To album»', (
    tester,
  ) async {
    await withAlbum(tester);
    await tapAndSettle(tester, menu);
    final go = tester.getTopLeft(find.byKey(const Key('player-menu-go'))).dy;
    final artist = tester.getTopLeft(find.text('К исполнителю')).dy;
    final album = tester.getTopLeft(find.text('К альбому')).dy;
    expect(go, lessThan(artist));
    expect(artist, lessThan(album));
    expect(find.text('Добавить в плейлист'), findsOneWidget);
  });

  testWidgets('«To artist» — inside shell, «back» navigates to player', (
    tester,
  ) async {
    await withAlbum(tester);
    await tapAndSettle(tester, menu);
    await tapAndSettle(tester, find.text('К исполнителю'));
    expect(
      tester.widget<ArtistScreen>(find.byType(ArtistScreen)).name,
      'Metallica',
    );
    expect(player, findsNothing);
    expect(navBar.hitTestable(), findsOneWidget);
    expect(mini.hitTestable(), findsOneWidget);

    await tapBack(tester);
    await tester.pumpAndSettle();
    expect(player, findsOneWidget);
  });

  testWidgets('«To album» — track album inside shell, «back» — '
      'player', (tester) async {
    final rig = await withAlbum(tester);
    await tapAndSettle(tester, menu);
    await tapAndSettle(tester, find.text('К альбому'));
    expect(rig.server.calls('GET /v1/tracks/*/album'), hasLength(1));
    expect(tester.widget<AlbumScreen>(find.byType(AlbumScreen)).id, albumId);
    expect(player, findsNothing);
    expect(navBar.hitTestable(), findsOneWidget);
    expect(mini.hitTestable(), findsOneWidget);

    await tapBack(tester);
    await tester.pumpAndSettle();
    expect(find.byType(AlbumScreen), findsNothing);
    expect(player, findsOneWidget);
  });

  testWidgets('album not found — message is shown, player remains open', (
    tester,
  ) async {
    await withAlbum(tester, status: 404);
    await tapAndSettle(tester, menu);
    await tapAndSettle(tester, find.text('К альбому'));
    expect(find.byType(AlbumScreen), findsNothing);
    expect(find.text('Альбом не нашёлся'), findsWidgets);
    expect(player, findsOneWidget);
  });

  // Second glance Gemini (FT-743): server response arrives when user already
  // performed another action.
  testWidgets(
    'player closed before «no album» reply — no message is shown in UI',
    (tester) async {
      final rig = await withAlbum(tester);
      final reply = rig.server.later('GET /v1/tracks/*/album');
      await tapAndSettle(tester, menu);
      await tapAndSettle(tester, find.text('К альбому'));
      await tapAndSettle(tester, find.byKey(const Key('player-close')));
      reply.complete(answer(404, {'status': 'not_found'}));
      await tester.pumpAndSettle();
      expect(find.text('Альбом не нашёлся'), findsNothing);
    },
  );

  testWidgets('song changed before reply — old album does not open', (
    tester,
  ) async {
    final rig = await withAlbum(tester);
    final reply = rig.server.later('GET /v1/tracks/*/album');
    await tapAndSettle(tester, menu);
    await tapAndSettle(tester, find.text('К альбому'));
    // Track changed while response was in flight (like "next" or track ended).
    final queue = tester.widget<PlayerScreen>(find.byType(PlayerScreen)).player;
    queue.restore(
      const [
        Track(
          id: '00000000-0000-4000-8000-000000000099',
          title: 'Other',
          artist: 'Metallica',
          durationMs: 200000,
          artworkUrl: '',
        ),
      ],
      index: 0,
      at: Duration.zero,
    );
    await tester.pump();
    reply.complete(
      answer(200, {
        'album': {'id': albumId, 'title': 'Metallica'},
      }),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AlbumScreen), findsNothing);
    expect(player, findsOneWidget);
  });

  testWidgets('app exited before reply — does not crash', (tester) async {
    final rig = await withAlbum(tester);
    final reply = rig.server.later('GET /v1/tracks/*/album');
    await tapAndSettle(tester, menu);
    await tapAndSettle(tester, find.text('К альбому'));
    await tester.pumpWidget(const SizedBox());
    reply.complete(answer(404, {'status': 'not_found'}));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('app exited before server error — no crash', (tester) async {
    final rig = await withAlbum(tester);
    final reply = rig.server.later('GET /v1/tracks/*/album');
    await tapAndSettle(tester, menu);
    await tapAndSettle(tester, find.text('К альбому'));
    await tester.pumpWidget(const SizedBox());
    reply.complete(answer(500, {'status': 'internal'}));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
