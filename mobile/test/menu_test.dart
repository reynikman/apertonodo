import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/app.dart';
import 'package:music_stream/playback.dart';

import 'fake_server.dart';

/// P4 Menu (FT-472): Home first, Browse, Search, My Music.
void main() {
  testWidgets('home opened first, four-item menu, no network requests', (
    tester,
  ) async {
    final rig = Rig();
    await rig.start(tester);

    // Search is a tab, no dedicated search bar on home screen anymore.
    expect(find.byKey(const Key('home-search')), findsNothing);
    final bar = tester.getRect(find.byKey(const Key('nav-bar')));
    final tabs = [
      for (final name in ['home', 'browse', 'search', 'library'])
        tester.getRect(find.byKey(Key('tab-$name'))),
    ];
    for (final tab in tabs) {
      expect(bar.contains(tab.center), isTrue, reason: 'tab not on bar');
    }
    expect(
      [for (final tab in tabs) tab.left],
      [
        ...[for (final tab in tabs) tab.left]..sort(),
      ],
      reason: 'order: home, browse, search, my music',
    );
    expect(
      tester.getCenter(find.byKey(const Key('tab-capsule'))),
      tabs.first.center,
      reason: 'home opened first',
    );
    expect(rig.server.requests, isEmpty);
    await tester.pumpAndSettle();
    expect(rig.server.calls('GET /v1/history'), hasLength(1));
    expect(rig.server.calls('GET /v1/genres'), isEmpty);
  });

  testWidgets('tab builds on first open and retains its state properly', (
    tester,
  ) async {
    final rig = Rig();
    await rig.start(tester);
    await tester.pumpAndSettle();
    await typeSearch(tester, 'metallica');
    expect(find.text('Nothing Else Matters'), findsOneWidget);
    expect(rig.server.calls('GET /v1/genres'), isEmpty);

    await openTab(tester, 'browse');
    expect(find.text('Рок'), findsOneWidget);
    expect(
      rig.server.calls('GET /v1/genres'),
      hasLength(1),
      reason: 'genres cached: tab hits network once',
    );
    expect(rig.server.calls('GET /v1/letters'), isEmpty);

    // Search is a tab and retains state: query and results persist like
    // other tabs, and does not re-query network.
    final searches = rig.server.requests.length;
    await openTab(tester, 'search');
    expect(find.text('Nothing Else Matters'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(
            find.byKey(const Key('search-field')).hitTestable(),
          )
          .controller!
          .text,
      'metallica',
    );

    await openTab(tester, 'browse');
    expect(
      rig.server.calls('GET /v1/genres'),
      hasLength(1),
      reason: 'genres cached: returning to tab makes no network call',
    );
    expect(
      rig.server.requests,
      hasLength(searches),
      reason: 'search tab does not re-search or refetch genres',
    );
  });

  testWidgets('shell without server — search only, no menu', (tester) async {
    await tester.pumpWidget(const MusicApp());

    expect(find.byKey(const Key('search-field')), findsOneWidget);
    expect(find.byKey(const Key('nav-bar')), findsNothing);
  });

  testWidgets('mini-player sits above tab buttons', (tester) async {
    final rig = Rig();
    await rig.start(tester);
    await tester.pumpAndSettle();
    await typeSearch(tester, 'metallica');
    await tester.tap(find.text('Nothing Else Matters'));
    await tester.pump();
    // Source is still being looked up, bar progresses: frame-by-frame, not until idle.
    await tester.tap(find.byKey(const Key('tab-home')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final mini = tester.getRect(find.byKey(const Key('mini-player')));
    final tabs = tester.getRect(find.byKey(const Key('nav-bar')));

    expect(
      mini.bottom,
      lessThanOrEqualTo(tabs.top),
      reason: 'mini-player slipped under tab buttons',
    );
  });

  testWidgets('no mini player on the big player', (tester) async {
    final rig = Rig();
    await rig.start(tester);
    await tester.pumpAndSettle();
    await typeSearch(tester, 'metallica');
    await tester.tap(find.text('Nothing Else Matters'));
    await tester.pump();
    rig.audio.emit(AudioPhase.playing);
    await tester.pump();
    await openTab(tester, 'home');

    await tester.tap(find.byKey(const Key('mini-player')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byKey(const Key('nav-bar')).hitTestable(), findsNothing);
    expect(find.byKey(const Key('mini-player')).hitTestable(), findsNothing);
    expect(find.byKey(const Key('player-screen')), findsOneWidget);
    expect(find.byKey(const Key('player-pause-button')), findsOneWidget);
  });

  group('theme', () {
    Future<Brightness> brightnessWith(
      WidgetTester tester,
      Brightness system,
    ) async {
      tester.platformDispatcher.platformBrightnessTestValue = system;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await Rig().start(tester);
      await tester.pumpAndSettle();
      final field = tester.element(find.byKey(const Key('nav-bar')));
      return Theme.of(field).brightness;
    }

    testWidgets('dark system — dark app', (tester) async {
      expect(await brightnessWith(tester, Brightness.dark), Brightness.dark);
    });

    testWidgets('light system — still dark', (tester) async {
      expect(await brightnessWith(tester, Brightness.light), Brightness.dark);
    });
  });
}
