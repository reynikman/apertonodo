import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:music_stream/device_audio.dart';
import 'package:music_stream/playback.dart';

/// Which phase screen displays based on real player state.
///
/// Audit September 18: on stream break just_audio enters idle while playing
/// remains true (Android reports error, but only pause and stop reset
/// playing) — screen said "Playing" in silence. After song end —
/// completed with same playing, and "Playing" remained over finished track.
void main() {
  test('stream drop is error, not playing', () {
    expect(phaseOf(ProcessingState.idle, playing: true), AudioPhase.error);
  });

  test('finished song is idle, not playing', () {
    expect(phaseOf(ProcessingState.completed, playing: true), AudioPhase.idle);
    expect(phaseOf(ProcessingState.completed, playing: false), AudioPhase.idle);
  });

  test('everything else remains as before', () {
    expect(phaseOf(ProcessingState.idle, playing: false), AudioPhase.idle);
    expect(
      phaseOf(ProcessingState.loading, playing: false),
      AudioPhase.buffering,
    );
    expect(
      phaseOf(ProcessingState.buffering, playing: true),
      AudioPhase.buffering,
    );
    expect(phaseOf(ProcessingState.ready, playing: true), AudioPhase.playing);
    expect(phaseOf(ProcessingState.ready, playing: false), AudioPhase.paused);
  });
}
