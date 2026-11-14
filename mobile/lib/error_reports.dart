import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'device_info.dart';
import 'server_api.dart';

/// Only code identifiers, never error messages or user data.
String reportName(String name) => name
    .replaceAllMapped(
      RegExp(r'([A-Z]+)([A-Z][a-z])'),
      (match) => '${match[1]}_${match[2]}',
    )
    .replaceAllMapped(
      RegExp(r'([a-z0-9])([A-Z])'),
      (match) => '${match[1]}_${match[2]}',
    )
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9_]'), '')
    .replaceFirst(RegExp(r'^_+'), '');

class ErrorReport {
  const ErrorReport({
    required this.kind,
    required this.screen,
    this.frames = const [],
  });

  final String kind;
  final String screen;
  final List<Map<String, dynamic>> frames;

  static final _identifier = RegExp(r'^[a-z][a-z0-9_.-]{0,63}$');
  static final _function = RegExp(r'^[\w.<> $-]{1,200}$');
  static final _file = RegExp(r'^(package|dart):[\w./-]{1,200}$');
  static final _frame = RegExp(
    r'^#\d+\s+(.+?)\s+\(((?:package|dart):[\w./-]{1,200}):(\d+)(?::\d+)?\)$',
  );

  static bool _matches(RegExp shape, String value) =>
      shape.firstMatch(value)?.end == value.length;

  static String _clean(String value, RegExp unwanted, String fallback) {
    final cleaned = value.replaceAll(unwanted, '');
    if (cleaned.isEmpty) return fallback;
    return cleaned.substring(0, cleaned.length.clamp(0, 32));
  }

  /// Drop local paths, async markers and any frame outside the server schema.
  static List<Map<String, dynamic>> framesFrom(StackTrace stack) {
    final frames = <Map<String, dynamic>>[];
    for (final row in stack.toString().split('\n')) {
      final match = _frame.firstMatch(row.trim());
      if (match == null || !_matches(_function, match[1]!)) continue;
      final line = int.tryParse(match[3]!);
      if (line == null) continue;
      frames.add({'function': match[1]!, 'file': match[2]!, 'line': line});
      if (frames.length == 100) break;
    }
    return frames;
  }

  Map<String, dynamic> toJson() {
    const version = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');
    // The real Android version comes from the phone (DeviceInfo), never from
    // the kernel string — its first number is not the release.
    final release = DeviceInfo.release;
    final os = release == null || release.isEmpty
        ? (Platform.isAndroid ? 'Android' : Platform.operatingSystem)
        : 'Android $release';
    return {
      'kind': _matches(_identifier, kind) ? kind : 'unknown',
      'screen': _matches(_identifier, screen) ? screen : 'unknown',
      'app_version': _clean(version, RegExp(r'[^0-9A-Za-z.+-]'), 'dev'),
      'os': _clean(os, RegExp(r'[^0-9A-Za-z .+-]'), 'unknown'),
      'frames': [
        for (final frame
            in frames
                .where((frame) {
                  final function = frame['function'];
                  final file = frame['file'];
                  final line = frame['line'];
                  return function is String &&
                      _matches(_function, function) &&
                      file is String &&
                      _matches(_file, file) &&
                      line is int &&
                      line >= 0;
                })
                .take(100))
          {
            'function': frame['function'],
            'file': frame['file'],
            'line': frame['line'],
          },
      ],
    };
  }
}

enum ReportResult { sent, off, failed }

/// Opt-in belongs to this device and is off unless explicitly saved.
class ErrorReports extends ChangeNotifier {
  ErrorReports(this.api);

  final ServerApi api;
  static const _preference = 'automatic-error-reports';
  bool _automatic = false;
  bool get automatic => _automatic;
  bool _disposed = false;

  Future<void> load() async {
    var automatic = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      automatic = prefs.getBool(_preference) ?? false;
    } catch (_) {
      // Storage failure must not turn consent on or cause another crash.
    }
    if (_disposed) return;
    _automatic = automatic;
    notifyListeners();
  }

  Future<void> setAutomatic(bool automatic) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_preference, automatic);
    if (_disposed) return;
    _automatic = automatic;
    notifyListeners();
  }

  Future<void> crash(Object error, StackTrace stack) async {
    if (!_automatic || _disposed) return;
    try {
      await api.sendReport(
        ErrorReport(
          kind: 'crash.${reportName(error.runtimeType.toString())}',
          screen: 'app',
          frames: ErrorReport.framesFrom(stack),
        ),
      );
    } catch (_) {
      // Reporting must never become a second unhandled error.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
