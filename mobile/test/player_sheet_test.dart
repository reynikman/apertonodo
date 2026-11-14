import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/playback.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';
import 'golden_support.dart';

/// P-A82 item 1 (FT-565): player sheet does not get stuck, home screen below does not
/// jitter.
///
/// Owner findings 05.10:
/// - "swiped down slowly, moved slightly down — stayed stuck at 1/6 of screen".
///   If finger drifted slightly up during slow swipe, queue scrolled, gesture
///   stopped being recognized as "close", and on release sheet was left floating;
/// - "when sheet collapses — screen flickers abruptly like low fps,
///   mini player appears with delay". While player open, mini player and tabs
///   were unmounted, home stretched full screen; on close they were
///   restored and home visibly rebuilt.
///
/// Rule: on release — sheet either dismisses completely (drag > 1/8 height or
/// fling) or snaps back to top. Under sheet, home is already rendered in
/// final state: mini player and tabs remain mounted the entire time.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const phone = Size(360, 800);
  final screen = find.byKey(const Key('player-screen'));
  final cover = find.byKey(const Key('player-cover'));
  final mini = find.byKey(const Key('mini-player'));
  final navBar = find.byKey(const Key('nav-bar'));

  /// Track playing, player closed: positions of mini player and tabs.
  Future<(Rect, Rect)> playing(WidgetTester tester) async {
    usePhone(tester, phones['360']!);
    final rig = Rig();
    await rig.start(tester);
    await tester.pumpAndSettle();
    await typeSearch(tester, 'metallica');
    await tester.tap(find.text('Nothing Else Matters'));
    await tester.pump();
    rig.audio.emit(AudioPhase.playing);
    await tester.pumpAndSettle();
    return (tester.getRect(mini), tester.getRect(navBar));
  }

  Future<void> openPlayer(WidgetTester tester) async {
    await tester.tap(
      find.descendant(of: mini, matching: find.text('Nothing Else Matters')),
    );
    await tester.pumpAndSettle();
    expect(tester.getRect(screen).top, 0);
  }

  /// Slow drag, 10 pt steps every 100 ms; `back` — mid-drag finger moves
  /// slightly upwards like natural touch. Pause at end: no fling.
  Future<TestGesture> pull(
    WidgetTester tester,
    Offset from,
    double by, {
    double back = 0,
  }) async {
    final gesture = await tester.startGesture(from);
    var at = Duration.zero;
    Future<void> step(double dy) async {
      at += const Duration(milliseconds: 100);
      await gesture.moveBy(Offset(0, dy), timeStamp: at);
      await tester.pump();
    }

    for (var done = 0.0; done < by; done += 10) {
      await step(10);
      if (back > 0 && done >= by / 2 && done < by / 2 + 10) {
        await step(-back);
        await step(back);
      }
    }
    await gesture.moveBy(
      Offset.zero,
      timeStamp: at + const Duration(seconds: 1),
    );
    await tester.pump();
    return gesture;
  }

  void sheetAtRest(WidgetTester tester, String how) {
    if (screen.evaluate().isEmpty) return;
    expect(
      tester.getRect(screen).top,
      0,
      reason: '$how: bottom sheet stuck halfway',
    );
  }

  testWidgets('opened player — fullscreen, no blank strip below', (
    tester,
  ) async {
    await playing(tester);
    await openPlayer(tester);
    expect(
      tester.getRect(screen),
      Offset.zero & phone,
      reason: 'strip under player where mini player and tabs are',
    );
  });

  testWidgets('system «Back» button closes player, not entire app', (
    tester,
  ) async {
    final (miniAt, _) = await playing(tester);
    await openPlayer(tester);

    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();
    expect(screen, findsNothing);
    expect(tester.getRect(mini), miniAt);
    expect(find.byKey(const Key('search-field')), findsOneWidget);
  });

  testWidgets('slowly 1/6 screen and released — player closes fully', (
    tester,
  ) async {
    await playing(tester);
    await openPlayer(tester);

    final gesture = await pull(
      tester,
      tester.getCenter(cover),
      phone.height / 6,
    );
    expect(tester.getRect(screen).top, greaterThan(phone.height / 8));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(screen, findsNothing, reason: 'drag > 1/8 — player restored');
  });

  testWidgets('same by top bar — player closes fully', (tester) async {
    await playing(tester);
    await openPlayer(tester);

    final bar = tester.getRect(find.byKey(const Key('player-close')));
    final gesture = await pull(
      tester,
      Offset(phone.width / 2, bar.center.dy),
      phone.height / 6,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(screen, findsNothing, reason: 'drag > 1/8 — player restored');
  });

  testWidgets('hand twitched up on short drag — sheet stays at top, not '
      'stuck', (tester) async {
    await playing(tester);
    await openPlayer(tester);

    final gesture = await pull(tester, tester.getCenter(cover), 60, back: 12);
    expect(tester.getRect(screen).top, greaterThan(30));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(screen, findsOneWidget);
    sheetAtRest(tester, 'дрожь на ходу 60');
  });

  testWidgets('pulled slightly and released — sheet at top, clean', (
    tester,
  ) async {
    await playing(tester);
    await openPlayer(tester);

    final gesture = await pull(tester, tester.getCenter(cover), 60);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(screen, findsOneWidget);
    sheetAtRest(tester, 'ход 60');
  });

  testWidgets('home under sheet ready: mini player and tabs in place '
      'all the way', (tester) async {
    final (miniAt, barAt) = await playing(tester);
    await openPlayer(tester);
    expect(
      mini.hitTestable(),
      findsNothing,
      reason: 'mini player over opened player',
    );

    final gesture = await pull(tester, tester.getCenter(cover), 400);
    expect(
      mini.hitTestable(),
      findsOneWidget,
      reason: 'no mini player under lowered sheet — it appears abruptly',
    );
    expect(
      tester.getRect(mini),
      miniAt,
      reason: 'mini player widget is out of place',
    );
    expect(tester.getRect(navBar), barAt, reason: 'tabs out of place');

    await gesture.up();
    // Every frame of sheet dismissal: home screen does not rebuild.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        tester.getRect(mini),
        miniAt,
        reason: 'frame $i: mini player moved',
      );
      expect(
        tester.getRect(navBar),
        barAt,
        reason: 'frame $i: navigation tabs moved',
      );
    }
    await tester.pumpAndSettle();
    expect(screen, findsNothing);
    expect(tester.getRect(mini), miniAt);
    expect(tester.getRect(navBar), barAt);
  });

  testWidgets('«close» button — home screen does not rebuild either', (
    tester,
  ) async {
    final (miniAt, barAt) = await playing(tester);
    await openPlayer(tester);

    await tester.tap(find.byKey(const Key('player-close')));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        tester.getRect(mini),
        miniAt,
        reason: 'frame $i: mini player moved',
      );
      expect(
        tester.getRect(navBar),
        barAt,
        reason: 'frame $i: navigation tabs moved',
      );
    }
    await tester.pumpAndSettle();
    expect(screen, findsNothing);
  });
}
