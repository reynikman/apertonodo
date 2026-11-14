import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/player.dart';

import 'fakes.dart';

/// Headless player state: selection, track switch, pause, drop, retry.
///
/// Owner bug September 18: picking track did not start playback, picking another
/// while playing only changed title — pause paused old track.
/// Same day audit: double tap sent two Play calls, track switch during
/// waiting played old track with new title, mid-track drop
/// was displayed as "Playing".
void main() {
  late FakeAudio audio;

  setUp(() => audio = FakeAudio());
  tearDown(() => audio.close());

  Player player(FakePlayback playback) {
    final player = Player(playback: playback, audio: audio);
    addTearDown(player.dispose);
    return player;
  }

  test('selecting song plays it immediately', () async {
    final playback = FakePlayback(['https://example.test/s/sandman']);
    final p = player(playback);

    unawaited(p.select(sandman));
    expect(p.phase, AudioPhase.buffering, reason: 'buffering shown at once');
    await settle();

    expect(playback.started, [sandman.id]);
    expect(audio.played, [('https://example.test/s/sandman', Duration.zero)]);
    audio.emit(AudioPhase.playing);
    await settle();
    expect(p.phase, AudioPhase.playing);
    expect(p.current, sandman);
  });

  test(
    'choosing another song while playing plays new one, does not pause',
    () async {
      final playback = FakePlayback([
        'https://example.test/s/sandman',
        'https://example.test/s/duality',
      ]);
      final p = player(playback);
      await p.select(sandman);
      audio.emit(AudioPhase.playing);
      await settle();

      unawaited(p.select(duality));
      // Old track responds to its pause — screen ignores it.
      audio.emit(AudioPhase.paused);
      await settle();
      expect(p.current, duality);
      expect(p.phase, AudioPhase.buffering);
      expect(audio.pauses, 2, reason: 'old song stops immediately');
      expect(audio.played.last.$1, 'https://example.test/s/duality');

      audio.emit(AudioPhase.playing);
      await settle();
      expect(p.phase, AudioPhase.playing);
    },
  );

  test('double tap on song — one server request', () async {
    final answer = Completer<String>();
    final playback = FakePlayback([answer]);
    final p = player(playback);

    unawaited(p.select(sandman));
    unawaited(p.select(sandman));
    await settle();
    expect(playback.started, hasLength(1));

    answer.complete('https://example.test/s/sandman');
    await settle();
    audio.emit(AudioPhase.playing);
    await settle();
    await p.select(sandman);
    expect(
      playback.started,
      hasLength(1),
      reason: 'currently playing song does not restart',
    );
  });

  test(
    'while server seeks first song, picked second song — second track plays',
    () async {
      final slow = Completer<String>();
      final playback = FakePlayback([slow, 'https://example.test/s/duality']);
      final p = player(playback);

      unawaited(p.select(sandman));
      await settle();
      await p.select(duality);
      slow.complete('https://example.test/s/sandman');
      await settle();

      expect(audio.played.map((play) => play.$1), [
        'https://example.test/s/duality',
      ]);
      expect(p.current, duality);
    },
  );

  test(
    'first source opened after second chosen — first does not play',
    () async {
      final second = Completer<String>();
      final playback = FakePlayback(['https://example.test/s/sandman', second]);
      final p = player(playback);
      final opening = Completer<void>();
      audio.holdNextPlay = opening;

      unawaited(p.select(sandman));
      await settle(); // the first token arrived, its source opens
      unawaited(p.select(duality));
      await settle(); // waiting for the server for the second
      opening.complete(); // the first source opened and the player started it
      await settle();

      expect(
        audio.sounding,
        isNull,
        reason: 'first must not play under «Buffering» of second',
      );
      expect(p.current, duality);
      expect(p.phase, AudioPhase.buffering);

      second.complete('https://example.test/s/duality');
      await settle();
      expect(audio.sounding, 'https://example.test/s/duality');
    },
  );

  test('waiting for new song: old state does not change screen', () async {
    final slow = Completer<String>();
    final playback = FakePlayback(['https://example.test/s/sandman', slow]);
    final p = player(playback);
    await p.select(sandman);
    audio.emit(AudioPhase.playing);
    await settle();

    unawaited(p.select(duality));
    audio.emit(AudioPhase.playing); // a late event of the old song
    await settle();

    expect(p.phase, AudioPhase.buffering);
    expect(p.current, duality);
  });

  test('after pause button resumes, does not request new token', () async {
    final playback = FakePlayback();
    final p = player(playback);
    await p.select(sandman);
    audio.emit(AudioPhase.playing);
    await settle();

    await p.toggle();
    audio.emit(AudioPhase.paused);
    await settle();
    expect(p.phase, AudioPhase.paused);

    await p.toggle();
    expect(audio.resumes, 1);
    expect(playback.started, hasLength(1));
  });

  test('drop mid-song — «retry» from same second', () async {
    final playback = FakePlayback([
      'https://example.test/s/first',
      'https://example.test/s/second',
    ]);
    final p = player(playback);
    await p.select(sandman);
    audio.emit(AudioPhase.playing);
    await settle();

    audio.emit(AudioPhase.error, position: const Duration(seconds: 42));
    // Player idles after error — "retry" remains available.
    audio.emit(AudioPhase.idle);
    await settle();
    expect(p.phase, AudioPhase.error);
    expect(p.failure, PlayFailure.dropped);

    await p.retry();
    expect(playback.started, hasLength(2));
    expect(audio.played.last, (
      'https://example.test/s/second',
      const Duration(seconds: 42),
    ));
  });

  test('server refusal gives reason, retry restarts', () async {
    final playback = FakePlayback([
      PlayFailure.noSource,
      'https://example.test/s/sandman',
    ]);
    final p = player(playback);

    await p.select(sandman);
    expect(p.phase, AudioPhase.error);
    expect(p.failure, PlayFailure.noSource);

    await p.retry();
    expect(audio.played, [('https://example.test/s/sandman', Duration.zero)]);
  });

  test('failure after retry from mid-song does not lose second', () async {
    final playback = FakePlayback([
      'https://example.test/s/first',
      PlayFailure.noAnswer,
      'https://example.test/s/third',
    ]);
    final p = player(playback);
    await p.select(sandman);
    audio.emit(AudioPhase.playing);
    await settle();
    audio.emit(AudioPhase.error, position: const Duration(seconds: 90));
    await settle();

    await p.retry();
    expect(p.failure, PlayFailure.noAnswer);
    await p.retry();
    expect(audio.played.last, (
      'https://example.test/s/third',
      const Duration(seconds: 90),
    ));
  });

  test('player failed stream — error, not endless buffering', () async {
    final p = player(FakePlayback());
    audio.failNextPlay = StateError('источник не открылся');

    await p.select(sandman);

    expect(p.phase, AudioPhase.error);
    expect(p.failure, PlayFailure.player);
  });

  test('finished song restarts on button press', () async {
    final playback = FakePlayback();
    final p = player(playback);
    await p.select(sandman);
    audio.emit(AudioPhase.playing);
    await settle();
    audio.emit(AudioPhase.idle); // completed
    await settle();
    expect(p.phase, AudioPhase.idle);

    await p.toggle();
    expect(playback.started, hasLength(2));
    expect(audio.played.last.$2, Duration.zero);
  });

  group('HttpPlayback provides reason for failure', () {
    Future<PlayFailure?> failureFor(
      http.Client client, {
      Duration? timeout,
    }) async {
      try {
        await HttpPlayback(
          'http://192.0.2.1:8088',
          tokens: tokensFor('http://192.0.2.1:8088'),
          client: client,
          timeout: timeout ?? HttpPlayback.playbackTimeout,
        ).start(sandman.id);
        return null;
      } on PlaybackFailed catch (failed) {
        return failed.reason;
      }
    }

    http.Client answering(int status, [String body = '{}']) =>
        MockClient((_) async => http.Response(body, status));

    test('409 — source not found', () async {
      expect(await failureFor(answering(409)), PlayFailure.noSource);
    });

    test('404 — server does not know track', () async {
      expect(await failureFor(answering(404)), PlayFailure.unknownTrack);
    });

    test('401 — invalid build key', () async {
      expect(await failureFor(answering(401)), PlayFailure.noAccess);
    });

    test('502 from proxy and bad reply — server did not reply', () async {
      expect(await failureFor(answering(502)), PlayFailure.noAnswer);
      expect(
        await failureFor(answering(200, '<html>502 Bad Gateway</html>')),
        PlayFailure.noAnswer,
      );
    });

    test('network dropped — not exposed exception, but reason', () async {
      final client = MockClient(
        (_) async => throw http.ClientException('reset'),
      );
      expect(await failureFor(client), PlayFailure.noAnswer);
    });

    test('hung response drops by its timeout', () async {
      final client = MockClient((_) => Completer<http.Response>().future);
      expect(
        await failureFor(client, timeout: const Duration(milliseconds: 20)),
        PlayFailure.noAnswer,
      );
    });

    test('200 with token — stream URL', () async {
      final token = DateTime.now().microsecondsSinceEpoch.toString();
      final client = answering(200, jsonEncode({'token': token}));
      final url = await HttpPlayback(
        'http://192.0.2.1:8088',
        tokens: tokensFor('http://192.0.2.1:8088'),
        client: client,
      ).start('1');
      expect(url, 'http://192.0.2.1:8088/v1/stream/$token');
    });
  });
}
