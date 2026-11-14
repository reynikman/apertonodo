import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/player.dart';

import 'fakes.dart';

/// FT-753 (P1b): seeking past downloaded buffer. P1a measurement on a live source extension:
/// piece from target position arrives after 14–15 s — slow seeder finishes
/// delivering in-flight pipeline first. ExoPlayer waits 8 s for bytes then fails with read
/// error; player previously treated this as disconnect and re-queried source.
///
/// Here: error after seek before playback resumes within [Player.seekPatience]
/// is treated as buffering. Player reopens same
/// stream at seek position without re-querying server or showing "Disconnect".
/// If patience expires, standard disconnect with scheduled retry applies.
///
/// What tests do not prove: real ExoPlayer failing with error vs hanging in
/// buffering ([Player.stallAfter] handles that), and real release latency —
/// verified on owner device.
void main() {
  late FakeAudio audio;
  var now = DateTime(2026, 10, 11, 1);

  setUp(() {
    audio = FakeAudio();
    now = DateTime(2026, 10, 11, 1);
  });
  tearDown(() => audio.close());

  const quick = [Duration(milliseconds: 20), Duration(milliseconds: 20)];

  Player player(FakePlayback playback) {
    final player = Player(
      playback: playback,
      audio: audio,
      clock: () => now,
      reconnectDelays: quick,
    );
    addTearDown(player.dispose);
    return player;
  }

  Future<void> until(bool Function() done, {String reason = ''}) async {
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('timeout after 3s: $reason');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<Player> playing(FakePlayback playback) async {
    final p = player(playback);
    await p.select(sandman);
    audio.emit(AudioPhase.playing);
    await settle();
    return p;
  }

  test('error after seek - same stream from seek position, '
      'without new search or drop', () async {
    final playback = FakePlayback([
      'https://example.test/s/first',
      'https://example.test/s/second',
    ]);
    final p = await playing(playback);
    await p.seek(const Duration(seconds: 140));
    audio.emit(AudioPhase.buffering, position: const Duration(seconds: 140));
    await settle();
    now = now.add(const Duration(seconds: 8));
    audio.emit(AudioPhase.error, position: const Duration(seconds: 140));
    await until(() => audio.played.length == 2, reason: 'reopening');

    expect(p.phase, AudioPhase.buffering, reason: 'buffering, not drop');
    expect(p.failure, isNull);
    expect(p.reconnecting, isFalse);
    expect(audio.played.last, (
      'https://example.test/s/first',
      const Duration(seconds: 140),
    ), reason: 'same stream from seek position');
    expect(audio.played, hasLength(2));
    expect(playback.started, [sandman.id], reason: 'server not re-queried');
    expect(playback.failedUrls, isEmpty, reason: 'source not bad');

    audio.emit(AudioPhase.playing, position: const Duration(seconds: 140));
    await settle();
    expect(p.phase, AudioPhase.playing);
  });

  test('2nd and 3rd error in tolerance - same stream again', () async {
    final playback = FakePlayback(['https://example.test/s/first']);
    final p = await playing(playback);
    await p.seek(const Duration(seconds: 90));
    for (var i = 0; i < 3; i++) {
      now = now.add(const Duration(seconds: 9));
      audio.emit(AudioPhase.error, position: const Duration(seconds: 90));
      await until(() => audio.played.length == i + 2, reason: 'error ${i + 1}');
      expect(p.phase, AudioPhase.buffering, reason: 'error ${i + 1}');
    }
    expect(audio.played, hasLength(4));
    expect(
      audio.played
          .skip(1)
          .every(
            (e) =>
                e ==
                ('https://example.test/s/first', const Duration(seconds: 90)),
          ),
      isTrue,
    );
    expect(playback.started, [sandman.id]);
  });

  test('tolerance exhausted - drop and retry via server', () async {
    final playback = FakePlayback([
      'https://example.test/s/first',
      'https://example.test/s/back',
    ]);
    final p = await playing(playback);
    await p.seek(const Duration(seconds: 90));
    now = now.add(Player.seekPatience + const Duration(seconds: 1));
    audio.emit(AudioPhase.error, position: const Duration(seconds: 90));
    await settle();

    expect(p.phase, AudioPhase.error);
    expect(p.failure, PlayFailure.dropped);
    expect(p.reconnecting, isTrue);
    await until(
      () => audio.played.last.$1 == 'https://example.test/s/back',
      reason: 'scheduled retry via server',
    );
    expect(audio.played.last.$2, const Duration(seconds: 90));
  });

  test('played after seek - next error is a drop', () async {
    final playback = FakePlayback([
      'https://example.test/s/first',
      'https://example.test/s/back',
    ]);
    final p = await playing(playback);
    await p.seek(const Duration(seconds: 90));
    audio.emit(AudioPhase.playing, position: const Duration(seconds: 90));
    await settle();
    now = now.add(const Duration(seconds: 5));
    audio.emit(AudioPhase.error, position: const Duration(seconds: 95));
    await settle();

    expect(p.phase, AudioPhase.error);
    expect(p.failure, PlayFailure.dropped);
  });

  test('error without seek - drop, as before', () async {
    final playback = FakePlayback([
      'https://example.test/s/first',
      'https://example.test/s/back',
    ]);
    final p = await playing(playback);
    audio.emit(AudioPhase.error, position: const Duration(seconds: 42));
    await settle();
    expect(p.phase, AudioPhase.error);
    expect(p.failure, PlayFailure.dropped);
  });

  test('seek then another song - new song error does not go '
      'to old stream', () async {
    final playback = FakePlayback([
      'https://example.test/s/first',
      'https://example.test/s/other',
    ]);
    final p = await playing(playback);
    await p.seek(const Duration(seconds: 90));
    await p.select(duality);
    await settle();
    audio.emit(AudioPhase.error, position: Duration.zero);
    await settle();

    expect(p.current, duality);
    expect(
      audio.played.where((e) => e.$1 == 'https://example.test/s/first'),
      hasLength(1),
      reason: 'old stream not reopened',
    );
    expect(p.phase, AudioPhase.error);
  });

  // Second glance (Gemini 3), findings 1, 2, 3, and 5.

  test('new song searching, old stream reopened - it mutes', () async {
    final other = Completer<String>();
    final playback = FakePlayback(['https://example.test/s/first', other]);
    final p = await playing(playback);
    await p.seek(const Duration(seconds: 90));
    final hold = Completer<void>();
    audio.holdNextPlay = hold;
    audio.emit(AudioPhase.error, position: const Duration(seconds: 90));
    // Reopen timer (20 ms) fired, playUrl awaits `hold`.
    await Future<void>.delayed(const Duration(milliseconds: 80));
    unawaited(p.select(duality)); // the server looks for a new song
    await settle();
    final pauses = audio.pauses;
    hold.complete();
    await settle();
    expect(
      audio.played.where((e) => e.$1 == 'https://example.test/s/first'),
      hasLength(2),
      reason: 'old stream was actually reopened',
    );
    expect(
      audio.pauses,
      greaterThan(pauses),
      reason: 'opened old stream stopped',
    );
    expect(p.current, duality);
    other.complete('https://example.test/s/other');
    await settle();
  });

  test('reopen failed - retry via server from seek position', () async {
    final playback = FakePlayback([
      'https://example.test/s/first',
      'https://example.test/s/back',
    ]);
    final p = await playing(playback);
    await p.seek(const Duration(seconds: 120));
    audio.failNextPlay = StateError('не открылся');
    audio.emit(AudioPhase.error, position: const Duration(seconds: 120));
    await until(
      () =>
          audio.played.isNotEmpty &&
          audio.played.last.$1 == 'https://example.test/s/back',
      reason: 'scheduled retry',
    );
    expect(audio.played.last.$2, const Duration(seconds: 120));
    expect(p.current, sandman);
  });

  test('seek while paused - read error does not unmute', () async {
    final playback = FakePlayback([
      'https://example.test/s/first',
      'https://example.test/s/back',
    ]);
    final p = await playing(playback);
    await p.pause();
    audio.emit(AudioPhase.paused);
    await settle();
    await p.seek(const Duration(seconds: 90));
    audio.emit(AudioPhase.error, position: const Duration(seconds: 90));
    await settle();
    expect(audio.played, hasLength(1), reason: 'stream not auto-reopened');
    expect(p.phase, AudioPhase.error);
  });

  test('rapid errors in row - reopen with pause, not burst', () async {
    final playback = FakePlayback(['https://example.test/s/first']);
    final p = await playing(playback);
    await p.seek(const Duration(seconds: 90));
    for (var i = 0; i < 5; i++) {
      audio.emit(AudioPhase.error, position: const Duration(seconds: 90));
      await settle();
    }
    expect(
      audio.played.length,
      lessThanOrEqualTo(2),
      reason: '5 rapid errors - not 5 reopens',
    );
    expect(p.phase, AudioPhase.buffering);
  });
}
