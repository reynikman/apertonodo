import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// News consent and feed toggle (FT-581, Р-A83).
///
/// Two settings live on device, not on server:
/// - `news-consent` — whether user was asked about news; no key — not
///   asked, tab shows consent screen;
/// - `news-enabled` — whether user wants to see the feed; no key — disabled
///   (FT-796: by default no news at all, and no tab icon either).
///
/// Like error reports ([ErrorReports]), setting belongs to device and
/// survives restart. Storage failure should not enable news on its own.
class NewsPrefs extends ChangeNotifier {
  NewsPrefs();

  static const _consentKey = 'news-consent';
  static const _enabledKey = 'news-enabled';

  bool _consent = false;
  bool _enabled = false;
  bool _disposed = false;

  /// Consent screen has already been shown and accepted.
  bool get consent => _consent;

  /// Feed is enabled. Disabled — no tab icon and does not talk to server.
  bool get enabled => _enabled;

  Future<void> load() async {
    var consent = false;
    var enabled = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      consent = prefs.getBool(_consentKey) ?? false;
      enabled = prefs.getBool(_enabledKey) ?? false;
    } catch (_) {
      // Storage error does not enable news itself and must not crash screen.
    }
    if (_disposed) return;
    _consent = consent;
    _enabled = enabled;
    notifyListeners();
  }

  /// Accepted consent: from this launch screen is no longer shown.
  Future<void> accept() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_consentKey, true);
    } catch (_) {
      // Failed to save — will ask next time, but show feed now.
    }
    if (_disposed) return;
    _consent = true;
    notifyListeners();
  }

  Future<void> setEnabled(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_enabledKey, enabled);
    } catch (_) {
      // Setting will remain in memory until restart.
    }
    if (_disposed) return;
    _enabled = enabled;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
