import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/catalog.dart';
import 'package:music_stream/screens/parts.dart';
import 'package:music_stream/screens/search_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';

/// Idle search screen: recent queries, without genres or catalog.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('recent queries on empty search, no genres', (tester) async {
    SharedPreferences.setMockInitialValues({
      'recent-queries': ['metallica'],
    });
    final rig = Rig();
    await rig.start(tester);
    await tester.pumpAndSettle();
    await openTab(tester, 'search');

    expect(find.byKey(const Key('recent-metallica')), findsOneWidget);
    expect(find.text('Недавние запросы'), findsOneWidget);
    expect(
      tester.widget(find.byKey(const Key('recent-metallica'))),
      isA<ActionChip>(),
    );
    expect(find.widgetWithText(Heading, 'Жанры'), findsNothing);
    expect(find.widgetWithText(Heading, 'Исполнители'), findsNothing);
    expect(find.text('Недавно слушали'), findsOneWidget);
    expect(find.text('Duality'), findsOneWidget);
  });

  testWidgets('server error on home - search field stays', (tester) async {
    SharedPreferences.setMockInitialValues({
      'recent-queries': ['metallica'],
    });
    final rig = Rig();
    rig.server.fail('GET /v1/history', 503, 'library_unavailable');
    rig.server.fail('GET /v1/artists', 503, 'catalog_unavailable');
    await rig.start(tester);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('tab-search')), findsOneWidget);
    expect(find.byKey(const Key('recent-metallica')), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byKey(const Key('search-error')), findsNothing);

    await openTab(tester, 'search');
    expect(find.byKey(const Key('recent-metallica')), findsOneWidget);
  });

  testWidgets('no network calls without server, no extra UI', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SearchScreen(
          onSearch: (_) async => const SearchResult(),
          onSelect: (_, _) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('search-field')), findsOneWidget);
    expect(find.widgetWithText(Heading, 'Жанры'), findsNothing);
    expect(find.widgetWithText(Heading, 'Исполнители'), findsNothing);
    expect(find.textContaining('популярн'), findsNothing);
  });

  testWidgets('initial list is hidden after search', (tester) async {
    final rig = Rig();
    await rig.start(tester);
    await tester.pumpAndSettle();
    await typeSearch(tester, 'metallica');

    expect(find.widgetWithText(Heading, 'Жанры'), findsNothing);
    expect(find.text('Недавние запросы'), findsNothing);
    expect(find.text('Nothing Else Matters'), findsOneWidget);
  });

  testWidgets('clear icon clears field and restores recent queries', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'recent-queries': ['metallica'],
    });
    final rig = Rig();
    await rig.start(tester);
    await tester.pumpAndSettle();
    await typeSearch(tester, 'metallica');

    expect(find.text('Nothing Else Matters'), findsOneWidget);

    await tester.tap(find.byKey(const Key('search-clear')));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<TextField>(
            find.descendant(
              of: find.byType(SearchScreen),
              matching: find.byKey(const Key('search-field')),
            ),
          )
          .controller!
          .text,
      isEmpty,
    );
    expect(find.byKey(const Key('search-clear')), findsNothing);
    expect(find.text('Ничего не найдено'), findsNothing);
    expect(find.text('Nothing Else Matters'), findsNothing);
    expect(find.byKey(const Key('recent-metallica')), findsOneWidget);
  });
}
