// FT-697: skip buttons -15 / +30 s for podcasts and books (P-A100, H6-8). Lead check written before work.
//
// Contract:
// - step: 15 s backward, 30 s forward (`skipStep`);
// - `skipTarget(position, kind, duration)`: >= 0; <= duration if known and positive;
//   unknown (`null`) or 0 — no upper bound;
// - `SkipButton`: single tap — single `onPressed` call; long press does not trigger or repeat;
//   `onPressed == null` — button disabled; touch target >= 48 x 48;
// - button displays seconds (15 / 30); TalkBack reads `SkipTexts` label (tooltip), seconds omitted from label.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/screens/skip_buttons.dart';

const texts = SkipTexts(back: 'Back 15 seconds', forward: 'Forward 30 seconds');

Duration s(int seconds) => Duration(seconds: seconds);

Future<void> pumpButton(
  WidgetTester t,
  SkipKind kind, {
  VoidCallback? onPressed,
}) => t.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: Center(
        child: SkipButton(kind: kind, onPressed: onPressed, texts: texts),
      ),
    ),
  ),
);

void main() {
  test('steps', () {
    expect(skipStep(SkipKind.back), s(15));
    expect(skipStep(SkipKind.forward), s(30));
  });

  group('skipTarget', () {
    for (final (pos, kind, dur, want) in <(int, SkipKind, int?, int)>[
      (60, SkipKind.back, 600, 45),
      (60, SkipKind.forward, 600, 90),
      (10, SkipKind.back, 600, 0),
      (15, SkipKind.back, 600, 0),
      (0, SkipKind.back, 600, 0),
      (580, SkipKind.forward, 600, 600),
      (570, SkipKind.forward, 600, 600),
      (569, SkipKind.forward, 600, 599),
      (600, SkipKind.forward, 600, 600),
      (600, SkipKind.back, 600, 585),
      (580, SkipKind.forward, null, 610),
      (10, SkipKind.back, null, 0),
      (580, SkipKind.forward, 0, 610),
    ]) {
      test('$pos ${kind.name} dur $dur -> $want', () {
        expect(skipTarget(s(pos), kind, dur == null ? null : s(dur)), s(want));
      });
    }

    test('milliseconds are not lost', () {
      expect(
        skipTarget(const Duration(milliseconds: 20500), SkipKind.back, s(600)),
        const Duration(milliseconds: 5500),
      );
    });

    test(
      'position past duration: backward from duration does not go forward',
      () {
        expect(skipTarget(s(700), SkipKind.forward, s(600)), s(600));
      },
    );

    test('long audiobook - no overflow', () {
      expect(
        skipTarget(s(40 * 3600), SkipKind.forward, s(50 * 3600)),
        s(40 * 3600 + 30),
      );
    });
  });

  group('button', () {
    for (final kind in SkipKind.values) {
      testWidgets('${kind.name}: single tap - single call', (t) async {
        var n = 0;
        await pumpButton(t, kind, onPressed: () => n++);
        await t.tap(find.byType(SkipButton));
        await t.pumpAndSettle();
        expect(n, 1);
      });
    }

    testWidgets('long press does not trigger or repeat', (t) async {
      var n = 0;
      await pumpButton(t, SkipKind.forward, onPressed: () => n++);
      final g = await t.startGesture(t.getCenter(find.byType(SkipButton)));
      await t.pump(const Duration(seconds: 2));
      await g.cancel();
      await t.pumpAndSettle();
      expect(n, 0);
    });

    testWidgets('seconds count visible on button', (t) async {
      await pumpButton(t, SkipKind.back, onPressed: () {});
      expect(find.text('15'), findsOneWidget);
      await pumpButton(t, SkipKind.forward, onPressed: () {});
      expect(find.text('30'), findsOneWidget);
      expect(find.text('15'), findsNothing);
    });

    testWidgets('touch target at least 48', (t) async {
      for (final kind in SkipKind.values) {
        await pumpButton(t, kind, onPressed: () {});
        final size = t.getSize(find.byType(SkipButton));
        expect(size.width, greaterThanOrEqualTo(48), reason: kind.name);
        expect(size.height, greaterThanOrEqualTo(48), reason: kind.name);
      }
    });

    testWidgets('disabled when no action', (t) async {
      final sem = t.ensureSemantics();
      await pumpButton(t, SkipKind.back);
      expect(
        t.getSemantics(find.byType(IconButton)),
        isSemantics(isButton: true, isEnabled: false, tooltip: texts.back),
      );
      sem.dispose();
    });

    for (final (kind, label) in [
      (SkipKind.back, texts.back),
      (SkipKind.forward, texts.forward),
    ]) {
      testWidgets('TalkBack: ${kind.name} - "$label" no number', (t) async {
        final sem = t.ensureSemantics();
        await pumpButton(t, kind, onPressed: () {});
        final node = t.getSemantics(find.byType(IconButton));
        expect(
          node,
          isSemantics(isButton: true, isEnabled: true, tooltip: label),
        );
        expect(node.getSemanticsData().label, isNot(contains(RegExp(r'\d'))));
        sem.dispose();
      });
    }
  });
}
