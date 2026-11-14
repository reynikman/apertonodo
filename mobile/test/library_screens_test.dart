import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/screens/library_screens.dart';

import 'fake_server.dart';

/// Song of samples H (favorites, history, playlist) — the same Duality.
const dualityId = '33333333-3333-3333-3333-333333333333';
const playlistId = '9b7d8f0e-2c1a-4e5b-8d3f-6a1b2c3d4e5f';

/// "Gruppa krovi" from album page (sample F).
const albumSongId = '8bb7fd50-377c-4d57-8f8f-c83d00790c16';

bool heartOn(WidgetTester tester, String trackId) {
  return tester
      .widget<IconButton>(find.byKey(ValueKey('heart-$trackId')))
      .isSelected!;
}

Future<void> openMine(WidgetTester tester, Rig rig, String item) async {
  await rig.start(tester);
  await openTab(tester, 'library');
  await tapAndSettle(tester, find.text(item));
}

void main() {
  group('My music', () {
    testWidgets('favorites, history, and playlists rows', (tester) async {
      final rig = Rig();
      await rig.start(tester);
      await openTab(tester, 'library');

      // Row appearance guarded by library_design_test.dart (FT-487); here — that
      // screen queries server and names sections as in export.
      expect(find.byKey(const Key('library-favorites')), findsOneWidget);
      expect(find.text('История'), findsOneWidget);
      expect(find.text('Плейлисты'), findsOneWidget);
      expect(find.text('Избранное'), findsNothing);
      expect(rig.server.calls('GET /v1/favorites'), isNotEmpty);
      expect(rig.server.calls('GET /v1/playlists'), isNotEmpty);
    });

    testWidgets('sample favorites screen: track and lit heart indicator', (
      tester,
    ) async {
      final rig = Rig();
      await rig.screen(
        tester,
        (services) => FavoritesScreen(services: services),
      );

      expect(find.text('Duality'), findsOneWidget);
      expect(find.text('Slipknot · 4:12'), findsOneWidget);
      expect(heartOn(tester, dualityId), isTrue);
    });

    testWidgets('heart switched off in favorites — the song leaves the list', (
      tester,
    ) async {
      final rig = Rig();
      rig.server.on(
        'GET /v1/favorites',
        (_) => rig.server.liked.contains(dualityId)
            ? answer(200, sample('library-favorites'))
            : answer(200, {'tracks': const []}),
      );
      await rig.screen(
        tester,
        (services) => FavoritesScreen(services: services),
      );

      await tapAndSettle(
        tester,
        find.byKey(const ValueKey('heart-$dualityId')),
      );

      expect(rig.server.bodies('POST /v1/favorites/remove'), [
        {'track_id': dualityId},
      ]);
      expect(find.text('Duality'), findsNothing);
      expect(find.text('В избранном пока пусто'), findsOneWidget);
    });

    testWidgets('sample history: played time display; tap — queue G', (
      tester,
    ) async {
      final rig = Rig();
      await openMine(tester, rig, 'История');

      expect(find.text('Duality'), findsWidgets);
      // 18:04 UTC — 19.09 in any timezone from −18 to +5 h.
      expect(find.textContaining('Slipknot · 19.09 '), findsOneWidget);
      expect(rig.server.calls('GET /v1/history').last.url.queryParameters, {
        'offset': '0',
        'limit': '100',
      });

      await tester.tap(find.text('Duality').last);
      await tester.pump();
      expect(rig.playback.started, [dualityId]);
    });
  });

  group('heart', () {
    testWidgets('by the server response: the same song with another id is lit', (
      tester,
    ) async {
      // In favorites song stored under id from search, and album shows it under
      // its own. Server alone knows whether heart is lit: compares songs,
      // not ids.
      final rig = Rig();
      rig.server.liked
        ..clear()
        ..add(albumSongId);
      await openAlbum(tester, rig);
      // Home takes only count and fan from favorites (FT-474); afterwards
      // favorites list not needed by phone.
      final listed = rig.server.calls('GET /v1/favorites').length;

      expect(heartOn(tester, albumSongId), isTrue);
      expect(rig.server.bodies('POST /v1/favorites/contains'), [
        {
          'track_ids': [albumSongId],
        },
      ]);
      expect(
        rig.server.calls('GET /v1/favorites'),
        hasLength(listed),
        reason: 'heart does not match id with local favorites list',
      );

      await tapAndSettle(
        tester,
        find.byKey(const ValueKey('heart-$albumSongId')),
      );
      expect(rig.server.bodies('POST /v1/favorites/remove'), [
        {'track_id': albumSongId},
      ]);
      expect(heartOn(tester, albumSongId), isFalse);
    });

    testWidgets(
      'tapped an empty heart in search — added to favorites and lit',
      (tester) async {
        const found = '11111111-1111-1111-1111-111111111111';
        final rig = Rig();
        await rig.start(tester);
        await typeSearch(tester, 'metallica');
        expect(heartOn(tester, found), isFalse);

        await tapAndSettle(tester, find.byKey(const ValueKey('heart-$found')));

        expect(rig.server.bodies('POST /v1/favorites'), [
          {'track_id': found},
        ]);
        expect(heartOn(tester, found), isTrue);
        expect(rig.server.calls('POST /v1/favorites/contains'), hasLength(2));
      },
    );

    testWidgets('heart on track with cover sends cover path to server', (
      tester,
    ) async {
      // Owner finding 01.10: favorite song on Home without cover —
      // phone knew it, but did not send to server.
      const found = '11111111-1111-1111-1111-111111111111';
      final rig = Rig();
      rig.server.on('GET /v1/search', (_) {
        final answerBody = sample('search');
        (answerBody['tracks'] as List).first['artwork_url'] =
            '/v1/covers/nem-cover';
        return answer(200, answerBody);
      });
      await rig.start(tester);
      await typeSearch(tester, 'metallica');

      await tapAndSettle(tester, find.byKey(const ValueKey('heart-$found')));

      expect(rig.server.bodies('POST /v1/favorites'), [
        {'track_id': found, 'artwork_url': '/v1/covers/nem-cover'},
      ]);
    });
  });

  group('playlists', () {
    testWidgets(
      'create: empty name is rejected, name in body, playlist list reread',
      (tester) async {
        final rig = Rig();
        await rig.screen(
          tester,
          (services) => PlaylistsScreen(services: services),
        );
        expect(find.text('В дорогу'), findsOneWidget);

        await tapAndSettle(tester, find.text('Новый плейлист'));
        FilledButton save() => tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Сохранить'),
        );
        expect(save().onPressed, isNull);
        await tester.enterText(find.byKey(const Key('name-field')), '   ');
        await tester.pump();
        expect(save().onPressed, isNull);
        await tester.enterText(find.byKey(const Key('name-field')), ' Ночная ');
        await tester.pump();
        await tapAndSettle(tester, find.text('Сохранить'));

        expect(rig.server.bodies('POST /v1/playlists'), [
          {'name': 'Ночная'},
        ]);
        expect(rig.server.calls('GET /v1/playlists'), hasLength(2));
      },
    );

    testWidgets('sample playlist: pale track present, nothing to play', (
      tester,
    ) async {
      final rig = Rig();
      await rig.screen(
        tester,
        (services) => PlaylistScreen(
          services: services,
          id: playlistId,
          name: 'В дорогу',
        ),
      );

      expect(find.text('Duality'), findsOneWidget);
      expect(alphaOf(tester, 'Duality'), lessThan(0.5));
      final play = tester.widget<ButtonStyleButton>(
        find.ancestor(
          of: find.text('Играть плейлист'),
          matching: find.bySubtype<ButtonStyleButton>(),
        ),
      );
      expect(play.onPressed, isNull);
    });

    testWidgets('«Play playlist» — queue G from playable', (tester) async {
      final rig = Rig();
      rig.server.on(
        'GET /v1/playlists/*',
        (_) => answer(
          200,
          playlistOf(['Звезда', 'Ночь', 'Кукушка'], dead: {'Ночь'}),
        ),
      );
      await openMine(tester, rig, 'Плейлисты');
      await tapAndSettle(tester, find.text('В дорогу'));

      await tester.tap(find.text('Играть плейлист'));
      await tester.pump();
      expect(rig.playback.started, [songId('Звезда')]);
      rig.audio.emit(AudioPhase.playing);
      await tester.pump();
      rig.audio.finish();
      await tester.pump();
      expect(rig.playback.started, [songId('Звезда'), songId('Кукушка')]);
    });

    testWidgets('reorder — POST with the whole id list', (tester) async {
      final rig = Rig();
      rig.server.on(
        'GET /v1/playlists/*',
        (_) => answer(200, playlistOf(['Звезда', 'Ночь', 'Кукушка'])),
      );
      await rig.screen(
        tester,
        (services) => PlaylistScreen(
          services: services,
          id: playlistId,
          name: 'В дорогу',
        ),
      );

      tester
          .widget<ReorderableListView>(find.byType(ReorderableListView))
          .onReorderItem!(0, 2);
      await tester.pumpAndSettle();

      expect(rig.server.bodies('POST /v1/playlists/*/order'), [
        {
          'track_ids': [songId('Ночь'), songId('Кукушка'), songId('Звезда')],
        },
      ]);
      expect(
        rig.server.calls('POST /v1/playlists/*/order').single.url.path,
        '/v1/playlists/$playlistId/order',
      );
      final top = tester.getTopLeft(find.text('Ночь')).dy;
      expect(tester.getTopLeft(find.text('Звезда')).dy, greaterThan(top));
    });

    testWidgets('rename action — POST /rename, screen title changed', (
      tester,
    ) async {
      final rig = Rig();
      await rig.screen(
        tester,
        (services) => PlaylistScreen(
          services: services,
          id: playlistId,
          name: 'В дорогу',
        ),
      );

      await tapAndSettle(tester, find.byTooltip('Переименовать'));
      await tester.enterText(find.byKey(const Key('name-field')), 'В путь');
      await tester.pump();
      await tapAndSettle(tester, find.text('Сохранить'));

      expect(rig.server.bodies('POST /v1/playlists/*/rename'), [
        {'name': 'В путь'},
      ]);
      expect(find.widgetWithText(AppBar, 'В путь'), findsOneWidget);
    });

    testWidgets('delete — POST /delete, back to list, list reread', (
      tester,
    ) async {
      final rig = Rig();
      await openMine(tester, rig, 'Плейлисты');
      await tapAndSettle(tester, find.text('В дорогу'));
      final listed = rig.server.calls('GET /v1/playlists').length;

      await tapAndSettle(tester, find.byTooltip('Удалить плейлист'));
      await tapAndSettle(tester, find.text('Удалить'));

      expect(
        rig.server.calls('POST /v1/playlists/*/delete').single.url.path,
        '/v1/playlists/$playlistId/delete',
      );
      expect(find.text('Новый плейлист'), findsOneWidget);
      expect(
        rig.server.calls('GET /v1/playlists'),
        hasLength(listed + 1),
        reason: 'list reread after deletion',
      );
    });

    testWidgets('add from song menu: pick playlist, song in body', (
      tester,
    ) async {
      final rig = Rig();
      await openAlbum(tester, rig);

      await tapAndSettle(tester, find.byTooltip('Ещё'));
      await tapAndSettle(tester, find.text('Добавить в плейлист'));
      await tapAndSettle(tester, find.text('В дорогу'));

      // Album song carries album cover (FT-488).
      expect(rig.server.bodies('POST /v1/playlists/*/tracks'), [
        {
          'track_id': albumSongId,
          'artwork_url': '/v1/covers/7ff1eff0-a8c8-37dc-807e-eea5a9e173b5',
        },
      ]);
      expect(
        rig.server.calls('POST /v1/playlists/*/tracks').single.url.path,
        '/v1/playlists/$playlistId/tracks',
      );
      expect(find.text('Добавлено в «В дорогу»'), findsOneWidget);
    });

    testWidgets('track with cover sent to playlist with cover path', (
      tester,
    ) async {
      // Owner question 01.10: playlist songs have no cover — phone knew
      // it, but did not send to server (as with favorites before FT-482).
      const found = '11111111-1111-1111-1111-111111111111';
      final rig = Rig();
      rig.server.on('GET /v1/search', (_) {
        final answerBody = sample('search');
        (answerBody['tracks'] as List).first['artwork_url'] =
            '/v1/covers/nem-cover';
        return answer(200, answerBody);
      });
      await rig.start(tester);
      await typeSearch(tester, 'metallica');

      await tapAndSettle(tester, find.byTooltip('Ещё').first);
      await tapAndSettle(tester, find.text('Добавить в плейлист'));
      await tapAndSettle(tester, find.text('В дорогу'));

      expect(rig.server.bodies('POST /v1/playlists/*/tracks'), [
        {'track_id': found, 'artwork_url': '/v1/covers/nem-cover'},
      ]);
    });

    testWidgets('remove from playlist — POST remove, playlist reread', (
      tester,
    ) async {
      final rig = Rig();
      await rig.screen(
        tester,
        (services) => PlaylistScreen(
          services: services,
          id: playlistId,
          name: 'В дорогу',
        ),
      );

      await tapAndSettle(tester, find.byTooltip('Ещё'));
      await tapAndSettle(tester, find.text('Убрать из плейлиста'));

      expect(rig.server.bodies('POST /v1/playlists/*/tracks/remove'), [
        {'track_id': dualityId},
      ]);
      expect(rig.server.calls('GET /v1/playlists/*'), hasLength(2));
    });
  });
}
