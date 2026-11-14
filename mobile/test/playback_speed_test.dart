import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/l10n/app_localizations.dart';
import 'package:music_stream/models/track.dart';
import 'package:music_stream/playback_speed.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/player.dart';
import 'package:music_stream/podcast_progress.dart';
import 'package:music_stream/screens/speed_button.dart';

import 'fakes.dart';

/// Episode speed (FT-730): per-podcast setting, track speed remains normal.
///
/// Audio player remembers speed internally. Without reset, a track after 1.5x episode
/// would play at 1.5x, and an episode of another podcast at someone else's speed.
void main() {
  late FakeAudio audio;

  setUp(() => audio = FakeAudio());
  tearDown(() => audio.close());

  const song = Track(
    id: 't1',
    title: 'Song',
    artist: 'A',
    durationMs: 1000,
    artworkUrl: '',
  );
  const ep1 = Track(
    id: 'podcast:a',
    title: 'E1',
    artist: 'P',
    durationMs: 1000,
    artworkUrl: '',
  );
  const ep2 = Track(
    id: 'podcast:b',
    title: 'E2',
    artist: 'Q',
    durationMs: 1000,
    artworkUrl: '',
  );
  const feeds = {'podcast:a': 'feedA', 'podcast:b': 'feedB'};

  (Player, PlaybackSpeed, Map<String, double>) build({
    Map<String, double>? stored,
    Future<void> Function()? saving,
  }) {
    final player = Player(
      playback: FakePlayback(List.filled(10, 'https://example.test/s/1')),
      audio: audio,
    );
    final memory = stored ?? <String, double>{};
    final speed = PlaybackSpeed(
      player,
      audio,
      speedFor: (id) => switch (feeds[id]) {
        final feed? => memory[feed] ?? 1.0,
        null => null,
      },
      save: (id, v) async {
        await saving?.call();
        memory[feeds[id]!] = v;
      },
    );
    addTearDown(speed.dispose);
    addTearDown(player.dispose);
    return (player, speed, memory);
  }

  test('episode plays at its podcast speed', () async {
    final (player, speed, _) = build(stored: {'feedA': 1.5});
    unawaited(player.select(ep1));
    await settle();
    expect(audio.speeds, [1.5]);
    expect(speed.current, 1.5);
  });

  test('song after episode plays at normal speed', () async {
    final (player, speed, _) = build(stored: {'feedA': 1.5});
    unawaited(player.select(ep1));
    await settle();
    unawaited(player.select(song));
    await settle();
    expect(audio.speeds, [1.5, 1.0]);
    expect(speed.current, isNull);
  });

  test('different podcast plays at its own speed', () async {
    final (player, _, _) = build(stored: {'feedA': 2.0, 'feedB': 0.75});
    unawaited(player.select(ep1));
    await settle();
    unawaited(player.select(ep2));
    await settle();
    expect(audio.speeds, [2.0, 0.75]);
  });

  test('songs in a row and 1× episode — no audio stutter', () async {
    final (player, _, _) = build();
    unawaited(player.select(song));
    await settle();
    unawaited(player.select(ep1));
    await settle();
    expect(audio.speeds, isEmpty);
  });

  test('speed choice applies immediately to audio and store', () async {
    final (player, speed, memory) = build();
    unawaited(player.select(ep1));
    await settle();
    await speed.set(1.75);
    expect(audio.speeds, [1.75]);
    expect(memory['feedA'], 1.75);
    expect(speed.current, 1.75);
  });

  test('speed change does nothing for regular songs', () async {
    final (player, speed, memory) = build();
    unawaited(player.select(song));
    await settle();
    await speed.set(2.0);
    expect(audio.speeds, isEmpty);
    expect(memory, isEmpty);
  });

  test('button reflects selection without waiting for disk', () async {
    final disk = Completer<void>();
    final (player, speed, _) = build(saving: () => disk.future);
    unawaited(player.select(ep1));
    await settle();
    final seen = <double?>[];
    speed.addListener(() => seen.add(speed.current));
    unawaited(speed.set(2.5));
    await settle();
    expect(speed.current, 2.5);
    expect(seen, contains(2.5));
    disk.complete();
    await settle();
    expect(speed.current, 2.5);
  });

  test('closing while saving speed to disk does not crash', () async {
    final disk = Completer<void>();
    final player = Player(
      playback: FakePlayback(List.filled(10, 'https://example.test/s/1')),
      audio: audio,
    );
    addTearDown(player.dispose);
    final speed = PlaybackSpeed(
      player,
      audio,
      speedFor: (id) => feeds.containsKey(id) ? 1.0 : null,
      save: (_, _) => disk.future,
    );
    unawaited(player.select(ep1));
    await settle();
    final done = speed.set(1.5);
    speed.dispose();
    disk.complete();
    await done;
  });

  test('audio speed error does not crash and allows retry', () async {
    final (player, speed, _) = build(stored: {'feedA': 1.5});
    audio.failSpeed = true;
    unawaited(player.select(ep1));
    await settle();
    expect(audio.speeds, isEmpty);
    audio.failSpeed = false;
    await speed.set(1.5);
    expect(audio.speeds, [1.5]);
  });

  test('song after sped-up episode is not preloaded ahead', () async {
    final (player, _, _) = build(stored: {'feedA': 1.5});
    unawaited(player.playQueue([ep1, song]));
    await settle();
    audio.emit(AudioPhase.playing);
    await settle();
    // Audio player shares speed across all: queued track would have started at 1.5x.
    expect(audio.queuedNow, isNull);
  });

  test('at normal speed gapless transition is preserved', () async {
    final (player, _, _) = build();
    unawaited(player.playQueue([ep1, song]));
    await settle();
    audio.emit(AudioPhase.playing);
    await settle();
    expect(audio.queuedNow, isNotNull);
  });

  test('speeding up episode detaches pre-queued song', () async {
    final (player, speed, _) = build();
    unawaited(player.playQueue([ep1, song]));
    await settle();
    audio.emit(AudioPhase.playing);
    await settle();
    expect(audio.queuedNow, isNotNull);
    await speed.set(1.5);
    await settle();
    expect(audio.queuedNow, isNull);
  });

  test('speed label formatting', () {
    expect(speedLabel(1.0), '1×');
    expect(speedLabel(1.25), '1.25×');
    expect(speedLabel(0.5), '0.5×');
    expect(speedLabel(2.0), '2×');
  });

  testWidgets('button shows speed and allows choosing another value', (
    tester,
  ) async {
    double? chosen;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: SpeedButton(
            speed: 1.5,
            speeds: podcastSpeeds,
            tooltip: 'Скорость',
            onSelected: (v) => chosen = v,
          ),
        ),
      ),
    );
    expect(find.text('1.5×'), findsOneWidget);
    expect(find.bySemanticsLabel('Скорость 1.5×'), findsOneWidget);
    // TalkBack announces label once, without duplicate hint.
    expect(find.byTooltip('Скорость 1.5×'), findsNothing);
    expect(tester.getSize(find.byType(SpeedButton)).height >= 48, isTrue);
    await tester.tap(find.byType(SpeedButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('speed-2.0')));
    await tester.pumpAndSettle();
    expect(chosen, 2.0);
  });
}
