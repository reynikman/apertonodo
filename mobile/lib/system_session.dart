import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

/// System media session: notification, lock screen, headset, wearable.
///
/// Previously managed by just_audio_background, but it shows "next" and
/// "previous" only for its playlist. We have no player playlist: each track
/// URL is separate server token, and next track is chosen by [Player]
/// queue. Hence custom session, where "next/prev" invoke queue.
class SystemSession extends BaseAudioHandler with SeekHandler {
  AudioPlayer? _player;
  Future<void> Function()? _next;
  Future<void> Function()? _previous;
  Future<void> Function()? _pause;

  /// Session displays state of this player and controls it.
  void attach(AudioPlayer player) {
    _player = player;
    player.playbackEventStream.listen((_) => _broadcast());
    player.playingStream.listen((_) => _broadcast());
    player.durationStream.listen((duration) {
      final item = mediaItem.value;
      if (item != null && duration != null && item.duration != duration) {
        mediaItem.add(item.copyWith(duration: duration));
      }
    });
  }

  /// Currently playing item — for notification and lock screen.
  void show(MediaItem item) => mediaItem.add(item);

  void setSkips({
    Future<void> Function()? next,
    Future<void> Function()? previous,
    Future<void> Function()? pause,
  }) {
    _next = next;
    _previous = previous;
    _pause = pause;
    _broadcast();
  }

  /// N6-10 (FT-744): three buttons always in fixed positions. Previously "next"
  /// vanished at end of queue shifting pause under finger; now button
  /// remains present and tapping without next track does nothing.
  static List<MediaControl> controlsFor({required bool playing}) => [
    MediaControl.skipToPrevious,
    if (playing) MediaControl.pause else MediaControl.play,
    MediaControl.skipToNext,
  ];

  /// Compact notification displays all three.
  static const compactIndices = [0, 1, 2];

  void _broadcast() {
    final player = _player;
    if (player == null) {
      return;
    }
    final playing = player.playing;
    playbackState.add(
      playbackState.value.copyWith(
        controls: controlsFor(playing: playing),
        systemActions: const {MediaAction.seek},
        androidCompactActionIndices: compactIndices,
        processingState: switch (player.processingState) {
          ProcessingState.idle => AudioProcessingState.idle,
          ProcessingState.loading => AudioProcessingState.loading,
          ProcessingState.buffering => AudioProcessingState.buffering,
          ProcessingState.ready => AudioProcessingState.ready,
          ProcessingState.completed => AudioProcessingState.completed,
        },
        playing: playing,
        updatePosition: player.position,
        bufferedPosition: player.bufferedPosition,
        speed: player.speed,
      ),
    );
  }

  @override
  Future<void> play() async {
    // Future returned by play() completes only on pause: awaiting it here
    // would block system action until track ends.
    final player = _player;
    if (player != null) {
      unawaited(player.play());
    }
  }

  @override
  // FT-858: headset pause while the song is still loading went straight to the
  // engine, which had nothing to pause yet, and the song started anyway.
  Future<void> pause() async => (_pause ?? _player?.pause)?.call();

  @override
  Future<void> seek(Duration position) async => _player?.seek(position);

  @override
  Future<void> skipToNext() async => _next?.call();

  @override
  Future<void> skipToPrevious() async => _previous?.call();

  @override
  Future<void> stop() async {
    await _player?.pause();
    await super.stop();
  }
}
