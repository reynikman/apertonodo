// FT-659: Exchange podcast stop positions with server (Р-A93, block В-5).

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'podcast_progress.dart';

/// Set of changes from server and latest change mark.
@immutable
class PodcastChanges {
  final Map<String, EpisodeProgress> items;
  final int mark;

  PodcastChanges(Map<String, EpisodeProgress> items, this.mark)
    : items = Map.unmodifiable(items);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is PodcastChanges &&
        other.mark == mark &&
        mapEquals(other.items, items);
  }

  @override
  int get hashCode => Object.hash(mark, items.length);
}

/// Port for network exchange with server.
abstract class PodcastSyncPort {
  Future<Map<String, EpisodeProgress>> put(Map<String, EpisodeProgress> items);
  Future<PodcastChanges> changes(int after);
}

/// Result of a single sync cycle.
enum PodcastSyncResult { done, failed, stale }

/// Converts records into wire request format.
///
/// Key is split by first newline into feed_url and guid.
/// Records with invalid key are skipped.
Map<String, Object?> podcastToWire(Map<String, EpisodeProgress> items) {
  final list = <Map<String, Object?>>[];
  for (final entry in items.entries) {
    final key = entry.key;
    final newlineIndex = key.indexOf('\n');
    if (newlineIndex <= 0) continue;
    final feedUrl = key.substring(0, newlineIndex);
    final guid = key.substring(newlineIndex + 1);
    if (guid.isEmpty) continue;
    final progress = entry.value;
    list.add({
      'feed_url': feedUrl,
      'guid': guid,
      'position_ms': progress.positionMs,
      'done': progress.done,
      'updated_at': progress.updatedAt.toUtc().toIso8601String(),
    });
  }
  return {'items': list};
}

/// Parses server response into a set of records.
///
/// Does not throw exceptions on any invalid input data.
/// On duplicate episode, fresher record is kept.
Map<String, EpisodeProgress> podcastFromWire(Object? raw) {
  if (raw is! Map) return {};
  final rawItems = raw['items'];
  if (rawItems is! List) return {};

  final result = <String, EpisodeProgress>{};
  for (final item in rawItems) {
    if (item is! Map) continue;

    final feedUrl = item['feed_url'];
    if (feedUrl is! String || feedUrl.isEmpty || feedUrl.contains('\n')) {
      continue;
    }

    final guid = item['guid'];
    if (guid is! String || guid.isEmpty) {
      continue;
    }

    final progress = EpisodeProgress.fromJson(item);
    if (progress == null) {
      continue;
    }

    final key = podcastEpisodeKey(feedUrl, guid);
    final existing = result[key];
    if (existing == null) {
      result[key] = progress;
    } else {
      result[key] = newerProgress(existing, progress);
    }
  }

  return result;
}

/// Coordinator of podcast stop positions sync with server.
class PodcastSync {
  static const int batch = 500;
  static const int maxPages = 50;

  final PodcastProgressStore store;
  final PodcastSyncPort port;
  final PodcastProgressBox markBox;

  int _mark = 0;
  bool _markLoaded = false;
  int _generation = 0;
  Future<PodcastSyncResult>? _running;

  PodcastSync(this.store, this.port, this.markBox);

  /// Performs one sync cycle (send, then receive changes).
  ///
  /// Repeated call during operation returns same Future.
  Future<PodcastSyncResult> run() {
    if (_running != null) return _running!;
    final future = _run();
    _running = future;
    return future.whenComplete(() {
      if (_running == future) {
        _running = null;
      }
    });
  }

  /// Aborts ongoing sync without touching mark: screen closed (FT-735).
  /// Response arriving after is no longer applied.
  void cancel() {
    _generation++;
    _running = null;
  }

  /// Resets state on sign-out from account.
  ///
  /// Aborts current sync, returning stale.
  Future<void> reset() async {
    _generation++;
    _running = null;
    _mark = 0;
    _markLoaded = true;
    try {
      await markBox.write('0');
    } catch (_) {}
  }

  Future<void> _ensureMark(int myGen) async {
    if (_markLoaded) return;
    try {
      final raw = await markBox.read();
      if (_generation != myGen) return;
      if (raw != null && raw.trim().isNotEmpty) {
        final parsed = int.tryParse(raw.trim());
        if (parsed != null && parsed >= 0) {
          _mark = parsed;
        } else {
          _mark = 0;
        }
      } else {
        _mark = 0;
      }
    } catch (_) {
      if (_generation != myGen) return;
      _mark = 0;
    }
    _markLoaded = true;
  }

  Future<PodcastSyncResult> _run() async {
    final myGen = _generation;

    try {
      await _ensureMark(myGen);
    } catch (_) {
      if (_generation != myGen) return PodcastSyncResult.stale;
      return PodcastSyncResult.failed;
    }
    if (_generation != myGen) return PodcastSyncResult.stale;

    // 1. Send accumulated records
    final Map<String, EpisodeProgress> pending;
    try {
      pending = store.pending();
    } catch (_) {
      if (_generation != myGen) return PodcastSyncResult.stale;
      return PodcastSyncResult.failed;
    }
    if (_generation != myGen) return PodcastSyncResult.stale;

    if (pending.isNotEmpty) {
      final entries = pending.entries.toList();
      for (var i = 0; i < entries.length; i += batch) {
        final end = (i + batch < entries.length) ? i + batch : entries.length;
        final chunk = Map.fromEntries(entries.sublist(i, end));

        final Map<String, EpisodeProgress> answer;
        try {
          answer = await port.put(chunk);
        } catch (_) {
          if (_generation != myGen) return PodcastSyncResult.stale;
          return PodcastSyncResult.failed;
        }
        if (_generation != myGen) return PodcastSyncResult.stale;

        for (final entry in chunk.entries) {
          try {
            await store.ack(entry.key, entry.value);
          } catch (_) {
            if (_generation != myGen) return PodcastSyncResult.stale;
            return PodcastSyncResult.failed;
          }
          if (_generation != myGen) return PodcastSyncResult.stale;
        }

        try {
          await store.applyRemote(answer);
        } catch (_) {
          if (_generation != myGen) return PodcastSyncResult.stale;
          return PodcastSyncResult.failed;
        }
        if (_generation != myGen) return PodcastSyncResult.stale;
      }
    }

    // 2. Receive changes
    for (var page = 0; page < maxPages; page++) {
      final PodcastChanges changes;
      try {
        changes = await port.changes(_mark);
      } catch (_) {
        if (_generation != myGen) return PodcastSyncResult.stale;
        return PodcastSyncResult.failed;
      }
      if (_generation != myGen) return PodcastSyncResult.stale;

      // Empty page with advanced mark is not the end: phone might not have
      // parsed any records in it, but subsequent pages are needed.
      if (changes.items.isNotEmpty) {
        try {
          await store.applyRemote(changes.items);
        } catch (_) {
          if (_generation != myGen) return PodcastSyncResult.stale;
          return PodcastSyncResult.failed;
        }
        if (_generation != myGen) return PodcastSyncResult.stale;
      }

      if (changes.mark <= _mark) {
        break;
      }

      _mark = changes.mark;
      try {
        await markBox.write('$_mark');
      } catch (_) {
        // Mark write failure does not fail the sync.
      }
      if (_generation != myGen) return PodcastSyncResult.stale;
    }

    return PodcastSyncResult.done;
  }
}
