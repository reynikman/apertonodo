import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/player.dart';

import 'fakes.dart';

/// FT-615 (P-A85, beta requirement): network drops mid-track and returns —
/// music resumes automatically without taps; queue and playback position
/// are preserved.
///
/// Currently drop leaves player in error until "Retry" is tapped. Here
/// player retries automatically via [Player.reconnectDelays] (in tests —
/// milliseconds) and treats mid-track buffering longer than [Player.stallAfter]
/// as drop: offline device sometimes hangs buffering forever instead of failing.
///
/// What tests do not prove: how real ExoPlayer behaves when network
/// is turned off — verified on owner device (verification page in report).
void main() {
  late FakeAudio audio;

  setUp(() => audio = FakeAudio());
  tearDown(() => audio.close());

  const quick = [
    Duration(milliseconds: 20),
    Duration(milliseconds: 20),
    Duration(milliseconds: 20),
  ];

  Player player(
    FakePlayback playback, {
    List<Duration> delays = quick,
    Duration stallAfter = const Duration(seconds: 20),
  }) {
    final player = Player(
      playback: playback,
      audio: audio,
      reconnectDelays: delays,
      stallAfter: stallAfter,
    );
    addTearDown(player.dispose);
    return player;
  }

  Future<void> until(bool Function() done, {String reason = ''}) async {
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('timed out after 3s: $reason');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test('drop mid-song — network restored, playback resumes from same second '
      'without taps', () async {
    final playback = FakePlayback([
      'https://example.test/s/first',
      PlayFailure.noAnswer, // no network yet
      PlayFailure.noAnswer,
      'https://example.test/s/back',
    ]);
    // Next track in queue is preloaded (gapless) — preloading should
    // succeed without stealing responses meant for retrying current track.
    playback.onPrepare = (id) => 'https://example.test/s/ahead-$id';
    final p = player(playback);
    await p.playQueue([sandman, duality]);
    audio.emit(AudioPhase.playing);
    await settle();
    final queue = p.queue;

    audio.emit(AudioPhase.error, position: const Duration(seconds: 42));
    audio.emit(AudioPhase.idle);
    await settle();
    expect(p.phase, AudioPhase.error);
    expect(p.reconnecting, isTrue, reason: 'player awaits network');

    await until(
      () => audio.played.last.$1 == 'https://example.test/s/back',
      reason: 'retry without tap',
    );
    expect(audio.played.last, (
      'https://example.test/s/back',
      const Duration(seconds: 42),
    ));
    expect(playback.started, [sandman.id, sandman.id, sandman.id, sandman.id]);
    audio.emit(AudioPhase.playing);
    await settle();
    expect(p.phase, AudioPhase.playing);
    expect(p.reconnecting, isFalse);
    expect(p.current, sandman);
    expect(p.queue, queue, reason: 'queue is preserved');
  });

  test('infinite buffering mid-song is also a drop', () async {
    final playback = FakePlayback([
      'https://example.test/s/first',
      'https://example.test/s/back',
    ]);
    final p = player(playback, stallAfter: const Duration(milliseconds: 60));
    await p.select(sandman);
    audio.emit(AudioPhase.playing);
    await settle();
    audio.emit(AudioPhase.buffering, position: const Duration(seconds: 77));

    await until(
      () => audio.played.length == 2,
      reason: 'stalled buffering did not restart',
    );
    expect(audio.played.last, (
      'https://example.test/s/back',
      const Duration(seconds: 77),
    ));
  });

  test('short buffering is not a drop', () async {
    final playback = FakePlayback(['https://example.test/s/first']);
    final p = player(playback, stallAfter: const Duration(milliseconds: 200));
    await p.select(sandman);
    audio.emit(AudioPhase.playing);
    await settle();
    audio.emit(AudioPhase.buffering, position: const Duration(seconds: 10));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    audio.emit(AudioPhase.playing, position: const Duration(seconds: 10));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(audio.played, hasLength(1));
    expect(p.phase, AudioPhase.playing);
  });

  test('picking another track while waiting: old does not resume', () async {
    final playback = FakePlayback([
      'https://example.test/s/first',
      'https://example.test/s/duality',
    ]);
    final p = player(playback, delays: const [Duration(milliseconds: 150)]);
    await p.select(sandman);
    audio.emit(AudioPhase.playing);
    await settle();
    audio.emit(AudioPhase.error, position: const Duration(seconds: 42));
    await settle();

    await p.select(duality);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(playback.started, [sandman.id, duality.id]);
    expect(audio.played.last.$1, 'https://example.test/s/duality');
    expect(p.current, duality);
  });

  test('non-transient failure is not retried', () async {
    for (final failure in [
      PlayFailure.noSource,
      PlayFailure.unknownTrack,
      PlayFailure.noAccess,
    ]) {
      final playback = FakePlayback([failure]);
      final p = player(playback);
      await p.select(sandman);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(playback.started, [sandman.id], reason: '$failure');
      expect(p.reconnecting, isFalse, reason: '$failure');
    }
  });

  test(
    'schedule exhausted — plain error, manual retry works as expected here',
    () async {
      final playback = FakePlayback([
        'https://example.test/s/first',
        PlayFailure.noAnswer,
        PlayFailure.noAnswer,
        'https://example.test/s/manual',
      ]);
      final p = player(
        playback,
        delays: const [Duration(milliseconds: 20), Duration(milliseconds: 20)],
      );
      await p.select(sandman);
      audio.emit(AudioPhase.playing);
      await settle();
      audio.emit(AudioPhase.error, position: const Duration(seconds: 30));
      await settle();

      await until(() => playback.started.length == 3, reason: 'two retries');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(playback.started, hasLength(3), reason: 'no more retries');
      expect(p.phase, AudioPhase.error);
      expect(p.reconnecting, isFalse);

      await p.retry();
      expect(audio.played.last, (
        'https://example.test/s/manual',
        const Duration(seconds: 30),
      ));
    },
  );

  test('user pause is not a drop and does not retry', () async {
    final playback = FakePlayback(['https://example.test/s/first']);
    final p = player(playback, stallAfter: const Duration(milliseconds: 60));
    await p.select(sandman);
    audio.emit(AudioPhase.playing);
    await settle();
    await p.toggle();
    audio.emit(AudioPhase.paused, position: const Duration(seconds: 12));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(playback.started, [sandman.id]);
    expect(p.phase, AudioPhase.paused);
  });

  test('default schedule waits for network at least 10 minutes', () {
    final total = Player.defaultReconnectDelays.fold(
      Duration.zero,
      (sum, delay) => sum + delay,
    );
    expect(total, greaterThanOrEqualTo(const Duration(minutes: 10)));
    expect(
      Player.defaultReconnectDelays.every(
        (delay) => delay <= const Duration(seconds: 30),
      ),
      isTrue,
      reason: 'network restored — music waits at most 30s',
    );
    expect(
      Player.defaultReconnectDelays.first,
      lessThanOrEqualTo(const Duration(seconds: 2)),
    );
  });
}
