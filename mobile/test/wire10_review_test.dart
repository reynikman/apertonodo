import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/app.dart';
import 'package:music_stream/models/track.dart';
import 'package:music_stream/network_watch.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/prefetch_policy.dart';
import 'package:music_stream/quality_prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';
import 'fakes.dart';
import 'player_fixes_test.dart' show openPlayer, song;

Track _song(int n) => Track(
  id: '$n',
  title: 'Song $n',
  artist: 'Artist',
  durationMs: 200000,
  artworkUrl: '',
);

class TestNetwork implements NetworkPort {
  TestNetwork({this.throwOnAsk = false});

  final bool throwOnAsk;
  final changes = StreamController<bool>.broadcast();

  @override
  Stream<bool> get online => changes.stream;

  @override
  Future<bool> get isOnline async {
    if (throwOnAsk) throw StateError('no network service');
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('FT-692 Prefetch', () {
    testWidgets('Never does not prefetch or append next track', (tester) async {
      final prefetch = PrefetchPolicy();
      await prefetch.set(PrefetchMode.never);
      final audio = FakeAudio();
      addTearDown(audio.close);
      final playback = FakePlayback();

      await tester.pumpWidget(
        MusicApp(
          catalog: [_song(1), _song(2), _song(3)],
          playback: playback,
          audio: audio,
          server: FakeServer().api(),
          prefetch: prefetch,
        ),
      );
      await tester.pumpAndSettle();
      await typeSearch(tester, 'Song');
      await tester.tap(find.text('Song 1').first);
      await tester.pump();
      await tester.pump();
      audio.emit(AudioPhase.playing);
      await tester.pump();
      await tester.pump();

      expect(playback.prepared, isNot(contains('2')));
      expect(audio.queued, isEmpty);
      expect(audio.queuedNow, isNull);
    });

    testWidgets('setting Always prefetches on next track', (tester) async {
      final prefetch = PrefetchPolicy();
      await prefetch.set(PrefetchMode.never);
      final audio = FakeAudio();
      addTearDown(audio.close);
      final playback = FakePlayback();

      await tester.pumpWidget(
        MusicApp(
          catalog: [_song(1), _song(2), _song(3)],
          playback: playback,
          audio: audio,
          server: FakeServer().api(),
          prefetch: prefetch,
        ),
      );
      await tester.pumpAndSettle();
      await typeSearch(tester, 'Song');
      await tester.tap(find.text('Song 1').first);
      await tester.pump();
      audio.emit(AudioPhase.playing);
      await tester.pump();
      expect(playback.prepared, isNot(contains('2')));

      // Switch setting to "Always" without restarting app
      await prefetch.set(PrefetchMode.always);
      await tester.pump();

      // Transition to track 2
      await tester.tap(find.text('Song 2').first);
      await tester.pump();
      audio.emit(AudioPhase.playing);
      await tester.pump();
      await tester.pump();

      // Track 3 must be prepared
      expect(playback.prepared, contains('3'));
    });

    testWidgets('English locale in audio quality sheet', (tester) async {
      tester.platformDispatcher.localeTestValue = const Locale('en');
      tester.platformDispatcher.localesTestValue = const [Locale('en')];
      addTearDown(() {
        tester.platformDispatcher.localeTestValue = const Locale('ru');
        tester.platformDispatcher.localesTestValue = const [Locale('ru')];
      });
      final prefetch = PrefetchPolicy();
      final rig = Rig(
        account: true,
        prefetch: prefetch,
        quality: QualityPrefs(),
      );
      await rig.start(tester);
      await tester.pumpAndSettle();

      await typeSearch(tester, 'metallica');
      await tester.tap(find.text(song));
      await tester.pump();
      rig.audio.emit(AudioPhase.playing);
      await tester.pump();
      await tester.pump();

      await openTab(tester, 'home');
      await tester.pumpAndSettle();
      await openPlayer(tester);

      await openSoundQuality(tester);

      expect(find.text('Preload the next song'), findsOneWidget);
      expect(find.text('Always'), findsOneWidget);
      expect(find.text('Wi-Fi only'), findsOneWidget);
      expect(find.text('Never'), findsOneWidget);
      expect(
        find.text('A short pause between songs; saves mobile data'),
        findsOneWidget,
      );
    });

    testWidgets('TalkBack: radio semantics for prefetch sheet', (tester) async {
      final sem = tester.ensureSemantics();
      final prefetch = PrefetchPolicy();
      await prefetch.set(PrefetchMode.wifiOnly);
      final rig = Rig(
        account: true,
        prefetch: prefetch,
        quality: QualityPrefs(),
      );
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

      await openSoundQuality(tester);

      expect(
        tester.getSemantics(find.text('Только Wi-Fi')),
        isSemantics(isChecked: true),
      );
      expect(
        tester.getSemantics(find.text('Всегда')),
        isSemantics(isChecked: false),
      );
      expect(
        tester.getSemantics(find.text('Никогда')),
        isSemantics(isChecked: false),
      );
      sem.dispose();
    });
  });

  group('FT-691 NetworkWatch & Player.networkReturned', () {
    testWidgets('networkReturned does not restart playing track', (
      tester,
    ) async {
      final audio = FakeAudio();
      addTearDown(audio.close);
      final network = TestNetwork();
      addTearDown(network.changes.close);
      final playback = FakePlayback();

      await tester.pumpWidget(
        MusicApp(
          catalog: [_song(1)],
          playback: playback,
          audio: audio,
          server: FakeServer().api(),
          network: network,
        ),
      );
      await tester.pumpAndSettle();
      await typeSearch(tester, 'Song');
      await tester.tap(find.text('Song 1').first);
      await tester.pump();
      audio.emit(AudioPhase.playing);
      await tester.pump();

      expect(playback.started, hasLength(1));

      // Network blip: turned off then on
      network.changes.add(false);
      await tester.pump(const Duration(milliseconds: 500));
      network.changes.add(true);
      await tester.pump(const Duration(milliseconds: 2500));

      // Track must not restart
      expect(playback.started, hasLength(1));
    });

    testWidgets('networkReturned does not restart paused track', (
      tester,
    ) async {
      final audio = FakeAudio();
      addTearDown(audio.close);
      final network = TestNetwork();
      addTearDown(network.changes.close);
      final playback = FakePlayback();

      await tester.pumpWidget(
        MusicApp(
          catalog: [_song(1)],
          playback: playback,
          audio: audio,
          server: FakeServer().api(),
          network: network,
        ),
      );
      await tester.pumpAndSettle();
      await typeSearch(tester, 'Song');
      await tester.tap(find.text('Song 1').first);
      await tester.pump();
      audio.emit(AudioPhase.playing);
      await tester.pump();

      // User paused playback
      audio.emit(AudioPhase.paused);
      await tester.pump();
      expect(playback.started, hasLength(1));

      // Network returned
      network.changes.add(false);
      await tester.pump(const Duration(milliseconds: 500));
      network.changes.add(true);
      await tester.pump(const Duration(milliseconds: 2500));

      // Track remains paused, no new requests
      expect(playback.started, hasLength(1));
    });

    testWidgets('retry does not fire twice (timer canceled)', (tester) async {
      final audio = FakeAudio();
      addTearDown(audio.close);
      final network = TestNetwork();
      addTearDown(network.changes.close);
      // First 3 requests (0, 1, 3 s) fail, 4th (network signal at 6 s) succeeds
      final playback = FakePlayback([
        PlayFailure.noAnswer,
        PlayFailure.noAnswer,
        PlayFailure.noAnswer,
        'https://stream.example/1',
      ]);

      await tester.pumpWidget(
        MusicApp(
          catalog: [_song(1)],
          playback: playback,
          audio: audio,
          server: FakeServer().api(),
          network: network,
        ),
      );
      await tester.pumpAndSettle();
      await typeSearch(tester, 'Song');
      await tester.tap(find.text('Song 1').first);
      await tester.pump();

      // By 3.5 s 3 requests occurred (0, 1, 3 s), timer set to 7 s (4 s delay)
      await tester.pump(const Duration(milliseconds: 3500));
      expect(playback.started, hasLength(3));

      // Network dropped and returned
      network.changes.add(false);
      await tester.pump(const Duration(milliseconds: 500));
      network.changes.add(true);

      // After 2 s (at 6.0 s) network restored — 4th request starts, playback begins
      await tester.pump(const Duration(milliseconds: 2000));
      expect(playback.started, hasLength(4));

      // Verify at 7.5 s mark (when old 7 s timer was scheduled):
      // old timer was canceled, no new requests
      await tester.pump(const Duration(milliseconds: 1500));
      expect(playback.started, hasLength(4));
    });

    testWidgets('dispose MusicApp unsubscribes NetworkWatch', (tester) async {
      final audio = FakeAudio();
      addTearDown(audio.close);
      final network = TestNetwork();
      addTearDown(network.changes.close);
      final playback = FakePlayback([PlayFailure.noAnswer]);

      // Instantiate first MusicApp
      await tester.pumpWidget(
        MusicApp(
          key: const ValueKey(1),
          catalog: [_song(1)],
          playback: playback,
          audio: audio,
          server: FakeServer().api(),
          network: network,
        ),
      );
      await tester.pumpAndSettle();
      await typeSearch(tester, 'Song');
      await tester.tap(find.text('Song 1').first);
      await tester.pump();
      expect(playback.started, hasLength(1));

      // Re-instantiate MusicApp with new key (account switch)
      await tester.pumpWidget(
        MusicApp(
          key: const ValueKey(2),
          catalog: [_song(1)],
          playback: playback,
          audio: audio,
          server: FakeServer().api(),
          network: network,
        ),
      );
      await tester.pumpAndSettle();

      // Network returned
      network.changes.add(false);
      await tester.pump(const Duration(milliseconds: 100));
      network.changes.add(true);
      await tester.pump(const Duration(milliseconds: 2500));

      // No retry occurred in stale player
      expect(playback.started, hasLength(1));
    });

    testWidgets('network plugin failure does not crash app', (tester) async {
      final audio = FakeAudio();
      addTearDown(audio.close);
      final brokenPort = TestNetwork(throwOnAsk: true);
      addTearDown(brokenPort.changes.close);

      await tester.pumpWidget(
        MusicApp(
          catalog: [_song(1)],
          playback: FakePlayback(),
          audio: audio,
          server: FakeServer().api(),
          network: brokenPort,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
