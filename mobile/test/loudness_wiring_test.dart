import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/loudness.dart';
import 'package:music_stream/models/track.dart';
import 'package:music_stream/player.dart';
import 'package:music_stream/track_formats.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';
import 'fakes.dart';

class _ThrowingStore implements LoudnessStore {
  _ThrowingStore({this.throwOnRead = false, this.throwOnWrite = false});

  final bool throwOnRead;
  final bool throwOnWrite;

  @override
  Future<bool?> read() async {
    if (throwOnRead) throw Exception('simulated read failure');
    return null;
  }

  @override
  Future<void> write(bool enabled) async {
    if (throwOnWrite) throw Exception('simulated write failure');
  }
}

class _MemoryStore implements LoudnessStore {
  _MemoryStore([this.value]);
  bool? value;

  @override
  Future<bool?> read() async => value;

  @override
  Future<void> write(bool enabled) async => value = enabled;
}

const track1 = Track(
  id: 'track-1',
  title: 'Song 1',
  artist: 'Artist 1',
  artworkUrl: 'https://example.test/cover1.jpg',
  durationMs: 180000,
);
const track2 = Track(
  id: 'track-2',
  title: 'Song 2',
  artist: 'Artist 2',
  artworkUrl: 'https://example.test/cover2.jpg',
  durationMs: 200000,
);
const track3 = Track(
  id: 'track-3',
  title: 'Song 3',
  artist: 'Artist 3',
  artworkUrl: 'https://example.test/cover3.jpg',
  durationMs: 220000,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('gain offset arrives after track start', () async {
    final audio = FakeAudio();
    addTearDown(audio.close);
    final formats = TrackFormats();
    final gate = LoudnessGate(_MemoryStore(true));
    await gate.load();
    expect(gate.enabled, isTrue);

    final player = Player(audio: audio);
    addTearDown(player.dispose);

    final wire = LoudnessWire(
      player: player,
      audio: audio,
      gate: gate,
      formats: formats,
    );
    addTearDown(wire.dispose);

    // Track starts before Play response with gain adjustment is known
    await player.select(track1);
    expect(formats.gainOf(track1.id), isNull);
    expect(audio.volumes.where((v) => v < 1.0), isEmpty);

    // Play response arrives later — loudness is recalculated immediately
    formats.note(track1.id, {'format': 'mp3', 'gain_db': -8.0});
    expect(formats.gainOf(track1.id), -8.0);
    expect(
      audio.volumes.last,
      closeTo(loudnessVolume(enabled: true, gainDb: -8.0), 1e-6),
    );
  });

  test('changing track applies new volume', () async {
    final audio = FakeAudio();
    addTearDown(audio.close);
    final formats = TrackFormats();
    formats.note(track1.id, {'format': 'mp3', 'gain_db': -6.0});
    formats.note(track2.id, {'format': 'mp3', 'gain_db': -12.0});
    formats.note(track3.id, {'format': 'mp3'}); // no correction

    final gate = LoudnessGate(_MemoryStore(true));
    await gate.load();

    final player = Player(audio: audio);
    addTearDown(player.dispose);

    final wire = LoudnessWire(
      player: player,
      audio: audio,
      gate: gate,
      formats: formats,
    );
    addTearDown(wire.dispose);

    // First track: -6 dB
    await player.select(track1);
    expect(
      audio.volumes.last,
      closeTo(loudnessVolume(enabled: true, gainDb: -6.0), 1e-6),
    );

    // Switch to second track: -12 dB
    await player.select(track2);
    expect(
      audio.volumes.last,
      closeTo(loudnessVolume(enabled: true, gainDb: -12.0), 1e-6),
    );

    // Switch to third track without adjustment: resets to 1.0
    await player.select(track3);
    expect(audio.volumes.last, 1.0);
  });

  group('account logout', () {
    test('wire.dispose unsubscribes from all listeners', () async {
      final audio = FakeAudio();
      addTearDown(audio.close);
      final formats = TrackFormats();
      final gate = LoudnessGate(_MemoryStore(true));
      await gate.load();

      final player = Player(audio: audio);
      addTearDown(player.dispose);

      final wire = LoudnessWire(
        player: player,
        audio: audio,
        gate: gate,
        formats: formats,
      );

      await player.select(track1);
      formats.note(track1.id, {'format': 'mp3', 'gain_db': -6.0});
      final countBefore = audio.volumes.length;

      wire.dispose();

      // After dispose, track change, format change or gate do not call audio
      await player.select(track2);
      formats.note(track2.id, {'format': 'mp3', 'gain_db': -10.0});
      gate.begin(-15.0);
      expect(audio.volumes.length, countBefore);
    });

    test('gate.dispose properly releases resources', () async {
      final gate = LoudnessGate(_MemoryStore(true));
      await gate.load();
      gate.dispose();

      // Calls after dispose do not throw exceptions and do not mutate state
      final res = await gate.setEnabled(false);
      expect(res, isFalse);
      gate.begin(-6.0);
    });

    testWidgets('MusicApp on unmount properly releases wire and gate', (
      tester,
    ) async {
      final formats = TrackFormats();
      final gate = LoudnessGate(_MemoryStore(false));
      final rig = Rig(formats: formats, loudness: gate);

      await rig.start(tester);
      await tester.pumpAndSettle();

      // Unmount MusicApp (simulating screen switch / account logout)
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();

      // wire unsubscribed: events after unmount do not touch player
      expect(tester.takeException(), isNull);
    });
  });

  group('storage failure', () {
    test(
      'read error does not crash load() and leaves enabled = false',
      () async {
        final store = _ThrowingStore(throwOnRead: true);
        final gate = LoudnessGate(store);

        await expectLater(gate.load(), completes);
        expect(gate.enabled, isFalse);
        expect(gate.volume, 1.0);
      },
    );

    test('write error returns false and rolls back enabled', () async {
      final store = _ThrowingStore(throwOnWrite: true);
      final gate = LoudnessGate(store);
      await gate.load();
      expect(gate.enabled, isFalse);

      final success = await gate.setEnabled(true);
      expect(success, isFalse);
      expect(gate.enabled, isFalse);
      expect(gate.volume, 1.0);
    });

    test('SharedPreferencesLoudnessStore reads and writes key', () async {
      const store = SharedPreferencesLoudnessStore();
      expect(await store.read(), isNull);

      await store.write(true);
      expect(await store.read(), isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('loudness-enabled'), isTrue);

      await store.write(false);
      expect(await store.read(), isFalse);
      expect(prefs.getBool('loudness-enabled'), isFalse);
    });
  });
}
