import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/player.dart';

import 'fakes.dart';

/// Phone notifies server that stream failed to play (FT-546, pair to FT-536).
///
/// Owner finding 03.10: "Cowboys from Hell" did not play — file
/// was corrupt, but server never learned this and on each "Retry" returned same
/// release. Now, if player failed to open stream or stream broke in first
/// seconds, app sends `POST /v1/playback/failed` with stream token, and
/// server looks for retry in a different release. Mid-song interruption is network, not
/// file: server is not notified of it, otherwise it would discard good releases.
void main() {
  late FakeAudio audio;

  setUp(() => audio = FakeAudio());
  tearDown(() => audio.close());

  Player player(FakePlayback playback) {
    final player = Player(playback: playback, audio: audio);
    addTearDown(player.dispose);
    return player;
  }

  test('player failed to open stream: server receives report', () async {
    final playback = FakePlayback(['https://example.test/v1/stream/abc']);
    final p = player(playback);
    audio.failNextPlay = StateError('источник не открылся');

    unawaited(p.select(sandman));
    await settle();

    expect(p.phase, AudioPhase.error);
    expect(playback.failedUrls, ['https://example.test/v1/stream/abc']);
  });

  test('drop in first seconds: also reported', () async {
    final playback = FakePlayback(['https://example.test/v1/stream/abc']);
    final p = player(playback);

    unawaited(p.select(sandman));
    await settle();
    audio.emit(AudioPhase.playing);
    audio.emit(AudioPhase.error, position: const Duration(seconds: 2));
    await settle();

    expect(p.phase, AudioPhase.error);
    expect(playback.failedUrls, ['https://example.test/v1/stream/abc']);
  });

  test('drop mid-song is network: server not notified', () async {
    final playback = FakePlayback(['https://example.test/v1/stream/abc']);
    final p = player(playback);

    unawaited(p.select(sandman));
    await settle();
    audio.emit(AudioPhase.playing);
    audio.emit(AudioPhase.error, position: const Duration(seconds: 90));
    await settle();

    expect(p.phase, AudioPhase.error);
    expect(playback.failedUrls, isEmpty);
  });

  test('song finished playing: nothing to report', () async {
    final playback = FakePlayback(['https://example.test/v1/stream/abc']);
    final p = player(playback);

    unawaited(p.select(sandman));
    await settle();
    audio.emit(AudioPhase.playing);
    await settle();

    expect(p.phase, AudioPhase.playing);
    expect(playback.failedUrls, isEmpty);
  });

  group('HttpPlayback.failed', () {
    const base = 'http://192.0.2.1:8088';

    test('sends stream token to /v1/playback/failed', () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        return http.Response('', 204);
      });
      await HttpPlayback(
        base,
        tokens: tokensFor(base),
        client: client,
      ).failed('$base/v1/stream/abc');

      expect(requests, hasLength(1));
      expect(requests.single.method, 'POST');
      expect(requests.single.url.toString(), '$base/v1/playback/failed');
      expect(jsonDecode(requests.single.body), {'token': 'abc'});
    });

    test('local file on phone is not server stream: no request', () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response('', 204);
      });
      await HttpPlayback(
        base,
        tokens: tokensFor(base),
        client: client,
      ).failed('file:///data/user/0/music/song.flac');

      expect(calls, 0);
    });

    test('server failed to answer: error not exposed', () async {
      final client = MockClient(
        (_) async => throw http.ClientException('reset'),
      );
      await HttpPlayback(
        base,
        tokens: tokensFor(base),
        client: client,
      ).failed('$base/v1/stream/abc');
    });
  });
}
