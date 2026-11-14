import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/screens/catalog_screens.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';
import 'back.dart';

/// Owner remarks 02.10 for full player (`plan/p4-fixes.md`, G, I and 27):
/// - 4b: swipe down did not collapse player;
/// - A: artist name in player did not link anywhere;
/// - 27: "More" on player surfaced mini player and bottom bar over player — menu treated as
///   "navigated away from player";
/// - I: "Send report" expanded mini player card with a second row.
const song = 'Nothing Else Matters';
final player = find.byKey(const Key('player-screen'));
final mini = find.byKey(const Key('mini-player'));
final navBar = find.byKey(const Key('nav-bar'));

/// Track playing, user on Home: mini player at bottom.
Future<Rig> playing(WidgetTester tester) async {
  final rig = Rig();
  await rig.start(tester);
  await tester.pumpAndSettle();
  await typeSearch(tester, 'metallica');
  await tester.tap(find.text(song));
  await tester.pump();
  rig.audio.emit(AudioPhase.playing);
  await tester.pump();
  await openTab(tester, 'home');
  await tester.pumpAndSettle();
  return rig;
}

Future<void> openPlayer(WidgetTester tester) async {
  await tapAndSettle(
    tester,
    find.descendant(of: mini, matching: find.text(song)),
  );
  expect(player, findsOneWidget);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('4b: swipe down on player collapses it to mini player', (
    tester,
  ) async {
    await playing(tester);
    await openPlayer(tester);

    await tester.fling(
      find.byKey(const Key('player-title')),
      const Offset(0, 400),
      1500,
    );
    await tester.pumpAndSettle();

    expect(player, findsNothing);
    expect(mini, findsOneWidget);
  });

  testWidgets(
    '4b: queue is scrolled — swipe down scrolls it, player remains open',
    (tester) async {
      await playing(tester);
      await openPlayer(tester);
      final queue = find.byKey(const Key('queue'));

      await tester.drag(queue, const Offset(0, -300));
      await tester.pumpAndSettle();
      await tester.drag(queue, const Offset(0, 150));
      await tester.pumpAndSettle();

      expect(player, findsOneWidget);
    },
  );

  testWidgets('A: artist name in player opens artist page, back — '
      'player again', (tester) async {
    await playing(tester);
    await openPlayer(tester);

    await tapAndSettle(tester, find.byKey(const Key('player-artist')));
    expect(find.byType(ArtistScreen), findsOneWidget);
    expect(
      tester.widget<ArtistScreen>(find.byType(ArtistScreen)).name,
      'Metallica',
    );

    await tapBack(tester);
    await tester.pumpAndSettle();
    expect(player, findsOneWidget);
    expect(mini.hitTestable(), findsNothing);
  });

  testWidgets('27: «More» and «Add to playlist» over player do not show '
      'mini player and bottom bar', (tester) async {
    await playing(tester);
    await openPlayer(tester);
    expect(mini.hitTestable(), findsNothing);
    expect(navBar.hitTestable(), findsNothing);

    await tapAndSettle(tester, find.byKey(const Key('player-menu')));
    expect(mini.hitTestable(), findsNothing);
    expect(navBar.hitTestable(), findsNothing);

    await tapAndSettle(tester, find.text('Добавить в плейлист'));
    expect(find.text('Новый плейлист'), findsOneWidget);
    expect(mini.hitTestable(), findsNothing);
    expect(navBar.hitTestable(), findsNothing);

    await tapAndSettle(tester, find.text('Отмена').last);
    expect(player, findsOneWidget);
    expect(mini.hitTestable(), findsNothing);
  });

  testWidgets('I: audio error — mini player card does not grow, report on '
      'full player', (tester) async {
    final rig = await playing(tester);
    final height = tester.getSize(mini).height;
    expect(height, 68);

    rig.audio.emit(AudioPhase.error, position: const Duration(seconds: 20));
    await tester.pumpAndSettle();

    expect(tester.getSize(mini).height, height);
    expect(
      find.descendant(of: mini, matching: find.byKey(const Key('send-report'))),
      findsNothing,
    );

    await openPlayer(tester);
    expect(
      find.descendant(
        of: player,
        matching: find.byKey(const Key('send-report')),
      ),
      findsOneWidget,
    );
  });
}
