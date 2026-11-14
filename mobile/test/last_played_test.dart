import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/app.dart';
import 'package:music_stream/last_played.dart';
import 'package:music_stream/models/track.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/player.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

const pale = Track(
  id: '22222222-2222-2222-2222-222222222222',
  title: 'Chokehold',
  artist: 'Sleep Token',
  durationMs: 240000,
  artworkUrl: '',
  playable: false,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('saved — restored, including unplayable track', () async {
    final store = LastPlayed();
    await store.save(
      tracks: [sandman, pale],
      index: 1,
      position: const Duration(seconds: 41),
    );

    final loaded = await LastPlayed().load();

    expect(loaded, isNotNull);
    expect(loaded!.tracks, hasLength(2));
    expect(loaded.tracks[0].id, sandman.id);
    expect(loaded.tracks[0].playable, isTrue);
    expect(loaded.tracks[1].title, pale.title);
    expect(loaded.tracks[1].playable, isFalse);
    expect(loaded.index, 1);
    expect(loaded.position, const Duration(seconds: 41));
  });

  test('empty storage returns null', () async {
    expect(await LastPlayed().load(), isNull);
  });

  test('corrupted storage returns null without crashing', () async {
    SharedPreferences.setMockInitialValues({LastPlayed.key: '{'});
    expect(await LastPlayed().load(), isNull);

    final broken = LastPlayed(store: Future.error(Exception('нет')));
    expect(await broken.load(), isNull);
    await broken.save(tracks: [sandman], index: 0, position: Duration.zero);
  });

  test('restore sets track and queue without touching audio', () async {
    final playback = FakePlayback();
    final audio = FakeAudio();
    addTearDown(audio.close);
    final player = Player(playback: playback, audio: audio);
    addTearDown(player.dispose);

    player.restore(
      [sandman, duality],
      index: 1,
      at: const Duration(seconds: 42),
    );

    expect(player.current, duality);
    expect(player.queue, [sandman, duality]);
    expect(player.queueIndex, 1);
    expect(player.phase, AudioPhase.idle);
    expect(audio.played, isEmpty);
    expect(playback.started, isEmpty);
  });

  test(
    'restored track on «play» resumes playback from saved second position',
    () async {
      final playback = FakePlayback();
      final audio = FakeAudio();
      addTearDown(audio.close);
      final player = Player(playback: playback, audio: audio);
      addTearDown(player.dispose);
      player.restore([sandman], index: 0, at: const Duration(seconds: 42));

      await player.toggle();

      expect(audio.played, [
        ('https://example.test/s/1', const Duration(seconds: 42)),
      ]);
    },
  );

  test('finished track on «play» restarts from zero', () async {
    final playback = FakePlayback([
      'https://example.test/s/first',
      'https://example.test/s/second',
      'https://example.test/s/third',
    ]);
    final audio = FakeAudio();
    addTearDown(audio.close);
    final player = Player(playback: playback, audio: audio);
    addTearDown(player.dispose);

    await player.playQueue([sandman]);
    audio.emit(AudioPhase.playing);
    await settle();
    audio.emit(AudioPhase.error, position: const Duration(seconds: 40));
    await settle();
    await player.retry();
    audio.emit(AudioPhase.playing);
    await settle();
    audio.finish();
    await settle();
    expect(player.phase, AudioPhase.idle);

    await player.toggle();

    expect(audio.played.last, ('https://example.test/s/third', Duration.zero));
  });

  testWidgets(
    'app on launch with saved track displays the mini-player component',
    (tester) async {
      await LastPlayed().save(
        tracks: [sandman],
        index: 0,
        position: const Duration(seconds: 15),
      );

      await tester.pumpWidget(MusicApp(lastPlayed: LastPlayed()));
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('mini-player')), findsOneWidget);
      expect(find.text('Enter Sandman'), findsOneWidget);
    },
  );

  testWidgets('app without saved track hides the mini-player component', (
    tester,
  ) async {
    await tester.pumpWidget(MusicApp(lastPlayed: LastPlayed()));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('mini-player')), findsNothing);
  });
}
