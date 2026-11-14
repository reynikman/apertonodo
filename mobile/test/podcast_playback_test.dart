import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/player.dart';
import 'package:music_stream/podcast_progress.dart';
import 'package:music_stream/screens/player_screen.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/podcast_client.dart';
import 'package:music_stream/models/track.dart';
import 'package:music_stream/podcast_playback.dart';

import 'fakes.dart';

class MemoryBox implements PodcastProgressBox {
  String? data;

  @override
  Future<String?> read() async => data;

  @override
  Future<void> write(String value) async => data = value;
}

class FakeInner implements PlaybackPort {
  final started = <String>[];
  final failedUrls = <String>[];

  /// Storage contents: tracks and downloaded episodes (FT-733).
  final local = <String>{'t1'};

  @override
  Future<String> start(String trackId, {bool prepare = false}) async {
    started.add(trackId);
    return 'https://server.example/v1/stream/$trackId';
  }

  @override
  Future<bool> isLocal(String trackId) async => local.contains(trackId);

  @override
  Future<void> failed(String url) async => failedUrls.add(url);
}

const podcast = FoundPodcast(
  feedUrl: 'https://feed.example/rss',
  title: 'Подкаст',
  author: 'Автор',
  image: 'https://feed.example/cover.jpg',
);

const episode = PodcastEpisode(
  guid: 'g1',
  title: 'Выпуск',
  audioUrl: 'https://cdn.example/ep1.mp3',
  durationMs: 61000,
);

void main() {
  test('episode plays via author link, server is not queried', () async {
    final inner = FakeInner();
    final playback = PodcastPlayback(inner);
    final track = playback.play(podcast, episode);
    expect(PodcastPlayback.isPodcast(track.id), isTrue);
    expect(track.title, 'Выпуск');
    expect(track.artist, 'Подкаст');
    expect(track.durationMs, 61000);
    expect(track.artworkUrl, 'https://feed.example/cover.jpg');
    expect(await playback.start(track.id), 'https://cdn.example/ep1.mp3');
    expect(
      await playback.start(track.id, prepare: true),
      'https://cdn.example/ep1.mp3',
    );
    expect(inner.started, isEmpty);
    expect(await playback.isLocal(track.id), isFalse);
  });

  test('song goes to server as before', () async {
    final inner = FakeInner();
    final playback = PodcastPlayback(inner);
    expect(await playback.start('t1'), 'https://server.example/v1/stream/t1');
    expect(inner.started, ['t1']);
    expect(await playback.isLocal('t1'), isTrue);
    await playback.failed('https://server.example/v1/stream/t1');
    expect(inner.failedUrls, ['https://server.example/v1/stream/t1']);
  });

  test('downloaded episode plays from file, not link (FT-733)', () async {
    final inner = FakeInner();
    final playback = PodcastPlayback(inner);
    final track = playback.play(podcast, episode);
    inner.local.add(track.id);
    expect(await playback.isLocal(track.id), isTrue);
    expect(
      await playback.start(track.id),
      'https://server.example/v1/stream/${track.id}',
    );
    expect(inner.started, [track.id]);
  });

  test(
    'downloaded episode plays after restart without in-memory URL',
    () async {
      final inner = FakeInner();
      final id = PodcastPlayback(inner).play(podcast, episode).id;
      inner.local.add(id);
      final fresh = PodcastPlayback(inner);
      expect(await fresh.start(id), 'https://server.example/v1/stream/$id');
    },
  );

  test('episode without in-memory URL: clean failure, not server', () async {
    final inner = FakeInner();
    final playback = PodcastPlayback(inner);
    await expectLater(
      playback.start('podcast:unknown'),
      throwsA(
        isA<PlaybackFailed>().having(
          (e) => e.reason,
          'reason',
          PlayFailure.unknownTrack,
        ),
      ),
    );
    expect(inner.started, isEmpty);
  });

  test('author link failure is not reported to server', () async {
    final inner = FakeInner();
    final playback = PodcastPlayback(inner)..play(podcast, episode);
    await playback.failed('https://cdn.example/ep1.mp3');
    expect(inner.failedUrls, isEmpty);
  });

  test('same episode gets same id, different get different', () {
    final playback = PodcastPlayback(FakeInner());
    final a = playback.play(podcast, episode);
    final b = playback.play(podcast, episode);
    final c = playback.play(
      podcast,
      const PodcastEpisode(
        guid: 'g2',
        title: 'Другой',
        audioUrl: 'https://cdn.example/ep2.mp3',
      ),
    );
    expect(a.id, b.id);
    expect(a.id, isNot(c.id));
  });

  test('episode artwork takes precedence over podcast artwork', () {
    final track = PodcastPlayback(FakeInner()).play(
      podcast,
      const PodcastEpisode(
        guid: 'g3',
        title: 'С обложкой',
        audioUrl: 'https://cdn.example/ep3.mp3',
        image: 'https://cdn.example/ep3.jpg',
      ),
    );
    expect(track.artworkUrl, 'https://cdn.example/ep3.jpg');
  });

  test('song with similar starting id still goes to server', () async {
    final inner = FakeInner();
    expect(PodcastPlayback.isPodcast('podcastx'), isFalse);
    await PodcastPlayback(inner).start('podcastx');
    expect(inner.started, ['podcastx']);
  });

  group('Listen and episode position', () {
    late FakeAudio audio;
    late Player player;
    late PodcastPlayback playback;
    late PodcastProgressStore progress;
    final key = podcastEpisodeKey(podcast.feedUrl, episode.guid);

    setUp(() async {
      audio = FakeAudio();
      playback = PodcastPlayback(FakeInner());
      player = Player(playback: playback, audio: audio);
      progress = PodcastProgressStore(MemoryBox());
      await progress.restore();
    });

    tearDown(() async {
      player.dispose();
      progress.dispose();
      await audio.close();
    });

    test('new episode: starts from beginning', () async {
      await playback.listen(player, progress, podcast, episode);
      expect(audio.played, [('https://cdn.example/ep1.mp3', Duration.zero)]);
    });

    test('partially heard: resumes from position minus 3 seconds', () async {
      await progress.report(key, 42000, durationMs: 61000, force: true);
      await playback.listen(player, progress, podcast, episode);
      expect(audio.played, [
        ('https://cdn.example/ep1.mp3', const Duration(seconds: 39)),
      ]);
    });

    test('position loading from disk: waits for it instead of zero', () async {
      final box = MemoryBox();
      final first = PodcastProgressStore(box);
      await first.restore();
      await first.report(key, 42000, durationMs: 61000, force: true);
      await first.flush();
      first.dispose();
      final cold = PodcastProgressStore(box);
      addTearDown(cold.dispose);
      await playback.listen(player, cold, podcast, episode);
      expect(audio.played.single.$2, const Duration(seconds: 39));
    });

    test('song interrupted by episode goes to history', () async {
      final heard = <String>[];
      final withHistory = Player(
        playback: playback,
        audio: audio,
        listened: (id, ms, {artworkUrl = ''}) async => heard.add(id),
      );
      addTearDown(withHistory.dispose);
      await withHistory.select(
        const Track(
          id: 't1',
          title: 'Song',
          artist: 'Band',
          durationMs: 200000,
          artworkUrl: '',
        ),
      );
      audio.emit(AudioPhase.playing);
      await Future<void>.delayed(Duration.zero);
      audio.tick(const Duration(seconds: 20));
      await Future<void>.delayed(const Duration(milliseconds: 1));
      await progress.report(key, 42000, durationMs: 61000, force: true);
      await playback.listen(withHistory, progress, podcast, episode);
      expect(heard, ['t1']);
      expect(audio.played.last.$2, const Duration(seconds: 39));
    });

    test('completed episode: starts from beginning again', () async {
      await progress.report(key, 42000, durationMs: 61000, force: true);
      await progress.markDone(key);
      await playback.listen(player, progress, podcast, episode);
      expect(audio.played, [('https://cdn.example/ep1.mp3', Duration.zero)]);
    });

    test('second tap while playing does not restart', () async {
      await progress.report(key, 42000, durationMs: 61000, force: true);
      await playback.listen(player, progress, podcast, episode);
      audio.emit(AudioPhase.playing);
      await Future<void>.delayed(Duration.zero);
      await playback.listen(player, progress, podcast, episode);
      expect(audio.played, hasLength(1));
    });

    test('other episode while playing plays other episode', () async {
      await playback.listen(player, progress, podcast, episode);
      audio.emit(AudioPhase.playing);
      await Future<void>.delayed(Duration.zero);
      await playback.listen(
        player,
        progress,
        podcast,
        const PodcastEpisode(
          guid: 'g2',
          title: 'Другой',
          audioUrl: 'https://cdn.example/ep2.mp3',
        ),
      );
      expect(audio.played.last.$1, 'https://cdn.example/ep2.mp3');
    });
  });

  test('playing episode position is remembered, song is not', () async {
    final audio = FakeAudio();
    final playback = PodcastPlayback(FakeInner());
    final player = Player(playback: playback, audio: audio);
    final progress = PodcastProgressStore(MemoryBox());
    await progress.restore();
    addTearDown(() async {
      player.dispose();
      progress.dispose();
      await audio.close();
    });
    await player.select(
      const Track(
        id: 't1',
        title: 'S',
        artist: 'B',
        durationMs: 1,
        artworkUrl: '',
      ),
    );
    expect(
      playback.remember(player, progress, const Duration(seconds: 9)),
      isFalse,
    );
    await player.select(playback.play(podcast, episode));
    expect(
      playback.remember(player, progress, const Duration(seconds: 33)),
      isTrue,
    );
    await Future<void>.delayed(Duration.zero);
    expect(
      progress.of(podcastEpisodeKey(podcast.feedUrl, episode.guid))?.positionMs,
      33000,
    );
  });

  group('player screen for episode', () {
    testWidgets('-15 / +30 buttons, not past start', (tester) async {
      final audio = FakeAudio();
      addTearDown(audio.close);
      final playback = PodcastPlayback(FakeInner());
      final player = Player(playback: playback, audio: audio);
      addTearDown(player.dispose);
      await player.select(playback.play(podcast, episode));
      audio.emit(AudioPhase.playing);
      audio.position = const Duration(seconds: 10);

      await tester.pumpWidget(MaterialApp(home: PlayerScreen(player: player)));
      await tester.pump();

      expect(find.byKey(const Key('previous-button')), findsNothing);
      expect(find.byKey(const Key('next-button')), findsNothing);
      expect(
        find.byTooltip('Назад на 15 секунд').evaluate().isNotEmpty ||
            find.byTooltip('Back 15 seconds').evaluate().isNotEmpty,
        isTrue,
      );

      await tester.tap(find.byKey(const ValueKey('player-skip-forward')));
      await tester.pump();
      expect(audio.seeks.last, const Duration(seconds: 40));

      await tester.tap(find.byKey(const ValueKey('player-skip-back')));
      await tester.pump();
      expect(audio.seeks.last, const Duration(seconds: 25));

      audio.position = const Duration(seconds: 5);
      await tester.tap(find.byKey(const ValueKey('player-skip-back')));
      await tester.pump();
      expect(audio.seeks.last, Duration.zero);
    });

    testWidgets('song keeps previous and next buttons', (tester) async {
      final audio = FakeAudio();
      addTearDown(audio.close);
      final player = Player(
        playback: PodcastPlayback(FakeInner()),
        audio: audio,
      );
      addTearDown(player.dispose);
      await player.select(
        const Track(
          id: 't1',
          title: 'Song',
          artist: 'Band',
          durationMs: 200000,
          artworkUrl: '',
        ),
      );
      await tester.pumpWidget(MaterialApp(home: PlayerScreen(player: player)));
      await tester.pump();
      expect(find.byKey(const Key('previous-button')), findsOneWidget);
      expect(find.byKey(const ValueKey('player-skip-back')), findsNothing);
    });
  });
}
