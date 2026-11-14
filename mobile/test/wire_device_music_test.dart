import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/device_library.dart';
import 'package:music_stream/device_media.dart';
import 'package:music_stream/playback.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';

/// FT-783: "Device music". Section in "My Music" displays tracks from
/// device storage and plays them via `content://` bypassing server.
class FakeMedia implements DeviceMediaPort {
  FakeMedia(this.state);

  DeviceAccess state;
  var asked = 0;

  @override
  Future<DeviceAccess> access() async => state;

  @override
  Future<DeviceAccess> request() async {
    asked++;
    return state = DeviceAccess.granted;
  }

  @override
  Future<List<DeviceSong>> songs() async => const [
    DeviceSong(
      uri: 'content://media/external/audio/media/11',
      title: 'Pocket Song',
      artist: 'Pocket Band',
      album: 'Pocket Album',
      albumId: '5',
      durationMs: 200000,
      path: '/storage/emulated/0/Music/Pocket Band/one.mp3',
    ),
    DeviceSong(
      uri: 'content://media/external/audio/media/12',
      title: 'Second Pocket Song',
      artist: 'Pocket Band',
      album: 'Pocket Album',
      albumId: '5',
      durationMs: 180000,
      path: '/storage/emulated/0/Music/Pocket Band/two.mp3',
    ),
  ];
}

Future<void> openDevice(WidgetTester tester) async {
  await openTab(tester, 'library');
  final entry = find.byKey(const Key('library-device'));
  await tester.scrollUntilVisible(
    entry,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(entry);
  await tester.pumpAndSettle();
}

Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('local track plays from device uri without server', (
    tester,
  ) async {
    final rig = Rig(deviceMedia: FakeMedia(DeviceAccess.granted));
    await rig.start(tester);
    await openDevice(tester);

    expect(find.text('Pocket Song'), findsOneWidget);
    await tester.tap(find.text('Second Pocket Song'));
    await frames(tester);

    expect(rig.audio.played.last.$1, 'content://media/external/audio/media/12');
    expect(
      rig.playback.started,
      isEmpty,
      reason: 'device file is not requested from server',
    );
    rig.audio.emit(AudioPhase.playing);
    await tester.pump();
    await tester.pump();
    expect(find.text('Pocket Band'), findsWidgets);
  });

  testWidgets('no permission shows request; Allow reveals tracks', (
    tester,
  ) async {
    final media = FakeMedia(DeviceAccess.denied);
    final rig = Rig(deviceMedia: media);
    await rig.start(tester);
    await openDevice(tester);

    expect(find.text('Pocket Song'), findsNothing);
    await tester.tap(find.text('Разрешить'));
    await tester.pumpAndSettle();
    expect(media.asked, 1);
    expect(find.text('Pocket Song'), findsOneWidget);
  });

  testWidgets('no device media access dims device tile', (tester) async {
    final rig = Rig();
    await rig.start(tester);
    await openTab(tester, 'library');
    await tester.pumpAndSettle();
    // FT-798: disabled tile remains in place without opening screen.
    final tile = find.byKey(const Key('library-device'));
    expect(tile, findsOneWidget);
    expect(
      find.descendant(of: tile, matching: find.byType(Opacity)),
      findsWidgets,
    );
    await tester.tap(tile, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('library-title')).hitTestable(),
      findsOneWidget,
    );
  });

  group('Android platform channel', () {
    const channel = MethodChannel('apertono/media');

    void answer(WidgetTester tester, Map<String, Object?> replies) {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async => replies[call.method],
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
    }

    testWidgets('tracks and permission read as-is', (tester) async {
      answer(tester, {
        'access': 'granted',
        'request': 'denied_forever',
        'songs': [
          {
            'uri': 'content://media/external/audio/media/3',
            'title': 'T',
            'artist': 'A',
            'album': 'Al',
            'albumId': '',
            'durationMs': 61000,
            'track': 4,
            'path': '/storage/emulated/0/Music/t.flac',
          },
          {'title': 'без адреса'},
          'мусор',
        ],
      });
      final media = ChannelDeviceMedia();
      expect(await media.access(), DeviceAccess.granted);
      expect(await media.request(), DeviceAccess.deniedForever);
      final songs = await media.songs();
      expect(songs, hasLength(1), reason: 'missing uri or garbage skipped');
      expect(songs.single.uri, 'content://media/external/audio/media/3');
      expect(songs.single.durationMs, 61000);
      expect(songs.single.track, 4);
      expect(songs.single.albumId, '', reason: 'empty album is not "0"');
    });

    testWidgets('missing channel yields no access, no crash', (tester) async {
      // Channel responds in real time only: call hangs in fake clock.
      final media = ChannelDeviceMedia();
      final access = await tester.runAsync(media.access);
      final songs = await tester.runAsync(media.songs);
      expect(access, DeviceAccess.denied);
      expect(songs, isEmpty);
    });
  });

  test('manifest requests audio permission; legacy for pre-Android 13', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml');
    final text = manifest.readAsStringSync();
    expect(text, contains('android.permission.READ_MEDIA_AUDIO'));
    expect(
      RegExp(
        r'READ_EXTERNAL_STORAGE"\s+android:maxSdkVersion="32"',
      ).hasMatch(text),
      isTrue,
    );
  });
}
