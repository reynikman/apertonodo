import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// FT-628 (Р-A94): auto-update. Logic without network and without Android:
/// downloading and installer are hidden behind [UpdateSource] and [UpdateInstaller].

final _versionRe = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)(-beta)?(?:\+(\d+))?$');

/// Version numbers: major, minor, patch, 0 for `-beta` or 1 for a release (a
/// release is newer than the beta of the same version) and build number (or -1).
/// `null` — tag could not be parsed (`dev`, `nightly`, empty).
List<int>? _parse(String version) {
  final m = _versionRe.firstMatch(version.trim());
  if (m == null) return null;
  return [
    for (var i = 1; i <= 3; i++) int.parse(m[i]!),
    m[4] == null ? 1 : 0,
    m[5] == null ? -1 : int.parse(m[5]!),
  ];
}

/// [candidate] is strictly newer than [than]. Numeric comparison; if the three
/// numbers are equal, the build number decides, but only if both versions have it.
bool isNewerVersion(String candidate, {required String than}) {
  final a = _parse(candidate);
  final b = _parse(than);
  if (a == null || b == null) return false;
  for (var i = 0; i < 4; i++) {
    if (a[i] != b[i]) return a[i] > b[i];
  }
  if (a[4] < 0 || b[4] < 0) return false;
  return a[4] > b[4];
}

class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.apk,
    required this.sha256,
    this.bytes,
    this.notes = '',
  });

  final String version;
  final Uri apk;
  final String sha256;
  final int? bytes;
  final String notes;
}

final _digestRe = RegExp(r'^sha256:([0-9a-fA-F]{64})$');

/// One GitHub release -> update. Anything that cannot be verified
/// (no APK, not https, no sha256 digest) is `null`: such a file is not offered.
UpdateInfo? updateFromGithubRelease(Map<String, Object?> json) {
  final tag = json['tag_name'];
  final assets = json['assets'];
  if (json['draft'] == true || tag is! String || assets is! List) return null;
  final version = tag.startsWith('v') ? tag.substring(1) : tag;
  if (_parse(version) == null) return null;
  for (final asset in assets) {
    if (asset is! Map || asset['name'] is! String) continue;
    if (!(asset['name'] as String).endsWith('.apk')) continue;
    final url = asset['browser_download_url'];
    final digest = asset['digest'];
    final size = asset['size'];
    if (url is! String || digest is! String) return null;
    final apk = Uri.tryParse(url);
    final sum = _digestRe.firstMatch(digest)?[1];
    if (apk == null || apk.scheme != 'https' || sum == null) return null;
    final body = json['body'];
    final notes = body is String ? body : '';
    return UpdateInfo(
      version: version,
      apk: apk,
      sha256: sum.toLowerCase(),
      bytes: size is int ? size : null,
      notes: notes.length > 2000 ? notes.substring(0, 2000) : notes,
    );
  }
  return null;
}

abstract interface class UpdateSource {
  Future<UpdateInfo?> latest();
}

/// Stream emits downloaded fraction 0..1 and closes when Android installer
/// window is opened. Stream error is a failure.
abstract interface class UpdateInstaller {
  Stream<double> install(UpdateInfo info);
}

enum UpdatePhase { idle, available, downloading, failed }

class AppUpdate extends ChangeNotifier {
  AppUpdate({
    required this.current,
    required this.source,
    required this.installer,
    required this.prefs,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  static const checkedKey = 'update.checked';
  static const skippedKey = 'update.skipped';
  static const _every = Duration(hours: 24);

  final String current;
  final UpdateSource source;
  final UpdateInstaller installer;
  final SharedPreferences prefs;
  final DateTime Function() _clock;

  UpdateInfo? _available;
  UpdatePhase _phase = UpdatePhase.idle;
  double _progress = 0;

  UpdateInfo? get available => _available;
  UpdatePhase get phase => _phase;
  double get progress => _progress;

  Future<void> check({bool force = false}) async {
    final now = _clock();
    if (!force) {
      final last = prefs.getInt(checkedKey);
      if (last != null &&
          now.difference(
                DateTime.fromMillisecondsSinceEpoch(last, isUtc: true),
              ) <
              _every) {
        return;
      }
    }
    // Record time before network request: a failure also counts as a check.
    await prefs.setInt(checkedKey, now.millisecondsSinceEpoch);
    UpdateInfo? found;
    try {
      found = await source.latest();
    } catch (_) {
      // No network or malformed response — stay silent, ask in 24 hours.
      return;
    }
    // Download in progress — response must not reset its screen.
    if (_phase == UpdatePhase.downloading) return;
    final fresh =
        found != null &&
        isNewerVersion(found.version, than: current) &&
        found.version != prefs.getString(skippedKey);
    _available = fresh ? found : null;
    _phase = fresh ? UpdatePhase.available : UpdatePhase.idle;
    _progress = 0;
    notifyListeners();
  }

  void skip() {
    final info = _available;
    if (info == null) return;
    unawaited(prefs.setString(skippedKey, info.version));
    _available = null;
    _phase = UpdatePhase.idle;
    _progress = 0;
    notifyListeners();
  }

  Future<void> install() async {
    final info = _available;
    if (info == null || _phase == UpdatePhase.downloading) return;
    _phase = UpdatePhase.downloading;
    _progress = 0;
    notifyListeners();
    try {
      await for (final value in installer.install(info)) {
        _progress = value;
        notifyListeners();
      }
      _phase = UpdatePhase.available;
      _progress = 0;
    } catch (_) {
      _phase = UpdatePhase.failed;
    }
    notifyListeners();
  }
}
