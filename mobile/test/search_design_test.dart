import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/screens/artist_avatar.dart';
import 'package:music_stream/screens/parts.dart';
import 'package:music_stream/screens/search_screen.dart';
import 'package:music_stream/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';
import 'golden_support.dart';

/// Search per dump (P4, step 5; handoff §5.3, §6.3, frame `crop_phone3_search`):
/// screen title instead of AppBar, 50 dp field with radius 16, recent queries
/// as 32 dp chips, artist as tile with photo 54 and "Artist" label, tracks
/// under "Tracks" header in single tile 24. No albums in beta (P-A29). Heart icon
/// retained instead of dump arrow: required to favorite from search.
void main() {
  setUp(
    () => SharedPreferences.setMockInitialValues({
      'recent-queries': ['metallica', 'slipknot'],
    }),
  );

  final field = find.byKey(const Key('search-field'));
  final title = find.byKey(const Key('search-title'));
  final tracksTile = find.byKey(const Key('search-tracks'));
  final heardTile = find.byKey(const Key('heard-tracks'));

  /// Two artists and three tracks — production response to "metallica".
  Map<String, dynamic> results() {
    final answerBody = sample('search');
    final first = (answerBody['tracks'] as List).first as Map<String, dynamic>;
    answerBody['artists'] = [
      {'name': 'Metallica', 'photo': null},
      {'name': 'Metallica & San Francisco Symphony', 'photo': null},
    ];
    answerBody['tracks'] = [
      for (final (i, song) in [
        'Nothing Else Matters',
        'One',
        'Fade to Black',
      ].indexed)
        {
          ...first,
          'id': '1111111${i + 1}-1111-1111-1111-111111111111',
          'title': song,
        },
    ];
    return answerBody;
  }

  Future<Rig> openSearch(WidgetTester tester, {Size? size}) async {
    usePhone(tester, size ?? phones['360']!);
    final rig = Rig();
    rig.server.on('GET /v1/search', (_) => answer(200, results()));
    await rig.start(tester);
    await tester.pumpAndSettle();
    await openTab(tester, 'search');
    return rig;
  }

  Future<void> search(WidgetTester tester) async {
    await tester.enterText(field, 'metallica');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
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

  testWidgets('Search heading instead of AppBar, below status bar', (
    tester,
  ) async {
    tester.view.padding = const FakeViewPadding(top: 36);
    addTearDown(tester.view.resetPadding);
    await openSearch(tester);

    final text = tester.widget<Text>(title);
    expect(text.data, 'Поиск');
    expect(text.style?.fontSize, ApertonoText.screenTitle.fontSize);
    expect(text.style?.fontWeight, FontWeight.w700);
    expect(
      find.descendant(
        of: find.byType(SearchScreen),
        matching: find.byType(AppBar),
      ),
      findsNothing,
    );
    // Status bar is 36 dp: header does not collide with clock.
    expect(tester.getRect(title).top, greaterThanOrEqualTo(44));
    expect(tester.getRect(title).left, 16);
    expect(
      tester.getRect(field).top,
      greaterThan(tester.getRect(title).bottom),
    );
  });

  testWidgets('field: height 50, radius 16, layout bg and border, lens', (
    tester,
  ) async {
    await openSearch(tester);

    final rect = tester.getRect(field);
    expect(rect.height, moreOrLessEquals(50, epsilon: 0.5));
    expect(rect.left, 16);
    expect(rect.right, 360 - 16);
    final decoration = tester.widget<TextField>(field).decoration!;
    expect(decoration.filled, isTrue);
    expect(decoration.fillColor, ApertonoColors.surface);
    expect(decoration.hintText, 'Исполнитель или песня');
    final enabled = decoration.enabledBorder! as OutlineInputBorder;
    expect(enabled.borderRadius, BorderRadius.circular(ApertonoRadii.medium));
    expect(enabled.borderSide.color, ApertonoColors.border);
    final focused = decoration.focusedBorder! as OutlineInputBorder;
    expect(focused.borderRadius, BorderRadius.circular(ApertonoRadii.medium));
    expect(focused.borderSide.color, ApertonoColors.accent);
    expect(
      find.descendant(of: field, matching: find.byIcon(Icons.search)),
      findsOneWidget,
    );
    // Field icons gray per dump; amber only on focused border.
    expect(decoration.prefixIconColor, ApertonoColors.textSecondary);
    expect(decoration.suffixIconColor, ApertonoColors.textSecondary);
    expect(find.byKey(const Key('search-clear')), findsNothing);
    await tester.enterText(field, 'm');
    await tester.pump();
    expect(find.byKey(const Key('search-clear')), findsOneWidget);
  });

  testWidgets('recent queries — chips 32 with radius 16 in one row', (
    tester,
  ) async {
    await openSearch(tester);

    final metallica = find.byKey(const Key('recent-metallica'));
    final slipknot = find.byKey(const Key('recent-slipknot'));
    expect(tester.widget(metallica), isA<ActionChip>());
    final chip = tester.widget<ActionChip>(metallica);
    final shape = chip.shape! as RoundedRectangleBorder;
    expect(shape.borderRadius, BorderRadius.circular(16));
    expect(chip.backgroundColor, ApertonoColors.surface);
    expect(
      tester.getSize(metallica).height,
      moreOrLessEquals(32, epsilon: 0.5),
    );
    // Single row horizontally scrollable per dump, not multi-line wrap.
    expect(tester.getRect(slipknot).top, tester.getRect(metallica).top);
    expect(
      tester.getRect(slipknot).left,
      greaterThan(tester.getRect(metallica).right),
    );
    expect(
      tester.getRect(metallica).top,
      greaterThan(tester.getRect(field).bottom),
    );
    // "Clear" is right of header on same line, not a list row.
    final clear = find.byKey(const Key('recent-clear'));
    final heading = find.text('Недавние запросы');
    expect(
      tester.getRect(find.text('Очистить')).center.dy,
      moreOrLessEquals(tester.getRect(heading).center.dy, epsilon: 2),
    );
    // Bound by text: button touch target may extend into padding.
    expect(
      tester.getRect(find.text('Очистить')).right,
      lessThanOrEqualTo(360 - 16 + 0.01),
    );
    expect(
      tester.getRect(clear).left,
      greaterThan(tester.getRect(heading).right),
    );
    expect(
      tester.getRect(clear).bottom,
      lessThan(tester.getRect(metallica).top),
    );
  });

  testWidgets('recently listened - songs in single tile 24', (tester) async {
    await openSearch(tester);

    expect(find.text('Недавно слушали'), findsOneWidget);
    final box = decorationOf(tester, heardTile);
    expect(box.borderRadius, BorderRadius.circular(ApertonoRadii.xLarge));
    expect((box.border as Border?)?.top.color, ApertonoColors.border);
    expect(
      find.descendant(of: heardTile, matching: find.byType(TrackTile)),
      findsWidgets,
    );
    final tile = tester.getRect(heardTile);
    expect(tile.left, 16);
    expect(tile.right, 360 - 16);
  });

  testWidgets('artist - tile: photo 54, name, "Artist", arrow', (tester) async {
    await openSearch(tester);
    await search(tester);

    final metallica = find.byKey(const Key('artist-Metallica'));
    final symphony = find.byKey(
      const Key('artist-Metallica & San Francisco Symphony'),
    );
    expect(metallica, findsOneWidget);
    expect(symphony, findsOneWidget);
    final rect = tester.getRect(metallica);
    expect(rect.left, 16);
    expect(rect.right, 360 - 16);
    expect(rect.top, greaterThan(tester.getRect(field).bottom));
    // Tiles stacked vertically, not horizontal carousel.
    expect(tester.getRect(symphony).top, greaterThan(rect.bottom));
    final box = decorationOf(tester, metallica);
    expect(box.borderRadius, BorderRadius.circular(20));
    expect((box.border as Border?)?.top.color, ApertonoColors.border);
    expect(
      tester.getSize(
        find.descendant(of: metallica, matching: find.byType(ArtistAvatar)),
      ),
      const Size(54, 54),
    );
    final name = tester.widget<Text>(
      find.descendant(of: metallica, matching: find.text('Metallica')),
    );
    expect(name.style?.fontSize, 16.5);
    expect(name.style?.fontWeight, FontWeight.w700);
    final caption = tester.widget<Text>(
      find.descendant(of: metallica, matching: find.text('Исполнитель')),
    );
    expect(caption.style?.color, ApertonoColors.textSecondary);
    expect(
      find.descendant(
        of: metallica,
        matching: find.byIcon(Icons.chevron_right),
      ),
      findsOneWidget,
    );
  });

  testWidgets('songs - under "Tracks" in single tile 24, no albums', (
    tester,
  ) async {
    await openSearch(tester);
    await search(tester);

    expect(find.widgetWithText(Heading, 'Треки'), findsOneWidget);
    expect(find.text('Результаты поиска'), findsNothing);
    expect(find.text('Альбомы'), findsNothing);
    final box = decorationOf(tester, tracksTile);
    expect(box.borderRadius, BorderRadius.circular(ApertonoRadii.xLarge));
    expect(
      find.descendant(of: tracksTile, matching: find.byType(TrackTile)),
      findsNWidgets(3),
    );
    // Subtle dividers between tracks per dump; omitted after last item.
    expect(
      find.descendant(of: tracksTile, matching: find.byType(Divider)),
      findsNWidgets(2),
    );
    final tile = tester.getRect(tracksTile);
    expect(tile.left, 16);
    expect(tile.right, 360 - 16);
    expect(
      tile.top,
      greaterThan(
        tester
            .getRect(
              find.byKey(
                const Key('artist-Metallica & San Francisco Symphony'),
              ),
            )
            .bottom,
      ),
    );
    // Heart icon present: tracks can still be favorited from search.
    expect(
      find.descendant(
        of: tracksTile,
        matching: find.byKey(
          const ValueKey('heart-11111111-1111-1111-1111-111111111111'),
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('tapping artist tile opens artist page', (tester) async {
    final rig = await openSearch(tester);
    await search(tester);

    await tapAndSettle(tester, find.byKey(const Key('artist-Metallica')));
    expect(
      rig.server.calls('GET /v1/artist').first.url.queryParameters['name'],
      'Metallica',
    );
  });

  testWidgets('search over screen - back arrow next to title', (tester) async {
    // Without AppBar, back arrow must be drawn explicitly. Search opens on top
    // from unnumbered top track — user must be able to navigate back.
    final rig = Rig();
    await rig.screen(
      tester,
      (services) => Builder(
        builder: (context) => TextButton(
          key: const Key('open'),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => SearchScreen(
                onSearch: services.search,
                onSelect: services.play,
              ),
            ),
          ),
          child: const Text('open'),
        ),
      ),
    );
    await tapAndSettle(tester, find.byKey(const Key('open')));
    final back = find.byKey(const Key('search-back'));
    expect(back, findsOneWidget);
    expect(
      tester.getRect(back).center.dy,
      moreOrLessEquals(tester.getRect(title).center.dy, epsilon: 2),
    );
    await tapAndSettle(tester, back);
    expect(find.byType(SearchScreen), findsNothing);
  });

  testWidgets('large font: nothing overflows', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await openSearch(tester);
    expect(tester.takeException(), isNull, reason: 'idle search');
    await search(tester);
    expect(tester.takeException(), isNull, reason: 'results');
    expect(find.byKey(const Key('artist-Metallica')), findsOneWidget);
  });

  testWidgets('Search tab does not draw back arrow', (tester) async {
    await openSearch(tester);
    expect(find.byKey(const Key('search-back')), findsNothing);
    expect(find.byType(BackButton), findsNothing);
  });

  group('снимок-эталон', () {
    setUpAll(() async {
      await loadAppFonts();
      compareOnMacOnly();
    });

    for (final MapEntry(key: name, value: size) in phones.entries) {
      testWidgets('idle search on $name dp', (tester) async {
        await openSearch(tester, size: size);
        await expectLater(
          find.byType(MaterialApp).first,
          matchesGoldenFile('goldens/search_idle_$name.png'),
        );
      });

      testWidgets('results on $name dp', (tester) async {
        await openSearch(tester, size: size);
        await search(tester);
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        await expectLater(
          find.byType(MaterialApp).first,
          matchesGoldenFile('goldens/search_results_$name.png'),
        );
      });
    }
  });
}
