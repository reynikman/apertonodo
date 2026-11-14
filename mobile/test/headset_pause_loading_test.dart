import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/player.dart';

import 'fakes.dart';

/// FT-858, owner tail "headset pause while loading": the headset and shade
/// pause went straight to the audio engine, which had nothing to pause while
/// the server was still preparing the song — and the song then started anyway.
///
/// Not proven here: a real headset button on the phone.
void main() {
  late FakeAudio audio;

  setUp(() => audio = FakeAudio());
  tearDown(() => audio.close());

  test(
    'system pause while the server is still looking keeps silence',
    () async {
      final answer = Completer<String>();
      final playback = FakePlayback([answer]);
      final p = Player(playback: playback, audio: audio);
      addTearDown(p.dispose);

      unawaited(p.select(sandman));
      await settle();
      expect(p.phase, AudioPhase.buffering);
      expect(audio.systemPause, isNotNull, reason: 'system pause is not ours');

      await audio.systemPause!();
      expect(p.phase, AudioPhase.idle);
      expect(p.current, sandman);

      answer.complete('https://example.test/s/late');
      await settle();
      expect(
        audio.played,
        isEmpty,
        reason: 'a late answer must not start sound',
      );
    },
  );

  test('sleep timer pause while loading also stops it', () async {
    final answer = Completer<String>();
    final p = Player(playback: FakePlayback([answer]), audio: audio);
    addTearDown(p.dispose);

    unawaited(p.select(sandman));
    await settle();
    await p.pause();
    answer.complete('https://example.test/s/late');
    await settle();
    expect(audio.played, isEmpty);
    expect(p.phase, AudioPhase.idle);
  });
}
