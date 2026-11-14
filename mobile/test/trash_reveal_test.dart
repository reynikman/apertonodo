import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/screens/trash_reveal.dart';
import 'package:music_stream/theme.dart';

/// FT-790 (owner finding 12.10): in History screen edge swipe-to-back gesture
/// deleted track immediately. Now swipe merely
/// reveals trash icon, tap deletes it, while screen edge is reserved for system navigation.
void main() {
  late int removed;

  Future<void> pump(
    WidgetTester tester, {
    EdgeInsets gestures = EdgeInsets.zero,
  }) async {
    removed = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: apertonoTheme(),
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(systemGestureInsets: gestures),
            child: Scaffold(
              body: TrashReveal(
                label: 'Убрать из истории',
                onRemove: () => removed++,
                child: const SizedBox(
                  height: 64,
                  width: double.infinity,
                  child: Center(child: Text('Song Row')),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  final trash = find.byKey(const Key('trash-reveal-button'));

  testWidgets('full swipe does not delete: only reveals trash', (tester) async {
    await pump(tester);
    expect(trash, findsNothing);

    await tester.drag(find.text('Song Row'), const Offset(-700, 0));
    await tester.pumpAndSettle();

    expect(removed, 0);
    expect(trash, findsOneWidget);
    expect(tester.getSize(trash).width, greaterThanOrEqualTo(48));
    expect(tester.getSize(trash).height, greaterThanOrEqualTo(48));
    expect(find.byTooltip('Убрать из истории'), findsOneWidget);
  });

  testWidgets('tapping trash deletes once', (tester) async {
    await pump(tester);
    await tester.drag(find.text('Song Row'), const Offset(-200, 0));
    await tester.pumpAndSettle();

    await tester.tap(trash);
    await tester.pumpAndSettle();

    expect(removed, 1);
  });

  testWidgets('short swipe does not reveal trash', (tester) async {
    await pump(tester);

    await tester.drag(find.text('Song Row'), const Offset(-20, 0));
    await tester.pumpAndSettle();

    expect(trash, findsNothing);
    expect(removed, 0);
  });

  testWidgets('swiping back hides trash', (tester) async {
    await pump(tester);
    await tester.drag(find.text('Song Row'), const Offset(-200, 0));
    await tester.pumpAndSettle();
    expect(trash, findsOneWidget);

    await tester.drag(find.text('Song Row'), const Offset(200, 0));
    await tester.pumpAndSettle();

    expect(trash, findsNothing);
    expect(removed, 0);
  });

  testWidgets('edge swipe system back does not touch row', (tester) async {
    await pump(tester);
    final row = tester.getRect(find.byType(TrashReveal));

    await tester.dragFrom(
      Offset(row.right - 10, row.center.dy),
      const Offset(-300, 0),
    );
    await tester.pumpAndSettle();
    expect(trash, findsNothing);

    await tester.dragFrom(
      Offset(row.left + 10, row.center.dy),
      const Offset(-300, 0),
    );
    await tester.pumpAndSettle();
    expect(trash, findsNothing);
    expect(removed, 0);
  });

  testWidgets('wider system gesture area also yielded to system', (
    tester,
  ) async {
    await pump(tester, gestures: const EdgeInsets.only(right: 60));
    final row = tester.getRect(find.byType(TrashReveal));

    await tester.dragFrom(
      Offset(row.right - 50, row.center.dy),
      const Offset(-300, 0),
    );
    await tester.pumpAndSettle();
    expect(trash, findsNothing);

    await tester.dragFrom(
      Offset(row.right - 80, row.center.dy),
      const Offset(-300, 0),
    );
    await tester.pumpAndSettle();
    expect(trash, findsOneWidget);
  });

  test('History removes row via trash button, not swipe', () {
    final source = File('lib/screens/library_screens.dart').readAsStringSync();
    expect(source, isNot(contains('Dismissible(')));
    expect(source, contains('TrashReveal('));
    expect(source, contains('HistoryUndoBar('));
  });
}
