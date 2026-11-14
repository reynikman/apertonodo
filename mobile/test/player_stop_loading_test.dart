import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/player.dart';

import 'fakes.dart';

/// Owner finding 13.10 no. 2 (FT-850): the "loading" button was dead. A tap
/// on it stops loading; the song stays chosen and Play starts it again.
void main() {
  late FakeAudio audio;

  setUp(() => audio = FakeAudio());
  tearDown(() => audio.close());

  Player player(FakePlayback playback) {
    final player = Player(playback: playback, audio: audio);
    addTearDown(player.dispose);
    return player;
  }

  test('tap while the server is still looking stops loading', () async {
    final answer = Completer<String>();
    final playback = FakePlayback([answer, 'https://example.test/s/again']);
    final p = player(playback);

    unawaited(p.select(sandman));
    await settle();
    expect(p.phase, AudioPhase.buffering);

    await p.toggle();
    expect(p.phase, AudioPhase.idle, reason: 'the button turns back into Play');
    expect(p.current, sandman, reason: 'the song stays chosen');

    answer.complete('https://example.test/s/late');
    await settle();
    expect(audio.played, isEmpty, reason: 'a late answer must not start sound');
    expect(p.phase, AudioPhase.idle);

    await p.toggle();
    await settle();
    expect(playback.started, [sandman.id, sandman.id]);
    expect(audio.played, [('https://example.test/s/again', Duration.zero)]);
  });

  test('tap while the stream is opening silences it', () async {
    final playback = FakePlayback(['https://example.test/s/sandman']);
    final p = player(playback);
    final hold = Completer<void>();
    audio.holdNextPlay = hold;

    unawaited(p.select(sandman));
    await settle();
    expect(p.phase, AudioPhase.buffering);

    await p.toggle();
    expect(p.phase, AudioPhase.idle);

    hold.complete();
    await settle();
    audio.emit(AudioPhase.playing);
    await settle();
    expect(audio.sounding, isNull, reason: 'opened stream must not play');
    expect(p.phase, AudioPhase.idle);
  });

  test('tap while a playing song stalls keeps its second', () async {
    final playback = FakePlayback(['https://example.test/s/sandman']);
    final p = player(playback);
    await p.select(sandman);
    audio.emit(AudioPhase.playing);
    await settle();
    audio.position = const Duration(seconds: 42);
    audio.emit(AudioPhase.buffering);
    await settle();
    expect(p.phase, AudioPhase.buffering);

    await p.toggle();
    expect(p.phase, AudioPhase.idle);
    expect(audio.sounding, isNull);

    await p.toggle();
    await settle();
    expect(audio.played.last.$2, const Duration(seconds: 42));
  });
}
