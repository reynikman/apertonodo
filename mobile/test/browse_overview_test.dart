import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/theme.dart';

import 'fake_server.dart';
import 'golden_support.dart';

/// Browse (P4, step 4): ten genre tiles with photos per Figma export (§6.2) and
/// "All genres" for the rest. No alphabetical artist list (P-A41).

/// Tile order — as in Figma export, not as returned by server.
const photoGenres = [
  'rock',
  'metal',
  'pop',
  'hip-hop',
  'electronic',
  'jazz',
  'alternative',
  'classical',
  'rnb',
  'reggae',
];

/// Production server genres after FT-476 — in its order (`sort`).
const serverGenres = [
  ('pop', 'Поп', 41250),
  ('rock', 'Рок', 63120),
  ('alternative', 'Альтернатива', 22410),
  ('metal', 'Метал', 30877),
  ('punk', 'Панк', 9120),
  ('hip-hop', 'Хип-хоп', 18904),
  ('rnb', 'R&B и соул', 8211),
  ('electronic', 'Электроника', 35002),
  ('dance', 'Танцевальная', 7400),
  ('jazz', 'Джаз', 12033),
  ('blues', 'Блюз', 4021),
  ('country', 'Кантри', 3304),
  ('folk', 'Фолк', 9877),
  ('classical', 'Классика', 6650),
  ('latin', 'Латинская', 5541),
  ('reggae', 'Регги', 2230),
  ('k-pop', 'K-pop', 1104),
  ('j-pop', 'J-pop', 2309),
  ('soundtrack', 'Саундтреки', 3120),
  ('easy-listening', 'Изи-лиснинг', 1201),
  ('kids', 'Детское', 640),
  ('singer-songwriter', 'Авторская песня', 2101),
  ('worldwide', 'Мировая', 25004),
];

Map<String, dynamic> genresAnswer([
  List<(String, String, int)> genres = serverGenres,
]) => {
  'genres': [
    for (final (id, name, artists) in genres)
      {'id': id, 'name': name, 'artists': artists},
  ],
};

String nameOf(String slug) =>
    serverGenres.firstWhere((genre) => genre.$1 == slug).$2;

void main() {
  final allGenres = find.byKey(const Key('browse-all-genres'));
  Finder tile(String slug) => find.byKey(ValueKey('genre-card-$slug'));

  Future<Rig> openBrowse(
    WidgetTester tester, [
    List<(String, String, int)> genres = serverGenres,
    Size phone = const Size(360, 800),
  ]) async {
    usePhone(tester, phone);
    final rig = Rig();
    rig.server.on('GET /v1/genres', (_) => answer(200, genresAnswer(genres)));
    await rig.start(tester);
    await openTab(tester, 'browse');
    return rig;
  }

  testWidgets('heading Browse, without Artists entry', (tester) async {
    final rig = await openBrowse(tester);

    final title = tester.widget<Text>(find.byKey(const Key('browse-title')));
    expect(title.data, 'Обзор');
    expect(title.style?.fontSize, ApertonoText.screenTitle.fontSize);
    expect(title.style?.fontWeight, FontWeight.w700);
    expect(find.byKey(const Key('browse-artists')), findsNothing);
    expect(find.text('Исполнители'), findsNothing);
    expect(find.text('Каталог жанров'), findsNothing);
    expect(rig.server.calls('GET /v1/letters'), isEmpty);
    expect(
      rig.server
          .calls('GET /v1/artists')
          .where((request) => request.url.queryParameters['genre'] == null),
      isEmpty,
      reason: 'artists without genre are alphabetical list, no longer exists',
    );
  });

  testWidgets('ten photo tiles in export order, others are not shown', (
    tester,
  ) async {
    await openBrowse(tester);

    for (final slug in photoGenres) {
      await tester.ensureVisible(tile(slug));
    }
    final shown = [
      for (final element in find.byWidgetPredicate((widget) {
        final key = widget.key;
        return key is ValueKey<String> && key.value.startsWith('genre-card-');
      }).evaluate())
        element,
    ];
    final order = [
      for (final element
          in shown..sort((a, b) {
            final ra = (a.renderObject! as RenderBox).localToGlobal(
              Offset.zero,
            );
            final rb = (b.renderObject! as RenderBox).localToGlobal(
              Offset.zero,
            );
            return ra.dy != rb.dy
                ? ra.dy.compareTo(rb.dy)
                : ra.dx.compareTo(rb.dx);
          }))
        (element.widget.key! as ValueKey<String>).value.substring(
          'genre-card-'.length,
        ),
    ];
    expect(order, photoGenres);
    for (final (slug, _, _) in serverGenres) {
      if (!photoGenres.contains(slug)) {
        expect(tile(slug), findsNothing, reason: slug);
      }
    }
  });

  testWidgets('tile: two columns, radius 14, photo and name', (tester) async {
    await openBrowse(tester);

    final rock = tester.getRect(tile('rock'));
    final metal = tester.getRect(tile('metal'));
    final pop = tester.getRect(tile('pop'));
    // Tile height matches screen (FT-794): browse_fit_test enforces it.
    expect(rock.height, greaterThanOrEqualTo(48));
    expect(rock.left, moreOrLessEquals(16, epsilon: 0.5));
    expect(metal.right, moreOrLessEquals(360 - 16, epsilon: 0.5));
    expect(metal.left - rock.right, moreOrLessEquals(12, epsilon: 0.5));
    expect(metal.top, rock.top);
    expect(pop.top - rock.bottom, moreOrLessEquals(12, epsilon: 0.5));

    for (final slug in photoGenres) {
      await tester.ensureVisible(tile(slug));
      final clip = tester.widget<ClipRRect>(
        find
            .descendant(
              of: tile(slug),
              matching: find.byType(ClipRRect),
              matchRoot: true,
            )
            .first,
      );
      expect(
        clip.borderRadius,
        BorderRadius.circular(ApertonoRadii.genre),
        reason: slug,
      );
      var image = tester
          .widget<Image>(
            find.descendant(of: tile(slug), matching: find.byType(Image)),
          )
          .image;
      if (image is ResizeImage) image = image.imageProvider;
      expect(image, isA<AssetImage>(), reason: slug);
      expect(
        (image as AssetImage).assetName,
        'assets/genres/$slug.jpg',
        reason: slug,
      );
      // Title is rendered by app (in Russian, read by TalkBack), not photo.
      expect(
        find.descendant(of: tile(slug), matching: find.text(nameOf(slug))),
        findsOneWidget,
        reason: slug,
      );
    }
  });

  test('photos in app: ten JPEGs, lightweight, with authors', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final sources = File('assets/genres/SOURCES.md').readAsStringSync();
    for (final slug in photoGenres) {
      final file = File('assets/genres/$slug.jpg');
      expect(file.existsSync(), isTrue, reason: slug);
      final bytes = file.readAsBytesSync();
      expect(bytes.sublist(0, 2), [0xFF, 0xD8], reason: '$slug: not JPEG');
      expect(bytes.length, lessThan(150 * 1024), reason: '$slug: too heavy');
      // Declared in pubspec.yaml — otherwise won't enter build.
      final asset = await rootBundle.load('assets/genres/$slug.jpg');
      expect(asset.lengthInBytes, bytes.length, reason: slug);
      expect(sources, contains('`$slug`'), reason: '$slug: not in SOURCES.md');
    }
  });

  testWidgets('tile opens artists of its genre', (tester) async {
    final rig = await openBrowse(tester);

    await tester.ensureVisible(tile('metal'));
    await tapAndSettle(tester, tile('metal'));
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('Метал')),
      findsOneWidget,
    );
    expect(rig.server.calls('GET /v1/artists').first.url.queryParameters, {
      'genre': 'metal',
      'offset': '0',
      'limit': '100',
    });
  });

  testWidgets('All Genres: full list with number of artists included', (
    tester,
  ) async {
    // Tall screen: all 23 rows visible at once, without scrolling.
    final rig = await openBrowse(tester, serverGenres, const Size(360, 2000));

    await tester.ensureVisible(allGenres);
    expect(
      find.descendant(of: allGenres, matching: find.text('Все жанры')),
      findsOneWidget,
    );
    await tapAndSettle(tester, allGenres);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text('Все жанры'),
      ),
      findsOneWidget,
    );
    for (final (slug, name, _) in serverGenres) {
      final row = find.byKey(ValueKey('genre-row-$slug'));
      expect(
        find.descendant(of: row, matching: find.text(name)),
        findsOneWidget,
        reason: slug,
      );
      expect(
        find.descendant(of: row, matching: find.textContaining('исполнител')),
        findsOneWidget,
        reason: slug,
      );
    }
    final punk = find.byKey(const ValueKey('genre-row-punk'));
    await tapAndSettle(tester, punk);
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('Панк')),
      findsOneWidget,
    );
    expect(
      rig.server.calls('GET /v1/artists').first.url.queryParameters['genre'],
      'punk',
    );
    expect(
      rig.server.calls('GET /v1/genres'),
      hasLength(1),
      reason: 'All Genres uses existing list, no second request made',
    );
  });

  testWidgets('no photo genres: no tiles shown, All Genres is present', (
    tester,
  ) async {
    // Legacy or test server: none of the genres from export. Long name
    // on 360 dp must not overflow row — Flutter itself makes
    // overflow a test error.
    await openBrowse(tester, [
      ('easy', 'Easy Listening и инструментальная эстрада', 1234),
    ]);

    expect(
      find.byWidgetPredicate((widget) {
        final key = widget.key;
        return key is ValueKey<String> && key.value.startsWith('genre-card-');
      }),
      findsNothing,
    );
    await tapAndSettle(tester, allGenres);
    expect(find.textContaining('Easy Listening'), findsOneWidget);
  });

  group('снимок-эталон', () {
    setUpAll(() async {
      await loadAppFonts();
      compareOnMacOnly();
    });

    for (final MapEntry(key: name, value: size) in phones.entries) {
      testWidgets('browse at $name dp', (tester) async {
        usePhone(tester, size);
        // Full app, not screen alone: theme, fonts, and tab bar
        // match real phone.
        final rig = Rig();
        rig.server.on('GET /v1/genres', (_) => answer(200, genresAnswer()));
        await rig.start(tester);
        // Golden snapshot with active playback: mini-player is almost always present,
        // and screen must fit above it (owner's requirement 12.10).
        await typeSearch(tester, 'metallica');
        await tester.tap(find.text('Nothing Else Matters'));
        await tester.pump();
        rig.audio.emit(AudioPhase.playing);
        await tester.pumpAndSettle();
        await openTab(tester, 'browse');
        await tester.pumpAndSettle();
        final mini = find.byKey(const Key('mini-player'));
        expect(mini, findsOneWidget);
        expect(
          tester.getRect(find.byKey(const Key('browse-all-genres'))).bottom,
          lessThanOrEqualTo(tester.getRect(mini).top + 0.5),
          reason: 'All Genres slips under mini-player',
        );
        for (final element in find.byType(Scrollable).evaluate()) {
          final state = (element as StatefulElement).state as ScrollableState;
          if (state.position.axis != Axis.vertical) continue;
          expect(
            state.position.maxScrollExtent,
            0,
            reason: 'screen is scrollable vertically',
          );
        }
        // App assets are decoded outside test clock.
        await tester.runAsync(() async {
          for (final element in find.byType(Image).evaluate()) {
            await precacheImage((element.widget as Image).image, element);
          }
        });
        await tester.pumpAndSettle();
        await expectLater(
          find.byType(MaterialApp).first,
          matchesGoldenFile('goldens/browse_$name.png'),
        );
      });
    }
  });
}
