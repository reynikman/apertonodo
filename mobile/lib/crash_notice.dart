import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'error_reports.dart';

/// Memory of crash and "send report?" prompt upon next launch (FT-698).
class CrashNotice {
  CrashNotice(this._prefs);

  final SharedPreferences _prefs;

  static const runningKey = 'crash.running';
  static const neverKey = 'crash.never';
  static const pendingKey = 'crash.pending';

  bool _crashed = false;
  bool _answered = false;

  /// Remember if "running" flag was set (there was a crash), and set it again.
  Future<void> start() async {
    _crashed = _prefs.getBool(runningKey) ?? false;
    await _prefs.setBool(runningKey, true);
  }

  /// Moving to background clears the flag: OS kill in background is not a crash.
  Future<void> paused() async {
    await _prefs.remove(runningKey);
  }

  /// Returning to foreground sets the flag again.
  Future<void> resumed() async {
    await _prefs.setBool(runningKey, true);
  }

  /// Save crash report without error text or personal data.
  Future<void> remember(Object error, StackTrace stack) async {
    final report = ErrorReport(
      kind: 'crash.${reportName(error.runtimeType.toString())}',
      screen: 'app',
      frames: ErrorReport.framesFrom(stack),
    );
    await _prefs.setString(
      pendingKey,
      jsonEncode({
        'kind': report.kind,
        'screen': report.screen,
        'frames': report.frames,
      }),
    );
  }

  /// There was a crash, answer not given yet and "never ask again" not chosen.
  bool get shouldAsk =>
      _crashed && !_answered && !(_prefs.getBool(neverKey) ?? false);

  /// Saved report; if record missing or corrupted — crash.native without stack.
  ErrorReport get report {
    final raw = _prefs.getString(pendingKey);
    if (raw == null) {
      return const ErrorReport(kind: 'crash.native', screen: 'app');
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return const ErrorReport(kind: 'crash.native', screen: 'app');
      }
      final kind = decoded['kind'];
      final screen = decoded['screen'];
      final frames = decoded['frames'];
      if (kind is! String ||
          kind.isEmpty ||
          screen is! String ||
          screen.isEmpty ||
          frames is! List) {
        return const ErrorReport(kind: 'crash.native', screen: 'app');
      }
      final parsedFrames = <Map<String, dynamic>>[];
      for (final f in frames) {
        if (f is Map) {
          parsedFrames.add(Map<String, dynamic>.from(f));
        }
      }
      return ErrorReport(kind: kind, screen: screen, frames: parsedFrames);
    } catch (_) {
      return const ErrorReport(kind: 'crash.native', screen: 'app');
    }
  }

  /// Answer to prompt: clear report, do not ask during this launch,
  /// remember "never" on [neverAgain]; return report only on [send].
  Future<ErrorReport?> answer({
    required bool send,
    required bool neverAgain,
  }) async {
    final currentReport = report;
    _answered = true;
    await _prefs.remove(pendingKey);
    if (neverAgain) {
      await _prefs.setBool(neverKey, true);
    }
    return send ? currentReport : null;
  }
}
