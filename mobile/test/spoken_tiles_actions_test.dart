import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/l10n/app_localizations.dart';
import 'package:music_stream/models/track.dart';
import 'package:music_stream/offline/download_queue.dart';
import 'package:music_stream/offline/track_store.dart';
import 'package:music_stream/playback_speed.dart';
import 'package:music_stream/player.dart';
import 'package:music_stream/podcast_downloads.dart';
import 'package:music_stream/screens/parts.dart';
import 'package:music_stream/screens/player_screen.dart';
import 'package:music_stream/screens/sleep_timer_sheet.dart';
import 'package:music_stream/sleep_timer.dart';

import 'fake_server.dart';
import 'fakes.dart';

class _DummyStore implements EpisodeStore {
  @override
  File partFile(String id, {required String format}) => File('/tmp/$id.part');

  @override
  Future<File> commit(
    String id, {
    required String format,
    required Hold hold,
  }) => Future.value(File('/tmp/$id'));

  @override
  Future<File?> fileFor(String id) => Future.value(null);

  @override
  Future<void> remove(String id) => Future.value();

  @override
  Future<bool> roomForDownload() => Future.value(true);
}

class _DummyTransfer implements FileTransfer {
  @override
  Future<bool> fetch(TransferJob job) => Future.value(true);

  @override
  Future<void> cancel(String trackId) => Future.value();
}

class _FakePodcastDownloads extends PodcastDownloads {
  _FakePodcastDownloads({this.states = const {}})
    : super(
        store: _DummyStore(),
        transfer: _DummyTransfer(),
        isMetered: () async => false,
        allowMobile: () async => true,
      );

  final Map<String, EpisodeDownloadState> states;
  final List<String> downloaded = [];

  @override
  EpisodeDownloadState stateOf(String feedUrl, [String? guid]) {
    final id = guid == null ? feedUrl : PodcastDownloads.idFor(feedUrl, guid);
    return states[id] ?? super.stateOf(feedUrl, guid);
  }

  @override
  Future<EpisodeDownloadResult> downloadEpisode(String trackId) async {
    downloaded.add(trackId);
    return EpisodeDownloadResult.started;
  }
}

void main() {
  const episode = Track(
    id: 'podcast:ep',
    title: 'Episode 42',
    artist: 'Podcast Show',
    durationMs: 3600000,
    artworkUrl: '',
  );

  Services createServices({
    PlaybackSpeed? speed,
    SleepTimer? sleepTimer,
    PodcastDownloads? podcastDownloads,
  }) {
    final server = FakeServer();
    return Services(
      server: server.api(),
      search: server.catalog().search,
      play: (_, _) {},
      prepare: (_) {},
      speed: speed,
      sleepTimer: sleepTimer,
      podcastDownloads: podcastDownloads,
    );
  }

  Future<Player> pumpPlayer(
    WidgetTester tester, {
    Services? services,
    Track current = episode,
    List<Track>? queue,
  }) async {
    final audio = FakeAudio();
    addTearDown(audio.close);
    final player = Player(
      playback: FakePlayback(List.filled(10, 'https://example.test/s/1')),
      audio: audio,
    );
    addTearDown(player.dispose);
    final fullQueue = queue ?? [current];
    await player.playQueue(fullQueue);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PlayerScreen(player: player, services: services),
        ),
      ),
    );
    await tester.pump();
    return player;
  }

  Finder tile(String key) => find.byKey(ValueKey(key));

  group('speed tile', () {
    testWidgets('no action on tile without services.speed', (tester) async {
      final handle = tester.ensureSemantics();
      try {
        final services = createServices(speed: null);
        await pumpPlayer(tester, services: services);

        final speedTile = tile('spoken-speed');
        expect(speedTile, findsOneWidget);
        expect(
          tester.getSemantics(speedTile),
          isSemantics(isButton: true, hasEnabledState: true, isEnabled: false),
        );
      } finally {
        handle.dispose();
      }
    });

    testWidgets('shows speed and changes it on tap', (tester) async {
      final audio = FakeAudio();
      addTearDown(audio.close);
      final player = Player(
        playback: FakePlayback(List.filled(10, 'https://example.test/s/1')),
        audio: audio,
      );
      addTearDown(player.dispose);

      double current = 1.0;
      final saved = <double>[];
      final speed = PlaybackSpeed(
        player,
        audio,
        speedFor: (_) => current,
        save: (_, v) async {
          current = v;
          saved.add(v);
        },
      );
      addTearDown(speed.dispose);

      final services = createServices(speed: speed);
      await player.select(episode);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: PlayerScreen(player: player, services: services),
          ),
        ),
      );
      await tester.pump();

      // Current speed "1x" displayed
      expect(
        find.descendant(of: tile('spoken-speed'), matching: find.text('1×')),
        findsOneWidget,
      );

      // Tap speed tile
      await tester.tap(tile('spoken-speed'));
      await tester.pumpAndSettle();

      // Speed selection menu opened
      final option15 = find.byKey(const ValueKey('speed-1.5'));
      expect(option15, findsOneWidget);

      // Select 1.5x
      await tester.tap(option15);
      await tester.pumpAndSettle();

      expect(saved, contains(1.5));
    });
  });

  group('sleep timer tile', () {
    testWidgets('no action without services.sleepTimer', (tester) async {
      final handle = tester.ensureSemantics();
      try {
        final services = createServices(sleepTimer: null);
        await pumpPlayer(tester, services: services);

        final sleepTile = tile('spoken-sleep');
        expect(sleepTile, findsOneWidget);
        expect(
          tester.getSemantics(sleepTile),
          isSemantics(isButton: true, hasEnabledState: true, isEnabled: false),
        );
      } finally {
        handle.dispose();
      }
    });

    testWidgets('tap opens SleepTimerSheet', (tester) async {
      final audio = FakeAudio();
      addTearDown(audio.close);
      final player = Player(
        playback: FakePlayback(List.filled(10, 'https://example.test/s/1')),
        audio: audio,
      );
      addTearDown(player.dispose);
      final sleepTimer = SleepTimer(player: player);
      addTearDown(sleepTimer.dispose);

      final services = createServices(sleepTimer: sleepTimer);
      await pumpPlayer(tester, services: services);

      await tester.tap(tile('spoken-sleep'));
      await tester.pumpAndSettle();

      expect(find.byType(SleepTimerSheet), findsOneWidget);
    });

    testWidgets('active sleep timer highlights tile', (tester) async {
      final handle = tester.ensureSemantics();
      try {
        final audio = FakeAudio();
        addTearDown(audio.close);
        final player = Player(
          playback: FakePlayback(List.filled(10, 'https://example.test/s/1')),
          audio: audio,
        );
        addTearDown(player.dispose);
        final sleepTimer = SleepTimer(player: player);
        addTearDown(sleepTimer.dispose);

        final services = createServices(sleepTimer: sleepTimer);
        await pumpPlayer(tester, services: services);

        expect(
          tester.getSemantics(tile('spoken-sleep')),
          isSemantics(isButton: true, isSelected: false),
        );

        sleepTimer.untilEndOfTrack();
        await tester.pump();

        expect(
          tester.getSemantics(tile('spoken-sleep')),
          isSemantics(isButton: true, isSelected: true),
        );
      } finally {
        handle.dispose();
      }
    });
  });

  group('download tile', () {
    testWidgets('no action without services.podcastDownloads', (tester) async {
      final handle = tester.ensureSemantics();
      try {
        final services = createServices(podcastDownloads: null);
        await pumpPlayer(tester, services: services);

        final dlTile = tile('spoken-download');
        expect(dlTile, findsOneWidget);
        expect(
          tester.getSemantics(dlTile),
          isSemantics(isButton: true, hasEnabledState: true, isEnabled: false),
        );
      } finally {
        handle.dispose();
      }
    });

    testWidgets('tap starts episode download', (tester) async {
      final downloads = _FakePodcastDownloads();
      final services = createServices(podcastDownloads: downloads);
      await pumpPlayer(tester, services: services);

      await tester.tap(tile('spoken-download'));
      await tester.pump();

      expect(downloads.downloaded, contains(episode.id));
    });

    testWidgets('downloading state shows icon and cannot be tapped again', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      try {
        final downloads = _FakePodcastDownloads(
          states: {episode.id: EpisodeDownloadState.downloading},
        );
        final services = createServices(podcastDownloads: downloads);
        await pumpPlayer(tester, services: services);

        final dlTile = tile('spoken-download');
        expect(
          find.descendant(of: dlTile, matching: find.byIcon(Icons.downloading)),
          findsOneWidget,
        );
        expect(
          tester.getSemantics(dlTile),
          isSemantics(isButton: true, hasEnabledState: true, isEnabled: false),
        );
      } finally {
        handle.dispose();
      }
    });

    testWidgets('onPhone state shows Downloaded and is selected', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      try {
        final downloads = _FakePodcastDownloads(
          states: {episode.id: EpisodeDownloadState.onPhone},
        );
        final services = createServices(podcastDownloads: downloads);
        await pumpPlayer(tester, services: services);

        final dlTile = tile('spoken-download');
        expect(
          find.descendant(of: dlTile, matching: find.text('Downloaded')),
          findsOneWidget,
        );
        expect(
          tester.getSemantics(dlTile),
          isSemantics(isButton: true, isSelected: true),
        );
      } finally {
        handle.dispose();
      }
    });
  });

  group('queue tile', () {
    testWidgets('tap scrolls screen to queue', (tester) async {
      final queue = List.generate(
        15,
        (i) => Track(
          id: 'podcast:ep$i',
          title: 'Episode $i',
          artist: 'Show',
          durationMs: 3600000,
          artworkUrl: '',
        ),
      );
      await pumpPlayer(tester, current: queue.first, queue: queue);

      final scrollable = find.byType(Scrollable);
      final initialOffset = tester
          .state<ScrollableState>(scrollable)
          .position
          .pixels;
      expect(initialOffset, equals(0.0));

      await tester.tap(tile('spoken-queue'));
      await tester.pumpAndSettle();

      final newOffset = tester
          .state<ScrollableState>(scrollable)
          .position
          .pixels;
      expect(newOffset, greaterThan(initialOffset));
    });
  });
}
