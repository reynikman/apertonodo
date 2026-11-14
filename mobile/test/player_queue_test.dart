import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/app.dart';
import 'package:music_stream/models/track.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/player.dart';
import 'package:music_stream/screens/parts.dart';
import 'package:music_stream/screens/player_screen.dart';

import 'fake_server.dart';
import 'fakes.dart';

Track song(int n) => Track(
  id: '00000000-0000-4000-8000-00000000000$n',
  title: 'Song $n',
  artist: 'Band',
  durationMs: 200000,
  artworkUrl: '',
);

final album = [song(1), song(2), song(3)];

/// Player where current track is already playing.
Future<(Player, FakePlayback, FakeAudio)> playing({
  int start = 0,
  Random? random,
}) async {
  final playback = FakePlayback();
  final audio = FakeAudio();
  final player = Player(playback: playback, audio: audio, random: random);
  await player.playQueue(album, start: start);
  audio.emit(AudioPhase.playing);
  await settle();
  return (player, playback, audio);
}

void main() {
  _firstResult();

  group('queue', () {
    test('play album from song — «next» moves down it', () async {
      final (player, playback, _) = await playing(start: 1);
      expect(player.current, album[1]);
      expect(player.queueIndex, 1);

      await player.next();

      expect(player.current, album[2]);
      expect(playback.started, [album[1].id, album[2].id]);
    });

    test('at queue end without repeat «next» does nothing', () async {
      final (player, playback, _) = await playing(start: 2);
      expect(player.hasNext, isFalse);

      await player.next();

      expect(player.current, album[2]);
      expect(playback.started, [album[2].id]);
    });

    test('song finished — next one starts', () async {
      final (player, playback, audio) = await playing();

      audio.finish();
      await settle();

      expect(player.current, album[1]);
      expect(playback.started, [album[0].id, album[1].id]);
    });

    test('last song finished — silence, not new song', () async {
      final (player, playback, audio) = await playing(start: 2);

      audio.finish();
      await settle();

      expect(player.phase, AudioPhase.idle);
      expect(playback.started, [album[2].id]);
    });

    test('«prev» from mid-song — to its start', () async {
      final (player, playback, audio) = await playing(start: 1);
      audio.position = const Duration(seconds: 40);

      await player.previous();

      expect(audio.seeks, [Duration.zero]);
      expect(player.current, album[1]);
      expect(playback.started, [album[1].id, album[2].id]);
    });

    test('«prev» from song start — to previous', () async {
      final (player, playback, audio) = await playing(start: 1);
      audio.position = const Duration(seconds: 1);

      await player.previous();

      expect(player.current, album[0]);
      expect(playback.started, [album[1].id, album[2].id, album[0].id]);
    });

    test('«prev» on first song — to its start', () async {
      final (player, playback, audio) = await playing();

      await player.previous();

      expect(audio.seeks, [Duration.zero]);
      expect(playback.started, [album[0].id, album[1].id]);
    });

    test('queue song on tap', () async {
      final (player, playback, _) = await playing();

      await player.jump(2);

      expect(player.current, album[2]);
      expect(player.queueIndex, 2);
    });

    test('seek is sent to player', () async {
      final (player, _, audio) = await playing();

      await player.seek(const Duration(seconds: 90));

      expect(audio.seeks, [const Duration(seconds: 90)]);
    });
  });

  group('repeat', () {
    test('off → queue → song → off', () async {
      final (player, _, _) = await playing();
      expect(player.repeat, Repeat.off);
      player.cycleRepeat();
      expect(player.repeat, Repeat.all);
      player.cycleRepeat();
      expect(player.repeat, Repeat.one);
      player.cycleRepeat();
      expect(player.repeat, Repeat.off);
    });

    test('queue repeat: after last — first', () async {
      final (player, playback, audio) = await playing(start: 2);
      player.cycleRepeat();

      audio.finish();
      await settle();

      expect(player.current, album[0]);
      expect(playback.started, [album[2].id, album[0].id]);
    });

    test(
      'song repeat: finished — restarts from start without new server request',
      () async {
        final (player, playback, audio) = await playing();
        player
          ..cycleRepeat()
          ..cycleRepeat();
        final resumes = audio.resumes;

        audio.finish();
        await settle();

        expect(player.current, album[0]);
        expect(audio.seeks, [Duration.zero]);
        expect(audio.resumes, resumes + 1);
        expect(playback.started, [album[0].id, album[1].id]);
      },
    );
  });

  group('shuffle', () {
    test('current stays, rest — all and once each', () async {
      final (player, _, _) = await playing(start: 1, random: Random(7));

      player.toggleShuffle();

      expect(player.shuffle, isTrue);
      expect(player.queueIndex, 0);
      expect(player.queue.first, album[1]);
      expect(player.queue.toSet(), album.toSet());
      expect(player.current, album[1]);
    });

    test('turn off — original order, from current song', () async {
      final (player, _, _) = await playing(start: 1, random: Random(7));
      player
        ..toggleShuffle()
        ..toggleShuffle();

      expect(player.queue, album);
      expect(player.queueIndex, 1);
    });

    test('when shuffled «next» follows new order', () async {
      final (player, _, _) = await playing(random: Random(7));
      player.toggleShuffle();
      final order = player.queue;

      await player.next();

      expect(player.current, order[1]);
    });
  });

  group('next is prepared in advance', () {
    test('while song plays, server prepares next', () async {
      final (_, playback, _) = await playing();

      expect(playback.prepared, [album[1].id]);
    });

    test('ready next plays without second server request', () async {
      final playback = FakePlayback()..onPrepare = (id) => 'https://x/$id';
      final audio = FakeAudio();
      final player = Player(playback: playback, audio: audio);
      await player.playQueue(album);
      audio.emit(AudioPhase.playing);
      await settle();

      audio.finish();
      await settle();

      expect(playback.started, [album[0].id]);
      expect(audio.played.last.$1, 'https://x/${album[1].id}');
    });

    test(
      'downloaded after prefetch plays from device, not remote URL',
      () async {
        final playback = FakePlayback(['file:///music/2.opus'])
          ..onPrepare = (id) => 'https://x/$id';
        final audio = FakeAudio();
        final player = Player(playback: playback, audio: audio);
        await player.playQueue(album);
        audio.emit(AudioPhase.playing);
        await settle();
        playback.local.add(album[1].id);

        audio.finish();
        await settle();

        expect(playback.started, [album[0].id, album[1].id]);
        expect(audio.played.last.$1, 'file:///music/2.opus');
      },
    );

    test('not prepared — fetched regular way', () async {
      final (_, playback, audio) = await playing();

      audio.finish();
      await settle();

      expect(playback.started, [album[0].id, album[1].id]);
      expect(audio.played, hasLength(2));
    });

    test('last queue song prepares nothing', () async {
      final (_, playback, _) = await playing(start: 2);

      expect(playback.prepared, isEmpty);
    });
  });

  group('system buttons', () {
    test('«next» from sheet calls queue', () async {
      final (player, _, audio) = await playing();

      await audio.skipNext!();

      expect(player.current, album[1]);
    });

    test('no «next» button on last song', () async {
      final (_, _, audio) = await playing(start: 2);

      expect(audio.skipNext, isNull);
      expect(audio.skipPrevious, isNotNull);
    });

    test('enabled queue repeat — «next» appeared', () async {
      final (player, _, audio) = await playing(start: 2);

      player.cycleRepeat();

      expect(audio.skipNext, isNotNull);
    });
  });

  testWidgets('search becomes queue: «next» on active player screen', (
    tester,
  ) async {
    final playback = FakePlayback();
    final audio = FakeAudio();
    addTearDown(audio.close);
    await tester.pumpWidget(
      MusicApp(catalog: album, playback: playback, audio: audio),
    );
    await tester.enterText(find.byKey(const Key('search-field')), 'band');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.tap(find.text('Song 1').first);
    await tester.pump();
    audio.emit(AudioPhase.playing);
    await tester.pump();

    await tester.tap(find.byKey(const Key('mini-player')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('seek-bar')), findsOneWidget);
    await tester.tap(find.byKey(const Key('next-button')));
    await tester.pump();

    expect(playback.started, [album[0].id, album[1].id]);
    expect(find.byKey(const Key('player-title')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('player-title'))).data,
      'Song 2',
    );
  });

  testWidgets('player opens on cover even when 20th song plays', (
    tester,
  ) async {
    // Rule G55 previously said "open queue at playing track". Since phase M
    // header and queue are a single list, and this pushed cover above screen
    // top: on device player opened with cover and title scrolled out of view.
    final songs = [
      for (var n = 1; n <= 30; n++)
        Track(
          id: 't$n',
          title: 'Song $n',
          artist: 'Band',
          durationMs: 200000,
          artworkUrl: '',
        ),
    ];
    final player = Player();
    addTearDown(player.dispose);
    await player.playQueue(songs, start: 19);

    await tester.pumpWidget(MaterialApp(home: PlayerScreen(player: player)));
    await tester.pump();
    await tester.pump();

    final title = find.byKey(const Key('player-title'));
    expect(title, findsOneWidget);
    expect(tester.getTopLeft(title).dy, greaterThanOrEqualTo(0));
    expect(tester.widget<Text>(title).data, 'Song 20');
  });

  testWidgets('another album from the same row — scrolls too', (tester) async {
    List<Track> album(String name) => [
      for (var n = 1; n <= 30; n++)
        Track(
          id: '$name$n',
          title: '$name Song $n',
          artist: 'Band',
          durationMs: 200000,
          artworkUrl: '',
        ),
    ];
    final player = Player();
    addTearDown(player.dispose);
    await player.playQueue(album('A'), start: 19);

    await tester.pumpWidget(MaterialApp(home: PlayerScreen(player: player)));
    await tester.pump();

    // User scrolled down to queue and looks at top rows. Currently playing
    // 20th track is not in view — scrolling must bring it back into view.
    await tester.drag(find.byKey(const Key('queue')), const Offset(0, -700));
    await tester.pumpAndSettle();
    expect(find.text('B Song 20'), findsNothing);

    await player.playQueue(album('B'), start: 19);
    await tester.pump();
    await tester.pump();

    expect(
      find.descendant(
        of: find.byKey(const Key('queue')),
        matching: find.text('B Song 20'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('song duration is visible in queue', (tester) async {
    final songs = [
      Track(
        id: 't1',
        title: 'Song 1',
        artist: 'Band',
        durationMs: 200000,
        artworkUrl: '',
      ),
      Track(
        id: 't2',
        title: 'Song 2',
        artist: 'Band',
        durationMs: 0,
        artworkUrl: '',
      ),
    ];
    final player = Player();
    addTearDown(player.dispose);
    await player.playQueue(songs);

    await tester.pumpWidget(MaterialApp(home: PlayerScreen(player: player)));
    await tester.pump();

    // Duration is in dedicated column on right (dump, FT-489); missing duration —
    // duration hidden, artist stays.
    final first = find.byKey(const Key('queue-row-0'));
    final second = find.byKey(const Key('queue-row-1'));
    expect(
      find.descendant(of: first, matching: find.text('3:20')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: first, matching: find.text('Band')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: second, matching: find.text('Band')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: second, matching: find.textContaining(':')),
      findsNothing,
    );
  });

  testWidgets('heart icon on player screen toggles on and off properly', (
    tester,
  ) async {
    final player = Player();
    addTearDown(player.dispose);
    await player.playQueue([song(1)]);
    final rig = Rig();
    await rig.screen(
      tester,
      (services) => PlayerScreen(player: player, services: services),
    );

    final heart = find.byKey(const Key('player-heart'));
    expect(tester.widget<IconButton>(heart).isSelected, isFalse);

    await tapAndSettle(tester, heart);
    expect(tester.widget<IconButton>(heart).isSelected, isTrue);

    await tapAndSettle(tester, heart);
    expect(tester.widget<IconButton>(heart).isSelected, isFalse);
  });

  testWidgets('repainting same song does not re-query favorites', (
    tester,
  ) async {
    final player = Player();
    addTearDown(player.dispose);
    await player.playQueue(album);
    final rig = Rig();
    await rig.screen(
      tester,
      (services) => PlayerScreen(player: player, services: services),
    );
    expect(rig.server.calls('POST /v1/favorites/contains'), hasLength(1));

    // Buffering, playing, paused — player notifies, track remains the same.
    player.cycleRepeat();
    await tester.pump();
    player.cycleRepeat();
    await tester.pump();
    player.cycleRepeat();
    await tester.pump();

    expect(rig.server.calls('POST /v1/favorites/contains'), hasLength(1));
  });

  testWidgets('mini player shows cover', (tester) async {
    await _miniPlayer(tester, artworkUrl: '/v1/covers/abc');

    expect(
      find.descendant(
        of: find.byKey(const Key('mini-player')),
        matching: find.byType(Cover),
      ),
      findsOneWidget,
    );
  });

  testWidgets('player screen shows cover when server is passed', (
    tester,
  ) async {
    final player = Player();
    addTearDown(player.dispose);
    await player.playQueue([song(1).withArtwork('/v1/covers/abc')]);
    await Rig().screen(
      tester,
      (services) => PlayerScreen(player: player, services: services),
    );

    // Large cover is dedicated; small queue row thumbnail does not count.
    expect(
      find.descendant(
        of: find.byKey(const Key('player-cover')),
        matching: find.byType(Cover),
      ),
      findsOneWidget,
    );
  });

  testWidgets('song without cover — renders letter box, not crash', (
    tester,
  ) async {
    await _miniPlayer(tester, artworkUrl: '');
    expect(tester.takeException(), isNull);
    expect(
      find.descendant(
        of: find.byKey(const Key('mini-player')),
        matching: find.byType(ArtistSquare),
      ),
      findsOneWidget,
    );

    final player = Player();
    addTearDown(player.dispose);
    await player.playQueue([song(1)]);
    await Rig().screen(
      tester,
      (services) => PlayerScreen(player: player, services: services),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(ArtistSquare), findsWidgets);
  });

  testWidgets('cover on 360×640 does not overflow player', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final player = Player();
    addTearDown(player.dispose);
    await player.playQueue(album);
    await Rig().screen(
      tester,
      (services) => PlayerScreen(player: player, services: services),
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets('cover on 640×360 does not overflow player', (tester) async {
    tester.view.physicalSize = const Size(640, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final player = Player();
    addTearDown(player.dispose);
    await player.playQueue(album);
    await Rig().screen(
      tester,
      (services) => PlayerScreen(player: player, services: services),
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets('cover on 640×360 with 1.3 font does not overflow player', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final player = Player();
    addTearDown(player.dispose);
    await player.playQueue(album);
    await Rig().screen(
      tester,
      (services) => Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.3)),
          child: PlayerScreen(player: player, services: services),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets('cover on 640×320 with 1.6 font does not overflow player', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final player = Player();
    addTearDown(player.dispose);
    await player.playQueue(album);
    await Rig().screen(
      tester,
      (services) => Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.6)),
          child: PlayerScreen(player: player, services: services),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets('player screen has own pause, distinct from mini player', (
    tester,
  ) async {
    final audio = FakeAudio();
    addTearDown(audio.close);
    final player = Player(playback: FakePlayback(), audio: audio);
    addTearDown(player.dispose);
    await player.playQueue([song(1)]);
    audio.emit(AudioPhase.playing);

    await tester.pumpWidget(MaterialApp(home: PlayerScreen(player: player)));
    // `settle()` from fakes.dart hangs test here: it waits for real time,
    // but testWidgets has its own clock. Phase event is delivered by pump.
    await tester.pump();

    // Count from current: starting track calls pause() so previous track
    // stops immediately — counter is already non-zero by this point.
    final before = audio.pauses;
    // Custom key: mini player has `pause-button`, and both are visible simultaneously.
    await tester.tap(find.byKey(const Key('player-pause-button')));
    await tester.pump();

    expect(audio.pauses, before + 1);
  });
}

Future<void> _miniPlayer(
  WidgetTester tester, {
  required String artworkUrl,
}) async {
  final audio = FakeAudio();
  addTearDown(audio.close);
  await tester.pumpWidget(
    MusicApp(
      catalog: [
        Track(
          id: '1',
          title: 'Duality',
          artist: 'Slipknot',
          durationMs: 252000,
          artworkUrl: artworkUrl,
        ),
      ],
      playback: FakePlayback(),
      audio: audio,
      server: FakeServer().api(),
    ),
  );
  await tester.pumpAndSettle();
  await typeSearch(tester, 'duality');
  await tester.tap(find.text('Duality').first);
  await tester.pump();
}

void _firstResult() {
  testWidgets('the first result song is prepared while the person reads', (
    tester,
  ) async {
    final playback = FakePlayback()..onPrepare = (id) => 'https://x/$id';
    final audio = FakeAudio();
    addTearDown(audio.close);
    await tester.pumpWidget(
      MusicApp(catalog: album, playback: playback, audio: audio),
    );
    await tester.enterText(find.byKey(const Key('search-field')), 'band');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();

    expect(playback.prepared, [album[0].id]);
    expect(playback.started, isEmpty, reason: 'search plays nothing itself');

    await tester.tap(find.text('Song 1').first);
    await tester.pump();

    expect(playback.started, isEmpty, reason: 'ready song requested again');
    expect(audio.played.single.$1, 'https://x/${album[0].id}');
  });
}
