import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/screens/player_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';
import 'golden_support.dart';

/// P-A73 item 3 (FT-555): full player slides up from bottom and follows finger
/// down. Owner finding 04.10: swiped down — player slid to the right instead.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final screen = find.byKey(const Key('player-screen'));
  final cover = find.byKey(const Key('player-cover'));

  Future<void> openPlayer(WidgetTester tester) async {
    usePhone(tester, phones['360']!);
    final rig = Rig();
    await rig.start(tester);
    await tester.pumpAndSettle();
    await typeSearch(tester, 'metallica');
    await tester.tap(find.text('Nothing Else Matters'));
    await tester.pump();
    rig.audio.emit(AudioPhase.playing);
    await tester.pump();
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('mini-player')),
        matching: find.text('Nothing Else Matters'),
      ),
    );
  }

  /// Drag slowly: 20 pt steps every 100 ms — not a fling.
  Future<TestGesture> pull(WidgetTester tester, double by) async {
    final gesture = await tester.startGesture(tester.getCenter(cover));
    var at = Duration.zero;
    for (var done = 0.0; done < by; done += 20) {
      at += const Duration(milliseconds: 100);
      await gesture.moveBy(const Offset(0, 20), timeStamp: at);
      await tester.pump();
    }
    await gesture.moveBy(
      Offset.zero,
      timeStamp: at + const Duration(seconds: 1),
    );
    await tester.pump();
    return gesture;
  }

  testWidgets('opens from bottom, not from side', (tester) async {
    await openPlayer(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final opening = tester.getRect(screen);
    expect(opening.left, 0, reason: 'player slides from side');
    expect(opening.top, greaterThan(0), reason: 'player not from bottom');
    await tester.pumpAndSettle();
    expect(tester.getRect(screen).top, 0);
  });

  testWidgets('drag down gesture — player follows finger and closes', (
    tester,
  ) async {
    await openPlayer(tester);
    await tester.pumpAndSettle();

    final gesture = await pull(tester, 300);
    final dragged = tester.getRect(screen);
    expect(dragged.left, 0, reason: 'player moves sideways, not down');
    expect(
      dragged.top,
      inInclusiveRange(240, 310),
      reason: 'player does not follow finger',
    );
    expect(
      find.byKey(const Key('search-field')),
      findsOneWidget,
      reason: 'black screen under player, not app',
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(screen, findsNothing);
    expect(find.byKey(const Key('mini-player')), findsOneWidget);
  });

  testWidgets('drag slightly and release — player returns', (tester) async {
    await openPlayer(tester);
    await tester.pumpAndSettle();

    final gesture = await pull(tester, 60);
    expect(tester.getRect(screen).top, greaterThan(0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(screen, findsOneWidget);
    expect(tester.getRect(screen).top, 0);
  });

  testWidgets('quick fling down closes player even from short drag', (
    tester,
  ) async {
    await openPlayer(tester);
    await tester.pumpAndSettle();

    await tester.flingFrom(tester.getCenter(cover), const Offset(0, 120), 1500);
    await tester.pumpAndSettle();
    expect(screen, findsNothing);
  });

  // Owner finding 13.10 no. 6 (FT-851): the mini player and the tab bar
  // popped in whole on the first pixel of the drag.
  testWidgets('bottom bar comes in with the finger, not at once', (
    tester,
  ) async {
    await openPlayer(tester);
    await tester.pumpAndSettle();
    final reveal = find.byKey(const Key('player-bar-reveal'));
    double revealed() => tester.widget<PlayerBarReveal>(reveal).revealed;
    expect(revealed(), 0, reason: 'at rest the player covers the bar');

    final gesture = await tester.startGesture(tester.getCenter(cover));
    await gesture.moveBy(
      const Offset(0, 20),
      timeStamp: const Duration(milliseconds: 100),
    );
    await tester.pump();
    await gesture.moveBy(
      const Offset(0, 10),
      timeStamp: const Duration(milliseconds: 200),
    );
    await tester.pump();
    final early = revealed();
    expect(early, greaterThan(0), reason: 'bar does not start to show');
    expect(early, lessThan(0.6), reason: 'bar pops in whole at once');

    await gesture.moveBy(
      const Offset(0, 300),
      timeStamp: const Duration(milliseconds: 900),
    );
    await tester.pump();
    expect(revealed(), 1, reason: 'bar fully shown once the player is away');
    await gesture.up();
    await tester.pumpAndSettle();
  });
}
