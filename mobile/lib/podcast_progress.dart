// FT-656: Stop position and speed on device (Р-A93, block В-5).

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Allowed podcast speeds.
const List<double> podcastSpeeds = [
  0.5,
  0.75,
  1.0,
  1.25,
  1.5,
  1.75,
  2.0,
  2.5,
  3.0,
];

/// Nearest allowed speed from [podcastSpeeds].
///
/// If distance is equal — smaller speed is chosen.
/// For `NaN` and infinities, returns `1.0`.
double nearestPodcastSpeed(num v) {
  if (v.isNaN || v.isInfinite) return 1.0;
  final val = v.toDouble();
  var best = podcastSpeeds.first;
  var bestDiff = (val - best).abs();
  for (final s in podcastSpeeds) {
    final diff = (val - s).abs();
    if (diff < bestDiff) {
      best = s;
      bestDiff = diff;
    }
  }
  return best;
}

/// Podcast episode key by feed URL and episode guid.
String podcastEpisodeKey(String feedUrl, String guid) => '$feedUrl\n$guid';

/// Checks whether episode is finished.
///
/// If duration is unknown or not greater than zero — always `false`.
/// Otherwise `true` if remaining is at most min(30 000 ms, durationMs ~/ 20).
bool podcastFinished(int positionMs, int? durationMs) {
  if (durationMs == null || durationMs <= 0) return false;
  final fivePercent = durationMs ~/ 20;
  final threshold = 30000 < fivePercent ? 30000 : fivePercent;
  final remaining = durationMs - positionMs;
  return remaining <= threshold;
}

/// Stop position of a podcast episode.
@immutable
class EpisodeProgress {
  final int positionMs;
  final bool done;
  final DateTime updatedAt;

  EpisodeProgress({
    required this.positionMs,
    required this.done,
    required DateTime updatedAt,
  }) : updatedAt = updatedAt.toUtc();

  Map<String, Object?> toJson() => {
    'position_ms': positionMs,
    'done': done,
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };

  static EpisodeProgress? fromJson(Object? json) {
    if (json is! Map) return null;
    final positionMs = json['position_ms'];
    if (positionMs is! int || positionMs < 0) return null;
    final done = json['done'];
    if (done is! bool) return null;
    final updatedAtRaw = json['updated_at'];
    if (updatedAtRaw is! String || !updatedAtRaw.endsWith('Z')) return null;
    final parsed = DateTime.tryParse(updatedAtRaw);
    if (parsed == null) return null;

    return EpisodeProgress(
      positionMs: positionMs,
      done: done,
      updatedAt: parsed,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is EpisodeProgress &&
        other.positionMs == positionMs &&
        other.done == done &&
        other.updatedAt.isAtSameMomentAs(updatedAt);
  }

  @override
  int get hashCode =>
      Object.hash(positionMs, done, updatedAt.microsecondsSinceEpoch);

  @override
  String toString() => 'EpisodeProgress';
}

/// Selects fresher record between [a] and [b].
///
/// First compares time [EpisodeProgress.updatedAt]. If equal,
/// finished record wins. If still equal — one with greater
/// [EpisodeProgress.positionMs]. If completely equal, returns [a].
EpisodeProgress newerProgress(EpisodeProgress a, EpisodeProgress b) {
  if (a.updatedAt.isAfter(b.updatedAt)) return a;
  if (b.updatedAt.isAfter(a.updatedAt)) return b;
  if (a.done != b.done) {
    return a.done ? a : b;
  }
  if (a.positionMs > b.positionMs) return a;
  if (b.positionMs > a.positionMs) return b;
  return a;
}

/// Determines playback resume position in ms.
///
/// If no record, episode is finished, position is less than 10 000 ms or
/// position is not less than known duration — returns `0`.
/// Otherwise returns position minus 3000 ms.
int podcastResumeMs(EpisodeProgress? progress, {int? durationMs}) {
  if (progress == null) return 0;
  if (progress.done) return 0;
  if (progress.positionMs < 10000) return 0;
  if (durationMs != null &&
      durationMs > 0 &&
      progress.positionMs >= durationMs) {
    return 0;
  }
  return progress.positionMs - 3000;
}

/// Storage of raw progress data on disk.
abstract class PodcastProgressBox {
  Future<String?> read();
  Future<void> write(String data);
}

/// Storage of podcast progress and speeds on device.
class PodcastProgressStore extends ChangeNotifier {
  static const int maxEpisodes = 5000;
  static const Duration saveEvery = Duration(seconds: 5);

  final PodcastProgressBox _box;
  final DateTime Function() _clock;

  final Map<String, EpisodeProgress> _episodes = {};
  final Map<String, double> _speeds = {};
  final Set<String> _dirty = <String>{};

  /// Speeds chosen in this session: old buffer does not restore them.
  final Set<String> _speedTouched = <String>{};

  DateTime? _lastDiskWriteTime;
  bool _needsSave = false;

  /// After `clear()` store is closed until next `restore()`: late report
  /// from player or server response does not bring back previous user's records.
  bool _closed = false;
  int _epoch = 0;
  bool _disposed = false;
  Future<void> _saveQueue = Future<void>.value();

  PodcastProgressStore(this._box, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Timestamp of new record: device clock, but always later than previous episode record —
  /// otherwise after clock rollback fresh position would lose to old one.
  DateTime _stamp(EpisodeProgress? old) {
    final now = _clock().toUtc();
    if (old == null || now.isAfter(old.updatedAt)) return now;
    return old.updatedAt.add(const Duration(milliseconds: 1));
  }

  /// Episode progress for [key].
  EpisodeProgress? of(String key) => _episodes[key];

  /// Playback speed of podcast [feedUrl] (default 1.0).
  double speedOf(String feedUrl) => _speeds[feedUrl] ?? 1.0;

  /// Sets playback speed for podcast [feedUrl].
  Future<void> setSpeed(String feedUrl, num v) async {
    if (_closed) return;
    final target = nearestPodcastSpeed(v);
    final current = speedOf(feedUrl);
    _speedTouched.add(feedUrl);
    if (target == current) return;

    if (target == 1.0) {
      _speeds.remove(feedUrl);
    } else {
      _speeds[feedUrl] = target;
    }
    _notify();
    await _enqueueSave();
  }

  /// Reports current playback position of episode.
  Future<void> report(
    String key,
    int positionMs, {
    int? durationMs,
    bool force = false,
  }) async {
    if (positionMs < 0 || _closed) return;

    final done = podcastFinished(positionMs, durationMs);
    final old = _episodes[key];
    final progress = EpisodeProgress(
      positionMs: positionMs,
      done: done,
      updatedAt: _stamp(old),
    );

    _episodes[key] = progress;
    _dirty.add(key);
    _pruneIfNeeded();

    if (old == null || old.done != done) {
      _notify();
    }

    final doneChanged = (old?.done ?? false) != done;
    // Clock moved back — difference is negative; cannot wait for it to catch up.
    final sinceWrite = _lastDiskWriteTime == null
        ? null
        : _clock().toUtc().difference(_lastDiskWriteTime!);
    final timePassed =
        sinceWrite == null || sinceWrite.isNegative || sinceWrite >= saveEvery;
    final shouldWriteNow = force || doneChanged || timePassed;

    if (shouldWriteNow) {
      await _enqueueSave();
    } else {
      _needsSave = true;
    }
  }

  /// Marks episode as finished. Position is kept.
  Future<void> markDone(String key) async {
    if (_closed) return;
    final old = _episodes[key];
    final pos = old?.positionMs ?? 0;
    final progress = EpisodeProgress(
      positionMs: pos,
      done: true,
      updatedAt: _stamp(old),
    );
    _episodes[key] = progress;
    _dirty.add(key);
    _pruneIfNeeded();
    _notify();
    await _enqueueSave();
  }

  /// Marks episode as new (position 0, not finished).
  Future<void> markNew(String key) async {
    if (_closed) return;
    final progress = EpisodeProgress(
      positionMs: 0,
      done: false,
      updatedAt: _stamp(_episodes[key]),
    );
    _episodes[key] = progress;
    _dirty.add(key);
    _pruneIfNeeded();
    _notify();
    await _enqueueSave();
  }

  /// Episodes awaiting dispatch to server.
  Map<String, EpisodeProgress> pending() {
    final result = <String, EpisodeProgress>{};
    for (final key in _dirty) {
      final ep = _episodes[key];
      if (ep != null) {
        result[key] = ep;
      }
    }
    return result;
  }

  /// Acknowledges successful dispatch of record to server.
  Future<void> ack(String key, EpisodeProgress sent) async {
    if (!_dirty.contains(key)) return;
    final current = _episodes[key];
    if (current == null || current != sent) return;

    _dirty.remove(key);
    await _enqueueSave();
  }

  /// Applies records received from server.
  Future<void> applyRemote(Map<String, EpisodeProgress> remote) async {
    if (_closed) return;
    var changed = false;
    for (final entry in remote.entries) {
      final key = entry.key;
      final remoteProgress = entry.value;
      final current = _episodes[key];
      if (current == null) {
        _episodes[key] = remoteProgress;
        _dirty.remove(key);
        changed = true;
      } else {
        if (current == remoteProgress) continue;
        final winner = newerProgress(current, remoteProgress);
        if (winner == remoteProgress) {
          _episodes[key] = remoteProgress;
          _dirty.remove(key);
          changed = true;
        }
      }
    }
    if (!changed) return;
    _pruneIfNeeded();
    _notify();
    await _enqueueSave();
  }

  /// Restores state from storage.
  Future<void> restore() async {
    final epoch = ++_epoch;
    _closed = false;
    String? raw;
    try {
      raw = await _box.read();
    } catch (_) {
      return;
    }
    // While reading, store was cleared (sign-out) or read anew — this reply is obsolete.
    if (epoch != _epoch) return;
    if (raw == null || raw.isEmpty) return;

    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;

    final episodesRaw = decoded['episodes'];
    if (episodesRaw is Map) {
      for (final entry in episodesRaw.entries) {
        final k = entry.key;
        if (k is! String) continue;
        final parsed = EpisodeProgress.fromJson(entry.value);
        if (parsed == null) continue;
        final current = _episodes[k];
        if (current == null) {
          _episodes[k] = parsed;
        } else {
          _episodes[k] = newerProgress(current, parsed);
        }
      }
    }

    final speedsRaw = decoded['speeds'];
    if (speedsRaw is Map) {
      for (final entry in speedsRaw.entries) {
        final feedUrl = entry.key;
        if (feedUrl is! String) continue;
        final v = entry.value;
        if (v is! num) continue;
        final speed = nearestPodcastSpeed(v);
        if (speed == 1.0) continue;
        if (!_speedTouched.contains(feedUrl) && !_speeds.containsKey(feedUrl)) {
          _speeds[feedUrl] = speed;
        }
      }
    }

    final dirtyRaw = decoded['dirty'];
    if (dirtyRaw is List) {
      for (final item in dirtyRaw) {
        if (item is String && _episodes.containsKey(item)) {
          _dirty.add(item);
        }
      }
    }

    _pruneIfNeeded();
    _notify();
  }

  /// Flushes pending changes to disk and awaits current write completion.
  /// `false` — not all written to disk: write failed, next `flush()` will retry.
  Future<bool> flush() async {
    if (_needsSave) {
      return _enqueueSave();
    }
    await _saveQueue;
    return !_needsSave;
  }

  /// Clears all records in memory and on disk and closes store until `restore()`.
  /// `false` — old data remains on disk: retry `flush()`.
  Future<bool> clear() async {
    _epoch++;
    _closed = true;
    _episodes.clear();
    _speeds.clear();
    _speedTouched.clear();
    _dirty.clear();
    _notify();
    return _enqueueSave();
  }

  void _pruneIfNeeded() {
    if (_episodes.length <= maxEpisodes) return;
    final entries = _episodes.entries.toList();
    entries.sort((a, b) {
      final aDirty = _dirty.contains(a.key);
      final bDirty = _dirty.contains(b.key);
      if (!aDirty && bDirty) return -1;
      if (aDirty && !bDirty) return 1;
      final timeCmp = a.value.updatedAt.compareTo(b.value.updatedAt);
      if (timeCmp != 0) return timeCmp;
      return a.key.compareTo(b.key);
    });

    final toRemoveCount = entries.length - maxEpisodes;
    for (var i = 0; i < toRemoveCount; i++) {
      final key = entries[i].key;
      _episodes.remove(key);
      _dirty.remove(key);
    }
  }

  String _serialize() {
    final episodesMap = <String, Object?>{
      for (final entry in _episodes.entries) entry.key: entry.value.toJson(),
    };
    final speedsMap = <String, Object?>{
      for (final entry in _speeds.entries)
        if (entry.value != 1.0) entry.key: entry.value,
    };
    final dirtyList = _dirty.where(_episodes.containsKey).toList();
    return jsonEncode({
      'v': 1,
      'episodes': episodesMap,
      'speeds': speedsMap,
      'dirty': dirtyList,
    });
  }

  Future<bool> _enqueueSave() {
    _needsSave = true;
    final completer = Completer<bool>();
    _saveQueue = _saveQueue.catchError((_) {}).then((_) async {
      if (!_needsSave) {
        completer.complete(true);
        return;
      }
      _needsSave = false;
      final jsonStr = _serialize();
      var written = false;
      try {
        await _box.write(jsonStr);
        _lastDiskWriteTime = _clock().toUtc();
        written = true;
      } catch (_) {
        _needsSave = true;
      } finally {
        completer.complete(written);
      }
    });
    return completer.future;
  }
}
