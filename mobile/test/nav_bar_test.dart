import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/screens/nav_bar.dart';
import 'package:music_stream/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';
import 'golden_support.dart';
import 'back.dart';

/// Tab bar per dump (P4, step 2b; FT-471, FT-472): floating island
/// 66 dp with 14 dp padding and 8 dp from bottom, five equal columns (FT-579) — Home, Browse,
/// News, Search, My Music; under active tab — dark capsule 68x44 with gold
/// icon. No labels, so TalkBack must announce tab name.
/// Bar is visible on nested screens too (dump, §7): tab of origin is highlighted.
/// origin tab remains highlighted.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({'news-enabled': true}));

  const names = ['home', 'browse', 'news', 'search', 'library'];
  const labels = ['Главная', 'Обзор', 'Новости', 'Поиск', 'Моя музыка'];

  final bar = find.byKey(const Key('nav-bar'));
  final capsule = find.byKey(const Key('tab-capsule'));
  Finder tab(String name) => find.byKey(Key('tab-$name'));

  /// Icon color as rendered: custom or from ambient theme.
  Color? iconColor(WidgetTester tester, String name) {
    final icon = find.descendant(of: tab(name), matching: find.byType(Icon));
    expect(icon, findsOneWidget, reason: 'tab icon $name is single Icon');
    return tester.widget<Icon>(icon).color ??
        IconTheme.of(tester.element(icon)).color;
  }

  Future<Rig> start(WidgetTester tester) async {
    usePhone(tester, phones['360']!);
    final rig = Rig();
    await rig.start(tester);
    await tester.pumpAndSettle();
    return rig;
  }

  testWidgets('island: margin 14, height 66, bottom 8', (tester) async {
    await start(tester);

    final rect = tester.getRect(bar);
    expect(rect.left, 14);
    expect(rect.right, 360 - 14);
    expect(rect.height, 66);
    expect(rect.bottom, 800 - 8);
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets('above system gesture bar — same 8', (tester) async {
    usePhone(tester, phones['360']!);
    tester.view.padding = const FakeViewPadding(bottom: 24);
    tester.view.viewPadding = const FakeViewPadding(bottom: 24);
    final rig = Rig();
    await rig.start(tester);
    await tester.pumpAndSettle();

    expect(tester.getRect(bar).bottom, 800 - 24 - 8);
    expect(tester.getRect(bar).height, 66);
  });

  testWidgets('five equal columns (FT-579), full column is tappable', (
    tester,
  ) async {
    await start(tester);

    final island = tester.getRect(bar);
    final rects = [for (final name in names) tester.getRect(tab(name))];
    for (final (i, rect) in rects.indexed) {
      expect(rect.width, closeTo(rects.first.width, 0.01), reason: names[i]);
      expect(rect.width, greaterThanOrEqualTo(48), reason: names[i]);
      expect(rect.height, greaterThanOrEqualTo(48), reason: names[i]);
      expect(rect.center.dy, closeTo(island.center.dy, 0.01), reason: names[i]);
      if (i > 0) {
        expect(
          rect.left,
          closeTo(rects[i - 1].right, 0.01),
          reason: 'gap between columns ${names[i - 1]} and ${names[i]}',
        );
      }
    }
    expect(rects.first.left, greaterThanOrEqualTo(island.left + 8));
    expect(rects.last.right, lessThanOrEqualTo(island.right - 8));
    // Columns are centered within the island, not pinned to edge.
    expect(
      rects.first.left - island.left,
      closeTo(island.right - rects.last.right, 0.01),
    );
  });

  testWidgets('active tab — capsule 68×44 shape and gold icon displayed', (
    tester,
  ) async {
    await start(tester);

    expect(capsule, findsOneWidget);
    expect(tester.getSize(capsule), const Size(68, 44));
    expect(tester.getCenter(capsule), tester.getCenter(tab('home')));
    expect(iconColor(tester, 'home'), ApertonoColors.accent);
    for (final name in names.skip(1)) {
      expect(iconColor(tester, name), ApertonoColors.textSecondary);
    }
  });

  testWidgets('no labels, tabs announced by TalkBack', (tester) async {
    final semantics = tester.ensureSemantics();
    await start(tester);

    expect(
      find.descendant(of: bar, matching: find.byType(Text)),
      findsNothing,
      reason: 'tab bar has no labels per spec',
    );
    for (final (i, label) in labels.indexed) {
      final node = find.descendant(
        of: bar,
        matching: find.bySemanticsLabel(label),
      );
      expect(node, findsOneWidget, reason: 'TalkBack misses «$label»');
      expect(
        tester.getSemantics(node),
        isSemantics(
          label: label,
          isButton: true,
          isSelected: i == 0,
          hasTapAction: true,
        ),
        reason: label,
      );
    }
    semantics.dispose();
  });

  testWidgets('tap opens tab, capsule moves, columns stay fixed', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await start(tester);
    final before = [for (final name in names) tester.getRect(tab(name))];

    await tester.tap(tab('browse'));
    await tester.pumpAndSettle();

    expect(find.text('Рок'), findsOneWidget);
    expect(capsule, findsOneWidget);
    expect(tester.getCenter(capsule), tester.getCenter(tab('browse')));
    expect(iconColor(tester, 'browse'), ApertonoColors.accent);
    expect(iconColor(tester, 'home'), ApertonoColors.textSecondary);
    expect([for (final name in names) tester.getRect(tab(name))], before);
    expect(
      tester.getSemantics(
        find.descendant(of: bar, matching: find.bySemanticsLabel('Обзор')),
      ),
      isSemantics(isSelected: true),
    );
    expect(
      tester.getSemantics(
        find.descendant(of: bar, matching: find.bySemanticsLabel('Главная')),
      ),
      isSemantics(isSelected: false),
    );

    // Tap near column edge outside icon also selects the tab.
    final search = tester.getRect(tab('search'));
    await tester.tapAt(search.centerRight - const Offset(3, 0));
    await tester.pumpAndSettle();
    expect(tester.getCenter(capsule), search.center);
    expect(find.byKey(const Key('search-field')).hitTestable(), findsOneWidget);
    semantics.dispose();
  });

  /// Track playing; user stayed on search tab.
  Future<Rig> playing(WidgetTester tester) async {
    final rig = await start(tester);
    await typeSearch(tester, 'metallica');
    await tester.tap(find.text('Nothing Else Matters'));
    await tester.pump();
    rig.audio.emit(AudioPhase.playing);
    await tester.pumpAndSettle();
    return rig;
  }

  testWidgets('mini-player sits above bar with 8 gap on each tab', (
    tester,
  ) async {
    await playing(tester);

    // "My Music" at 360 dp in Ahem test font overflows tiles —
    // that is step 7 (tiles with large font); here gap matters.
    for (final name in ['home', 'browse', 'search']) {
      await openTab(tester, name);
      final mini = tester.getRect(find.byKey(const Key('mini-player')));
      expect(tester.getRect(bar).top - mini.bottom, 8, reason: name);
    }
  });

  testWidgets('search is tab: no back arrow, no search bar on home', (
    tester,
  ) async {
    await start(tester);
    expect(find.byKey(const Key('home-search')), findsNothing);

    await openTab(tester, 'search');
    expect(find.byKey(const Key('search-field')).hitTestable(), findsOneWidget);
    expect(find.byType(BackButton), findsNothing);
    expect(tester.getCenter(capsule), tester.getCenter(tab('search')));
  });

  testWidgets('empty search tab focuses input field immediately', (
    tester,
  ) async {
    await start(tester);
    await openTab(tester, 'search');

    // Previously main bar opened search with keyboard: single tap to
    // input. Tab must not become an extra tap away.
    final field = find.byKey(const Key('search-field')).hitTestable();
    expect(tester.widget<TextField>(field).focusNode?.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);

    // And on every subsequent open, not only the first.
    await openTab(tester, 'home');
    expect(tester.testTextInput.isVisible, isFalse);
    await openTab(tester, 'search');
    expect(tester.widget<TextField>(field).focusNode?.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
  });

  testWidgets('returning to search with results does not open keyboard', (
    tester,
  ) async {
    await start(tester);
    await typeSearch(tester, 'metallica');
    await openTab(tester, 'home');
    expect(
      tester.testTextInput.isVisible,
      isFalse,
      reason: 'left search — keyboard closed',
    );

    await openTab(tester, 'search');
    expect(find.text('Nothing Else Matters'), findsOneWidget);
    final field = find.byKey(const Key('search-field')).hitTestable();
    expect(tester.widget<TextField>(field).focusNode?.hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets('keyboard open — bar and mini-player hidden', (tester) async {
    await playing(tester);
    tester.view.viewInsets = const FakeViewPadding(bottom: 900);
    await tester.pumpAndSettle();

    expect(bar, findsNothing);
    expect(find.byKey(const Key('mini-player')), findsNothing);

    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    expect(bar, findsOneWidget);
    expect(find.byKey(const Key('mini-player')), findsOneWidget);
  });

  testWidgets('on nested screen bar visible, parent tab highlighted', (
    tester,
  ) async {
    await start(tester);
    await openTab(tester, 'browse');
    await tapAndSettle(tester, find.text('Рок'));

    expect(find.byType(BackButton), findsOneWidget);
    expect(bar, findsOneWidget);
    expect(tester.getRect(bar).bottom, 800 - 8);
    expect(tester.getCenter(capsule), tester.getCenter(tab('browse')));

    // "All genres" is also a nested screen of "Browse".
    await tapBack(tester);
    await tester.pumpAndSettle();
    await tapAndSettle(tester, find.byKey(const Key('browse-all-genres')));
    expect(find.byKey(const ValueKey('genre-row-rock')), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);
    expect(tester.getCenter(capsule), tester.getCenter(tab('browse')));
  });

  testWidgets('back from nested — returns to origin', (tester) async {
    await start(tester);
    await openTab(tester, 'browse');
    await tapAndSettle(tester, find.text('Рок'));
    await tapAndSettle(tester, find.text('Кино'));

    await tapBack(tester);
    await tester.pumpAndSettle();
    expect(find.text('Кино'), findsOneWidget, reason: 'returned to genre');
    await tapBack(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('browse-title')), findsOneWidget);
    expect(tester.getCenter(capsule), tester.getCenter(tab('browse')));
  });

  testWidgets('tab tap from nested screen returns back to tab root', (
    tester,
  ) async {
    await start(tester);
    await openTab(tester, 'browse');
    await tapAndSettle(tester, find.text('Рок'));

    await openTab(tester, 'home');
    expect(find.byType(BackButton), findsNothing);
    expect(tester.getCenter(capsule), tester.getCenter(tab('home')));

    // Selecting same tab from nested screen navigates to its root.
    await openTab(tester, 'browse');
    await tapAndSettle(tester, find.text('Рок'));
    await openTab(tester, 'browse');
    expect(find.byType(BackButton), findsNothing);
    expect(find.byKey(const Key('browse-title')), findsOneWidget);
  });

  testWidgets('on nested screen mini-player stays above gesture bar', (
    tester,
  ) async {
    usePhone(tester, phones['360']!);
    tester.view.padding = const FakeViewPadding(bottom: 24);
    tester.view.viewPadding = const FakeViewPadding(bottom: 24);
    final rig = Rig();
    await rig.start(tester);
    await tester.pumpAndSettle();
    await typeSearch(tester, 'metallica');
    await tester.tap(find.text('Nothing Else Matters'));
    await tester.pump();
    rig.audio.emit(AudioPhase.playing);
    await openTab(tester, 'browse');
    await tapAndSettle(tester, find.text('Рок'));

    expect(tester.getRect(bar).bottom, 800 - 24 - 8);
    final mini = tester.getRect(find.byKey(const Key('mini-player')));
    expect(tester.getRect(bar).top - mini.bottom, 8);
  });

  testWidgets('on full player bar is hidden', (tester) async {
    await playing(tester);
    await tapAndSettle(tester, find.byKey(const Key('mini-player')));

    expect(find.byKey(const Key('player-screen')), findsOneWidget);
    expect(bar.hitTestable(), findsNothing);
  });

  group('снимок-эталон', () {
    setUpAll(() async {
      await loadAppFonts();
      compareOnMacOnly();
    });

    for (final MapEntry(key: name, value: size) in phones.entries) {
      testWidgets('tab bar at $name dp', (tester) async {
        usePhone(tester, size);
        // Bar alone without screen above: screenshot does not change when home screen
        // changes. Margin above so shadow fits in frame.
        await tester.pumpWidget(
          MaterialApp(
            theme: apertonoTheme(),
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: RepaintBoundary(
                  key: const Key('frame'),
                  child: ColoredBox(
                    color: ApertonoColors.background,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 24),
                      child: ApertonoNavBar(current: 1, onOpen: (_) {}),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await expectLater(
          find.byKey(const Key('frame')),
          matchesGoldenFile('goldens/nav_bar_$name.png'),
        );
      });
    }
  });
}
