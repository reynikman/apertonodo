import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Single band of phone equalizer: frequency and gain limits in dB.
@immutable
class EqBand {
  const EqBand({
    required this.centerHz,
    required this.minDb,
    required this.maxDb,
  });

  final int centerHz;
  final double minDb;
  final double maxDb;

  @override
  bool operator ==(Object other) =>
      other is EqBand &&
      other.centerHz == centerHz &&
      other.minDb == minDb &&
      other.maxDb == maxDb;

  @override
  int get hashCode => Object.hash(centerHz, minDb, maxDb);
}

/// Phone equalizer. `bands()` throws if absent, and can take a long time to
/// respond: on phone bands are known only after the first song.
abstract class EqualizerPort {
  Future<List<EqBand>> bands();
  Future<void> setEnabled(bool on);
  Future<void> setGain(int index, double db);
}

const _presetHz = [60, 230, 910, 3600, 14000];

/// Presets in dB by frequencies [_presetHz]. No higher than +6 dB: higher means clipping.
const _presets = <String, List<double>>{
  'flat': [0, 0, 0, 0, 0],
  'bass': [6, 4, 0, 0, 0],
  'treble': [0, 0, 0, 4, 6],
  'vocal': [-1, 1, 4, 3, 0],
};

/// Equalizer (FT-621, Р-A77): presets and custom sliders, choice is stored on
/// phone, like [NewsPrefs]. If no equalizer — everything silently does nothing.
class Equalizer extends ChangeNotifier {
  Equalizer({required this.port});

  final EqualizerPort port;

  static const _enabledKey = 'eq-enabled';
  static const _presetKey = 'eq-preset';
  static const _gainsKey = 'eq-gains';

  bool _available = false;
  // Before first `load()` bands are not yet available — screen waits instead of saying "no equalizer".
  bool _loading = true;
  bool _enabled = false;
  bool _disposed = false;
  String _preset = 'flat';
  List<EqBand> _bands = const [];
  List<double> _gains = const [];

  bool get available => _available;

  /// Bands have not arrived yet.
  bool get loading => _loading;
  bool get enabled => _enabled;
  String get preset => _preset;
  List<EqBand> get bands => _bands;
  List<double> get gains => _gains;

  Future<void> load() async {
    _loading = true;
    notifyListeners();
    List<EqBand> bands;
    try {
      bands = await port.bands();
    } catch (_) {
      bands = const [];
    }
    if (_disposed) return;
    var enabled = false;
    var preset = 'flat';
    var gains = List<double>.filled(bands.length, 0);
    try {
      final prefs = await SharedPreferences.getInstance();
      enabled = prefs.getBool(_enabledKey) ?? false;
      final saved = prefs.getStringList(_gainsKey);
      final parsed = saved?.map(double.parse).toList();
      if (parsed != null && parsed.length == bands.length) {
        gains = [
          for (var i = 0; i < parsed.length; i++) _clamp(bands[i], parsed[i]),
        ];
        final id = prefs.getString(_presetKey);
        preset = (id == 'custom' || _presets.containsKey(id)) ? id! : 'flat';
      }
    } catch (_) {
      // Corrupted or inaccessible storage — flat audio.
      gains = List<double>.filled(bands.length, 0);
      preset = 'flat';
    }
    if (_disposed) return;
    _bands = bands;
    _available = bands.isNotEmpty;
    _enabled = enabled;
    _preset = preset;
    _gains = gains;
    _loading = false;
    notifyListeners();
    if (!_available) return;
    await _guard(() => port.setEnabled(_enabled));
    for (var i = 0; i < _gains.length; i++) {
      await _guard(() => port.setGain(i, _gains[i]));
    }
  }

  Future<void> choose(String id) async {
    final points = _presets[id];
    if (!_available || points == null) return;
    _preset = id;
    _gains = [for (final b in _bands) _clamp(b, _nearest(points, b.centerHz))];
    notifyListeners();
    for (var i = 0; i < _gains.length; i++) {
      await _guard(() => port.setGain(i, _gains[i]));
    }
    await _save();
  }

  Future<void> setGain(int index, double db) async {
    if (!_available || index < 0 || index >= _bands.length) return;
    _preset = 'custom';
    _gains = List.of(_gains)..[index] = _clamp(_bands[index], db);
    notifyListeners();
    await _guard(() => port.setGain(index, _gains[index]));
    await _save();
  }

  Future<void> setEnabled(bool on) async {
    if (!_available) return;
    _enabled = on;
    notifyListeners();
    await _guard(() => port.setEnabled(on));
    await _save();
  }

  double _clamp(EqBand b, double db) => db.clamp(b.minDb, b.maxDb).toDouble();

  /// Preset value at the closest frequency (logarithmic) point.
  double _nearest(List<double> points, int hz) {
    var best = 0;
    var bestDist = double.infinity;
    for (var i = 0; i < _presetHz.length; i++) {
      // Frequency ratio is the same as logarithmic distance.
      final ratio = hz / _presetHz[i];
      final d = ratio >= 1 ? ratio : 1 / ratio;
      if (d < bestDist) {
        bestDist = d;
        best = i;
      }
    }
    return points[best];
  }

  Future<void> _guard(Future<void> Function() call) async {
    try {
      await call();
    } catch (_) {
      // Phone rejected it — screen must not crash.
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_enabledKey, _enabled);
      await prefs.setString(_presetKey, _preset);
      await prefs.setStringList(_gainsKey, [for (final g in _gains) '$g']);
    } catch (_) {
      // Failed to persist — sound is already configured, next launch will be flat.
    }
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
