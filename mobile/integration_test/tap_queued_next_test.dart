import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:music_stream/auth/session_store.dart';
import 'package:music_stream/auth/token_provider.dart';
import 'package:music_stream/device_audio.dart';
import 'package:music_stream/main.dart' show initBackgroundAudio;
import 'package:music_stream/models/track.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/player.dart';
import 'package:path_provider/path_provider.dart';

/// FT-554, P-A73 p. 1: tapped a song in playlist that is already queued
/// next (FT-550) — it plays instead of "nothing happens".
///
/// Owner finding 04.10: after tapping song in playlist, no requests
/// went to server — neither Play nor stream. Next song is already queued and
/// downloading to reserve file (`reserveCache`), filename based on song ID. Tapping
/// same song opens a second source into the same file.
///
/// No server needed: test starts HTTP on phone itself and serves tones over
/// network to use real caching sources, as in production. Serves second
/// song slowly — it is still downloading when tapped.
const rate = 48000;

void say(String line) {
  // ignore: avoid_print
  print(line);
}

/// WAV PCM 16-bit, stereo, 48 kHz, quiet tone.
Uint8List toneWav(double seconds) {
  final frames = (seconds * rate).round();
  final pcm = ByteData(frames * 4);
  for (var i = 0; i < frames; i++) {
    final value = ((i ~/ 24) % 2 == 0 ? 1 : -1) * 3000;
    pcm.setInt16(i * 4, value, Endian.little);
    pcm.setInt16(i * 4 + 2, value, Endian.little);
  }
  final header = ByteData(44);
  void tag(int at, String text) {
    for (var i = 0; i < text.length; i++) {
      header.setUint8(at + i, text.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  header.setUint32(4, 36 + pcm.lengthInBytes, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, 2, Endian.little);
  header.setUint32(24, rate, Endian.little);
  header.setUint32(28, rate * 4, Endian.little);
  header.setUint16(32, 4, Endian.little);
  header.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  header.setUint32(40, pcm.lengthInBytes, Endian.little);
  return (BytesBuilder()
        ..add(header.buffer.asUint8List())
        ..add(pcm.buffer.asUint8List()))
      .takeBytes();
}

/// Song URL is HTTP on phone itself.
class HttpPlayback implements PlaybackPort {
  HttpPlayback(this.base);

  final Uri base;

  @override
  Future<bool> isLocal(String trackId) async => false;

  @override
  Future<String> start(String trackId, {bool prepare = false}) async =>
      base.resolve('/$trackId.wav').toString();

  @override
  Future<void> failed(String url) async {}
}

Track song(int n) => Track(
  id: 'tap-next-$n',
  title: 'Tap Next $n',
  artist: 'Flowtune',
  durationMs: 20000,
  artworkUrl: '',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('tapping the glued next queued song plays it immediately', (
    tester,
  ) async {
    await initBackgroundAudio();
    final wav = toneWav(20);
    final asked = <String>[];
    var sending = 0; // открытые ответы медленной второй песни
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final name = request.uri.pathSegments.last;
      asked.add(name);
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType('audio', 'wav')
        ..contentLength = wav.length;
      // Second song downloads slowly: not fully downloaded when tapped.
      final slow = name == 'tap-next-2.wav';
      const chunk = 32 * 1024;
      if (slow) sending++;
      try {
        for (var at = 0; at < wav.length; at += chunk) {
          final end = at + chunk > wav.length ? wav.length : at + chunk;
          request.response.add(wav.sublist(at, end));
          await request.response.flush();
          if (slow) {
            await Future<void>.delayed(const Duration(milliseconds: 250));
          }
        }
        await request.response.close();
      } catch (_) {
        // Player closed connection — normal behavior.
      } finally {
        if (slow) sending--;
      }
    });

    final root = await getApplicationSupportDirectory();
    final cache = Directory('${root.path}/tap-next-cache');
    if (cache.existsSync()) await cache.delete(recursive: true);
    await cache.create(recursive: true);
    final base = Uri.parse('http://127.0.0.1:${server.port}');
    final audio = DeviceAudio(
      tokens: TokenProvider(SessionStore(), server: base),
      // Like in app (main.dart): reserve filename based on song ID.
      reserveCache: (id) async => File('${cache.path}/$id'),
    );
    final player = Player(playback: HttpPlayback(base), audio: audio);
    addTearDown(player.dispose);

    Future<bool> waitFor(bool Function() ok, Duration limit) async {
      final deadline = DateTime.now().add(limit);
      while (!ok() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      return ok();
    }

    final album = [song(1), song(2), song(3)];
    await player.playQueue(album);
    expect(
      await waitFor(
        () => player.phase == AudioPhase.playing,
        const Duration(seconds: 20),
      ),
      isTrue,
      reason: 'first song did not play - scenario did not reach check',
    );
    say('TAP_STAGE=first-playing');
    // Second track queued next, already downloading.
    expect(
      await waitFor(
        () => asked.contains('tap-next-2.wav'),
        const Duration(seconds: 15),
      ),
      isTrue,
      reason: 'second song not glued - scenario did not reach check',
    );
    say('TAP_STAGE=next-queued');
    await Future<void>.delayed(const Duration(seconds: 1));

    // Tapping second in list — same as what playlist screen does.
    final tapped = player.playQueue(album, start: 1);
    final played = await waitFor(
      () =>
          player.current?.id == 'tap-next-2' &&
          player.phase == AudioPhase.playing &&
          audio.position > const Duration(milliseconds: 500),
      const Duration(seconds: 10),
    );
    say(
      'TAP_RESULT current=${player.current?.id} phase=${player.phase} '
      'position=${audio.position.inMilliseconds}',
    );
    expect(
      played,
      isTrue,
      reason: 'tapped song did not play in 10s - nothing happens',
    );
    await tapped.timeout(const Duration(seconds: 5));
    // Finish second song download within test: two sources error
    // in one reserve file (PathNotFoundException in
    // LockCachingAudioSource) otherwise arrives after test — when unlucky.
    expect(
      await waitFor(() => sending == 0, const Duration(seconds: 60)),
      isTrue,
      reason: 'download of second song did not finish in 60s',
    );
    await Future<void>.delayed(const Duration(seconds: 2));
    final kept = File('${cache.path}/tap-next-2');
    say(
      'TAP_CACHE kept=${kept.existsSync() ? kept.lengthSync() : -1} '
      'part=${File('${kept.path}.part').existsSync()}',
    );
    expect(
      kept.existsSync() && kept.lengthSync() == wav.length,
      isTrue,
      reason: 'spare file of second song not intact after download',
    );
    await player.toggle();
  });
}
