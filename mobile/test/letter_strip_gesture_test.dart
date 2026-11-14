import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/screens/catalog_screens.dart';

import 'genre_letters_test.dart' show openRock, rigWith, artistOffsets;

/// N6-3 (FT-738): alphabet strip sat flush against right edge, and on gesture-nav
/// phones finger dragging letter caught system "back". Strip and list
/// inset from edge by system gesture inset; without gestures — former layout.
void main() {
  Future<void> withInsets(
    WidgetTester tester, {
    double right = 0,
    double left = 0,
  }) async {
    final ratio = tester.view.devicePixelRatio;
    tester.view.systemGestureInsets = FakeViewPadding(
      right: right * ratio,
      left: left * ratio,
    );
    addTearDown(tester.view.resetSystemGestureInsets);
  }

  Rect strip(WidgetTester tester) =>
      tester.getRect(find.byKey(const Key('letter-strip')));

  double screenWidth(WidgetTester tester) =>
      tester.view.physicalSize.width / tester.view.devicePixelRatio;

  testWidgets('24 dp gesture on right: strip avoids gesture area', (
    tester,
  ) async {
    await withInsets(tester, right: 24);
    await openRock(tester, rigWith());
    expect(strip(tester).right, lessThanOrEqualTo(screenWidth(tester) - 24));
  });

  testWidgets('without gestures strip stays at the edge', (tester) async {
    await openRock(tester, rigWith());
    expect(strip(tester).right, screenWidth(tester));
    expect(strip(tester).width, 40);
  });

  testWidgets('left-only gesture does not move strip', (tester) async {
    await withInsets(tester, left: 24);
    await openRock(tester, rigWith());
    expect(strip(tester).right, screenWidth(tester));
  });

  testWidgets('list does not go under shifted strip', (tester) async {
    await withInsets(tester, right: 24);
    await openRock(tester, rigWith());
    final row = tester.getRect(find.byType(ArtistRow).first);
    expect(row.right, lessThanOrEqualTo(strip(tester).left));
  });

  testWidgets('letter bubble does not overlap shifted strip', (tester) async {
    await withInsets(tester, right: 24);
    await openRock(tester, rigWith());
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('letter-K'))),
    );
    await tester.pump();
    final bubble = tester.getRect(find.byKey(const Key('letter-bubble')));
    expect(bubble.right, lessThanOrEqualTo(strip(tester).left));
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('letter on shifted strip still opens section properly', (
    tester,
  ) async {
    await withInsets(tester, right: 24);
    final rig = rigWith();
    await openRock(tester, rig);
    await tester.tap(find.byKey(const Key('letter-К')));
    await tester.pumpAndSettle();
    expect(artistOffsets(rig).last, '180');
    expect(find.text('Кино 1'), findsOneWidget);
  });
}
