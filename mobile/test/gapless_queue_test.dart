// Lead check FT-550 (P7, P-A62): album track is not opened afresh
// after previous one ends — player pre-queues it in advance and transitions seamlessly.
// Currently 260–300 ms silence between tracks (device-smoke 17799); here is
// Player ↔ AudioPort contract, while acoustic gap is measured by device_gapless.sh.
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/models/track.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/player.dart';

import 'fakes.dart';

Track song(int n) => Track(
  id: '00000000-0000-4000-8000-00000000005$n',
  title: 'Song $n',
  artist: 'Band',
  durationMs: 200000,
  artworkUrl: '',
);

final album = [song(1), song(2), song(3)];

class Bench {
  Bench() {
    player = Player(
      playback: playback,
      audio: audio,
      listened: (id, ms, {artworkUrl = ''}) async => sent.add(id),
    );
  }

  final playback = FakePlayback(['u1', 'u2', 'u3', 'u4']);
  final audio = FakeAudio();
  final sent = <String>[];
  late final Player player;

  Future<void> playing() {
    audio.emit(AudioPhase.playing);
    return settle();
  }
}

List<String> urls(FakeAudio audio) => [for (final p in audio.played) p.$1];

void main() {
  test('next is glued in advance', () async {
    final b = Bench();
    await b.player.playQueue(album);
    await b.playing();
    expect(urls(b.audio), ['u1']);
    expect(b.audio.queued, ['u2']);
  });

  test('transition automatic without new source', () async {
    final b = Bench();
    await b.player.playQueue(album);
    await b.playing();
    b.audio.advance();
    await settle();
    expect(b.player.current?.id, song(2).id);
    // playUrl at boundary is the gap itself.
    expect(urls(b.audio), ['u1']);
    expect(b.audio.sounding, 'u2');
    expect(b.player.phase, AudioPhase.playing);
    // Further into album: third is queued while second plays.
    expect(b.audio.queued, ['u2', 'u3']);
    // Completed track logged to history, as with normal transition.
    expect(b.sent, contains(song(1).id));
  });

  test('last song: nothing to glue', () async {
    final b = Bench();
    await b.player.playQueue(album, start: 2);
    await b.playing();
    expect(b.audio.queued, isEmpty);
  });

  test('repeat one: nothing follows', () async {
    final b = Bench();
    await b.player.playQueue(album);
    await b.playing();
    while (b.player.repeat != Repeat.one) {
      b.player.cycleRepeat();
    }
    await settle();
    // Otherwise next track would play instead of repeat.
    expect(b.audio.queuedNow, isNull);
  });

  test('manual next: no duplicate song', () async {
    final b = Bench();
    await b.player.playQueue(album);
    await b.playing();
    await b.player.next();
    await b.playing();
    expect(b.player.current?.id, song(2).id);
    // Only third track can be queued.
    expect(b.audio.queuedNow, anyOf(isNull, isNot('u2')));
    if (b.audio.queuedNow != null) {
      b.audio.advance();
      await settle();
      expect(b.player.current?.id, song(3).id);
    }
  });

  test('next not provided: fallback to old path', () async {
    final audio = FakeAudio();
    // u1 — first; failure — queueing second; u2 — second after completion.
    final playback = FakePlayback(['u1', PlayFailure.noSource, 'u2']);
    final player = Player(playback: playback, audio: audio);
    await player.playQueue(album);
    audio.emit(AudioPhase.playing);
    await settle();
    expect(audio.queued, isEmpty);
    audio.finish();
    await settle();
    expect(player.current?.id, song(2).id);
    expect(urls(audio), ['u1', 'u2']);
  });
}
