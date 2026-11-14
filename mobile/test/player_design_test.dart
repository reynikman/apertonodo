import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/models/track.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/player.dart';
import 'package:music_stream/screens/cover_glow.dart';
import 'package:music_stream/screens/parts.dart';
import 'package:music_stream/screens/player_screen.dart';
import 'package:music_stream/sleep_timer.dart';
import 'package:music_stream/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';
import 'golden_support.dart';

/// Full player per dump (P4, step 8; frame `crop_phone6_player`): no
/// AppBar — circular "collapse", heart, and "⋮"; cover 272 with glow;
/// title and artist on the left; amber seek bar; button row with amber
/// pause 64 in the center; single card queue below. Queue contains full
/// list including played tracks, under "Queue" header (owner finding 30.09:
/// "Up next" looked like a button). No drag handle: reordering
/// tracks in queue is not supported. "Download" is in "⋮" menu, not under title.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final close = find.byKey(const Key('player-close'));
  final heart = find.byKey(const Key('player-heart'));
  final menu = find.byKey(const Key('player-menu'));
  final cover = find.byKey(const Key('player-cover'));
  final title = find.byKey(const Key('player-title'));
  final artist = find.byKey(const Key('player-artist'));
  final seek = find.byKey(const Key('seek-bar'));
  final position = find.byKey(const Key('seek-position'));
  final total = find.byKey(const Key('seek-total'));
  final shuffle = find.byKey(const Key('shuffle-button'));
  final previous = find.byKey(const Key('previous-button'));
  final pause = find.byKey(const Key('player-pause-button'));
  final next = find.byKey(const Key('next-button'));
  final repeat = find.byKey(const Key('repeat-button'));
  final heading = find.byKey(const Key('queue-heading'));
  Finder row(int index) => find.byKey(Key('queue-row-$index'));

  const names = [
    ('Numb', 187),
    ('Somewhere I Belong', 213),
    ('Breaking the Habit', 196),
    ('From the Inside', 175),
    ('Faint', 162),
  ];
  final songs = [
    for (final (i, (name, seconds)) in names.indexed)
      Track(
        id: '00000000-0000-4000-8000-00000000000${i + 1}',
        title: name,
        artist: 'Linkin Park',
        durationMs: seconds * 1000,
        artworkUrl: '/v1/covers/lp-${i + 1}',
      ),
  ];

  TextStyle styleOf(WidgetTester tester, Finder text) {
    final paragraph = find.descendant(
      of: text,
      matching: find.byType(RichText),
      matchRoot: true,
    );
    return tester.renderObject<RenderParagraph>(paragraph.first).text.style!;
  }

  Color? background(WidgetTester tester, Finder button) =>
      tester.widget<IconButton>(button).style?.backgroundColor?.resolve({});

  /// Rendered icon color: icon is text (font glyph).
  Color? iconColor(WidgetTester tester, Finder button) => tester
      .renderObject<RenderParagraph>(
        find.descendant(of: button, matching: find.byType(RichText)).first,
      )
      .text
      .style
      ?.color;

  /// Player open on top of background screen, track [start] plays at 2:14.
  Future<(Player, Rig)> open(
    WidgetTester tester, {
    Size? size,
    int start = 0,
    bool queue = true,
    Future<void> Function(Track track)? onDownload,
  }) async {
    usePhone(tester, size ?? phones['360']!);
    tester.view.padding = const FakeViewPadding(top: 36);
    addTearDown(tester.view.resetPadding);
    final rig = Rig();
    addTearDown(() => expect(rig.server.unknown, isEmpty));
    addTearDown(rig.audio.close);
    final player = Player(playback: rig.playback, audio: rig.audio);
    addTearDown(player.dispose);
    if (queue) {
      await player.playQueue(songs, start: start);
      rig.audio.emit(AudioPhase.playing);
    }
    // FT-805: full quick actions row — download, lyrics, sleep timer, as on device.
    final sleep = SleepTimer(player: player);
    addTearDown(sleep.dispose);
    final services = Services(
      server: rig.server.api(),
      search: rig.server.catalog().search,
      play: (tracks, index) => rig.played.add((tracks, index)),
      prepare: (track) => rig.prepared.add(track.id),
      sleepTimer: sleep,
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
            onDownload: onDownload ?? (_) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    rig.audio.tick(const Duration(seconds: 134));
    // First frame delivers position, second frame paints it.
    await tester.pump();
    await tester.pump();
    return (player, rig);
  }

  testWidgets('header: no AppBar, two 40 circles below notification bar', (
    tester,
  ) async {
    await open(tester);

    expect(find.byType(AppBar), findsNothing);
    expect(find.text('Плеер'), findsNothing);
    for (final button in [close, menu]) {
      expect(tester.getSize(button), const Size(40, 40));
      expect(tester.getRect(button).top, inInclusiveRange(36 + 4, 36 + 16));
      expect(
        tester.getCenter(button).dy,
        moreOrLessEquals(tester.getCenter(close).dy, epsilon: 0.5),
      );
    }
    expect(tester.getRect(close).left, 16);
    expect(tester.getRect(menu).right, 360 - 16);
    // FT-805: heart moved from header to song title.
    expect(
      tester.getRect(heart).top,
      greaterThan(tester.getRect(cover).bottom),
    );
    expect(background(tester, close), ApertonoColors.surfaceRaised);
    expect(iconColor(tester, close), ApertonoColors.textPrimary);
    final closeButton = tester.widget<IconButton>(close);
    expect((closeButton.icon as Icon).icon, Icons.keyboard_arrow_down);
    expect(closeButton.tooltip, 'Свернуть');
  });

  testWidgets('«collapse» returns to screen below player', (tester) async {
    await open(tester);

    await tapAndSettle(tester, close);

    expect(find.byKey(const Key('player-screen')), findsNothing);
    expect(find.text('под плеером'), findsOneWidget);
  });

  testWidgets('heart in favorites — white and filled, not amber', (
    tester,
  ) async {
    await open(tester);

    await tapAndSettle(tester, heart);

    expect(tester.widget<IconButton>(heart).isSelected, isTrue);
    expect(
      find.descendant(of: heart, matching: find.byIcon(Icons.favorite)),
      findsOneWidget,
    );
    expect(iconColor(tester, heart), ApertonoColors.textPrimary);
  });

  testWidgets('cover 272 centered, with glow effect and radius 16', (
    tester,
  ) async {
    await open(tester);

    expect(tester.widget(cover), isA<CoverGlow>());
    final rect = tester.getRect(cover);
    expect(rect.size, const Size(272, 272));
    expect(rect.center.dx, 180);
    expect(
      rect.top - tester.getRect(close).bottom,
      inInclusiveRange(8.0, 24.0),
    );
    final image = tester.widget<Cover>(
      find.descendant(of: cover, matching: find.byType(Cover)),
    );
    expect(image.size, 272);
    expect(image.radius, ApertonoRadii.medium);
  });

  testWidgets('on 412 cover is 320 — grows no further', (tester) async {
    await open(tester, size: phones['412']!);

    final rect = tester.getRect(cover);
    expect(rect.size, const Size(320, 320));
    expect(rect.center.dx, 206);
  });

  testWidgets('title and artist on left, with 24 padding', (tester) async {
    await open(tester);

    final name = tester.getRect(title);
    expect(name.left, 24);
    expect(name.top - tester.getRect(cover).bottom, inInclusiveRange(16, 32));
    expect(tester.widget<Text>(title).data, 'Numb');
    expect(
      tester.widget<Text>(title).textAlign,
      anyOf(isNull, TextAlign.start, TextAlign.left),
    );
    final big = styleOf(tester, title);
    expect(big.fontSize, 22);
    expect(big.fontWeight, FontWeight.w700);
    expect(big.color, ApertonoColors.textPrimary);

    final by = tester.getRect(artist);
    expect(by.left, 24);
    expect(by.top - name.bottom, inInclusiveRange(0, 8));
    expect(tester.widget<Text>(artist).data, 'Linkin Park');
    final small = styleOf(tester, artist);
    expect(small.fontSize, 15);
    expect(small.color, ApertonoColors.textSecondary);
  });

  testWidgets('seek bar amber, track 4, thumb 12; mono time at the edges', (
    tester,
  ) async {
    await open(tester);

    expect(
      tester.getRect(seek).top,
      greaterThan(tester.getRect(artist).bottom),
    );
    final theme = SliderTheme.of(tester.element(seek));
    expect(theme.activeTrackColor, ApertonoColors.accent);
    expect(theme.thumbColor, ApertonoColors.accent);
    expect(theme.inactiveTrackColor, isNot(ApertonoColors.accent));
    expect(theme.trackHeight, 4);
    final thumb = theme.thumbShape;
    expect(thumb, isA<RoundSliderThumbShape>());
    expect((thumb! as RoundSliderThumbShape).enabledThumbRadius, 6);

    expect(tester.widget<Text>(position).data, '2:14');
    expect(tester.widget<Text>(total).data, '3:07');
    expect(tester.getRect(position).left, 24);
    expect(tester.getRect(total).right, 360 - 24);
    for (final time in [position, total]) {
      final style = styleOf(tester, time);
      expect(style.fontFamily, ApertonoFonts.mono);
      expect(style.color, ApertonoColors.textSecondary);
      expect(tester.getRect(time).top, greaterThan(tester.getRect(seek).top));
    }
  });

  testWidgets('buttons in row: amber pause 64 in center, «prev» and '
      '«next» — 52 circles', (tester) async {
    await open(tester);

    final line = tester.getCenter(pause).dy;
    for (final button in [shuffle, previous, pause, next, repeat]) {
      expect(button, findsOneWidget);
      expect(tester.getCenter(button).dy, moreOrLessEquals(line, epsilon: 0.5));
    }
    expect(
      tester.getRect(shuffle).top,
      greaterThan(tester.getRect(total).bottom),
    );
    expect(tester.getSize(pause), const Size(64, 64));
    expect(tester.getCenter(pause).dx, 180);
    expect(background(tester, pause), ApertonoColors.accent);
    expect(
      tester.getSize(find.descendant(of: pause, matching: find.byType(Icon))),
      const Size(32, 32),
    );
    for (final button in [previous, next]) {
      expect(tester.getSize(button), const Size(52, 52));
      expect(background(tester, button), ApertonoColors.surfaceRaised);
      expect(iconColor(tester, button), ApertonoColors.textPrimary);
    }
    // FT-805: buttons clustered tightly in center, not stretched to edges.
    final order = [shuffle, previous, pause, next, repeat];
    for (var i = 1; i < order.length; i++) {
      expect(
        tester.getRect(order[i]).left - tester.getRect(order[i - 1]).right,
        inInclusiveRange(8.0, 12.0),
        reason: 'gap before button $i',
      );
    }
    expect(
      tester.getRect(shuffle).left + tester.getRect(repeat).right,
      moreOrLessEquals(360, epsilon: 1),
    );
    for (final button in [shuffle, repeat]) {
      expect(background(tester, button), isNull);
      expect(iconColor(tester, button), ApertonoColors.textPrimary);
    }
  });

  testWidgets('active «shuffle» and «repeat» — amber', (tester) async {
    final (player, _) = await open(tester);

    player.toggleShuffle();
    player.cycleRepeat();
    // Button color transitions smoothly — wait for transition to finish.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(iconColor(tester, shuffle), ApertonoColors.accent);
    expect(iconColor(tester, repeat), ApertonoColors.accent);
  });

  // FT-849, owner's finding 13.10 No. 8: the icon alone does not say which repeat is on.
  testWidgets('repeat names its new mode, one message at a time', (
    tester,
  ) async {
    await open(tester);

    await tester.tap(repeat);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.widgetWithText(SnackBar, 'Повтор очереди'), findsOneWidget);

    await tester.tap(repeat);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.widgetWithText(SnackBar, 'Повтор песни'), findsOneWidget);
    expect(find.widgetWithText(SnackBar, 'Повтор очереди'), findsNothing);
    expect(
      tester
          .widget<Icon>(
            find.descendant(of: repeat, matching: find.byType(Icon)),
          )
          .icon,
      Icons.repeat_one,
    );

    await tester.tap(repeat);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.widgetWithText(SnackBar, 'Повтор выключен'), findsOneWidget);
  });

  testWidgets('queue — single card: header radius 24, rows '
      'flush, visible right away', (tester) async {
    await open(tester);

    final head = tester.widget<Material>(heading);
    expect(head.color, ApertonoColors.surface);
    expect(
      head.borderRadius,
      const BorderRadius.vertical(top: Radius.circular(24)),
    );
    final top = tester.getRect(heading);
    expect(top.left, 8);
    expect(top.right, 360 - 8);
    expect(
      top.top - tester.getRect(find.byKey(const Key('player-quick'))).bottom,
      inInclusiveRange(16.0, 40.0),
    );
    final label = find.descendant(of: heading, matching: find.text('Очередь'));
    expect(label, findsOneWidget);
    expect(styleOf(tester, label).fontSize, 12.5);
    expect(styleOf(tester, label).color, ApertonoColors.textSecondary);

    // Header and first track are visible upon opening, without scroll.
    expect(tester.getRect(row(0)).bottom, lessThanOrEqualTo(800));

    // FT-805: quick row placed below buttons — two rows built without scrolling.
    var above = top.bottom;
    for (var i = 0; i < 2; i++) {
      final rect = tester.getRect(row(i));
      expect(tester.widget<Material>(row(i)).color, ApertonoColors.surface);
      expect(rect.left, 8, reason: 'row $i');
      expect(rect.right, 360 - 8, reason: 'row $i');
      expect(rect.height, greaterThanOrEqualTo(56), reason: 'row $i');
      expect(rect.top, moreOrLessEquals(above, epsilon: 0.5), reason: '$i');
      above = rect.bottom;
    }
    // Card ends cleanly with the last row, not cut off abruptly.
    expect(tester.widget<Material>(row(0)).borderRadius, isNull);
    await tester.scrollUntilVisible(row(4), 200);
    expect(
      tester.widget<Material>(row(4)).borderRadius,
      const BorderRadius.vertical(bottom: Radius.circular(24)),
    );
  });

  testWidgets(
    'queue row: cover 40, track title, artist, time shown on the right; '
    'без номера и без значка перетаскивания',
    (tester) async {
      await open(tester);

      final rect = tester.getRect(row(1));
      final thumb = find.descendant(of: row(1), matching: find.byType(Cover));
      expect(thumb, findsOneWidget);
      expect(tester.getSize(thumb), const Size(40, 40));
      expect(tester.getRect(thumb).left, rect.left + 16);
      expect(tester.widget<Cover>(thumb).path, '/v1/covers/lp-2');

      final name = find.descendant(
        of: row(1),
        matching: find.text('Somewhere I Belong'),
      );
      expect(styleOf(tester, name).fontSize, ApertonoText.trackTitle.fontSize);
      expect(styleOf(tester, name).color, ApertonoColors.textPrimary);
      final by = find.descendant(
        of: row(1),
        matching: find.text('Linkin Park'),
      );
      expect(styleOf(tester, by).color, ApertonoColors.textSecondary);
      final time = find.descendant(of: row(1), matching: find.text('3:33'));
      expect(time, findsOneWidget);
      expect(styleOf(tester, time).fontFamily, ApertonoFonts.mono);
      expect(styleOf(tester, time).color, ApertonoColors.textSecondary);
      expect(tester.getRect(time).right, rect.right - 16);

      expect(find.textContaining('01.'), findsNothing);
      expect(find.textContaining('02.'), findsNothing);
      expect(find.byIcon(Icons.drag_handle), findsNothing);
      expect(find.byIcon(Icons.reorder), findsNothing);
    },
  );

  testWidgets('playing row — amber title; played tracks also in queue', (
    tester,
  ) async {
    await open(tester, start: 1);
    await tester.scrollUntilVisible(row(2), 100);

    Color? colorOf(int i, String text) => styleOf(
      tester,
      find.descendant(of: row(i), matching: find.text(text)),
    ).color;
    expect(colorOf(0, 'Numb'), ApertonoColors.textPrimary);
    expect(colorOf(1, 'Somewhere I Belong'), ApertonoColors.accent);
    expect(colorOf(2, 'Breaking the Habit'), ApertonoColors.textPrimary);
  });

  testWidgets('tapping queue row plays this song', (tester) async {
    final (player, _) = await open(tester);

    await tester.scrollUntilVisible(row(2), 100);
    await tester.tap(row(2));
    await tester.pump();

    expect(player.current, songs[2]);
  });

  testWidgets('«Download» — quick row icon, «Add to playlist» — '
      'in «⋮» menu', (tester) async {
    final saved = <String>[];
    await open(tester, onDownload: (track) async => saved.add(track.title));

    expect(find.text('В загрузки'), findsNothing);
    expect(tester.getSize(menu), const Size(40, 40));

    await tapAndSettle(tester, menu);
    expect(find.text('Добавить в плейлист'), findsOneWidget);
    expect(find.byKey(const Key('download-track')), findsNothing);
    await tester.tapAt(const Offset(4, 400));
    await tester.pumpAndSettle();

    await tapAndSettle(tester, find.byKey(const Key('player-quick-download')));

    expect(saved, ['Numb']);
    expect(find.textContaining('Добавлено в «Загрузки»'), findsOneWidget);
  });

  testWidgets('without song — «No track» and «collapse», no AppBar', (
    tester,
  ) async {
    await open(tester, queue: false);

    expect(find.text('Нет трека'), findsOneWidget);
    expect(find.byType(AppBar), findsNothing);
    await tapAndSettle(tester, close);
    expect(find.text('под плеером'), findsOneWidget);
  });

  testWidgets('large font: nothing overflows', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await open(tester);
    expect(tester.takeException(), isNull);
    expect(title, findsOneWidget);
    await tester.fling(
      find.byKey(const Key('queue')),
      const Offset(0, -2000),
      4000,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  group('снимок-эталон', () {
    setUpAll(() async {
      await loadAppFonts();
      compareOnMacOnly();
    });

    for (final MapEntry(key: label, value: size) in phones.entries) {
      testWidgets('full player at $label dp', (tester) async {
        // Five track queue as in screenshot; app theme and fonts applied.
        // Path from mini player to full player is tested by navigation_test and nav_bar_test.
        await open(tester, size: size);
        expect(find.byKey(const Key('player-screen')), findsOneWidget);
        await expectLater(
          find.byType(MaterialApp).first,
          matchesGoldenFile('goldens/player_$label.png'),
        );
      });
    }
  });
}
