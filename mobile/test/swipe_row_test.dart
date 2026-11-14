// FT-695: swipe on track row — "Play next" (B-4). Lead check written before work.
//
// Contract:
// - swipe right exceeding `swipeThreshold` (0.3) of row width — `onPlayNext` exactly once; shorter — none;
// - swipe left — no-op, row does not move;
// - gesture starting within `swipeEdgeGuard` (24) of left edge — ignored (system back gesture zone);
// - label displayed below row during swipe; row snaps back on release and label disappears;
// - `onPlayNext == null` — row immovable, action disabled;
// - tap on row propagates to track selection;
// - TalkBack: custom row action with label invoking `onPlayNext`.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/screens/swipe_row.dart';

const label = 'Play next';
const rowKey = Key('row');

Future<void> pumpRow(
  WidgetTester t, {
  VoidCallback? onPlayNext,
  VoidCallback? onTap,
}) async {
  t.view.physicalSize = const Size(360, 780);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            const SizedBox(height: 100),
            SwipeRow(
              onPlayNext: onPlayNext,
              label: label,
              child: Material(
                child: InkWell(
                  key: rowKey,
                  onTap: onTap,
                  child: const SizedBox(
                    height: 64,
                    width: double.infinity,
                    child: Text('Song'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Row semantics node — outermost `Semantics` widget inside `SwipeRow`.
final rowNode = find
    .descendant(of: find.byType(SwipeRow), matching: find.byType(Semantics))
    .first;

double rowLeft(WidgetTester t) => t.getTopLeft(find.byKey(rowKey)).dx;

const y = 132.0;

void main() {
  test('constants', () {
    expect(swipeThreshold, 0.3);
    expect(swipeEdgeGuard, 24.0);
  });

  testWidgets('long swipe right triggers once', (t) async {
    var n = 0;
    await pumpRow(t, onPlayNext: () => n++);
    await t.dragFrom(const Offset(60, y), const Offset(180, 0));
    await t.pumpAndSettle();
    expect(n, 1);
  });

  testWidgets('just past threshold triggers', (t) async {
    var n = 0;
    await pumpRow(t, onPlayNext: () => n++);
    await t.dragFrom(const Offset(60, y), const Offset(120, 0));
    await t.pumpAndSettle();
    expect(n, 1);
  });

  testWidgets('just below threshold does not trigger', (t) async {
    var n = 0;
    await pumpRow(t, onPlayNext: () => n++);
    await t.dragFrom(const Offset(60, y), const Offset(96, 0));
    await t.pumpAndSettle();
    expect(n, 0);
  });

  testWidgets('short swipe does not trigger', (t) async {
    var n = 0;
    await pumpRow(t, onPlayNext: () => n++);
    await t.dragFrom(const Offset(60, y), const Offset(40, 0));
    await t.pumpAndSettle();
    expect(n, 0);
  });

  testWidgets('back and forth below threshold does not trigger', (t) async {
    var n = 0;
    await pumpRow(t, onPlayNext: () => n++);
    final g = await t.startGesture(const Offset(60, y));
    await g.moveBy(const Offset(200, 0));
    await t.pump();
    await g.moveBy(const Offset(-180, 0));
    await t.pump();
    await g.up();
    await t.pumpAndSettle();
    expect(n, 0);
  });

  testWidgets('swipe left does nothing, row stays', (t) async {
    var n = 0;
    await pumpRow(t, onPlayNext: () => n++);
    final g = await t.startGesture(const Offset(300, y));
    await g.moveBy(const Offset(-200, 0));
    await t.pump();
    expect(rowLeft(t), 0);
    await g.up();
    await t.pumpAndSettle();
    expect(n, 0);
  });

  testWidgets('start at left edge does nothing', (t) async {
    var n = 0;
    await pumpRow(t, onPlayNext: () => n++);
    final g = await t.startGesture(const Offset(10, y));
    await g.moveBy(const Offset(250, 0));
    await t.pump();
    expect(rowLeft(t), 0);
    expect(find.text(label), findsNothing);
    await g.up();
    await t.pumpAndSettle();
    expect(n, 0);
  });

  testWidgets('start at left edge with small steps does nothing', (t) async {
    var n = 0;
    await pumpRow(t, onPlayNext: () => n++);
    final g = await t.startGesture(const Offset(10, y));
    for (var i = 0; i < 50; i++) {
      await g.moveBy(const Offset(5, 0));
      await t.pump(const Duration(milliseconds: 8));
    }
    expect(rowLeft(t), 0);
    await g.up();
    await t.pumpAndSettle();
    expect(n, 0);
  });

  testWidgets('second swipe while row returning also triggers', (t) async {
    var n = 0;
    await pumpRow(t, onPlayNext: () => n++);
    await t.dragFrom(const Offset(60, y), const Offset(200, 0));
    await t.pump(const Duration(milliseconds: 40));
    final g = await t.startGesture(const Offset(60, y));
    for (var i = 0; i < 20; i++) {
      await g.moveBy(const Offset(10, 0));
      await t.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await t.pumpAndSettle();
    expect(n, 2);
  });

  testWidgets('start just past edge triggers', (t) async {
    var n = 0;
    await pumpRow(t, onPlayNext: () => n++);
    await t.dragFrom(const Offset(30, y), const Offset(200, 0));
    await t.pumpAndSettle();
    expect(n, 1);
  });

  testWidgets('during swipe row moves and label is shown', (t) async {
    await pumpRow(t, onPlayNext: () {});
    final g = await t.startGesture(const Offset(60, y));
    await g.moveBy(const Offset(80, 0));
    await t.pump();
    expect(rowLeft(t), closeTo(80, 1));
    expect(find.text(label), findsOneWidget);
    await g.up();
    await t.pumpAndSettle();
    expect(rowLeft(t), 0);
    expect(find.text(label), findsNothing);
  });

  testWidgets('row returns after trigger', (t) async {
    await pumpRow(t, onPlayNext: () {});
    await t.dragFrom(const Offset(60, y), const Offset(200, 0));
    await t.pumpAndSettle();
    expect(rowLeft(t), 0);
    expect(find.text(label), findsNothing);
  });

  testWidgets('row does not slide past max width', (t) async {
    await pumpRow(t, onPlayNext: () {});
    final g = await t.startGesture(const Offset(60, y));
    await g.moveBy(const Offset(1000, 0));
    await t.pump();
    expect(rowLeft(t), lessThanOrEqualTo(360));
    await g.up();
    await t.pumpAndSettle();
  });

  testWidgets('without action row does not move', (t) async {
    await pumpRow(t);
    final g = await t.startGesture(const Offset(60, y));
    await g.moveBy(const Offset(200, 0));
    await t.pump();
    expect(rowLeft(t), 0);
    expect(find.text(label), findsNothing);
    await g.up();
    await t.pumpAndSettle();
  });

  testWidgets('tap reaches the row', (t) async {
    var taps = 0, next = 0;
    await pumpRow(t, onPlayNext: () => next++, onTap: () => taps++);
    await t.tap(find.text('Song'));
    await t.pumpAndSettle();
    expect(taps, 1);
    expect(next, 0);
  });

  testWidgets('two swipes trigger twice', (t) async {
    var n = 0;
    await pumpRow(t, onPlayNext: () => n++);
    await t.dragFrom(const Offset(60, y), const Offset(200, 0));
    await t.pumpAndSettle();
    await t.dragFrom(const Offset(60, y), const Offset(200, 0));
    await t.pumpAndSettle();
    expect(n, 2);
  });

  testWidgets('TalkBack: Play Next action', (t) async {
    final sem = t.ensureSemantics();
    var n = 0;
    await pumpRow(t, onPlayNext: () => n++);
    final node = t.getSemantics(rowNode);
    expect(
      node,
      isSemantics(customActions: const [CustomSemanticsAction(label: label)]),
    );
    node.owner!.performAction(
      node.id,
      SemanticsAction.customAction,
      CustomSemanticsAction.getIdentifier(
        const CustomSemanticsAction(label: label),
      ),
    );
    await t.pump();
    expect(n, 1);
    sem.dispose();
  });

  testWidgets('TalkBack: without action no custom action present', (t) async {
    final sem = t.ensureSemantics();
    await pumpRow(t);
    final data = t.getSemantics(rowNode).getSemanticsData();
    expect(data.customSemanticsActionIds ?? const <int>[], isEmpty);
    sem.dispose();
  });
}
