import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/screens/catalog_screens.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'back.dart';
import 'fake_server.dart';
import 'player_fixes_test.dart' show openPlayer, playing;

/// P2 (FT-739, findings H6-2 and H6-6): artist from player opened on outer
/// navigator over shell — without bottom bar and mini-player, and tab
/// switch did not dismiss it, leaving blank screen beneath. Artist always
/// opens inside shell; "back" from it returns to player (lead decision:
/// user does not lose place), tab switch does not.
final player = find.byKey(const Key('player-screen'));
final mini = find.byKey(const Key('mini-player'));
final navBar = find.byKey(const Key('nav-bar'));
final artist = find.byType(ArtistScreen);

Future<void> systemBack(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
}

Future<void> artistFromPlayer(WidgetTester tester) async {
  await playing(tester);
  await openPlayer(tester);
  await tapAndSettle(tester, find.byKey(const Key('player-artist')));
  expect(artist, findsOneWidget);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('artist from player displays nav bar and mini-player', (
    tester,
  ) async {
    await artistFromPlayer(tester);
    expect(player, findsNothing);
    expect(navBar.hitTestable(), findsOneWidget);
    expect(mini.hitTestable(), findsOneWidget);
  });

  testWidgets('back arrow -> player, another back -> shell, not empty', (
    tester,
  ) async {
    await artistFromPlayer(tester);
    await tapBack(tester);
    await tester.pumpAndSettle();
    expect(player, findsOneWidget);
    expect(artist, findsNothing);

    await systemBack(tester);
    expect(player, findsNothing);
    expect(navBar.hitTestable(), findsOneWidget);
    expect(mini.hitTestable(), findsOneWidget);
  });

  testWidgets('system back behaves same as arrow', (tester) async {
    await artistFromPlayer(tester);
    await systemBack(tester);
    expect(player, findsOneWidget);
    expect(artist, findsNothing);
  });

  testWidgets('tab change removes artist and does not open player', (
    tester,
  ) async {
    await artistFromPlayer(tester);
    await openTab(tester, 'search');
    expect(artist, findsNothing);
    expect(player, findsNothing);
    expect(navBar.hitTestable(), findsOneWidget);
    expect(find.byKey(const Key('search-field')).hitTestable(), findsOneWidget);

    await systemBack(tester);
    expect(player, findsNothing);
    expect(navBar.hitTestable(), findsOneWidget);
  });

  testWidgets('double tap on name: player returns only once (review)', (
    tester,
  ) async {
    await playing(tester);
    await openPlayer(tester);
    final name = find.byKey(const Key('player-artist'));
    await tester.tap(name);
    await tester.tap(name, warnIfMissed: false);
    await tester.pumpAndSettle();
    var returns = 0;
    for (var i = 0; i < 6; i++) {
      if (player.evaluate().isNotEmpty) {
        returns++;
        await systemBack(tester);
      } else if (artist.evaluate().isNotEmpty) {
        await tapBack(tester);
        await tester.pumpAndSettle();
      }
    }
    expect(returns, 1);
    expect(artist, findsNothing);
  });

  testWidgets(
    'player opened and minimized manually: back does not return it (review)',
    (tester) async {
      await artistFromPlayer(tester);
      await tapAndSettle(
        tester,
        find.descendant(of: mini, matching: find.text('Nothing Else Matters')),
      );
      expect(player, findsOneWidget);
      await systemBack(tester);
      expect(player, findsNothing);
      expect(artist, findsOneWidget);

      await tapBack(tester);
      await tester.pumpAndSettle();
      expect(artist, findsNothing);
      expect(player, findsNothing);
    },
  );
}
