import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/screens/catalog_screens.dart';
import 'package:music_stream/screens/library_screens.dart';
import 'package:music_stream/screens/parts.dart';
import 'package:music_stream/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';
import 'golden_support.dart';
import 'back.dart';

/// Home screen per Figma export (P4, step 3; FT-474; handoff §6.1, prototype-v2
/// `.home-screen`): "Home", tile of four artists, two tiles
/// "Favorite songs" and "Playlists", tile of four recent songs without
/// header. Without scrolling while it fits; tiles shrink 260 → 180.
void main() {
  // Real fonts: in square Ahem "Favorite songs" does not fit in row,
  // and "does home screen fit" check would measure wrong screen.
  setUpAll(loadAppFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final title = find.byKey(const Key('home-title'));
  final artists = find.byKey(const Key('home-artists'));
  final favorites = find.byKey(const Key('home-favorites'));
  final playlists = find.byKey(const Key('home-playlists'));
  final recent = find.byKey(const Key('home-recent'));
  final mini = find.byKey(const Key('mini-player'));

  /// Five songs by five artists; Slipknot listened to most frequently.
  Map<String, dynamic> history() => {
    'tracks': [
      for (final (artist, song) in [
        ('Slipknot', 'Duality'),
        ('Queen', 'Bohemian Rhapsody'),
        ('Slipknot', 'Psychosocial'),
        ('Nirvana', 'Smells Like Teen Spirit'),
        ('Radiohead', 'Creep'),
        ('Linkin Park', 'Numb'),
      ])
        songLike('library-history', songId(song), song)
          ..['artist'] = artist
          ..['artwork_url'] = '/v1/covers/${songId(song)}',
    ],
    'total': 6,
  };

  Map<String, dynamic> favoritesOf(int count) => {
    'tracks': [
      for (var i = 1; i <= count; i++)
        songLike('library-favorites', songId('Любимая $i'), 'Любимая $i')
          ..['artwork_url'] = '/v1/covers/fav-$i',
    ],
  };

  Map<String, dynamic> playlistsOf(int count) => {
    'playlists': [
      for (var i = 1; i <= count; i++)
        {
          'id': '0a0a0a0a-0000-4000-8000-00000000000$i',
          'name': 'Плейлист $i',
          'tracks': 3,
        },
    ],
  };

  Rig rigWithData({int liked = 128, int lists = 6}) {
    final rig = Rig();
    rig.server.on('GET /v1/history', (_) => answer(200, history()));
    rig.server.on('GET /v1/favorites', (_) => answer(200, favoritesOf(liked)));
    rig.server.on('GET /v1/playlists', (_) => answer(200, playlistsOf(lists)));
    rig.server.on(
      'GET /v1/playlists/*',
      (request) => answer(
        200,
        playlistOf(['Песня из ${request.url.pathSegments.last}'])
          ..['tracks'][0]['artwork_url'] =
              '/v1/covers/pl-${request.url.pathSegments.last}',
      ),
    );
    return rig;
  }

  Future<Rig> open(
    WidgetTester tester, {
    Size? size,
    Rig? rig,
    double textScale = 1,
  }) async {
    usePhone(tester, size ?? phones['360']!);
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final it = rig ?? rigWithData();
    await it.start(tester);
    await tester.pumpAndSettle();
    return it;
  }

  Iterable<String> imageUrls(WidgetTester tester, Finder within) => tester
      .widgetList<Image>(
        find.descendant(of: within, matching: find.byType(Image)),
      )
      .map((image) => image.image)
      .whereType<NetworkImage>()
      .map((image) => image.url);

  BorderRadius? radiusOf(WidgetTester tester, Finder finder) {
    final box = tester.widget<DecoratedBox>(finder);
    return (box.decoration as BoxDecoration).borderRadius as BorderRadius?;
  }

  testWidgets('top to bottom: Home, artists, recent, two tiles list', (
    tester,
  ) async {
    await open(tester);

    final t = tester.getRect(title);
    final a = tester.getRect(artists);
    final f = tester.getRect(favorites);
    final p = tester.getRect(playlists);
    final r = tester.getRect(recent);
    expect(t.bottom, lessThanOrEqualTo(a.top));
    // P-A45: favorites more important than recent — tiles at bottom, under thumb.
    expect(a.bottom, lessThanOrEqualTo(r.top));
    expect(r.bottom, lessThanOrEqualTo(f.top));
    expect(f.top, p.top, reason: 'tiles sit in one row');
    expect(
      f.right,
      lessThan(p.left),
      reason: 'Favorites on left, Playlists on right',
    );

    // Screen padding 16, gap between blocks 10.
    for (final block in [a, r]) {
      expect(block.left, 16);
      expect(block.right, 360 - 16);
    }
    expect(f.left, 16);
    expect(p.right, 360 - 16);
    expect(p.left - f.right, 10);
    expect(f.width, p.width);
    expect(r.top - a.bottom, 10);
    expect(f.top - r.bottom, 10);
  });

  testWidgets('Home title is 26 bold, old header texts absent here', (
    tester,
  ) async {
    await open(tester);

    final text = tester.widget<Text>(title);
    expect(text.data, 'Главная');
    expect(text.style?.fontSize, 26);
    expect(text.style?.fontWeight, FontWeight.w700);
    for (final old in ['Ваши артисты', 'Недавно играло', 'Недавнее']) {
      expect(find.text(old), findsNothing, reason: old);
    }
  });

  testWidgets('artists: four most frequent from history, circles 56, tile 22', (
    tester,
  ) async {
    await open(tester);

    expect(radiusOf(tester, artists), BorderRadius.circular(22));
    // Slipknot — twice, others once and alphabetically.
    final names = ['Slipknot', 'Linkin Park', 'Nirvana', 'Queen'];
    for (final name in names) {
      expect(
        find.descendant(of: artists, matching: find.text(name)),
        findsOneWidget,
        reason: name,
      );
    }
    expect(
      find.descendant(of: artists, matching: find.text('Radiohead')),
      findsNothing,
      reason: 'fifth artist does not fit in tile',
    );
    expect(
      find.descendant(of: artists, matching: find.byType(Scrollable)),
      findsNothing,
      reason: 'artist row has no scroll',
    );
    final circles = find.descendant(
      of: artists,
      matching: find.byKey(const Key('home-artist-avatar')),
    );
    expect(circles, findsNWidgets(4));
    for (final circle in circles.evaluate()) {
      expect(tester.getSize(find.byWidget(circle.widget)), const Size(56, 56));
    }
    final name = tester.widget<Text>(
      find.descendant(of: artists, matching: find.text('Slipknot')),
    );
    expect(name.style?.fontSize, 12);
    expect(name.style?.fontWeight, FontWeight.w500);
  });

  testWidgets('no history: four catalog artists, recent block gone', (
    tester,
  ) async {
    final rig = rigWithData();
    rig.server.on(
      'GET /v1/history',
      (_) => answer(200, {'tracks': const [], 'total': 0}),
    );
    rig.server.on('GET /v1/artists', (_) {
      return answer(200, {
        'artists': [
          for (var i = 1; i <= 6; i++) {'name': 'Исполнитель $i'},
        ],
        'total': 6,
      });
    });
    await open(tester, rig: rig);

    for (var i = 1; i <= 4; i++) {
      expect(
        find.descendant(of: artists, matching: find.text('Исполнитель $i')),
        findsOneWidget,
      );
    }
    expect(find.text('Исполнитель 5'), findsNothing);
    expect(recent, findsNothing);
    expect(favorites, findsOneWidget);
    expect(playlists, findsOneWidget);
  });

  testWidgets('tapping artist tile opens page, tab stays on Home', (
    tester,
  ) async {
    final rig = await open(tester);

    await tapAndSettle(
      tester,
      find.descendant(of: artists, matching: find.text('Slipknot')),
    );

    expect(find.byType(ArtistScreen), findsOneWidget);
    expect(rig.server.calls('GET /v1/artist'), hasLength(1));
    expect(find.byKey(const Key('nav-bar')), findsOneWidget);
    expect(
      tester.getCenter(find.byKey(const Key('tab-capsule'))),
      tester.getCenter(find.byKey(const Key('tab-home'))),
    );
  });

  testWidgets('tiles: radius 22, headers and count shown', (tester) async {
    await open(tester, rig: rigWithData(liked: 128, lists: 6));

    for (final tile in [favorites, playlists]) {
      expect(radiusOf(tester, tile), BorderRadius.circular(22));
    }
    expect(
      find.descendant(of: favorites, matching: find.text('Любимые песни')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: favorites, matching: find.text('128 треков')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: playlists, matching: find.text('Плейлисты')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: playlists, matching: find.text('6 плейлистов')),
      findsOneWidget,
    );
    final head = tester.widget<Text>(
      find.descendant(of: favorites, matching: find.text('Любимые песни')),
    );
    expect(head.style?.fontSize, 16.5);
    expect(head.style?.fontWeight, FontWeight.w700);
    final sub = tester.widget<Text>(
      find.descendant(of: favorites, matching: find.text('128 треков')),
    );
    expect(sub.style?.fontSize, 12.5);
  });

  testWidgets('count pluralizes: 1 track, 3 playlists', (tester) async {
    await open(tester, rig: rigWithData(liked: 1, lists: 3));
    expect(find.text('1 трек'), findsOneWidget);
    expect(find.text('3 плейлиста'), findsOneWidget);
  });

  testWidgets('empty: tiles remain, empty label, fan placeholders', (
    tester,
  ) async {
    final rig = await open(tester, rig: rigWithData(liked: 0, lists: 0));

    expect(
      find.descendant(of: favorites, matching: find.text('Пока пусто')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: playlists, matching: find.text('Пока пусто')),
      findsOneWidget,
    );
    expect(rig.server.calls('GET /v1/playlists/*'), isEmpty);
    for (final tile in [favorites, playlists]) {
      expect(
        find.descendant(
          of: tile,
          matching: find.byKey(const Key('home-fan-cover')),
        ),
        findsNWidgets(3),
        reason: 'fan holds shape without covers',
      );
      expect(
        find.descendant(
          of: find.descendant(
            of: tile,
            matching: find.byKey(const Key('home-fan-cover')),
          ),
          matching: find.byType(Text),
        ),
        findsNothing,
        reason: 'empty fan without initials: slot for cover',
      );
      // Musical note icon on placeholder stuck out from under middle cover as dot
      // (owner finding 01.10, P-A45).
      expect(
        find.descendant(
          of: find.descendant(
            of: tile,
            matching: find.byKey(const Key('home-fan-cover')),
          ),
          matching: find.byType(Icon),
        ),
        findsNothing,
        reason: 'no icon on empty fan slot',
      );
    }
  });

  testWidgets('tile icons white: heart on Favorites, list on Lists', (
    tester,
  ) async {
    await open(tester);

    final heart = tester.widget<Icon>(
      find.descendant(of: favorites, matching: find.byType(Icon)).first,
    );
    final list = tester.widget<Icon>(
      find.descendant(of: playlists, matching: find.byType(Icon)).first,
    );
    expect(heart.icon, Icons.favorite_border);
    expect(list.icon, Icons.queue_music);
    // P-A45: owner on 01.10 — "make icon white, same as playlists".
    expect(heart.color, ApertonoColors.textPrimary);
    expect(list.color, ApertonoColors.textPrimary);
  });

  testWidgets('liked song without cover shows initials in fan view', (
    tester,
  ) async {
    // Owner finding 01.10: single favorite song, but fan is empty — song
    // has no cover, and fan rendered blank space instead of placeholder.
    final rig = rigWithData(liked: 1);
    rig.server.on(
      'GET /v1/favorites',
      (_) => answer(200, {
        'tracks': [
          songLike('library-favorites', songId('Любимая 1'), 'Любимая 1')
            ..['artist'] = 'Metallica'
            ..['artwork_url'] = '',
        ],
      }),
    );
    await open(tester, rig: rig);

    final fan = find.descendant(
      of: favorites,
      matching: find.byKey(const Key('home-fan-cover')),
    );
    expect(fan, findsNWidgets(3));
    expect(
      find.descendant(of: fan, matching: find.byType(Cover)),
      findsOneWidget,
      reason: 'song exists: card in fan, not empty slot',
    );
    expect(
      find.descendant(of: fan, matching: find.text('M')),
      findsOneWidget,
      reason: 'without cover: artist initials as in lists',
    );
  });

  testWidgets('Favorites fan: first three favorite covers', (tester) async {
    await open(tester);

    expect(
      find.descendant(
        of: favorites,
        matching: find.byKey(const Key('home-fan-cover')),
      ),
      findsNWidgets(3),
    );
    expect(
      imageUrls(tester, favorites),
      unorderedEquals([for (var i = 1; i <= 3; i++) '$base/v1/covers/fav-$i']),
    );
  });

  testWidgets('Playlists fan: first cover of first 3 playlists', (
    tester,
  ) async {
    final rig = await open(tester);

    expect(
      rig.server.calls('GET /v1/playlists/*'),
      hasLength(3),
      reason: 'at most three fan queries',
    );
    expect(
      imageUrls(tester, playlists),
      unorderedEquals([
        for (var i = 1; i <= 3; i++)
          '$base/v1/covers/pl-0a0a0a0a-0000-4000-8000-00000000000$i',
      ]),
    );
  });

  testWidgets('no network queries before first frame renders', (tester) async {
    usePhone(tester, phones['360']!);
    final rig = rigWithData();
    await rig.start(tester);

    expect(title, findsOneWidget);
    expect(rig.server.requests, isEmpty);
    await tester.pumpAndSettle();
  });

  testWidgets('Favorite songs opens its screen, tab remains Home', (
    tester,
  ) async {
    await open(tester);

    await tapAndSettle(tester, favorites);
    expect(find.byType(FavoritesScreen), findsOneWidget);
    expect(
      tester.getCenter(find.byKey(const Key('tab-capsule'))),
      tester.getCenter(find.byKey(const Key('tab-home'))),
    );

    await tapBack(tester);
    await tester.pumpAndSettle();
    await tapAndSettle(tester, playlists);
    expect(find.byType(PlaylistsScreen), findsOneWidget);
  });

  testWidgets('recent: 4 rows, cover 44 radius 10, three dashes', (
    tester,
  ) async {
    await open(tester);

    expect(radiusOf(tester, recent), BorderRadius.circular(22));
    // History ordered newest to oldest: four initial distinct songs.
    final songs = [
      'Duality',
      'Bohemian Rhapsody',
      'Psychosocial',
      'Smells Like Teen Spirit',
    ];
    for (final song in songs) {
      expect(
        find.descendant(of: recent, matching: find.text(song)),
        findsOneWidget,
        reason: song,
      );
    }
    expect(
      find.descendant(of: recent, matching: find.text('Creep')),
      findsNothing,
      reason: 'fifth song does not fit in tile',
    );
    final covers = find.descendant(
      of: recent,
      matching: find.byKey(const Key('home-recent-cover')),
    );
    expect(covers, findsNWidgets(4));
    expect(tester.getSize(covers.first), const Size(44, 44));
    expect(
      find.descendant(of: recent, matching: find.byType(Divider)),
      findsNWidgets(3),
    );
    final song = tester.widget<Text>(
      find.descendant(of: recent, matching: find.text('Psychosocial')),
    );
    expect(song.style?.fontSize, 14.5);
    expect(song.style?.fontWeight, FontWeight.w600);
  });

  testWidgets('at 360 dp with mini-player home fits without scrolling', (
    tester,
  ) async {
    final rig = await open(tester);
    await tester.tap(
      find.descendant(of: recent, matching: find.text('Psychosocial')),
    );
    await tester.pump();
    rig.audio.emit(AudioPhase.playing);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(mini, findsOneWidget);
    final scroll = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byKey(const Key('home-screen')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(
      scroll.position.maxScrollExtent,
      0,
      reason: 'home screen should not scroll',
    );
    expect(
      tester.getRect(mini).top - tester.getRect(favorites).bottom,
      greaterThanOrEqualTo(10),
      reason: 'tiles tucked under mini player',
    );
    final tile = tester.getRect(favorites).height;
    expect(tile, inInclusiveRange(180, 260));
  });

  testWidgets('owner device: header sits under notification bar', (
    tester,
  ) async {
    // TECNO KJ7: 360×812 dp, status bar 36 dp, no bottom buttons
    // (gestures). On 01.10 "Home" slid under clock: tests lacked status bar.
    tester.view.padding = const FakeViewPadding(top: 36);
    final rig = await open(tester, size: const Size(360, 812));
    await tester.tap(
      find.descendant(of: recent, matching: find.text('Psychosocial')),
    );
    await tester.pump();
    rig.audio.emit(AudioPhase.playing);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      tester.getRect(find.byKey(const Key('home-title'))).top,
      greaterThanOrEqualTo(36 + 8),
      reason: 'header sits under notification bar',
    );
    final scroll = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byKey(const Key('home-screen')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(
      scroll.position.maxScrollExtent,
      0,
      reason: 'home screen should not scroll',
    );
    expect(
      tester.getRect(mini).top - tester.getRect(favorites).bottom,
      greaterThanOrEqualTo(10),
      reason: 'tiles tucked under mini player',
    );
  });

  testWidgets('at 412 dp tiles take full height 260', (tester) async {
    await open(tester, size: phones['412']);

    expect(tester.getRect(favorites).height, 260);
    expect(tester.getRect(playlists).height, 260);
  });

  testWidgets('large font: screen scrolls, no content is clipped', (
    tester,
  ) async {
    await open(tester, textScale: 2);

    expect(tester.takeException(), isNull);
    final scroll = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byKey(const Key('home-screen')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(scroll.position.maxScrollExtent, greaterThan(0));
    await tester.scrollUntilVisible(
      find.descendant(
        of: recent,
        matching: find.text('Smells Like Teen Spirit'),
      ),
      200,
      scrollable: find
          .descendant(
            of: find.byKey(const Key('home-screen')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('favorites and playlists fail: tiles alive, no error', (
    tester,
  ) async {
    final rig = rigWithData();
    rig.server.fail('GET /v1/favorites', 503, 'library_unavailable');
    rig.server.fail('GET /v1/playlists', 503, 'library_unavailable');
    await open(tester, rig: rig);

    expect(favorites, findsOneWidget);
    expect(playlists, findsOneWidget);
    expect(find.byType(ErrorWidget), findsNothing);
    expect(find.text('Сервер недоступен'), findsNothing);
    expect(find.textContaining('library_unavailable'), findsNothing);
    expect(
      find.textContaining('треков'),
      findsNothing,
      reason: 'count is not fabricated',
    );
    expect(recent, findsOneWidget);
    expect(artists, findsOneWidget);
  });

  testWidgets('tile colors taken from export theme', (tester) async {
    await open(tester);

    final box =
        tester.widget<DecoratedBox>(artists).decoration as BoxDecoration;
    expect(box.gradient, ApertonoColors.cardGradient);
    expect((box.border as Border?)?.top.color, ApertonoColors.border);
  });

  group('снимок-эталон', () {
    setUpAll(compareOnMacOnly);

    for (final MapEntry(key: name, value: size) in phones.entries) {
      testWidgets('home screen at $name dp', (tester) async {
        await open(tester, size: size);
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/home_$name.png'),
        );
      });
    }
  });
}
