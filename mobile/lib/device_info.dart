import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Answers that only Android has (FT-522, Р-A60).
///
/// Downloads go over an unmetered network only, and that decision belongs to
/// Android — Flutter has no such answer. The system version in an error report
/// must be the real release, not the first number in the kernel string, which
/// made a phone on Android 14 report "Android 7".
class DeviceInfo {
  DeviceInfo._();

  static const _channel = MethodChannel('apertono/device');
  static String? _release;

  /// Ask the phone once at startup. No bridge or any failure → no version.
  static Future<void> load() async {
    try {
      _release = await _channel.invokeMethod<String>('androidRelease');
    } catch (_) {
      _release = null;
    }
  }

  /// The Android version, or null when the phone did not answer.
  static String? get release => _release;

  /// Unknown counts as metered: downloading on mobile by accident is worse.
  static Future<bool> isMetered() async {
    try {
      return await _channel.invokeMethod<bool>('isMetered') ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Free space in app folder, or null when Android did not answer.
  ///
  /// The "Storage for music" step decides how much to allocate based on it (FT-529).
  static Future<int?> freeBytes() async {
    try {
      return await _channel.invokeMethod<int>('freeBytes');
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  static void forget() => _release = null;
}
