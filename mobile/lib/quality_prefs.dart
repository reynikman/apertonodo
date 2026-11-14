import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Audio quality preference (FT-633, P-A94) — single setting on device.
///
/// Three modes:
/// - `auto` — as before this card: request compressed copy on metered
///   network, otherwise original file as-is;
/// - `economy` — always compressed copy without checking network;
/// - `lossless` — always original file as-is without checking network.
///
/// Storage is `SharedPreferences`, key `quality-mode`, value is mode name.
/// Missing key, unknown value, non-string, storage error — `auto`, without
/// throwing exceptions: broken config must not crash app startup.
class QualityPrefs extends ChangeNotifier {
  QualityPrefs();

  static const _modeKey = 'quality-mode';

  QualityMode _mode = QualityMode.auto;
  bool _disposed = false;

  /// Current mode. Until `load` completes — "Auto".
  QualityMode get mode => _mode;

  Future<void> load() async {
    var mode = QualityMode.auto;
    try {
      final prefs = await SharedPreferences.getInstance();
      mode = _parse(prefs.getString(_modeKey));
    } catch (_) {
      // Storage error — "Auto": unknown preference, fallback to original behavior.
    }
    if (_disposed) return;
    _mode = mode;
    notifyListeners();
  }

  /// Changes mode immediately, notifies listeners, then persists to storage.
  /// Same mode selected again — no-op and does not notify listeners.
  Future<void> setMode(QualityMode mode) async {
    if (_disposed || mode == _mode) return;
    _mode = mode;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_modeKey, mode.name);
    } catch (_) {
      // Save failed — setting persists in memory until app restart.
    }
  }

  /// Whether to request compressed copy from server.
  ///
  /// `economy` — always true, `lossless` — always false; network not checked
  /// in these modes. In `auto` mode delegates to `isMetered`; if it throws
  /// exception — treated as metered network (same as `DeviceInfo.isMetered`).
  Future<bool> preferOpus(Future<bool> Function() isMetered) async {
    switch (_mode) {
      case QualityMode.economy:
        return true;
      case QualityMode.lossless:
        return false;
      case QualityMode.auto:
        try {
          return await isMetered();
        } catch (_) {
          return true;
        }
    }
  }

  static QualityMode _parse(String? raw) => switch (raw) {
    'economy' => QualityMode.economy,
    'lossless' => QualityMode.lossless,
    _ => QualityMode.auto,
  };

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Audio quality mode. Mode name (`name`) is stored in preferences.
enum QualityMode { auto, economy, lossless }
