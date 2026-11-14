import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_stream/lossless_once.dart';
import 'package:music_stream/models/track.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/player.dart';
import 'package:music_stream/ratings.dart';
import 'package:music_stream/screens/parts.dart';
import 'package:music_stream/screens/player_screen.dart';
import 'package:music_stream/server_ports.dart';
import 'package:music_stream/sleep_timer.dart';
import 'package:music_stream/theme.dart';
import 'package:music_stream/track_formats.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';
import 'fakes.dart';
import 'golden_support.dart';

/// FT-809: "This song lossless" — music player "three dots" sheet item
/// (owner 12.10: general quality in settings, but for a specific song —
/// option to pick lossless). Unknown in advance if the song has FLAC:
/// item honestly tries and, if failed, reports it.
void main() {
  setUpAll(loadAppFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const id = '00000000-0000-4000-8000-000000000001';
  const other = '00000000-0000-4000-8000-000000000002';
  const song = Track(
    id: id,
    title: 'Numb',
    artist: 'Linkin Park',
    durationMs: 187000,
    artworkUrl: '/v1/covers/lp-1',
  );
  const second = Track(
    id: other,
    title: 'Faint',
    artist: 'Linkin Park',
    durationMs: 162000,
    artworkUrl: '',
  );
  const episode = Track(
    id: 'podcast:ep',
    title: 'Episode',
    artist: 'Show',
    durationMs: 3600000,
    artworkUrl: '',
  );

  group('one-time flag sent to Play', () {
    Future<List<Map<String, dynamic>>> bodies(
      LosslessOnce once,
      Future<void> Function(HttpPlayback playback) act, {
      bool opus = false,
    }) async {
      final sent = <Map<String, dynamic>>[];
      final playback = HttpPlayback(
        'https://music.test',
        tokens: tokensFor('https://music.test'),
        client: MockClient((request) async {
          sent.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response(
            jsonEncode({'token': 't', 'state': 'ready', 'track': {}}),
            200,
          );
        }),
        preferOpus: () async => opus,
        preferLossless: () => false,
        losslessOnce: once,
      );
      await act(playback);
      return sent;
    }

    test('flagged song requests lossless even in saver mode', () async {
      final once = LosslessOnce()..ask(id);
      final sent = await bodies(once, (p) => p.start(id), opus: true);
      expect(sent.single['prefer'], 'lossless');
    });

    test('flag is one-time: next Play follows settings', () async {
      final once = LosslessOnce()..ask(id);
      final sent = await bodies(once, (p) async {
        await p.start(id);
        await p.start(id);
      }, opus: true);
      expect(sent[0]['prefer'], 'lossless');
      expect(sent[1]['prefer'], 'opus');
    });

    test('prebuffering next song does not consume flag', () async {
      final once = LosslessOnce()..ask(id);
      final sent = await bodies(once, (p) async {
        await p.start(id, prepare: true);
        await p.start(id);
      });
      expect(sent[0].containsKey('prefer'), isFalse);
      expect(sent[1]['prefer'], 'lossless');
    });

    test('other song does not receive or consume flag', () async {
      final once = LosslessOnce()..ask(id);
      final sent = await bodies(once, (p) async {
        await p.start(other);
        await p.start(id);
      });
      expect(sent[0].containsKey('prefer'), isFalse);
      expect(sent[1]['prefer'], 'lossless');
    });
  });

  test(
    'reloadCurrent: same song at same second position, queue remains intact',
    () async {
      final playback = FakePlayback();
      final audio = FakeAudio();
      addTearDown(audio.close);
      final player = Player(playback: playback, audio: audio);
      addTearDown(player.dispose);
      await player.playQueue([second, song, episode], start: 1);
      audio.emit(AudioPhase.playing);
      audio.position = const Duration(seconds: 42);

      await player.reloadCurrent();

      expect(playback.started, [id, id]);
      expect(audio.played.last.$2, const Duration(seconds: 42));
      expect(player.current?.id, id);
      expect(player.queueIndex, 1);
      expect([for (final t in player.queue) t.id], [other, id, 'podcast:ep']);
    },
  );

  group('sheet item', () {
    final menu = find.byKey(const Key('player-menu'));
    final sheet = find.byKey(const Key('player-menu-sheet'));
    final sound = find.byKey(const Key('player-menu-sound'));
    final item = find.byKey(const Key('player-lossless-once'));
    const missed = 'Без потерь для этой песни не нашлось';

    Future<({FakePlayback playback, LosslessOnce once, TrackFormats formats})>
    open(
      WidgetTester tester, {
      Track track = song,
      String? format = 'mp3',
      bool withOnce = true,
      List<Object> answers = const ['https://example.test/s/1'],
      bool english = false,
      bool hasSheet = true,
    }) async {
      usePhone(tester, const Size(360, 800));
      if (english) {
        tester.platformDispatcher.localeTestValue = const Locale('en');
        tester.platformDispatcher.localesTestValue = const [Locale('en')];
        addTearDown(tester.platformDispatcher.clearLocaleTestValue);
        addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      }
      final rig = Rig();
      rig.server.on('POST /v1/ratings/of', (_) => answer(200, {'ratings': {}}));
      addTearDown(rig.audio.close);
      final playback = FakePlayback(answers);
      final player = Player(playback: playback, audio: rig.audio);
      addTearDown(player.dispose);
      await player.playQueue([track]);
      rig.audio.emit(AudioPhase.playing);
      final sleep = SleepTimer(player: player);
      addTearDown(sleep.dispose);
      final formats = TrackFormats();
      if (format != null) {
        formats.note(track.id, {'format': format});
      }
      final once = LosslessOnce();
      final api = rig.server.api();
      final services = Services(
        server: api,
        search: rig.server.catalog().search,
        play: (tracks, index) {},
        prepare: (track) {},
        openArtist: (_) {},
        sleepTimer: sleep,
        ratings: RatingsStore(ServerRatingsPort(api)),
        formats: formats,
        losslessOnce: withOnce ? once : null,
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
      final hint = find.byKey(const Key('player-heart-hint'));
      if (hint.evaluate().isNotEmpty) {
        await tester.tap(hint, warnIfMissed: false);
        await tester.pumpAndSettle();
      }
      await tester.tap(menu);
      await tester.pumpAndSettle();
      expect(sheet, hasSheet ? findsOneWidget : findsNothing);
      return (playback: playback, once: once, formats: formats);
    }

    testWidgets('lossy song — item in «Sound» section', (tester) async {
      await open(tester);
      expect(sound, findsOneWidget);
      expect(item, findsOneWidget);
      expect(
        find.descendant(of: item, matching: find.text('Эту песню без потерь')),
        findsOneWidget,
      );
      // "Audio" section is between "Go to" and "Help".
      final go = tester.getTopLeft(find.byKey(const Key('player-menu-go'))).dy;
      final help = tester
          .getTopLeft(find.byKey(const Key('player-menu-help')))
          .dy;
      final y = tester.getTopLeft(sound).dy;
      expect(y, greaterThan(go));
      expect(y, lessThan(help));
      expect(tester.getTopLeft(item).dy, greaterThan(y));
      // Sheet with new section still fits on screen.
      expect(tester.getRect(sheet).top, greaterThanOrEqualTo(0));
      expect(tester.takeException(), isNull);
    });

    testWidgets('already lossless — item and section hidden', (tester) async {
      await open(tester, format: 'flac');
      expect(item, findsNothing);
      expect(sound, findsNothing);
    });

    testWidgets('unknown format — item hidden', (tester) async {
      await open(tester, format: null);
      expect(item, findsNothing);
      expect(sound, findsNothing);
    });

    testWidgets('no flag in app — item hidden', (tester) async {
      await open(tester, withOnce: false);
      expect(item, findsNothing);
    });

    testWidgets('podcast episode has no item', (tester) async {
      // Episode keeps old dropdown menu (FT-807): no bottom sheet at all.
      await open(tester, track: episode, hasSheet: false);
      expect(item, findsNothing);
    });

    testWidgets('tap action: set flag, restart Play, bottom sheet closed', (
      tester,
    ) async {
      final answerLater = Completer<String>();
      final opened = await open(
        tester,
        answers: ['https://example.test/s/1', answerLater],
      );
      await tester.tap(item);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(sheet, findsNothing);
      expect(opened.playback.started, [id, id]);
      // Mock does not read the flag — it must sit and wait for Play.
      expect(opened.once.take(id), isTrue);

      // Server found lossless: no message shown.
      opened.formats.note(id, {'format': 'flac'});
      answerLater.complete('https://example.test/s/2');
      await tester.pumpAndSettle();
      expect(find.text(missed), findsNothing);
    });

    testWidgets('lossless not found — message is shown', (tester) async {
      await open(tester);
      await tester.tap(item);
      await tester.pumpAndSettle();
      expect(find.text(missed), findsOneWidget);
    });

    testWidgets('English phone displays item in English', (tester) async {
      await open(tester, english: true);
      expect(
        find.descendant(
          of: item,
          matching: find.text('Play this song lossless'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: sound, matching: find.text('SOUND')),
        findsOneWidget,
      );
      await tester.tap(item);
      await tester.pumpAndSettle();
      expect(
        find.text('No lossless copy of this song was found'),
        findsOneWidget,
      );
    });
  });
}
