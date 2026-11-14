import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/screens/space_hint.dart';
import 'package:music_stream/screens/storage_step.dart';

// FT-700: capacity hint (FT-694, B-5) placed below storage slider.
// Lead check written before implementation.
const gib = 1024 * 1024 * 1024;
const hint = Key('storage-hint');

Future<void> showStep(WidgetTester tester, int? free) async {
  await tester.pumpWidget(StorageStep(freeBytes: free, onDone: (_) async {}));
  await tester.pumpAndSettle();
}

Future<void> slide(WidgetTester tester, double gigabytes) async {
  tester.widget<Slider>(find.byKey(const Key('storage-slider'))).onChanged!(
    gigabytes,
  );
  await tester.pump();
}

String hintText(WidgetTester tester) => tester
    .widget<Text>(
      find.descendant(of: find.byKey(hint), matching: find.byType(Text)),
    )
    .data!;

void main() {
  testWidgets('hint under slider: 10 GB - 340 and 2600', (tester) async {
    await showStep(tester, 200 * gib);
    expect(find.byKey(hint), findsOneWidget);
    expect(tester.widget(find.byKey(hint)), isA<SpaceHint>());
    expect(hintText(tester), contains('340'));
    expect(hintText(tester), contains('2600'));
    expect(hintText(tester), contains('FLAC'));
    expect(hintText(tester), contains('Opus'));
  });

  testWidgets('hint recalculates as slider moves', (tester) async {
    await showStep(tester, 200 * gib);
    await slide(tester, 5);
    expect(hintText(tester), contains('170'));
    expect(hintText(tester), contains('1300'));
    await slide(tester, 50);
    expect(hintText(tester), contains('1700'));
    expect(hintText(tester), contains('13000'));
  });

  testWidgets('zero GB - separate text without numbers', (tester) async {
    await showStep(tester, 200 * gib);
    await slide(tester, 0);
    expect(hintText(tester), isNotEmpty);
    expect(hintText(tester), isNot(contains(RegExp(r'\d'))));
  });

  testWidgets('hint placed below slider and above button', (tester) async {
    await showStep(tester, 200 * gib);
    final sliderBottom = tester
        .getBottomLeft(find.byKey(const Key('storage-slider')))
        .dy;
    final buttonTop = tester
        .getTopLeft(find.byKey(const Key('storage-done')))
        .dy;
    final top = tester.getTopLeft(find.byKey(hint)).dy;
    expect(top, greaterThanOrEqualTo(sliderBottom));
    expect(
      tester.getBottomLeft(find.byKey(hint)).dy,
      lessThanOrEqualTo(buttonTop),
    );
  });

  testWidgets('no space - no slider and no hint', (tester) async {
    await showStep(tester, gib ~/ 2);
    expect(find.byKey(const Key('storage-no-room')), findsOneWidget);
    expect(find.byKey(hint), findsNothing);
  });

  testWidgets('hint does not overflow narrow screen', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await showStep(tester, 200 * gib);
    await slide(tester, 50);
    expect(tester.takeException(), isNull);
  });
}
