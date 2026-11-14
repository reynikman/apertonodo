import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';
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

/// P7, P-A62: the phone records the app's own audio (FT-549).
///
/// No server needed: gaplessness is a player property. The test writes 1 kHz tone
/// WAV files (volume 0.5, 48 kHz) with continuous phase between chunks directly to
/// app directory and plays them through the app's real player
/// (`Player`/`DeviceAudio`, `file://`, like downloaded files), not bypassing it:
///   clean — single 6 s file;
///   hole  — single 6 s file with 100 ms silence in the middle;
///   album — three 2 s files, single queue, automatic track advance at song end.
///
/// The work is split between two sides, like `device_offline.sh`. The dev test build
/// records audio (`apertono/gapless`), the test prints `GAP_ASK=<action>`, and
/// `scripts/device_gapless.sh` performs action via adb: grants permissions and
/// clicks the system recording consent dialog. Each case is its own recording;
/// `manifest.json` matches format from `scripts/gapless_capture_check.py`.
const channel = MethodChannel('apertono/gapless');
const rate = 48000;

void say(String line) {
  // ignore: avoid_print
  print(line);
}

/// Calling capture channel. Channel is attached to engine after activity
/// onCreate — in first moments it may still be absent.
Future<Object?> gapCall(String method, [Object? arguments]) async {
  for (var attempt = 0; ; attempt++) {
    try {
      return await channel.invokeMethod<Object>(method, arguments);
    } on MissingPluginException {
      if (attempt >= 40) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }
}

class TonePart {
  const TonePart.tone(this.seconds) : silent = false;
  const TonePart.silence(this.seconds) : silent = true;

  final double seconds;
  final bool silent;
}

/// WAV PCM 16-bit, stereo, 48 kHz — same format that capture records. Tone phase
/// continues across chunks and across files ([sampleIndex] returns where
/// stopped): file boundary must not be a phase boundary.
Future<int> writeToneWav(
  File file,
  List<TonePart> parts,
  int sampleIndex,
) async {
  var frames = 0;
  for (final part in parts) {
    frames += (part.seconds * rate).round();
  }
  final pcm = ByteData(frames * 4);
  var index = sampleIndex;
  var offset = 0;
  for (final part in parts) {
    final count = (part.seconds * rate).round();
    for (var i = 0; i < count; i++) {
      final value = part.silent ? 0.0 : 0.5 * sin(2 * pi * 1000 * index / rate);
      index++;
      final sample = (value * 32767).round();
      pcm.setInt16(offset, sample, Endian.little);
      pcm.setInt16(offset + 2, sample, Endian.little);
      offset += 4;
    }
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
  final bytes = BytesBuilder()
    ..add(header.buffer.asUint8List())
    ..add(pcm.buffer.asUint8List());
  await file.writeAsBytes(bytes.takeBytes(), flush: true);
  return index;
}

/// Song URL is a local phone file, like downloaded audio: no server.
class FilePlayback implements PlaybackPort {
  FilePlayback(this.files);

  final Map<String, String> files;

  @override
  Future<bool> isLocal(String trackId) async => files.containsKey(trackId);

  @override
  Future<String> start(String trackId, {bool prepare = false}) async {
    final path = files[trackId];
    if (path == null) {
      throw const PlaybackFailed(PlayFailure.unknownTrack);
    }
    return 'file://$path';
  }

  @override
  Future<void> failed(String url) async {}
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('internal sound recording honest: drops appear as pauses', (
    tester,
  ) async {
    // Permissions are granted by script before first audio: test cannot
    // click system dialogs (device_offline.sh does the same).
    say('GAP_ASK=grant');
    await Future<void>.delayed(const Duration(seconds: 3));
    await initBackgroundAudio();

    final root = await getApplicationSupportDirectory();
    final sources = Directory('${root.path}/gapless-src');
    final captures = Directory('${root.path}/gapless');
    if (sources.existsSync()) await sources.delete(recursive: true);
    if (captures.existsSync()) await captures.delete(recursive: true);
    await sources.create(recursive: true);
    await captures.create(recursive: true);
    say('GAP_DIR=${captures.path}');

    // 1 kHz tones with continuous phase: file boundary is not a phase boundary.
    var phase = 0;
    phase = await writeToneWav(File('${sources.path}/clean.wav'), const [
      TonePart.tone(6),
    ], phase);
    phase = await writeToneWav(File('${sources.path}/hole.wav'), const [
      TonePart.tone(2.95),
      TonePart.silence(0.1),
      TonePart.tone(2.95),
    ], phase);
    final albumPaths = <String>[];
    for (var i = 0; i < 3; i++) {
      final file = File('${sources.path}/album-${i + 1}.wav');
      phase = await writeToneWav(file, const [TonePart.tone(2)], phase);
      albumPaths.add(file.path);
    }

    // App's real player: player needs tokens, file plays from the phone.
    final tokens = TokenProvider(
      SessionStore(),
      server: Uri.parse('http://127.0.0.1'),
    );
    final audio = DeviceAudio(tokens: tokens);
    final files = <String, String>{
      'gapless-clean': '${sources.path}/clean.wav',
      'gapless-hole': '${sources.path}/hole.wav',
      'gapless-album-1': albumPaths[0],
      'gapless-album-2': albumPaths[1],
      'gapless-album-3': albumPaths[2],
    };
    final player = Player(playback: FilePlayback(files), audio: audio);
    addTearDown(player.dispose);

    Future<void> waitPhase(
      AudioPhase wanted,
      Duration limit,
      String reason,
    ) async {
      final deadline = DateTime.now().add(limit);
      while (player.phase != wanted && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      expect(player.phase, wanted, reason: reason);
    }

    Future<void> waitRecording(Duration limit) async {
      final deadline = DateTime.now().add(limit);
      var on = false;
      while (!on && DateTime.now().isBefore(deadline)) {
        on = await gapCall('isRecording') == true;
        if (!on) await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      expect(
        on,
        isTrue,
        reason: 'recording did not start - consent dialog not clicked?',
      );
    }

    // One case — one recording. Recording starts before audio and ends after
    // it: silence at the edges is not a dropout, and meter knows this.
    Future<void> recordCase(String name, Future<void> Function() play) async {
      say('GAP_STAGE=$name');
      final started = await gapCall('start', {
        'path': '${captures.path}/$name.wav',
      });
      if (started != true) {
        // Android displayed consent dialog — script clicks it (GAP_ASK=consent).
        say('GAP_ASK=consent');
        await waitRecording(const Duration(seconds: 45));
      } else {
        expect(
          await gapCall('isRecording'),
          isTrue,
          reason: 'recording $name did not start although consent was given',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await play();
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(
        await gapCall('stop'),
        isTrue,
        reason: 'recording $name did not close',
      );
    }

    Track track(String id, int durationMs) => Track(
      id: id,
      title: id,
      artist: 'Flowtune',
      durationMs: durationMs,
      artworkUrl: '',
    );

    Future<void> playOne(Track one) async {
      await player.select(one);
      await waitPhase(
        AudioPhase.playing,
        const Duration(seconds: 20),
        'файл ${one.id} не играет через плеер приложения',
      );
      await waitPhase(
        AudioPhase.idle,
        const Duration(seconds: 30),
        'файл ${one.id} не доиграл до конца',
      );
    }

    await recordCase('clean', () => playOne(track('gapless-clean', 6000)));
    await recordCase('hole', () => playOne(track('gapless-hole', 6000)));
    await recordCase('album', () async {
      await player.playQueue([
        track('gapless-album-1', 2000),
        track('gapless-album-2', 2000),
        track('gapless-album-3', 2000),
      ]);
      await waitPhase(
        AudioPhase.playing,
        const Duration(seconds: 20),
        'альбом не начал играть через очередь приложения',
      );
      // At boundary player may briefly show idle: wait for third song first,
      // and only then end of queue — otherwise recording aborts after first.
      final third = DateTime.now().add(const Duration(seconds: 30));
      while (player.current?.id != 'gapless-album-3' &&
          DateTime.now().isBefore(third)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      expect(
        player.current?.id,
        'gapless-album-3',
        reason: 'queue did not reach third song on its own',
      );
      await waitPhase(
        AudioPhase.idle,
        const Duration(seconds: 60),
        'альбом не доиграл: очередь не дошла до конца',
      );
    });

    await File('${captures.path}/manifest.json').writeAsString(
      jsonEncode({
        'cases': {
          'clean': {'file': 'clean.wav', 'tone_s': 6},
          'hole': {'file': 'hole.wav', 'tone_s': 6, 'hole_ms': 100},
          'album': {'file': 'album.wav', 'tone_s': 6, 'tracks': 3},
        },
      }),
    );
    await gapCall('close');
    // flutter drive uninstalls app right after test — along with recordings
    // folder. Mac pulls them now and puts a `pulled` marker.
    say('GAP_ASK=pull');
    final pulled = File('${captures.path}/pulled');
    final until = DateTime.now().add(const Duration(seconds: 60));
    while (!pulled.existsSync() && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    expect(pulled.existsSync(), isTrue, reason: 'mac did not pull recordings');
    say('GAP_DONE');
  });
}
