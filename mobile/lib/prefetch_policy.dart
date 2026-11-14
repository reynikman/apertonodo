import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Next track prefetch mode (FT-692, Р-A101).
///
/// Order of values and constant names are storage contract.
enum PrefetchMode { always, wifiOnly, never }

/// Decides whether to prefetch next track based on mode and network state.
///
/// - `always` — always allowed;
/// - `never` — always forbidden;
/// - `wifiOnly` — only when on Wi-Fi and unmetered connection.
bool mayPrefetch(
  PrefetchMode mode, {
  required bool onWifi,
  required bool metered,
}) {
  switch (mode) {
    case PrefetchMode.always:
      return true;
    case PrefetchMode.wifiOnly:
      return onWifi && !metered;
    case PrefetchMode.never:
      return false;
  }
}

/// Text labels for prefetch settings section (Р-A84).
class PrefetchTexts {
  const PrefetchTexts({
    required this.title,
    required this.always,
    required this.wifiOnly,
    required this.never,
    required this.neverHint,
  });

  final String title;
  final String always;
  final String wifiOnly;
  final String never;
  final String neverHint;
}

/// Next track prefetch policy persisted in [SharedPreferences].
class PrefetchPolicy extends ChangeNotifier {
  static const String _storageKey = 'prefetch_mode';

  PrefetchMode _mode = PrefetchMode.always;
  bool _disposed = false;

  /// Current prefetch mode. Before [load] — `always`.
  PrefetchMode get mode => _mode;

  /// Loads persisted mode from [SharedPreferences].
  ///
  /// On missing key, unknown value, non-string or storage failure,
  /// defaults to `always`. Notifies listeners only on actual mode change.
  Future<void> load() async {
    var next = PrefetchMode.always;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.get(_storageKey);
      if (raw is String) {
        for (final m in PrefetchMode.values) {
          if (m.name == raw) {
            next = m;
            break;
          }
        }
      }
    } catch (_) {
      next = PrefetchMode.always;
    }

    if (_disposed) return;
    if (_mode != next) {
      _mode = next;
      notifyListeners();
    }
  }

  /// Sets new prefetch mode.
  ///
  /// If mode does not change — does nothing (no notification, no write).
  /// On mode change, notifies listeners exactly once and persists mode name.
  /// Storage failure does not throw.
  Future<void> set(PrefetchMode mode) async {
    if (_disposed || _mode == mode) {
      return;
    }
    _mode = mode;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_storageKey, mode.name);
    } catch (_) {
      // Storage write failure is not an exception.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Settings section for next track prefetch.
class PrefetchSection extends StatelessWidget {
  const PrefetchSection({super.key, required this.policy, required this.texts});

  final PrefetchPolicy policy;
  final PrefetchTexts texts;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: policy,
      builder: (context, _) => RadioGroup<PrefetchMode>(
        groupValue: policy.mode,
        onChanged: (mode) {
          if (mode != null) {
            unawaited(policy.set(mode));
          }
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                texts.title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            RadioListTile<PrefetchMode>(
              value: PrefetchMode.always,
              title: Text(texts.always),
            ),
            RadioListTile<PrefetchMode>(
              value: PrefetchMode.wifiOnly,
              title: Text(texts.wifiOnly),
            ),
            RadioListTile<PrefetchMode>(
              value: PrefetchMode.never,
              title: Text(texts.never),
              subtitle: Text(texts.neverHint),
            ),
          ],
        ),
      ),
    );
  }
}
