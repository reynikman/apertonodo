import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/screens/search_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';

/// Recent queries — only on search screen, and only while field is empty.
void main() {
  setUp(
    () => SharedPreferences.setMockInitialValues({
      'recent-queries': ['metallica'],
    }),
  );

  testWidgets('recent queries visible on search, not on home', (tester) async {
    final rig = Rig();
    await rig.start(tester);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('recent-metallica')), findsNothing);
    expect(find.text('Недавние запросы'), findsNothing);

    await openTab(tester, 'search');

    expect(find.byType(SearchScreen), findsOneWidget);
    expect(find.byKey(const Key('recent-metallica')), findsOneWidget);
    expect(find.text('Недавние запросы'), findsOneWidget);

    await tester.enterText(
      find.descendant(
        of: find.byType(SearchScreen),
        matching: find.byKey(const Key('search-field')),
      ),
      'm',
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('recent-metallica')), findsNothing);
  });
}
