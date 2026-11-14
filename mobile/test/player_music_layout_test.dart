import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/models/track.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/player.dart';
import 'package:music_stream/ratings.dart';
import 'package:music_stream/screens/parts.dart';
import 'package:music_stream/server_ports.dart';
import 'package:music_stream/screens/player_screen.dart';
import 'package:music_stream/sleep_timer.dart';
import 'package:music_stream/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';
import 'golden_support.dart';

/// FT-805: music player per prototype `docs/design/prototypes/player-music.html`
/// (layout decided by owner 12.10). Heart is right of title, below control
/// buttons — row of three unlabeled icons "download · lyrics · sleep
/// timer", long press on heart opens rating, hint shown only
/// once. Episode and book player unchanged.
void main() {
  setUpAll(loadAppFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final heart = find.byKey(const Key('player-heart'));
  final title = find.byKey(const Key('player-title'));
  final artist = find.byKey(const Key('player-artist'));
  final cover = find.byKey(const Key('player-cover'));
  final next = find.byKey(const Key('next-button'));
  final heading = find.byKey(const Key('queue-heading'));
  final quick = find.byKey(const Key('player-quick'));
  final quickDownload = find.byKey(const Key('player-quick-download'));
  final quickLyrics = find.byKey(const Key('player-quick-lyrics'));
  final quickSleep = find.byKey(const Key('player-quick-sleep'));
  final hint = find.byKey(const Key('player-heart-hint'));

  const song = Track(
    id: '00000000-0000-4000-8000-000000000001',
    title: 'Numb',
    artist: 'Linkin Park',
    durationMs: 187000,
    artworkUrl: '/v1/covers/lp-1',
  );
  const episode = Track(
    id: 'podcast:ep',
    title: 'Episode',
    artist: 'Show',
    durationMs: 3600000,
    artworkUrl: '',
  );

  Future<(Player, Rig, List<String>)> open(
    WidgetTester tester, {
    Track track = song,
    Size? size,
  }) async {
    usePhone(tester, size ?? phones['360']!);
    final rig = Rig();
    rig.server
      ..on('POST /v1/ratings/of', (_) => answer(200, {'ratings': {}}))
      ..on(
        'POST /v1/ratings',
        (_) => answer(200, {'stars': 4, 'disliked': false}),
      );
    addTearDown(rig.audio.close);
    final player = Player(playback: rig.playback, audio: rig.audio);
    addTearDown(player.dispose);
    await player.playQueue([track]);
    rig.audio.emit(AudioPhase.playing);
    final sleep = SleepTimer(player: player);
    addTearDown(sleep.dispose);
    final saved = <String>[];
    final api = rig.server.api();
    final services = Services(
      server: api,
      search: rig.server.catalog().search,
      play: (tracks, index) {},
      prepare: (track) {},
      sleepTimer: sleep,
      ratings: RatingsStore(ServerRatingsPort(api)),
    );
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: apertonoTheme(),
        navigatorKey: navigator,
        home: const Scaffold(body: Text('под плеером')),
      ),
    );
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => PlayerScreen(
            player: player,
            services: services,
            onDownload: (track) async => saved.add(track.title),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (player, rig, saved);
  }

  testWidgets('heart is to right of title, not in header', (tester) async {
    await open(tester);

    final h = tester.getRect(heart);
    expect(h.top, greaterThan(tester.getRect(cover).bottom));
    expect(h.left, greaterThanOrEqualTo(tester.getRect(title).right));
    expect(h.right, lessThanOrEqualTo(360 - 16));
    // Vertically within "title + artist" block.
    expect(h.center.dy, greaterThan(tester.getRect(title).top));
    expect(h.center.dy, lessThan(tester.getRect(artist).bottom));
    expect(tester.getSize(heart).shortestSide, greaterThanOrEqualTo(40));
  });

  testWidgets('quick row: download, lyrics, timer — 3 icons without labels', (
    tester,
  ) async {
    await open(tester);

    final row = tester.getRect(quick);
    expect(row.top, greaterThanOrEqualTo(tester.getRect(next).bottom));
    expect(row.bottom, lessThanOrEqualTo(tester.getRect(heading).top));
    final xs = [
      for (final f in [quickDownload, quickLyrics, quickSleep])
        tester.getCenter(f).dx,
    ];
    expect(xs[0], lessThan(xs[1]));
    expect(xs[1], lessThan(xs[2]));
    // Row centered on screen, not pinned to edge.
    expect((xs[0] + xs[2]) / 2, moreOrLessEquals(180, epsilon: 1));
    expect(xs[1], moreOrLessEquals(180, epsilon: 1));
    for (final f in [quickDownload, quickLyrics, quickSleep]) {
      expect(tester.getSize(f).shortestSide, greaterThanOrEqualTo(48));
      expect(
        tester.getCenter(f).dy,
        moreOrLessEquals(tester.getCenter(quickLyrics).dy, epsilon: 0.5),
      );
      expect(tester.widget<IconButton>(f).tooltip, isNotEmpty);
    }
    expect(
      find.descendant(of: quick, matching: find.byType(Text)),
      findsNothing,
      reason: 'no labels below icons (owner note 12.10)',
    );
  });

  testWidgets('quick row icons work', (tester) async {
    final (_, rig, saved) = await open(tester);
    rig.server.on(
      'GET /v1/lyrics/*',
      (_) => answer(404, {'detail': 'not found'}),
    );

    await tapAndSettle(tester, quickDownload);
    expect(saved, ['Numb']);

    await tapAndSettle(tester, quickSleep);
    expect(find.byKey(const Key('sleep-15')), findsOneWidget);
    await tapAndSettle(tester, find.byKey(const Key('sleep-15')));
    // Timer sheet remains open after selection (like from menu): close it.
    await tester.tapAt(const Offset(180, 40));
    await tester.pumpAndSettle();
    expect(
      tester.widget<IconButton>(quickSleep).isSelected,
      isTrue,
      reason: 'armed timer is visible by icon',
    );

    await tapAndSettle(tester, quickLyrics);
    // FT-843: one request when the player opens; it got no answer (404), so the tap asks again.
    expect(rig.server.calls('GET /v1/lyrics/*'), hasLength(2));
    await tester.tapAt(const Offset(180, 40));
    await tester.pumpAndSettle();

    // Disabled timer dims (and does not remain active after test).
    await tapAndSettle(tester, quickSleep);
    await tapAndSettle(tester, find.byKey(const Key('sleep-off')));
    await tester.tapAt(const Offset(180, 40));
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(quickSleep).isSelected, isFalse);
  });

  testWidgets('long press on heart opens rating dialog, not «like»', (
    tester,
  ) async {
    await open(tester);

    await tester.longPress(heart);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('rating-star-4')), findsOneWidget);
    expect(find.byKey(const Key('rating-dislike')), findsOneWidget);
    expect(tester.widget<IconButton>(heart).isSelected, isFalse);
  });

  testWidgets('heart tooltip shown once', (tester) async {
    await open(tester);
    expect(hint, findsOneWidget);
    expect(
      find.descendant(of: hint, matching: find.textContaining('Удержите')),
      findsOneWidget,
    );

    await tapAndSettle(tester, find.byKey(const Key('player-close')));
    await open(tester);

    expect(hint, findsNothing);
  });

  testWidgets('tooltip dismisses on tap and does not block heart', (
    tester,
  ) async {
    await open(tester);

    await tapAndSettle(tester, hint);
    expect(hint, findsNothing);

    await tapAndSettle(tester, heart);
    expect(tester.widget<IconButton>(heart).isSelected, isTrue);
  });

  testWidgets('English locale phone reads action tooltip in English', (
    tester,
  ) async {
    tester.platformDispatcher.localeTestValue = const Locale('en');
    tester.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.platformDispatcher.clearLocaleTestValue);
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    await open(tester);

    expect(
      find.descendant(of: hint, matching: find.textContaining('Hold')),
      findsOneWidget,
    );
  });

  testWidgets('podcast episode has no quick row or action tooltip', (
    tester,
  ) async {
    await open(tester, track: episode);

    expect(quick, findsNothing);
    expect(hint, findsNothing);
  });

  for (final name in ['360', '412']) {
    testWidgets('at $name dp row fits in width, nothing clipped', (
      tester,
    ) async {
      await open(tester, size: phones[name]);

      expect(tester.takeException(), isNull);
      final width = phones[name]!.width;
      expect(tester.getRect(quick).left, greaterThanOrEqualTo(0));
      expect(tester.getRect(quick).right, lessThanOrEqualTo(width));
      expect(tester.getRect(heart).right, lessThanOrEqualTo(width - 16));
    });
  }
}
