import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/models/track.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/player.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';
import 'fakes.dart';

Track song(int n) => Track(
  id: '00000000-0000-4000-8000-00000000000$n',
  title: 'Song $n',
  artist: 'Band',
  durationMs: 200000,
  artworkUrl: '',
);

final album = [song(1), song(2), song(3)];

/// Player G with test-controlled clock and history submission recording.
class Bench {
  Bench() {
    player = Player(
      playback: playback,
      audio: audio,
      clock: () => now,
      listened: (id, ms, {artworkUrl = ''}) async => sent.add((id, ms)),
    );
  }

  final playback = FakePlayback();
  final audio = FakeAudio();
  final sent = <(String, int)>[];
  var now = DateTime(2026, 9, 19, 12);
  late final Player player;

  Future<void> phase(AudioPhase phase, {Duration position = Duration.zero}) {
    audio.emit(phase, position: position);
    return settle();
  }

  void wait(int seconds) => now = now.add(Duration(seconds: seconds));
}

void main() {
  // Playback cache lives in phone settings — distinct for each test.
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'another song — history gets how long the previous one played',
    () async {
      final bench = Bench();
      await bench.player.playQueue(album);
      await bench.phase(AudioPhase.playing);
      bench.wait(40);

      await bench.player.next();

      expect(bench.sent, [(album[0].id, 40000)]);
    },
  );

  test('a pause does not count and sends what was heard by itself', () async {
    final bench = Bench();
    await bench.player.playQueue(album);
    await bench.phase(AudioPhase.playing);
    bench.wait(10);
    await bench.phase(AudioPhase.paused);
    expect(bench.sent, [(album[0].id, 10000)]);

    bench.wait(600);
    await bench.phase(AudioPhase.playing);
    bench.wait(25);
    await bench.player.next();

    expect(bench.sent, [(album[0].id, 10000), (album[0].id, 35000)]);
  });

  test('buffering is not counted', () async {
    final bench = Bench();
    await bench.player.playQueue(album);
    await bench.phase(AudioPhase.playing);
    bench.wait(5);
    await bench.phase(AudioPhase.buffering);
    bench.wait(20);
    await bench.phase(AudioPhase.playing);
    bench.wait(5);

    await bench.player.next();

    expect(bench.sent, [(album[0].id, 10000)]);
  });

  test('song finished: reported; next counts from zero', () async {
    final bench = Bench();
    await bench.player.playQueue(album);
    await bench.phase(AudioPhase.playing);
    bench.wait(200);
    bench.audio.finish();
    await settle();
    expect(bench.sent, [(album[0].id, 200000)]);
    expect(bench.player.current, album[1]);

    await bench.phase(AudioPhase.playing);
    bench.wait(5);
    await bench.player.next();

    expect(bench.sent, [(album[0].id, 200000), (album[1].id, 5000)]);
  });

  test('retry after a drop continues the same listen', () async {
    final bench = Bench();
    await bench.player.playQueue(album);
    await bench.phase(AudioPhase.playing);
    bench.wait(20);
    await bench.phase(AudioPhase.error, position: const Duration(seconds: 20));

    await bench.player.retry();
    await bench.phase(AudioPhase.playing);
    bench.wait(15);
    await bench.player.next();

    expect(bench.sent, [(album[0].id, 35000)]);
  });

  test('played zero seconds: nothing reported', () async {
    final bench = Bench();
    await bench.player.playQueue(album);
    await bench.phase(AudioPhase.buffering);
    bench.wait(30);

    await bench.player.next();

    expect(bench.sent, isEmpty);
  });

  testWidgets('in app: POST /v1/history with launch count (D1)', (
    tester,
  ) async {
    final rig = Rig();
    await rig.start(tester);
    await typeSearch(tester, 'metallica');
    await tester.tap(find.text('Nothing Else Matters').first);
    await tester.pump();
    rig.audio.emit(AudioPhase.playing);
    await tester.pump();
    // Real clock: song needs to play for some duration.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    rig.audio.emit(AudioPhase.paused);
    await tester.pumpAndSettle();

    final body = rig.server.bodies('POST /v1/history').single;
    expect(
      body.keys,
      unorderedEquals(['listen_id', 'track_id', 'started_at', 'listened_ms']),
    );
    expect(body['track_id'], '11111111-1111-1111-1111-111111111111');
    expect(body['listened_ms'], allOf(isA<int>(), greaterThanOrEqualTo(30)));
  });

  testWidgets('POST /v1/history sends artwork_url', (tester) async {
    final rig = Rig();
    rig.server.on(
      'GET /v1/search',
      (_) => answer(200, {
        'artists': [
          {'name': 'Metallica'},
        ],
        'tracks': [
          songLike(
            'search',
            '11111111-1111-1111-1111-111111111111',
            'Nothing Else Matters',
          )..['artwork_url'] = '/v1/covers/black-album',
        ],
      }),
    );
    await rig.start(tester);
    await typeSearch(tester, 'metallica');
    await tester.tap(find.text('Nothing Else Matters').first);
    await tester.pump();
    rig.audio.emit(AudioPhase.playing);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    rig.audio.emit(AudioPhase.paused);
    await tester.pumpAndSettle();

    final body = rig.server.bodies('POST /v1/history').single;
    expect(body['artwork_url'], '/v1/covers/black-album');
  });
}
