import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_stream/offline/offline_playback.dart';
import 'package:music_stream/offline/track_store.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/screens/player_screen.dart';
import 'package:music_stream/track_formats.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fake_server.dart';
import 'fakes.dart' show tokensFor;
import 'player_fixes_test.dart' show openPlayer, song;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('TrackFormats review', () {
    test('format cache: replayed track lost on eviction', () {
      final formats = TrackFormats();
      formats.note('track-0', {'format': 'flac'});
      for (var i = 1; i < 200; i++) {
        formats.note('track-$i', {'format': 'mp3'});
      }
      // Exactly 200 tracks in memory, track-0 is oldest.
      // Now track-0 plays again with same format:
      formats.note('track-0', {'format': 'flac'});
      // Next track is prepared (exceeding 200 limit):
      formats.note('track-200', {'format': 'mp3'});
      // track-0 has just played, but the early return kept its order from being updated,
      // and it was evicted:
      expect(formats.of('track-0'), 'flac');
    });

    test('replaying same track without audio block clears old format', () {
      final formats = TrackFormats();
      formats.note('track-1', {'format': 'flac'});
      expect(formats.of('track-1'), 'flac');
      // Same track restarted, but Play response lacks audio block:
      formats.note('track-1', null);
      expect(formats.of('track-1'), isNull);
    });
  });

  group('PlayerScreen widget review', () {
    testWidgets('tapping artist opens page even with badge present', (
      tester,
    ) async {
      final formats = TrackFormats();
      final rig = Rig(formats: formats);
      await rig.start(tester);
      await tester.pumpAndSettle();
      await typeSearch(tester, 'metallica');
      await tester.tap(find.text(song));
      await tester.pump();
      rig.audio.emit(AudioPhase.playing);
      await tester.pump();
      await openTab(tester, 'home');
      await tester.pumpAndSettle();
      await openPlayer(tester);

      final current = tester
          .widget<PlayerScreen>(find.byType(PlayerScreen))
          .player
          .current!;
      formats.note(current.id, {'format': 'flac'});
      await tester.pumpAndSettle();

      final artistFinder = find.byKey(const Key('player-artist'));
      expect(artistFinder, findsOneWidget);
      await tester.tap(artistFinder);
      await tester.pumpAndSettle();

      expect(find.text(current.artist), findsAtLeastNWidgets(1));
    });

    testWidgets('narrow screen and large font do not overflow artist row', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });

      final formats = TrackFormats();
      final rig = Rig(formats: formats);
      await rig.start(tester);
      await tester.pumpAndSettle();
      await typeSearch(tester, 'metallica');
      await tester.tap(find.text(song));
      await tester.pump();
      rig.audio.emit(AudioPhase.playing);
      await tester.pump();
      await openTab(tester, 'home');
      await tester.pumpAndSettle();
      await openPlayer(tester);

      final current = tester
          .widget<PlayerScreen>(find.byType(PlayerScreen))
          .player
          .current!;
      formats.note(current.id, {'format': 'flac'});
      await tester.pumpAndSettle();

      final err = tester.takeException();
      expect(err, isNull);
    });
  });

  group('OfflinePlayback review', () {
    test('downloaded track preserves previous streaming format', () async {
      sqfliteFfiInit();
      final tempDir = await Directory.systemTemp.createTemp('apertono_test_');
      addTearDown(() => tempDir.delete(recursive: true));
      final store = await TrackStore.open(
        root: tempDir,
        namespace: 'account',
        databaseFactory: databaseFactoryFfi,
        now: () => DateTime.now(),
        freeBytes: () async => 10 * 1024 * 1024 * 1024,
      );
      final formats = TrackFormats();
      final inner = HttpPlayback(
        'https://music.test',
        tokens: tokensFor('https://music.test'),
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'token': 't',
              'state': 'ready',
              'track': <String, Object>{},
              'audio': {'format': 'mp3'},
            }),
            200,
          ),
        ),
        formats: formats,
      );
      // First track played over network as mp3:
      await inner.start('track-1');
      expect(formats.of('track-1'), 'mp3');

      // Then track downloaded to device as flac:
      final part = store.partFile('track-1', format: 'flac');
      await part.parent.create(recursive: true);
      await part.writeAsBytes(List.filled(100, 1));
      await store.commit('track-1', format: 'flac', hold: Hold.download);

      // Launch via OfflinePlayback (matching main.dart):
      final offline = OfflinePlayback(
        inner: inner,
        store: Future.value(store),
        tokens: tokensFor('https://music.test'),
        formats: formats,
      );
      await offline.start('track-1');

      // Format must update to flac (actual playing file on device):
      expect(formats.of('track-1'), 'flac');
    });
  });
}
