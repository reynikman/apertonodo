import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/screens/catalog_screens.dart';

import 'fake_server.dart';

/// P-A73 item 6 (FT-557): genre alphabet strip ~40 wide on right; drag
/// finger — large letter popup alongside, light haptic feedback on letter change, release —
/// list positioned at that letter. Letter tap works as before
/// (`genre_letters_test.dart`).
final names = [
  for (var i = 1; i <= 120; i++) 'Alpha $i',
  for (var i = 1; i <= 60; i++) 'Kilo $i',
  for (var i = 1; i <= 70; i++) 'Кино $i',
];

const letters = [
  {'letter': 'A', 'artists': 120, 'offset': 0},
  {'letter': 'K', 'artists': 60, 'offset': 120},
  {'letter': 'К', 'artists': 70, 'offset': 180},
];

Future<Rig> openRock(WidgetTester tester) async {
  final rig = Rig();
  rig.server.on('GET /v1/artists', (request) {
    final offset = int.parse(request.url.queryParameters['offset']!);
    final limit = int.parse(request.url.queryParameters['limit']!);
    return answer(200, {
      'artists': [
        for (final name in names.skip(offset).take(limit)) {'name': name},
      ],
      'total': names.length,
    });
  });
  rig.server.on('GET /v1/letters', (_) => answer(200, {'letters': letters}));
  await rig.screen(
    tester,
    (services) => ArtistsScreen(
      services: services,
      title: 'Рок',
      load: (offset) =>
          services.server.artistCatalog(genre: 'rock', offset: offset),
      letters: () => services.server.genreLetters('rock'),
    ),
  );
  await tester.pumpAndSettle();
  return rig;
}

/// Haptic feedback calls requested from Android by app.
List<String> watchHaptics(WidgetTester tester) {
  final haptics = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        haptics.add('${call.arguments}');
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return haptics;
}

void main() {
  testWidgets('letter bar about 40 wide at right edge', (tester) async {
    await openRock(tester);
    final strip = tester.getRect(find.byKey(const Key('letter-strip')));
    final screen = tester.getRect(find.byType(Scaffold));
    expect(strip.width, inInclusiveRange(36, 48));
    expect(strip.right, closeTo(screen.right, 1));
    // Each letter on strip is easy to hit by touch width.
    for (final letter in ['A', 'K', 'К']) {
      expect(
        tester.getRect(find.byKey(Key('letter-$letter'))).width,
        greaterThanOrEqualTo(36),
        reason: letter,
      );
    }
  });

  testWidgets('dragged finger: large letter, vibration on change, '
      'released: list jumps to letter', (tester) async {
    final rig = await openRock(tester);
    final haptics = watchHaptics(tester);
    expect(find.byKey(const Key('letter-bubble')), findsNothing);

    final a = tester.getCenter(find.byKey(const Key('letter-A')));
    final k = tester.getCenter(find.byKey(const Key('letter-K')));
    final ka = tester.getCenter(find.byKey(const Key('letter-К')));

    final gesture = await tester.startGesture(a);
    await tester.pump(const Duration(milliseconds: 50));
    // Small drag within same letter — same letter, no haptic feedback.
    await gesture.moveBy(const Offset(0, 1));
    await tester.pump(const Duration(milliseconds: 50));
    final atStart = haptics.length;

    await gesture.moveTo(k);
    await tester.pump(const Duration(milliseconds: 50));
    final bubble = find.byKey(const Key('letter-bubble'));
    expect(bubble, findsOneWidget);
    expect(
      find.descendant(of: bubble, matching: find.text('K')),
      findsOneWidget,
    );
    // Large letter popup at least 40, beside strip, not over it.
    final big = tester.widget<Text>(
      find.descendant(of: bubble, matching: find.text('K')),
    );
    final size =
        big.style?.fontSize ??
        DefaultTextStyle.of(
          tester.element(find.descendant(of: bubble, matching: find.text('K'))),
        ).style.fontSize;
    expect(size, greaterThanOrEqualTo(40));
    expect(
      tester.getRect(bubble).right,
      lessThanOrEqualTo(
        tester.getRect(find.byKey(const Key('letter-strip'))).left,
      ),
    );
    expect(haptics.length, atStart + 1, reason: 'A -> K: single vibration');
    expect(haptics.last, contains('selectionClick'));

    await gesture.moveTo(ka);
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      find.descendant(of: bubble, matching: find.text('К')),
      findsOneWidget,
    );
    expect(haptics.length, atStart + 2, reason: 'K -> K: another vibration');

    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('letter-bubble')), findsNothing);
    final offsets = [
      for (final request in rig.server.calls('GET /v1/artists'))
        request.url.queryParameters['offset'],
    ];
    expect(offsets.last, '180');
    expect(find.text('Кино 1'), findsOneWidget);
    expect(find.text('Alpha 1'), findsNothing);
  });
}
