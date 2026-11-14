import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'playback.dart';
import 'player.dart';
import 'track_formats.dart';

/// Lower bound of loudness adjustment in decibels (Р-A96).
///
/// We don't reduce below this so an erroneous or garbage measurement doesn't mute the track.
const double loudnessFloorDb = -24;

/// Extracts numeric loudness adjustment in dB from `audio` field of server response.
///
/// Returns finite number as [double], or `null` if object is invalid,
/// field is missing or value is not a finite number.
double? gainDbOf(Object? audio) {
  if (audio is! Map) return null;
  final val = audio['gain_db'];
  if (val is! num) return null;
  final d = val.toDouble();
  if (!d.isFinite) return null;
  return d;
}

/// Computes player volume multiplier in range `(0, 1]`.
///
/// Rule Р-A96: only reduce. If leveling is disabled, no measurement,
/// value is not finite, or adjustment is positive or zero — multiplier is 1.0.
/// Otherwise `10^(x/20)`, where `x` is bounded below by [loudnessFloorDb].
double loudnessVolume({required bool enabled, required double? gainDb}) {
  if (!enabled || gainDb == null || !gainDb.isFinite || gainDb >= 0) {
    return 1.0;
  }
  final x = gainDb < loudnessFloorDb ? loudnessFloorDb : gainDb;
  return pow(10.0, x / 20.0).toDouble();
}

/// Storage for loudness leveling state.
abstract interface class LoudnessStore {
  /// Reads saved state (`null` if nothing is saved).
  Future<bool?> read();

  /// Writes new state.
  Future<void> write(bool enabled);
}

/// Storage for loudness leveling state in [SharedPreferences] (FT-765).
class SharedPreferencesLoudnessStore implements LoudnessStore {
  const SharedPreferencesLoudnessStore();

  static const key = 'loudness-enabled';

  @override
  Future<bool?> read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(key);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, enabled);
  }
}

/// Controls loudness leveling toggle and player multiplier.
class LoudnessGate extends ChangeNotifier {
  LoudnessGate([LoudnessStore? store])
    : _store = store ?? const SharedPreferencesLoudnessStore();

  final LoudnessStore _store;

  bool _enabled = false;
  double? _gainDb;
  bool _disposed = false;
  bool _userInteracted = false;
  int _writeSeq = 0;
  int _loadSeq = 0;

  /// Whether loudness leveling is enabled. Default is `false`.
  bool get enabled => _enabled;

  /// Current volume multiplier for player.
  double get volume => loudnessVolume(enabled: _enabled, gainDb: _gainDb);

  /// Loads state from storage.
  Future<void> load() async {
    if (_disposed || _userInteracted) return;
    final currentLoadSeq = ++_loadSeq;
    bool? saved;
    try {
      saved = await _store.read();
    } catch (_) {
      return;
    }
    if (_disposed || _userInteracted || _loadSeq != currentLoadSeq) return;
    if (saved == null) return;
    _applyEnabled(saved);
  }

  /// Sets toggle: value is applied immediately, then written to storage.
  Future<bool> setEnabled(bool value) async {
    if (_disposed) return false;
    _userInteracted = true;
    final seq = ++_writeSeq;
    final prev = _enabled;
    _applyEnabled(value);

    try {
      await _store.write(value);
      if (_disposed) return false;
      return true;
    } catch (_) {
      if (!_disposed && _writeSeq == seq) {
        _applyEnabled(prev);
      }
      return false;
    }
  }

  /// Sets loudness adjustment for the started track.
  void begin(double? gainDb) {
    if (_disposed) return;
    final oldVolume = volume;
    _gainDb = gainDb;
    final newVolume = volume;
    if (newVolume != oldVolume) {
      notifyListeners();
    }
  }

  bool _applyEnabled(bool value) {
    if (_disposed) return false;
    final oldEnabled = _enabled;
    final oldVolume = volume;
    _enabled = value;
    final newVolume = volume;
    if (_enabled != oldEnabled || newVolume != oldVolume) {
      notifyListeners();
      return true;
    }
    return false;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Connects player, track format, loudness gate, and audio port (FT-765).
///
/// When track starts (current track changes in [Player]) — `gate.begin(formats.gainOf(id))`.
/// On any change in [gate] — `audio.setVolume(gate.volume)`.
/// If adjustment arrives after track start — [TrackFormats] notifies listeners,
/// and volume is reset for current track.
class LoudnessWire {
  LoudnessWire({
    required this.player,
    required this.audio,
    required this.gate,
    this.formats,
  }) {
    player.addListener(_onPlayerChanged);
    formats?.addListener(_onFormatsChanged);
    gate.addListener(_onGateChanged);
    _syncTrack(player.current?.id);
  }

  final Player player;
  final AudioPort audio;
  final LoudnessGate gate;
  final TrackFormats? formats;

  String? _trackId;
  bool _disposed = false;

  void _onPlayerChanged() {
    if (_disposed) return;
    final id = player.current?.id;
    if (id == _trackId) return;
    _trackId = id;
    _syncTrack(id);
  }

  void _onFormatsChanged() {
    if (_disposed) return;
    final id = _trackId;
    if (id != null) {
      gate.begin(formats?.gainOf(id));
    }
  }

  void _onGateChanged() {
    if (_disposed) return;
    unawaited(audio.setVolume(gate.volume).catchError((Object _) {}));
  }

  void _syncTrack(String? id) {
    gate.begin(id != null ? formats?.gainOf(id) : null);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    player.removeListener(_onPlayerChanged);
    formats?.removeListener(_onFormatsChanged);
    gate.removeListener(_onGateChanged);
  }
}
