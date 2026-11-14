import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/screens/catalog_screens.dart';
import 'package:music_stream/screens/search_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';

/// B-3: second tap on active Search tab resets state:
/// field cleared, focus and keyboard active, list scrolled to top. Clear icon
/// visible when empty with focus — tapping it dismisses keyboard.
void main() {
  setUp(
    () => SharedPreferences.setMockInitialValues({
      'recent-queries': ['metallica'],
    }),
  );

  Finder field() => find.descendant(
    of: find.byType(SearchScreen),
    matching: find.byKey(const Key('search-field')),
  );

  String fieldText(WidgetTester tester) =>
      tester.widget<TextField>(field()).controller!.text;

  bool fieldFocused(WidgetTester tester) =>
      tester.widget<TextField>(field()).focusNode!.hasFocus;

  ScrollPosition resultsScroll(WidgetTester tester) {
    final list = find.descendant(
      of: find.byType(SearchScreen),
      matching: find.byWidgetPredicate(
        (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
      ),
    );
    return tester.state<ScrollableState>(list.last).position;
  }

  testWidgets('second tap on Search clears input, results and focuses', (
    tester,
  ) async {
    final rig = Rig();
    await rig.start(tester);
    await typeSearch(tester, 'metallica');
    expect(find.text('Nothing Else Matters'), findsOneWidget);

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(fieldFocused(tester), isFalse);

    await openTab(tester, 'search');

    expect(fieldText(tester), isEmpty);
    expect(find.text('Nothing Else Matters'), findsNothing);
    expect(find.byKey(const Key('recent-metallica')), findsOneWidget);
    expect(fieldFocused(tester), isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
  });

  testWidgets('second tap on Search scrolls list to top', (tester) async {
    // Low viewport: idle search (4 recent tracks) overflows —
    // otherwise list would scroll to top automatically due to shortness.
    await tester.binding.setSurfaceSize(const Size(400, 420));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final rig = Rig();
    final search = sample('search');
    rig.server.on(
      'GET /v1/search',
      (_) => answer(200, {
        ...search,
        'tracks': [
          for (var i = 0; i < 30; i++) songLike('search', 'song-$i', 'Song $i'),
        ],
      }),
    );
    rig.server.on(
      'GET /v1/history',
      (_) => answer(200, {
        'tracks': [
          for (var i = 0; i < 4; i++)
            songLike('library-history', 'heard-$i', 'Heard $i'),
        ],
        'total': 4,
      }),
    );
    await rig.start(tester);
    await typeSearch(tester, 'metallica');

    final position = resultsScroll(tester);
    expect(position.maxScrollExtent, greaterThan(0));
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(resultsScroll(tester).pixels, greaterThan(0));

    await openTab(tester, 'search');

    expect(find.text('Heard 0'), findsOneWidget);
    expect(resultsScroll(tester).maxScrollExtent, greaterThan(0));
    expect(resultsScroll(tester).pixels, 0);
  });

  testWidgets('opening Search tab does not change query', (tester) async {
    final rig = Rig();
    await rig.start(tester);
    await typeSearch(tester, 'metallica');

    await openTab(tester, 'home');
    await openTab(tester, 'search');

    expect(fieldText(tester), 'metallica');
    expect(find.text('Nothing Else Matters'), findsOneWidget);
  });

  testWidgets('clear icon: absent on empty query even with focus', (
    tester,
  ) async {
    final rig = Rig();
    await rig.start(tester);
    await openTab(tester, 'search');
    await tester.showKeyboard(field());
    await tester.pumpAndSettle();

    expect(fieldText(tester), isEmpty);
    expect(find.byKey(const Key('search-clear')), findsNothing);
  });

  testWidgets(
    'clear icon: text query - 48 dp, labeled, clears, keyboard stays',
    (tester) async {
      final rig = Rig();
      await rig.start(tester);
      await openTab(tester, 'search');
      await tester.enterText(field(), 'metal');
      await tester.pumpAndSettle();

      final clear = find.byKey(const Key('search-clear'));
      expect(tester.getSize(clear).width, greaterThanOrEqualTo(48));
      expect(tester.getSize(clear).height, greaterThanOrEqualTo(48));
      expect(tester.widget<IconButton>(clear).tooltip, 'Очистить');

      await tester.tap(clear);
      await tester.pumpAndSettle();

      expect(fieldText(tester), isEmpty);
      expect(fieldFocused(tester), isTrue);
    },
  );

  testWidgets('page over search: first tap goes to results, second resets', (
    tester,
  ) async {
    final rig = Rig();
    rig.server.on(
      'GET /v1/artist',
      (_) => answer(200, sample('catalog-artist')),
    );
    await rig.start(tester);
    await typeSearch(tester, 'metallica');
    await tapAndSettle(tester, find.byKey(const Key('artist-Metallica')));
    expect(find.byType(ArtistScreen), findsOneWidget);

    await openTab(tester, 'search');

    expect(find.byType(ArtistScreen), findsNothing);
    expect(fieldText(tester), 'metallica');
    expect(find.text('Nothing Else Matters'), findsOneWidget);

    await openTab(tester, 'search');

    expect(fieldText(tester), isEmpty);
  });
}
