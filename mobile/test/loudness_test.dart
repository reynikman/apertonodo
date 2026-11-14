import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/loudness.dart';

/// Lead check FT-650: loudness normalization per contract D2, items 4 and 6.

class _Store implements LoudnessStore {
  _Store([this.value]);
  bool? value;
  Object? readError;
  final writes = <bool>[];
  final gates = <Completer<void>>[];
  bool hold = false;
  Completer<bool?>? reading;

  @override
  Future<bool?> read() {
    if (readError != null) return Future.error(readError!);
    return reading?.future ?? Future.value(value);
  }

  @override
  Future<void> write(bool enabled) {
    writes.add(enabled);
    if (!hold) {
      value = enabled;
      return Future.value();
    }
    final gate = Completer<void>();
    gates.add(gate);
    return gate.future;
  }
}

Matcher _near(double value) => closeTo(value, 1e-9);

Future<LoudnessGate> _on([double? gainDb]) async {
  final gate = LoudnessGate(_Store(true));
  await gate.load();
  if (gainDb != null) gate.begin(gainDb);
  return gate;
}

void main() {
  group('volume multiplier adjustment', () {
    test('minus six dB — approximately half', () {
      expect(
        loudnessVolume(enabled: true, gainDb: -6),
        _near(pow(10, -0.3).toDouble()),
      );
      expect(loudnessVolume(enabled: true, gainDb: -20), _near(0.1));
      expect(
        loudnessVolume(enabled: true, gainDb: -0.5),
        _near(pow(10, -0.025).toDouble()),
      );
    });

    test('disabled — always 1.0', () {
      for (final gain in <double?>[-6, -20, 0, 5, null]) {
        expect(loudnessVolume(enabled: false, gainDb: gain), 1.0);
      }
    });

    test('attenuation only: zero and positive — 1.0', () {
      for (final gain in <double>[0, 0.01, 3, 12, 100]) {
        expect(
          loudnessVolume(enabled: true, gainDb: gain),
          1.0,
          reason: '$gain',
        );
      }
    });

    test('no measurement or not a number — 1.0', () {
      for (final gain in <double?>[
        null,
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        expect(
          loudnessVolume(enabled: true, gainDb: gain),
          1.0,
          reason: '$gain',
        );
      }
    });

    test('floor at −24 dB: bad measurement does not mute song', () {
      expect(loudnessFloorDb, -24);
      final floor = pow(10, -24 / 20).toDouble();
      expect(loudnessVolume(enabled: true, gainDb: -24), _near(floor));
      expect(loudnessVolume(enabled: true, gainDb: -24.01), _near(floor));
      expect(loudnessVolume(enabled: true, gainDb: -200), _near(floor));
      expect(loudnessVolume(enabled: true, gainDb: -23.99), greaterThan(floor));
    });

    test('multiplier always in range (0, 1]', () {
      for (var gain = -60.0; gain <= 20; gain += 0.37) {
        final volume = loudnessVolume(enabled: true, gainDb: gain);
        expect(volume, greaterThan(0.06));
        expect(volume, lessThanOrEqualTo(1.0));
      }
    });
  });

  group('audio field from server response', () {
    test('signed number is read as-is', () {
      expect(gainDbOf({'format': 'flac', 'gain_db': -7.25}), -7.25);
      expect(gainDbOf({'gain_db': -3}), -3.0);
      expect(gainDbOf({'gain_db': 2.5}), 2.5);
      expect(gainDbOf({'gain_db': 0}), 0.0);
      expect(gainDbOf(<String, dynamic>{'gain_db': -1}), isA<double>());
    });

    test('missing field, not number or object — no measurement', () {
      for (final Object? audio in [
        null,
        'flac',
        7,
        <Object>[],
        <String, dynamic>{},
        {'format': 'mp3'},
        {'gain_db': null},
        {'gain_db': '-7'},
        {'gain_db': true},
        {'gain_db': double.nan},
        {'gain_db': double.infinity},
        {'gain': -7},
        {
          'gain_db': {'value': -7},
        },
      ]) {
        expect(gainDbOf(audio), isNull, reason: '$audio');
      }
    });
  });

  group('toggle switch', () {
    test(
      'disabled by default — before load completed and when nothing is stored',
      () async {
        final gate = LoudnessGate(_Store());
        gate.begin(-10);
        expect(gate.enabled, isFalse);
        expect(gate.volume, 1.0);
        await gate.load();
        expect(gate.enabled, isFalse);
        expect(gate.volume, 1.0);
      },
    );

    test('saved «enabled» loads and notifies once', () async {
      final gate = LoudnessGate(_Store(true));
      var calls = 0;
      gate.addListener(() => calls++);
      await gate.load();
      expect(gate.enabled, isTrue);
      expect(calls, 1);
      await gate.load();
      expect(calls, 1);
    });

    test('saved «disabled» does not notify', () async {
      final gate = LoudnessGate(_Store(false));
      var calls = 0;
      gate.addListener(() => calls++);
      await gate.load();
      expect(gate.enabled, isFalse);
      expect(calls, 0);
    });

    test('storage read failed — disabled, no exception', () async {
      final store = _Store(true)..readError = StateError('disk');
      final gate = LoudnessGate(store);
      await gate.load();
      expect(gate.enabled, isFalse);
    });

    test('enable: applies immediately, saved, answer «yes»', () async {
      final store = _Store()..hold = true;
      final gate = LoudnessGate(store)..begin(-6);
      var calls = 0;
      gate.addListener(() => calls++);
      final done = gate.setEnabled(true);
      expect(gate.enabled, isTrue);
      expect(gate.volume, lessThan(1.0));
      expect(calls, 1);
      store.gates.single.complete();
      expect(await done, isTrue);
      expect(store.writes, [true]);
      expect(calls, 1);
    });

    test('not saved — reverts to previous, answer «no»', () async {
      final store = _Store(true)..hold = true;
      final gate = LoudnessGate(store);
      await gate.load();
      var calls = 0;
      gate.addListener(() => calls++);
      final done = gate.setEnabled(false);
      expect(gate.enabled, isFalse);
      store.gates.single.completeError(StateError('disk'));
      expect(await done, isFalse);
      expect(gate.enabled, isTrue);
      expect(calls, 2);
    });

    test('old write failure does not overwrite newer tap', () async {
      final store = _Store()..hold = true;
      final gate = LoudnessGate(store);
      final first = gate.setEnabled(true);
      final second = gate.setEnabled(false);
      final third = gate.setEnabled(true);
      store.gates[0].completeError(StateError('disk'));
      expect(await first, isFalse);
      expect(gate.enabled, isTrue);
      store.gates[1].completeError(StateError('disk'));
      expect(await second, isFalse);
      expect(gate.enabled, isTrue);
      store.gates[2].complete();
      expect(await third, isTrue);
      expect(gate.enabled, isTrue);
      expect(store.writes, [true, false, true]);
    });

    test(
      'same value saved again: persisted, but does not notify any listeners',
      () async {
        final store = _Store(true);
        final gate = LoudnessGate(store);
        await gate.load();
        var calls = 0;
        gate.addListener(() => calls++);
        expect(await gate.setEnabled(true), isTrue);
        expect(calls, 0);
        expect(store.writes, [true]);
      },
    );

    test('stale read does not overwrite user tap', () async {
      final store = _Store()..reading = Completer<bool?>();
      final gate = LoudnessGate(store);
      final loading = gate.load();
      expect(await gate.setEnabled(true), isTrue);
      store.reading!.complete(false);
      await loading;
      expect(gate.enabled, isTrue);
    });

    test('after dispose nothing crashes or changes', () async {
      final store = _Store()..hold = true;
      final gate = LoudnessGate(store);
      final pending = gate.setEnabled(true);
      final reading = Completer<bool?>();
      store.reading = reading;
      final loading = gate.load();
      gate.dispose();
      store.gates.single.completeError(StateError('disk'));
      reading.complete(false);
      expect(await pending, isFalse);
      await loading;
      expect(await gate.setEnabled(false), isFalse);
      gate.begin(-6);
      expect(store.writes, [true]);
    });
  });

  group('track gain offset', () {
    test('applied at start of track and persists', () async {
      final gate = await _on(-6);
      expect(gate.volume, _near(pow(10, -0.3).toDouble()));
      expect(gate.volume, _near(pow(10, -0.3).toDouble()));
    });

    test(
      'next track without measurement resets to 1.0, not prior gain',
      () async {
        final gate = await _on(-12);
        expect(gate.volume, lessThan(0.3));
        gate.begin(null);
        expect(gate.volume, 1.0);
      },
    );

    test('next track with positive gain resets to 1.0', () async {
      final gate = await _on(-12);
      gate.begin(4);
      expect(gate.volume, 1.0);
    });

    test('listeners notified of volume change without extra noise', () async {
      final gate = await _on();
      var calls = 0;
      gate.addListener(() => calls++);
      gate.begin(-6);
      expect(calls, 1);
      gate.begin(-6);
      expect(calls, 1);
      gate.begin(-9);
      expect(calls, 2);
      gate.begin(null);
      expect(calls, 3);
      gate.begin(null);
      gate.begin(3);
      gate.begin(0);
      expect(calls, 3);
    });

    test(
      'disabled: track playback start does not notify, audio volume is 1.0',
      () async {
        final gate = LoudnessGate(_Store(false));
        await gate.load();
        var calls = 0;
        gate.addListener(() => calls++);
        gate.begin(-6);
        gate.begin(-12);
        expect(calls, 0);
        expect(gate.volume, 1.0);
      },
    );

    test(
      'enabled mid-track — track gain correction applies immediately in audio',
      () async {
        final gate = LoudnessGate(_Store(false));
        await gate.load();
        gate.begin(-6);
        expect(gate.volume, 1.0);
        await gate.setEnabled(true);
        expect(gate.volume, _near(pow(10, -0.3).toDouble()));
        await gate.setEnabled(false);
        expect(gate.volume, 1.0);
      },
    );
  });
}
