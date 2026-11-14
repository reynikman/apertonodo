import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/app.dart';

import 'fakes.dart';

/// Player does not open as a stack of pages.
///
/// Owner bug September 18: mini player visible on player screen, and each
/// tap pushed another player page on top — "back" had to be tapped
/// once for each page.
void main() {
  Future<void> pick(WidgetTester tester, String query, String title) async {
    await tester.enterText(find.byKey(const Key('search-field')), query);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.tap(find.text(title).first);
    await tester.pump();
  }

  testWidgets('repeated mini-player taps still require single «back»', (
    tester,
  ) async {
    await tester.pumpWidget(const MusicApp(catalog: [sandman, duality]));
    await pick(tester, 'sandman', 'Enter Sandman');

    await tester.tap(find.byKey(const Key('mini-player')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('player-screen'), skipOffstage: false),
      findsOneWidget,
    );
    expect(find.byKey(const Key('mini-player')).hitTestable(), findsNothing);

    // No AppBar arrow on player — circular "collapse" button (FT-489).
    await tester.tap(find.byKey(const Key('player-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('search-field')), findsOneWidget);
    expect(find.byKey(const Key('player-screen')), findsNothing);
  });
}
