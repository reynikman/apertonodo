import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_stream/auth/session_store.dart';
import 'package:music_stream/auth/token_provider.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/screens/catalog_screens.dart';
import 'package:music_stream/screens/parts.dart';
import 'package:music_stream/screens/search_screen.dart';
import 'package:music_stream/server_api.dart';

import 'fake_server.dart';

const albumId = '7ff1eff0-a8c8-37dc-807e-eea5a9e173b5';
final zvezda = songId('Звезда');
final noch = songId('Ночь');
final kukushka = songId('Кукушка');

/// "Cinema" page from fixture F and second album — unplayable, without cover art.
Map<String, dynamic> kinoWithDeadAlbum() {
  final page = sample('catalog-artist');
  final albums = page['albums'] as List<dynamic>;
  albums.add({
    ...albums.first as Map<String, dynamic>,
    'id': 'b0000000-0000-4000-8000-000000000001',
    'title': 'Ночь',
    'year': 1986,
    'playable': false,
    'cover': null,
  });
  return page;
}

void main() {
  test(
    'catalog chain genres → artists → artist → album: paths and session token',
    () async {
      const secure = 'https://apertono.test';
      final sent = <http.BaseRequest>[];
      final fixtures = {
        'GET /v1/genres': 'catalog-genres',
        'GET /v1/artists': 'catalog-artists',
        'GET /v1/artist': 'catalog-artist',
        'GET /v1/albums/*': 'catalog-album',
      };
      final client = MockClient((request) async {
        sent.add(request);
        return answer(200, sample(fixtures[routeOf(request)]!));
      });
      final tokens = TokenProvider(_MemoryStore(), server: Uri.parse(secure));
      await tokens.signIn('session-token');
      final api = ServerApi(secure, client: client, tokens: tokens);

      await api.genres();
      await api.artistCatalog(genre: 'rock');
      await api.artist('Кино');
      await api.album(albumId);

      expect(
        [for (final request in sent) routeOf(request)],
        [
          'GET /v1/genres',
          'GET /v1/artists',
          'GET /v1/artist',
          'GET /v1/albums/*',
        ],
      );
      expect(sent[3].url.path, '/v1/albums/$albumId');
      for (final request in sent) {
        expect(
          request.headers['authorization'],
          'Bearer session-token',
          reason: routeOf(request),
        );
      }
    },
  );

  group('catalog', () {
    testWidgets('catalog without session', (tester) async {
      final rig = Rig();
      await openAlbum(tester, rig);

      expect(find.text('Играть альбом'), findsOneWidget);
      expect(find.text('Кино · 1988'), findsOneWidget);
      final server = rig.server;
      expect(
        server
            .calls('GET /v1/artists')
            .firstWhere((request) {
              return request.url.queryParameters['genre'] != null;
            })
            .url
            .queryParameters,
        {'genre': 'rock', 'offset': '0', 'limit': '100'},
      );
      expect(server.calls('GET /v1/artist').single.url.queryParameters, {
        'name': 'Кино',
      });
      expect(
        server.calls('GET /v1/albums/*').single.url.path,
        '/v1/albums/$albumId',
      );
      expect(
        server.requests.every(
          (request) => !request.headers.containsKey('authorization'),
        ),
        isTrue,
      );
    });

    testWidgets('genre opens the same list as Browse', (tester) async {
      final rig = Rig();
      await rig.start(tester);
      await tester.pumpAndSettle();

      await openTab(tester, 'browse');
      await tapAndSettle(tester, find.text('Рок'));

      expect(
        find.descendant(of: find.byType(AppBar), matching: find.text('Рок')),
        findsOneWidget,
      );
      expect(
        rig.server
            .calls('GET /v1/artists')
            .firstWhere(
              (request) => request.url.queryParameters['genre'] != null,
            )
            .url
            .queryParameters,
        {'genre': 'rock', 'offset': '0', 'limit': '100'},
      );
    });

    testWidgets('artists load in chunks as the list scrolls', (tester) async {
      final rig = Rig();
      final names = [for (var i = 1; i <= 150; i++) 'Исполнитель $i'];
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
      await rig.screen(
        tester,
        (services) => ArtistsScreen(
          services: services,
          title: 'Рок',
          load: (offset) =>
              services.server.artistCatalog(genre: 'rock', offset: offset),
        ),
      );

      await tester.scrollUntilVisible(find.text('Исполнитель 150'), 500);
      await tester.pumpAndSettle();

      expect(find.text('Исполнитель 150'), findsOneWidget);
      expect(
        [
          for (final request in rig.server.calls('GET /v1/artists'))
            request.url.queryParameters['offset'],
        ],
        ['0', '100'],
      );
    });
  });

  group('rules', () {
    testWidgets('unplayable album — dimmed but in place', (tester) async {
      final rig = Rig();
      rig.server.on('GET /v1/artist', (_) => answer(200, kinoWithDeadAlbum()));
      await rig.screen(
        tester,
        (services) => ArtistScreen(services: services, name: 'Кино'),
      );

      expect(find.text('Ночь'), findsOneWidget);
      expect(alphaOf(tester, 'Ночь'), lessThan(0.5));
      expect(alphaOf(tester, 'Группа крови'), 1.0);
    });

    testWidgets('unplayable album song — dimmed but in place', (tester) async {
      final rig = Rig();
      rig.server.on(
        'GET /v1/albums/*',
        (_) => answer(200, albumOf(['Звезда', 'Ночь'], dead: {'Ночь'})),
      );
      await rig.screen(
        tester,
        (services) =>
            AlbumScreen(services: services, id: albumId, title: 'Альбом'),
      );

      expect(find.text('Ночь'), findsOneWidget);
      expect(alphaOf(tester, 'Ночь'), lessThan(0.5));
      expect(alphaOf(tester, 'Звезда'), 1.0);
    });

    testWidgets(
      'cover from own server with session token; absent: letter square box',
      (tester) async {
        final rig = Rig();
        rig.server.on(
          'GET /v1/artist',
          (_) => answer(200, kinoWithDeadAlbum()),
        );
        await rig.screen(
          tester,
          (services) => ArtistScreen(services: services, name: 'Кино'),
        );

        final alive = find.ancestor(
          of: find.text('Группа крови'),
          matching: find.byType(InkWell),
        );
        final image = tester
            .widget<Image>(
              find.descendant(of: alive, matching: find.byType(Image)),
            )
            .image;
        expect(image, isA<NetworkImage>());
        expect((image as NetworkImage).url, '$base/v1/covers/$albumId');

        final dead = find.ancestor(
          of: find.text('Ночь'),
          matching: find.byType(InkWell),
        );
        final square = find.descendant(
          of: dead,
          matching: find.byType(ArtistSquare),
        );
        expect(square, findsOneWidget);
        expect(
          find.descendant(of: square, matching: find.text('К')),
          findsOneWidget,
        );

        // Cover art failed to load (in tests any image HTTP is 400) — still
        // square, not empty space.
        expect(
          find.descendant(of: alive, matching: find.byType(ArtistSquare)),
          findsOneWidget,
        );
      },
    );

    testWidgets('cover image request carries the session token', (
      tester,
    ) async {
      const secure = 'https://apertono.test';
      final tokens = TokenProvider(_MemoryStore(), server: Uri.parse(secure));
      await tokens.signIn('session-token');
      final api = ServerApi(
        secure,
        client: MockClient((_) async => answer(200, {})),
        tokens: tokens,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Cover(server: api, path: '/v1/covers/$albumId', artist: 'Кино'),
        ),
      );

      final image = tester.widget<Image>(find.byType(Image)).image;
      expect(image, isA<NetworkImage>());
      expect((image as NetworkImage).url, '$secure/v1/covers/$albumId');
      expect(image.headers, {'authorization': 'Bearer session-token'});
    });

    testWidgets('artist photo — with author and license credit', (
      tester,
    ) async {
      final rig = Rig();
      await rig.screen(
        tester,
        (services) => ArtistScreen(services: services, name: 'Metallica'),
      );

      final photo = sample('catalog-artist-lastfm')['artist'] as Map;
      final image = tester.widget<Image>(find.byType(Image).first).image;
      expect((image as NetworkImage).url, '$base${photo['photo']}');
      expect(find.text('фото: ${photo['photo_credit']}'), findsOneWidget);
    });

    testWidgets('no photo: no attribution line either, no placeholders', (
      tester,
    ) async {
      final rig = Rig();
      rig.server.on('GET /v1/artist', (_) {
        final page = sample('catalog-artist-lastfm');
        (page['artist'] as Map)['photo'] = null;
        (page['artist'] as Map)['photo_credit'] = null;
        return answer(200, page);
      });
      await rig.screen(
        tester,
        (services) => ArtistScreen(services: services, name: 'Metallica'),
      );

      expect(find.textContaining('фото:'), findsNothing);
    });

    test('artist initials', () {
      expect(initials('Кино'), 'К');
      expect(initials('Pink Floyd'), 'PF');
      expect(initials('The Velvet Underground'), 'TV');
      expect(initials('(hed) p.e.'), 'HP');
    });

    testWidgets('Last.fm blocks in the response — on screen', (tester) async {
      await Rig().screen(
        tester,
        (services) => ArtistScreen(services: services, name: 'Metallica'),
      );

      for (final text in [
        'Популярное',
        'Enter Sandman',
        'Похожие исполнители',
        'Megadeth',
        'Об исполнителе',
        'Metallica is an American heavy metal band.',
      ]) {
        expect(find.text(text), findsOneWidget, reason: text);
      }
    });

    testWidgets('no blocks in the response — none on screen, no placeholders', (
      tester,
    ) async {
      final rig = Rig();
      rig.server.on(
        'GET /v1/artist',
        (_) => answer(200, sample('catalog-artist')),
      );
      await rig.screen(
        tester,
        (services) => ArtistScreen(services: services, name: 'Кино'),
      );

      expect(find.text('Группа крови'), findsOneWidget);
      expect(find.byType(Heading), findsOneWidget, reason: 'only Albums');
      expect(find.text('Популярное'), findsNothing);
      expect(find.text('Похожие исполнители'), findsNothing);
      expect(find.text('Об исполнителе'), findsNothing);
    });

    testWidgets('similar artist: opens their page', (tester) async {
      final rig = Rig();
      await rig.screen(
        tester,
        (services) => ArtistScreen(services: services, name: 'Metallica'),
      );

      await tester.ensureVisible(find.text('Megadeth'));
      await tapAndSettle(tester, find.text('Megadeth'));
      expect(rig.server.calls('GET /v1/artist').last.url.queryParameters, {
        'name': 'Megadeth',
      });
    });

    testWidgets('tapped a top song — it plays, search never opened', (
      tester,
    ) async {
      const sandman = '005bfa2b-e86b-41a3-b08d-49b0372496dd';
      const one = '11111111-2222-4111-8111-111111111111';
      const hidden = '22222222-2222-4222-8222-222222222222';
      Map<String, dynamic> song(
        String id,
        String title, {
        bool playable = true,
      }) {
        return {
          'id': id,
          'title': title,
          'artist': 'Metallica',
          'duration_ms': 331000,
          'artwork_url': '',
          'playable': playable,
        };
      }

      final rig = Rig();
      rig.server.on('GET /v1/artist', (_) {
        final page = sample('catalog-artist-lastfm');
        page['top_tracks'] = [
          song(sandman, 'Enter Sandman'),
          {'title': 'Fade to Black', 'playable': true},
          song(one, 'One'),
          song(hidden, 'Hidden', playable: false),
        ];
        return answer(200, page);
      });
      await rig.screen(
        tester,
        (services) => ArtistScreen(services: services, name: 'Metallica'),
      );

      await tester.ensureVisible(find.text('Enter Sandman'));
      await tester.tap(find.text('Enter Sandman'));
      await tester.pump();

      expect(find.byType(SearchScreen), findsNothing);
      expect(rig.server.calls('GET /v1/search'), isEmpty);
      expect(rig.played, hasLength(1));
      final (queue, start) = rig.played.single;
      expect(start, 0);
      expect([for (final track in queue) track.id], [sandman, one]);
    });

    testWidgets('top song without a number — search', (tester) async {
      final rig = Rig();
      rig.server.on('GET /v1/artist', (_) {
        final page = sample('catalog-artist-lastfm');
        page['top_tracks'] = [
          {'title': 'Enter Sandman', 'playable': true},
        ];
        return answer(200, page);
      });
      await rig.screen(
        tester,
        (services) => ArtistScreen(services: services, name: 'Metallica'),
      );

      await tester.ensureVisible(find.text('Enter Sandman'));
      await tapAndSettle(tester, find.text('Enter Sandman'));
      expect(
        rig.server.calls('GET /v1/search').single.url.queryParameters['q'],
        'Metallica Enter Sandman',
      );
      expect(find.text('Nothing Else Matters'), findsOneWidget);
      // As in search menu (Phase D): first track of search results is preloaded.
      expect(rig.prepared, ['11111111-1111-1111-1111-111111111111']);
    });
  });

  group('queue', () {
    Rig albumRig() {
      final rig = Rig();
      rig.server.on(
        'GET /v1/albums/*',
        (_) =>
            // Dimmed both as first and mid-album: "Play album" must
            // start with first playable and skip dimmed track in the middle.
            answer(
              200,
              albumOf(
                ['Ночь', 'Звезда', 'Сон', 'Кукушка'],
                dead: {'Ночь', 'Сон'},
              ),
            ),
      );
      return rig;
    }

    Future<void> finishSong(WidgetTester tester, Rig rig) async {
      rig.audio.emit(AudioPhase.playing);
      await tester.pump();
      rig.audio.finish();
      await tester.pump();
    }

    testWidgets('song from album page goes to player with album cover art', (
      tester,
    ) async {
      final rig = Rig();
      await rig.screen(
        tester,
        (services) =>
            AlbumScreen(services: services, id: albumId, title: 'Группа крови'),
      );

      await tester.tap(find.text('Играть альбом'));
      await tester.pump();

      final (tracks, _) = rig.played.single;
      expect(tracks.first.artworkUrl, '/v1/covers/$albumId');
    });

    testWidgets(
      '"Play album" — queue G starting at the first playable, dimmed ones skipped',
      (tester) async {
        final rig = albumRig();
        await openAlbum(tester, rig);

        await tester.tap(find.text('Играть альбом'));
        await tester.pump();
        expect(rig.playback.started, [zvezda]);
        await finishSong(tester, rig);
        expect(rig.playback.started, [zvezda, kukushka]);
        await finishSong(tester, rig);
        expect(rig.playback.started, [
          zvezda,
          kukushka,
        ], reason: 'end of album');
      },
    );

    testWidgets('tapped song plays from it; tapped dim track is attempted', (
      tester,
    ) async {
      final rig = albumRig();
      await openAlbum(tester, rig);

      await tester.tap(find.text('Кукушка'));
      await tester.pump();
      expect(rig.playback.started, [kukushka]);

      await tester.tap(find.text('Ночь').first);
      await tester.pump();
      expect(rig.playback.started, [kukushka, noch]);
      await finishSong(tester, rig);
      expect(rig.playback.started, [kukushka, noch, zvezda]);
    });
  });
}

class _MemoryStore extends SessionStore {
  String? token;

  @override
  Future<void> saveToken(String token) async => this.token = token;

  @override
  Future<String?> readToken() async => token;

  @override
  Future<void> clear() async => token = null;
}
