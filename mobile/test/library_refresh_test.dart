import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';
import 'back.dart';

/// Owner findings 02.10 (`plan/p4-fixes.md`, C and D):
/// - 7: heart and new playlist did not appear on Home — Home read
///   "Favorites" and playlists once, on first tab open;
/// - 8: "New playlist" in "Add to playlist" sheet created empty
///   playlist — song had to be added to it manually again.
const found = '11111111-1111-1111-1111-111111111111';
const created = '0a0a0a0a-0000-4000-8000-000000000001';

/// Server with memory: favorites and playlists change on requests, like real ones.
class LiveLibrary {
  LiveLibrary(this.rig) {
    final searchTrack =
        (sample('search')['tracks'] as List).first as Map<String, dynamic>;
    final known = [
      searchTrack,
      ...sample('library-favorites')['tracks'] as List,
    ];
    // Favorites — exactly what is currently lit: unliked — gone from here too.
    rig.server.on(
      'GET /v1/favorites',
      (_) => answer(200, {
        'tracks': [
          for (final track in known)
            if (rig.server.liked.contains((track as Map)['id'])) track,
        ],
      }),
    );
    rig.server.on(
      'GET /v1/playlists',
      (_) => answer(200, {'playlists': playlists}),
    );
    rig.server.on('POST /v1/playlists', (request) {
      final name = bodyOf(request)['name'];
      playlists.add({'id': created, 'name': name, 'tracks': 0});
      return answer(201, {'id': created, 'name': name, 'tracks': 0});
    });
    rig.server.on('POST /v1/playlists/*/tracks', (request) {
      final id = request.url.pathSegments[2];
      for (final playlist in playlists) {
        if (playlist['id'] == id) {
          playlist['tracks'] = (playlist['tracks'] as int) + 1;
        }
      }
      return answer(200, {'status': 'ok'});
    });
  }

  final Rig rig;
  final playlists = [
    for (final row in sample('library-playlists')['playlists'] as List)
      {...row as Map<String, dynamic>},
  ];
}

String tileText(WidgetTester tester, String key) => [
  for (final text in tester.widgetList<Text>(
    find.descendant(of: find.byKey(Key(key)), matching: find.byType(Text)),
  ))
    text.data ?? text.textSpan?.toPlainText() ?? '',
].join(' · ');

Future<void> addToNewPlaylist(WidgetTester tester, String name) async {
  await tapAndSettle(tester, find.byTooltip('Ещё').first);
  await tapAndSettle(tester, find.text('Добавить в плейлист'));
  await tapAndSettle(tester, find.text('Новый плейлист'));
  await tester.enterText(find.byKey(const Key('name-field')), name);
  await tester.pump();
  await tapAndSettle(tester, find.text('Сохранить'));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('7: search heart visible on Home and in «My music»', (
    tester,
  ) async {
    final rig = Rig();
    LiveLibrary(rig);
    await rig.start(tester);
    // Both tabs opened already: first build reads server anyway.
    await openTab(tester, 'library');
    expect(tileText(tester, 'library-favorites'), contains('1 трек'));
    await openTab(tester, 'home');
    expect(tileText(tester, 'home-favorites'), contains('1 трек'));

    await typeSearch(tester, 'metallica');
    await tapAndSettle(tester, find.byKey(const ValueKey('heart-$found')));

    await openTab(tester, 'home');
    expect(tileText(tester, 'home-favorites'), contains('2 трека'));
    await openTab(tester, 'library');
    expect(tileText(tester, 'library-favorites'), contains('2 трека'));

    // Unliked — back to one, and on Home as well.
    await typeSearch(tester, 'metallica');
    await tapAndSettle(tester, find.byKey(const ValueKey('heart-$found')));
    await openTab(tester, 'home');
    expect(tileText(tester, 'home-favorites'), contains('1 трек'));
  });

  testWidgets('8: «New playlist» from add sheet — track already inside', (
    tester,
  ) async {
    final rig = Rig();
    final library = LiveLibrary(rig);
    await rig.start(tester);
    await typeSearch(tester, 'metallica');

    await addToNewPlaylist(tester, 'Adele');

    expect(rig.server.bodies('POST /v1/playlists'), [
      {'name': 'Adele'},
    ]);
    expect(rig.server.calls('POST /v1/playlists/*/tracks'), hasLength(1));
    expect(
      rig.server.calls('POST /v1/playlists/*/tracks').single.url.path,
      '/v1/playlists/$created/tracks',
    );
    expect(bodyOf(rig.server.calls('POST /v1/playlists/*/tracks').single), {
      'track_id': found,
    });
    expect(library.playlists.last['tracks'], 1);
    expect(find.text('Добавлено в «Adele»'), findsOneWidget);
    // Selection sheet closed: nowhere and no reason to tap second time.
    expect(find.text('Новый плейлист'), findsNothing);
  });

  testWidgets('7: new playlist visible on Home and in «My music»', (
    tester,
  ) async {
    final rig = Rig();
    LiveLibrary(rig);
    await rig.start(tester);
    await openTab(tester, 'library');
    expect(tileText(tester, 'library-playlists'), contains('1 плейлист'));
    await openTab(tester, 'home');
    expect(tileText(tester, 'home-playlists'), contains('1 плейлист'));

    await typeSearch(tester, 'metallica');
    await addToNewPlaylist(tester, 'Adele');

    await openTab(tester, 'home');
    expect(tileText(tester, 'home-playlists'), contains('2 плейлиста'));
    await openTab(tester, 'library');
    expect(tileText(tester, 'library-playlists'), contains('2 плейлиста'));
  });

  testWidgets('cancel name — no playlist, no track, picker sheet stays', (
    tester,
  ) async {
    final rig = Rig();
    LiveLibrary(rig);
    await rig.start(tester);
    await typeSearch(tester, 'metallica');

    await tapAndSettle(tester, find.byTooltip('Ещё').first);
    await tapAndSettle(tester, find.text('Добавить в плейлист'));
    await tapAndSettle(tester, find.text('Новый плейлист'));
    // Two "Cancel" buttons: name dialog over picker sheet — tap top one.
    await tapAndSettle(tester, find.text('Отмена').last);

    expect(rig.server.calls('POST /v1/playlists'), isEmpty);
    expect(rig.server.calls('POST /v1/playlists/*/tracks'), isEmpty);
    expect(find.text('Новый плейлист'), findsOneWidget);
  });

  testWidgets('5 hearts in a row — no redundant requests while '
      'Home is hidden; returned — reread once', (tester) async {
    // Rereading all on each tap — ~8 requests per heart: five
    // hearts in a row would hit NPM limit (burst 20) and return 429.
    final rig = Rig();
    LiveLibrary(rig);
    await rig.start(tester);
    await openTab(tester, 'library');
    await typeSearch(tester, 'metallica');
    final favorites = rig.server.calls('GET /v1/favorites').length;
    final playlists = rig.server.calls('GET /v1/playlists').length;

    for (var i = 0; i < 5; i++) {
      await tapAndSettle(tester, find.byKey(const ValueKey('heart-$found')));
    }
    expect(rig.server.calls('GET /v1/favorites'), hasLength(favorites));
    expect(rig.server.calls('GET /v1/playlists'), hasLength(playlists));

    await openTab(tester, 'home');
    expect(tileText(tester, 'home-favorites'), contains('2 трека'));
    expect(
      rig.server.calls('GET /v1/favorites').length - favorites,
      lessThanOrEqualTo(1),
    );
  });

  testWidgets('Home → «Favorites» → unhearted → back: on Home '
      'already empty', (tester) async {
    const duality = '33333333-3333-3333-3333-333333333333';
    final rig = Rig();
    LiveLibrary(rig);
    await rig.start(tester);
    await openTab(tester, 'home');
    expect(tileText(tester, 'home-favorites'), contains('1 трек'));

    await tapAndSettle(tester, find.byKey(const Key('home-favorites')));
    await tapAndSettle(tester, find.byKey(const ValueKey('heart-$duality')));
    await tapBack(tester);
    await tester.pumpAndSettle();

    expect(tileText(tester, 'home-favorites'), contains('Пока пусто'));
  });
}
