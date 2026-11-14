import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:music_stream/screens/catalog_screens.dart';
import 'package:music_stream/screens/library_screens.dart';
import 'package:music_stream/screens/parts.dart';

import 'fake_server.dart';

const albumId = '7ff1eff0-a8c8-37dc-807e-eea5a9e173b5';
const playlistId = '9b7d8f0e-2c1a-4e5b-8d3f-6a1b2c3d4e5f';

typedef Case = ({
  String route,
  String status,
  Widget Function(Services services) screen,
  String content,
  String? empty,
});

final cases = <String, Case>{
  'genres': (
    route: 'GET /v1/genres',
    status: 'catalog_unavailable',
    screen: (services) => GenresScreen(services: services),
    content: 'Рок',
    empty: 'Жанров пока нет',
  ),
  'genre artists': (
    route: 'GET /v1/artists',
    status: 'catalog_unavailable',
    screen: (services) => ArtistsScreen(
      services: services,
      title: 'Рок',
      load: (offset) =>
          services.server.artistCatalog(genre: 'rock', offset: offset),
    ),
    content: 'Кино',
    empty: 'Исполнителей нет',
  ),
  'artist': (
    route: 'GET /v1/artist',
    status: 'catalog_unavailable',
    screen: (services) => ArtistScreen(services: services, name: 'Metallica'),
    content: 'Enter Sandman',
    empty: 'Альбомов в каталоге нет',
  ),
  'album': (
    route: 'GET /v1/albums/*',
    status: 'catalog_unavailable',
    screen: (services) =>
        AlbumScreen(services: services, id: albumId, title: 'Альбом'),
    content: 'Играть альбом',
    empty: null,
  ),
  'favorites': (
    route: 'GET /v1/favorites',
    status: 'library_unavailable',
    screen: (services) => FavoritesScreen(services: services),
    content: 'Duality',
    empty: 'В избранном пока пусто',
  ),
  'history': (
    route: 'GET /v1/history',
    status: 'library_unavailable',
    screen: (services) => HistoryScreen(services: services),
    content: 'Duality',
    empty: 'История пуста',
  ),
  'playlists': (
    route: 'GET /v1/playlists',
    status: 'library_unavailable',
    screen: (services) => PlaylistsScreen(services: services),
    content: 'В дорогу',
    empty: null,
  ),
  'playlist': (
    route: 'GET /v1/playlists/*',
    status: 'library_unavailable',
    screen: (services) =>
        PlaylistScreen(services: services, id: playlistId, name: 'В дорогу'),
    content: 'Duality',
    empty: 'Пусто. Песни добавляются из поиска и альбомов',
  ),
};

void main() {
  group(
    '503 — "server unavailable" and a working retry button, not "empty"',
    () {
      for (final MapEntry(key: name, value: c) in cases.entries) {
        testWidgets(name, (tester) async {
          final rig = Rig();
          final repair = rig.server.fail(c.route, 503, c.status);
          await rig.screen(tester, c.screen);

          expect(find.text('Сервер недоступен'), findsOneWidget);
          expect(find.text(c.content), findsNothing);
          if (c.empty case final empty?) {
            expect(find.text(empty), findsNothing, reason: 'failure not empty');
          }

          repair();
          await tapAndSettle(tester, find.text('Повторить'));
          expect(find.text('Сервер недоступен'), findsNothing);
          expect(find.text(c.content), findsWidgets);
        });
      }
    },
  );

  group('404 — own wording, no useless retry button', () {
    Future<void> check(
      WidgetTester tester,
      String route,
      Widget Function(Services services) screen,
      String text,
    ) async {
      final rig = Rig();
      rig.server.fail(route, 404, 'not_found');
      await rig.screen(tester, screen);

      expect(find.text(text), findsOneWidget);
      expect(find.text('Повторить'), findsNothing);
    }

    testWidgets('artist', (tester) async {
      await check(
        tester,
        'GET /v1/artist',
        (services) => ArtistScreen(services: services, name: 'Нет такого'),
        'Исполнителя нет в каталоге',
      );
    });

    testWidgets('album', (tester) async {
      await check(
        tester,
        'GET /v1/albums/*',
        (services) =>
            AlbumScreen(services: services, id: albumId, title: 'Альбом'),
        'Альбом не найден',
      );
    });

    testWidgets('playlist', (tester) async {
      await check(
        tester,
        'GET /v1/playlists/*',
        (services) => PlaylistScreen(
          services: services,
          id: playlistId,
          name: 'В дорогу',
        ),
        'Плейлиста больше нет',
      );
    });
  });

  testWidgets('409 on a new order — playlist reloaded and the reason shown', (
    tester,
  ) async {
    final rig = Rig();
    rig.server.on(
      'GET /v1/playlists/*',
      (_) => answer(200, playlistOf(['Звезда', 'Ночь', 'Кукушка'])),
    );
    rig.server.fail('POST /v1/playlists/*/order', 409, 'conflict');
    await rig.screen(
      tester,
      (services) =>
          PlaylistScreen(services: services, id: playlistId, name: 'В дорогу'),
    );

    tester
        .widget<ReorderableListView>(find.byType(ReorderableListView))
        .onReorderItem!(0, 2);
    await tester.pumpAndSettle();

    expect(rig.server.calls('POST /v1/playlists/*/order'), hasLength(1));
    expect(rig.server.calls('GET /v1/playlists/*'), hasLength(2));
    expect(find.text('Плейлист изменился — показан текущий'), findsOneWidget);
    // Screen reflects server order, not failed local order.
    final first = tester.getTopLeft(find.text('Звезда')).dy;
    expect(tester.getTopLeft(find.text('Ночь')).dy, greaterThan(first));
  });

  testWidgets('network dropped - "Server did not reply" and "Retry"', (
    tester,
  ) async {
    final rig = Rig();
    rig.server.on(
      'GET /v1/genres',
      (_) => throw http.ClientException('connection reset'),
    );
    await rig.screen(tester, (services) => GenresScreen(services: services));

    expect(find.text('Сервер не ответил'), findsOneWidget);
    expect(find.text('Повторить'), findsOneWidget);
    expect(find.text('Жанров пока нет'), findsNothing);
  });

  testWidgets('401 - no access, not "empty"', (tester) async {
    final rig = Rig();
    rig.server.fail('GET /v1/favorites', 401, 'unauthorized');
    await rig.screen(tester, (services) => FavoritesScreen(services: services));

    expect(
      find.text('Нет доступа: ключ сборки не подходит к серверу'),
      findsOneWidget,
    );
    expect(find.text('В избранном пока пусто'), findsNothing);
  });

  testWidgets('favorite tap failed - reason shown, state preserved', (
    tester,
  ) async {
    const found = '11111111-1111-1111-1111-111111111111';
    final rig = Rig();
    rig.server.fail('POST /v1/favorites', 503, 'library_unavailable');
    await rig.start(tester);
    await typeSearch(tester, 'metallica');

    await tapAndSettle(tester, find.byKey(const ValueKey('heart-$found')));

    expect(find.text('Сервер недоступен'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('heart-$found')))
          .isSelected,
      isFalse,
    );
  });

  testWidgets('failure mid-list - loaded items stay', (tester) async {
    final rig = Rig();
    final names = [for (var i = 1; i <= 150; i++) 'Исполнитель $i'];
    rig.server.on('GET /v1/artists', (request) {
      final offset = int.parse(request.url.queryParameters['offset']!);
      if (offset > 0) {
        return answer(503, {'status': 'catalog_unavailable'});
      }
      return answer(200, {
        'artists': [
          for (final name in names.take(100)) {'name': name},
        ],
        'total': names.length,
      });
    });
    await rig.screen(
      tester,
      (services) => ArtistsScreen(
        services: services,
        title: 'Рок',
        load: (offset) =>
            services.server.artistCatalog(genre: 'rock', offset: offset),
      ),
    );

    await tester.scrollUntilVisible(find.text('Повторить'), 500);
    await tester.pumpAndSettle();

    expect(find.text('Сервер недоступен'), findsOneWidget);
    expect(find.text('Исполнитель 100'), findsOneWidget);
  });
}
