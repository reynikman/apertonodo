import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/opened_audio.dart';
import 'package:music_stream/playback.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';

/// FT-767: "Open with". Audio file from file manager plays immediately,
/// via `content://` from system, bypassing server.
const channel = MethodChannel('apertono/open');

/// Audio "prepares" with spinner — `pumpAndSettle` will never finish.
Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  void answerInitial(WidgetTester tester, Object? initial) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'initialAudio') return initial;
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
  }

  Future<void> deliver(WidgetTester tester, Map<String, String> file) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('openAudio', file),
      ),
      (_) {},
    );
  }

  testWidgets('file opened with app plays immediately', (tester) async {
    answerInitial(tester, {
      'uri': 'content://media/external/audio/media/7',
      'name': 'Song From Phone',
    });
    final rig = Rig(opened: OpenedAudioChannel());
    await rig.start(tester);
    await frames(tester);
    rig.audio.emit(AudioPhase.playing);
    await tester.pump();
    await tester.pump();

    expect(rig.audio.played.last.$1, 'content://media/external/audio/media/7');
    expect(find.text('Song From Phone'), findsWidgets);
  });

  testWidgets('file opened while app running replaces track', (tester) async {
    answerInitial(tester, null);
    final rig = Rig(opened: OpenedAudioChannel());
    await rig.start(tester);
    await tester.pumpAndSettle();
    expect(rig.audio.played, isEmpty, reason: 'nothing plays without file');

    await deliver(tester, {
      'uri': 'content://downloads/1',
      'name': 'Voice Note',
    });
    await frames(tester);
    expect(rig.audio.played.last.$1, 'content://downloads/1');
  });

  testWidgets('non-audio input ignored', (tester) async {
    answerInitial(tester, {'uri': '', 'name': 'x'});
    final rig = Rig(opened: OpenedAudioChannel());
    await rig.start(tester);
    await tester.pumpAndSettle();
    await deliver(tester, {'name': 'no uri'});
    await tester.pumpAndSettle();
    expect(rig.audio.played, isEmpty);
  });

  test('local device file never sent to server for stream url', () async {
    final inner = _Inner();
    final playback = OpenedPlayback(inner);
    final track = playback.open('content://x/1', 'A');
    expect(await playback.start(track.id), 'content://x/1');
    await playback.failed('content://x/1');
    expect(inner.calls, isEmpty);
    expect(await playback.start('t1'), 'inner:t1');
  });
}

class _Inner implements PlaybackPort {
  final calls = <String>[];

  @override
  Future<String> start(String trackId, {bool prepare = false}) async {
    calls.add('start $trackId');
    return 'inner:$trackId';
  }

  @override
  Future<bool> isLocal(String trackId) async => false;

  @override
  Future<void> failed(String url) async => calls.add('failed $url');
}
