import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/models/track.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/player.dart';
import 'package:music_stream/ratings.dart';
import 'package:music_stream/screens/parts.dart';
import 'package:music_stream/screens/player_screen.dart';
import 'package:music_stream/server_ports.dart';
import 'package:music_stream/sleep_timer.dart';
import 'package:music_stream/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';
import 'golden_support.dart';

/// FT-807: music player "three dots" — bottom sheet in our design, items
/// grouped into sections (prototype `docs/design/prototypes/player-music.html`,
/// `menuSheet`; owner 12.10: "regroup three dots — ok"). No "Audio"
/// section: general quality moved to settings (FT-804). Episode and book player
/// remains unchanged — old dropdown menu there.
void main() {
  setUpAll(loadAppFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final menu = find.byKey(const Key('player-menu'));
  final sheet = find.byKey(const Key('player-menu-sheet'));
  final headSong = find.byKey(const Key('player-menu-song'));
  final headGo = find.byKey(const Key('player-menu-go'));
  final headHelp = find.byKey(const Key('player-menu-help'));
  final playlist = find.byKey(const Key('player-add-to-playlist'));
  final rate = find.byKey(const Key('player-rate'));
  final dislike = find.byKey(const Key('player-dislike'));
  final toArtist = find.byKey(const Key('player-to-artist'));
  final problem = find.byKey(const Key('player-problem'));
  final items = [playlist, rate, dislike, toArtist, problem];
  final toPodcast = find.byKey(const Key('player-to-podcast'));
  final podcastsOpened = <String>[];
  setUp(podcastsOpened.clear);

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

  Future<(List<String> artists, List<String> ratings)> open(
    WidgetTester tester, {
    Track track = song,
    Size size = const Size(360, 800),
  }) async {
    usePhone(tester, size);
    final rig = Rig();
    final sent = <String>[];
    rig.server
      ..on('POST /v1/ratings/of', (_) => answer(200, {'ratings': {}}))
      ..on('POST /v1/ratings', (_) {
        sent.add('rating');
        return answer(200, {'stars': 0, 'disliked': true});
      });
    addTearDown(rig.audio.close);
    final player = Player(playback: rig.playback, audio: rig.audio);
    addTearDown(player.dispose);
    await player.playQueue([track]);
    rig.audio.emit(AudioPhase.playing);
    final sleep = SleepTimer(player: player);
    addTearDown(sleep.dispose);
    final artists = <String>[];
    final api = rig.server.api();
    final services = Services(
      server: api,
      search: rig.server.catalog().search,
      play: (tracks, index) {},
      prepare: (track) {},
      openArtist: artists.add,
      openPodcast: (track) => podcastsOpened.add(track.id),
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
            onDownload: (track) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Heart tooltip (FT-805) must not intercept taps.
    final hint = find.byKey(const Key('player-heart-hint'));
    if (hint.evaluate().isNotEmpty) {
      await tester.tap(hint, warnIfMissed: false);
      await tester.pumpAndSettle();
    }
    await tester.tap(menu);
    await tester.pumpAndSettle();
    return (artists, sent);
  }

  testWidgets('«three dots» opens bottom sheet, not popup menu', (
    tester,
  ) async {
    await open(tester);

    expect(find.byType(PopupMenuItem<VoidCallback>), findsNothing);
    expect(sheet, findsOneWidget);
    final box = tester.getRect(sheet);
    expect(box.left, 0);
    expect(box.right, 360);
    expect(box.bottom, 800);
    // Now playing in header: sheet obscures title on screen.
    final head = find.byKey(const Key('player-menu-head'));
    expect(
      find.descendant(of: head, matching: find.text('Numb')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: head, matching: find.textContaining('Linkin Park')),
      findsOneWidget,
    );
  });

  testWidgets('items grouped by sections: song, navigation, and help', (
    tester,
  ) async {
    await open(tester);

    double y(Finder f) => tester.getRect(f).top;
    for (final f in [headSong, headGo, headHelp, ...items]) {
      expect(find.descendant(of: sheet, matching: f), findsOneWidget);
    }
    expect(y(headSong), lessThan(y(playlist)));
    expect(y(playlist), lessThan(y(rate)));
    expect(y(rate), lessThan(y(dislike)));
    expect(y(dislike), lessThan(y(headGo)));
    expect(y(headGo), lessThan(y(toArtist)));
    expect(y(toArtist), lessThan(y(headHelp)));
    expect(y(headHelp), lessThan(y(problem)));
    // "Audio" section and general quality are not here (FT-804).
    expect(find.text('Качество звука'), findsNothing);
    expect(find.byKey(const Key('player-sleep')), findsNothing);
  });

  testWidgets('uniform rows: icon 22 at left 24, height at least 48', (
    tester,
  ) async {
    await open(tester);

    final textLefts = <double>{};
    for (final item in items) {
      final row = tester.getRect(item);
      expect(row.height, greaterThanOrEqualTo(48));
      expect(row.left, 0);
      expect(row.right, 360);
      final icon = find.descendant(of: item, matching: find.byType(Icon));
      expect(icon, findsOneWidget);
      expect(tester.widget<Icon>(icon).size, 22);
      final glyph = tester.getRect(icon);
      expect(glyph.left, 24);
      expect(glyph.center.dy, moreOrLessEquals(row.center.dy, epsilon: 0.5));
      final label = find.descendant(of: item, matching: find.byType(Text));
      textLefts.add(tester.getRect(label.first).left);
      expect(tester.getRect(label.first).left - glyph.right, 16);
    }
    expect(textLefts.length, 1, reason: 'labels start on one line');
  });

  testWidgets('section title — muted, properly aligned with icons', (
    tester,
  ) async {
    await open(tester);

    for (final (head, word) in [
      (headSong, 'ПЕСНЯ'),
      (headGo, 'ПЕРЕЙТИ'),
      (headHelp, 'ПОМОЩЬ'),
    ]) {
      final label = find.descendant(of: head, matching: find.text(word));
      expect(label, findsOneWidget);
      expect(tester.getRect(label).left, 24);
      final style = tester.widget<Text>(label).style!;
      expect(style.color, ApertonoColors.textMuted);
    }
  });

  testWidgets('item closes sheet and performs its action', (tester) async {
    final (artists, _) = await open(tester);

    await tester.tap(toArtist);
    await tester.pumpAndSettle();

    expect(sheet, findsNothing);
    expect(artists, ['Linkin Park']);
  });

  testWidgets('«Dislike» from sheet is sent to server', (tester) async {
    final (_, sent) = await open(tester);
    expect(
      find.descendant(of: dislike, matching: find.text('Не нравится')),
      findsOneWidget,
    );

    await tester.tap(dislike);
    await tester.pumpAndSettle();

    expect(sheet, findsNothing);
    expect(sent, ['rating']);
  });

  testWidgets('«Report a problem» opens report sheet', (tester) async {
    await open(tester);

    await tester.tap(problem);
    await tester.pumpAndSettle();

    expect(sheet, findsNothing);
    expect(find.byKey(const Key('problem-send')), findsOneWidget);
  });

  testWidgets('podcast episode retains popup menu', (tester) async {
    await open(tester, track: episode);

    expect(sheet, findsNothing);
    expect(find.byType(PopupMenuItem<VoidCallback>), findsWidgets);
  });

  // FT-863: an episode has no artist, album or playlist — the music
  // transitions led into the music catalogue with the podcast's name.
  testWidgets('podcast episode menu has no music transitions', (tester) async {
    await open(tester, track: episode);

    expect(find.byType(PopupMenuItem<VoidCallback>), findsWidgets);
    expect(toArtist, findsNothing);
    expect(find.byKey(const Key('player-to-album')), findsNothing);
    expect(find.byKey(const Key('player-spoken-playlist')), findsNothing);
    expect(find.text('Добавить в плейлист'), findsNothing);
  });

  // FT-865: from an episode's player straight to its podcast page.
  testWidgets('podcast episode menu leads to the podcast', (tester) async {
    await open(tester, track: episode);

    await tester.tap(toPodcast);
    await tester.pumpAndSettle();

    expect(podcastsOpened, ['podcast:ep']);
  });

  testWidgets('a song has no "To podcast"', (tester) async {
    await open(tester);

    expect(toPodcast, findsNothing);
  });

  testWidgets('sheet fits on a small phone screen', (tester) async {
    await open(tester, size: const Size(360, 640));

    expect(tester.takeException(), isNull);
    expect(tester.getRect(sheet).top, greaterThanOrEqualTo(0));
    expect(tester.getRect(problem).bottom, lessThanOrEqualTo(640));
  });

  testWidgets('English phone reads sections in English', (tester) async {
    tester.platformDispatcher.localeTestValue = const Locale('en');
    tester.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.platformDispatcher.clearLocaleTestValue);
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    await open(tester);

    expect(
      find.descendant(of: headSong, matching: find.text('SONG')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: headGo, matching: find.text('GO TO')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: headHelp, matching: find.text('HELP')),
      findsOneWidget,
    );
  });
}
