import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/app.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/screens/library_screens.dart';
import 'package:music_stream/screens/parts.dart';
import 'package:music_stream/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';
import 'fakes.dart';
import 'golden_support.dart';
import 'back.dart';

/// "My music": header title and account, tiles per owner mockup
/// 12.10 (FT-798): "Favorite songs" wide tile with cover fan, below
/// "Library" 2x2 grid. General layout (heights, "My ratings", import,
/// dimmed) — in `library_layout_test.dart`; here tile styling,
/// header, transitions and large font. No "Favorite artists" — server does
/// not store them (P4 plan, "Out of scope").
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final title = find.byKey(const Key('library-title'));
  final favorites = find.byKey(const Key('library-favorites'));
  final history = find.byKey(const Key('library-history'));
  final playlists = find.byKey(const Key('library-playlists'));
  final downloads = find.byKey(const Key('library-downloads'));
  final device = find.byKey(const Key('library-device'));

  String songId(int i) => '5e5e5e5e-0000-4000-8000-00000000000$i';

  Map<String, dynamic> favoritesOf(int count) => {
    'tracks': [
      for (var i = 1; i <= count; i++)
        songLike('library-favorites', songId(i), 'Любимая $i')
          ..['artwork_url'] = '/v1/covers/fav-$i',
    ],
  };

  Map<String, dynamic> playlistsOf(int count) => {
    'playlists': [
      for (var i = 1; i <= count; i++)
        {
          'id': '0a0a0a0a-0000-4000-8000-00000000000$i',
          'name': 'Плейлист $i',
          'tracks': i,
        },
    ],
  };

  /// App with login, like owner's: account in header and accessible
  /// "Downloaded". [account] = false — test wrapper without login and downloads.
  Future<Rig> openLibrary(
    WidgetTester tester, {
    Size? size,
    bool account = true,
    int liked = 4,
  }) async {
    usePhone(tester, size ?? phones['360']!);
    final rig = Rig();
    rig.server.on('GET /v1/favorites', (_) => answer(200, favoritesOf(liked)));
    rig.server.on('GET /v1/playlists', (_) => answer(200, playlistsOf(2)));
    if (account) {
      addTearDown(rig.audio.close);
      addTearDown(() => expect(rig.server.unknown, isEmpty));
      await tester.pumpWidget(
        MusicApp(
          catalogSource: rig.server.catalog(),
          playback: rig.playback,
          audio: rig.audio,
          server: rig.server.api(),
          namespace: 'test',
          onAccountAction: (_) async {},
          downloads: FakeDownloads([duality]),
        ),
      );
    } else {
      await rig.start(tester);
    }
    await tester.pumpAndSettle();
    await openTab(tester, 'library');
    return rig;
  }

  BoxDecoration decorationOf(WidgetTester tester, Finder finder) {
    final box = tester.widget<DecoratedBox>(
      find
          .descendant(
            of: finder,
            matching: find.byType(DecoratedBox),
            matchRoot: true,
          )
          .first,
    );
    return box.decoration as BoxDecoration;
  }

  Finder inRow(Finder row, Finder matching) =>
      find.descendant(of: row, matching: matching);

  List<Rect> coversIn(WidgetTester tester, Finder row) {
    final covers = inRow(row, find.byType(Cover));
    final rects = [
      for (var i = 0; i < covers.evaluate().length; i++)
        tester.getRect(covers.at(i)),
    ]..sort((a, b) => a.left.compareTo(b.left));
    return rects;
  }

  testWidgets('header «My music» displayed instead of counter bar', (
    tester,
  ) async {
    tester.view.padding = const FakeViewPadding(top: 36);
    addTearDown(tester.view.resetPadding);
    await openLibrary(tester);

    final text = tester.widget<Text>(title);
    expect(text.data, 'Моя музыка');
    expect(text.style?.fontSize, ApertonoText.screenTitle.fontSize);
    expect(text.style?.fontWeight, FontWeight.w700);
    // Phone status bar — 36 dp: header does not slide under clock.
    expect(tester.getRect(title).top, greaterThanOrEqualTo(44));
    expect(tester.getRect(title).left, 16);
    expect(
      find.descendant(
        of: find.byType(LibraryScreen),
        matching: find.byType(AppBar),
      ),
      findsNothing,
    );
    // Counter "N tracks · N lists" below header removed: numbers are in rows.
    expect(find.textContaining('списк'), findsNothing);
    expect(
      tester.getRect(favorites).top,
      greaterThan(tester.getRect(title).bottom),
    );
  });

  testWidgets('account in header; downloads moved to «Downloaded» tile', (
    tester,
  ) async {
    await openLibrary(tester);

    final account = find.byKey(const Key('account-button'));
    expect(account, findsOneWidget);
    expect(
      tester.getCenter(account).dy,
      closeTo(tester.getCenter(title).dy, 6),
    );
    expect(tester.getRect(account).right, lessThanOrEqualTo(360 - 4));
    expect(
      tester.getRect(account).left,
      greaterThanOrEqualTo(tester.getRect(title).right),
    );
    expect(find.byKey(const Key('downloads-button')), findsNothing);
    expect(downloads, findsOneWidget);
  });

  testWidgets('four 2×2 grid tiles look identical, without «artists»', (
    tester,
  ) async {
    await openLibrary(tester);

    final tiles = [playlists, history, downloads, device];
    for (final tile in tiles) {
      expect(tile, findsOneWidget);
      final box = decorationOf(tester, tile);
      expect(box.color, ApertonoColors.surface, reason: '$tile');
      expect(box.borderRadius, BorderRadius.circular(20), reason: '$tile');
      expect(
        (box.border as Border?)?.top.color,
        ApertonoColors.border,
        reason: '$tile',
      );
      final chevron = inRow(tile, find.byIcon(Icons.chevron_right));
      expect(chevron, findsOneWidget, reason: '$tile');
      expect(
        tester.widget<Icon>(chevron).color,
        ApertonoColors.textSecondary,
        reason: '$tile',
      );
      expect(
        tester.getRect(chevron).right,
        lessThanOrEqualTo(tester.getRect(tile).right - 8),
        reason: '$tile',
      );
    }
    final rects = [for (final tile in tiles) tester.getRect(tile)];
    // Left column from 16 margin, right — to 16 margin, identical width and height.
    expect(rects[0].left, 16);
    expect(rects[1].right, 360 - 16);
    expect(rects[1].left - rects[0].right, closeTo(12, 0.5));
    for (final rect in rects) {
      expect(rect.size, rects[0].size);
    }
    expect(find.text('Любимые исполнители'), findsNothing);
    expect(find.text('Слушать всё'), findsNothing);
    expect(find.text('Недавно в избранном'), findsNothing);
  });

  testWidgets(
    'icon 24, title and subtitle — tight group, nothing is clipped away',
    (tester) async {
      await openLibrary(tester);

      for (final (tile, icon, name, caption) in [
        (favorites, Icons.favorite_border, 'Любимые песни', '4 трека'),
        (playlists, Icons.playlist_play, 'Плейлисты', '2 плейлиста'),
        (history, Icons.schedule, 'История', 'Что слушали'),
        (downloads, Icons.download, 'Скачанное', 'Без интернета'),
        (device, Icons.phone_android, 'С телефона', 'Из памяти'),
      ]) {
        final glyph = inRow(tile, find.byIcon(icon));
        expect(glyph, findsOneWidget, reason: name);
        final widget = tester.widget<Icon>(glyph);
        expect(widget.size, 24, reason: name);
        expect(widget.color, ApertonoColors.textPrimary, reason: name);
        expect(
          tester.getRect(glyph).left,
          tester.getRect(tile).left + 16,
          reason: name,
        );

        final heading = inRow(tile, find.text(name));
        expect(heading, findsOneWidget, reason: name);
        final style = tester.widget<Text>(heading).style;
        expect(
          style?.fontWeight,
          tile == favorites ? FontWeight.w600 : FontWeight.w500,
          reason: name,
        );
        expect(style?.color, ApertonoColors.textPrimary, reason: name);
        // Icon above title, both from tile left edge.
        expect(tester.getRect(heading).left, tester.getRect(glyph).left);
        // Owner 12.10 remark: "icons in unclear positions, distances between
        // text". Compact group: icon, 8, title, 2, subtitle — positioned
        // centered vertically in tile, not stretched across it.
        expect(
          tester.getRect(heading).top - tester.getRect(glyph).bottom,
          8,
          reason: name,
        );
        final caption_ = tester.getRect(inRow(tile, find.text(caption)));
        expect(caption_.top - tester.getRect(heading).bottom, 2, reason: name);
        final box = tester.getRect(tile);
        final above = tester.getRect(glyph).top - box.top;
        final below = box.bottom - caption_.bottom;
        expect((above - below).abs(), lessThanOrEqualTo(1.5), reason: name);
        final under = inRow(tile, find.text(caption));
        expect(under, findsOneWidget, reason: name);
        final small = tester.widget<Text>(under).style;
        expect(small?.fontSize, ApertonoText.trackArtist.fontSize);
        expect(small?.color, ApertonoColors.textSecondary, reason: name);
        expect(
          tester.getRect(under).top,
          greaterThanOrEqualTo(tester.getRect(heading).bottom),
          reason: name,
        );
      }
    },
  );

  testWidgets('favorites: fan of 3 covers >56 to right of title', (
    tester,
  ) async {
    await openLibrary(tester);

    final covers = coversIn(tester, favorites);
    expect(covers, hasLength(3));
    final card = tester.getRect(favorites);
    for (final cover in covers) {
      expect(cover.width, greaterThan(56));
      expect(cover.top, greaterThanOrEqualTo(card.top));
      expect(cover.bottom, lessThanOrEqualTo(card.bottom));
      expect(cover.right, lessThanOrEqualTo(card.right));
    }
    // Fan: each subsequent peeks from under preceding.
    expect(covers[1].left, greaterThan(covers[0].left));
    expect(covers[2].left, greaterThan(covers[1].left));
    expect(covers[1].left, lessThan(covers[0].right));
    expect(
      covers.first.left,
      greaterThan(
        tester.getRect(inRow(favorites, find.text('Любимые песни'))).right,
      ),
    );
    // First favorite — on top of fan: drawn last.
    final paintedLast = tester.widget<Cover>(
      inRow(favorites, find.byType(Cover)).last,
    );
    expect(paintedLast.path, '/v1/covers/fav-1');
  });

  testWidgets('no favorites — tile remains, «0 tracks», no covers', (
    tester,
  ) async {
    await openLibrary(tester, liked: 0);

    expect(favorites, findsOneWidget);
    expect(inRow(favorites, find.text('0 треков')), findsOneWidget);
    expect(inRow(favorites, find.byType(Cover)), findsNothing);
  });

  testWidgets('grid tiles — without covers, including track history', (
    tester,
  ) async {
    await openLibrary(tester);
    for (final tile in [playlists, history, downloads, device]) {
      expect(inRow(tile, find.byType(Cover)), findsNothing);
    }
  });

  testWidgets('tiles open their screens', (tester) async {
    await openLibrary(tester);

    await tapAndSettle(tester, favorites);
    expect(find.byType(FavoritesScreen), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Любимые песни'), findsOneWidget);
    await tapBack(tester);
    await tester.pumpAndSettle();

    await tapAndSettle(tester, history);
    expect(find.byType(HistoryScreen), findsOneWidget);
    await tapBack(tester);
    await tester.pumpAndSettle();

    await tapAndSettle(tester, playlists);
    expect(find.byType(PlaylistsScreen), findsOneWidget);
    expect(find.text('Плейлист 2'), findsOneWidget);
    await tapBack(tester);
    await tester.pumpAndSettle();

    await tapAndSettle(tester, downloads);
    final list = find.byKey(const Key('downloads-list'));
    expect(list, findsOneWidget);
    expect(
      find.descendant(of: list, matching: find.text('Duality')),
      findsOneWidget,
    );
  });

  testWidgets('without login no account, «Downloaded» dimmed, inactive', (
    tester,
  ) async {
    await openLibrary(tester, account: false);
    expect(find.byKey(const Key('account-button')), findsNothing);
    expect(downloads, findsOneWidget);
    expect(inRow(downloads, find.byType(Opacity)), findsWidgets);
    await tester.tap(downloads, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(title.hitTestable(), findsOneWidget);
    expect(playlists, findsOneWidget);
    expect(inRow(playlists, find.byType(Opacity)), findsNothing);
  });

  testWidgets('large font: no overflow', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await openLibrary(tester);
    expect(tester.takeException(), isNull);
    expect(downloads, findsOneWidget);
  });

  group('снимок-эталон', () {
    setUpAll(() async {
      await loadAppFonts();
      compareOnMacOnly();
    });

    for (final MapEntry(key: name, value: size) in phones.entries) {
      testWidgets('My music at $name dp', (tester) async {
        // Snapshot with playing song: mini-player present almost always, and screen
        // must fit above it (FT-801).
        final rig = await openLibrary(tester, size: size);
        await typeSearch(tester, 'metallica');
        await tester.tap(find.text('Nothing Else Matters'));
        await tester.pump();
        rig.audio.emit(AudioPhase.playing);
        await tester.pumpAndSettle();
        await openTab(tester, 'library');
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('mini-player')), findsOneWidget);
        // Real font: nothing on tiles truncated with ellipsis.
        for (final tile in const [
          'favorites',
          'playlists',
          'history',
          'downloads',
          'device',
          'import',
        ]) {
          for (final element
              in find
                  .descendant(
                    of: find.byKey(Key('library-$tile')),
                    matching: find.byType(RichText),
                  )
                  .evaluate()) {
            final paragraph = element.renderObject! as RenderParagraph;
            expect(
              paragraph.didExceedMaxLines,
              isFalse,
              reason: '«${paragraph.text.toPlainText()}» clipped at $name dp',
            );
          }
        }
        await expectLater(
          find.byType(MaterialApp).first,
          matchesGoldenFile('goldens/library_$name.png'),
        );
      });
    }
  });
}
