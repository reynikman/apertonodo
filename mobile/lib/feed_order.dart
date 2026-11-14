// FT-707: Episode order of podcast on phone (Pd-2).

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Playback order of podcast episodes.
enum FeedOrder {
  /// Newest episodes first (default).
  newestFirst,

  /// From the first episode (oldest first).
  oldestFirst,
}

/// Raw storage of episode order data on disk.
abstract class FeedOrderBox {
  Future<String?> read();
  Future<void> write(String data);
}

/// Storage of podcast episode order on phone.
class FeedOrderStore extends ChangeNotifier {
  static const int maxFeeds = 2000;

  final FeedOrderBox _box;

  final Map<String, FeedOrder> _feeds = <String, FeedOrder>{};
  final Map<String, FeedOrder> _touchedBeforeRestore = <String, FeedOrder>{};

  bool _closed = false;
  bool _restored = false;
  bool _disposed = false;
  int _epoch = 0;
  Future<void> _saveQueue = Future<void>.value();

  FeedOrderStore(this._box);

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Episode order for podcast [feedUrl] (defaults to [FeedOrder.newestFirst]).
  FeedOrder orderOf(String feedUrl) {
    return _feeds[feedUrl] ?? FeedOrder.newestFirst;
  }

  /// Sets episode order for podcast [feedUrl].
  Future<void> set(String feedUrl, FeedOrder order) async {
    if (_closed) return;

    final current = orderOf(feedUrl);
    final changed = current != order;

    if (order == FeedOrder.oldestFirst) {
      _feeds.remove(feedUrl);
      _feeds[feedUrl] = order;
      _pruneIfNeeded();
    } else {
      _feeds.remove(feedUrl);
    }

    if (!_restored) {
      _touchedBeforeRestore[feedUrl] = order;
      if (changed) {
        _notify();
      }
      return;
    }

    if (changed) {
      _notify();
    }

    await _enqueueWrite();
  }

  /// Restores state from storage.
  Future<void> restore() async {
    final epoch = ++_epoch;
    _closed = false;
    String? raw;
    try {
      raw = await _box.read();
    } catch (_) {
      raw = null;
    }
    if (epoch != _epoch) return;

    final merged = <String, FeedOrder>{};
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final feeds = decoded['feeds'];
          if (feeds is Map) {
            for (final entry in feeds.entries) {
              final key = entry.key;
              if (key is! String) continue;
              if (_touchedBeforeRestore.containsKey(key)) continue;
              if (entry.value == 'oldest') {
                merged[key] = FeedOrder.oldestFirst;
              }
            }
          }
        }
      } catch (_) {
        // Ignore corrupted data.
      }
    }

    for (final entry in _touchedBeforeRestore.entries) {
      if (entry.value == FeedOrder.oldestFirst) {
        merged.remove(entry.key);
        merged[entry.key] = FeedOrder.oldestFirst;
      }
    }

    _feeds
      ..clear()
      ..addAll(merged);
    _pruneIfNeeded();

    _restored = true;
    final hadPending = _touchedBeforeRestore.isNotEmpty;
    _touchedBeforeRestore.clear();

    if (hadPending) {
      await _enqueueWrite();
    }
    _notify();
  }

  /// Clears all entries in memory and on disk and closes storage until next [restore].
  Future<void> clear() async {
    _epoch++;
    _closed = true;
    _restored = false;
    _feeds.clear();
    _touchedBeforeRestore.clear();
    _notify();
    await _enqueueWrite();
  }

  void _pruneIfNeeded() {
    if (_feeds.length <= maxFeeds) return;
    final toRemove = _feeds.length - maxFeeds;
    final keysToRemove = _feeds.keys.take(toRemove).toList();
    for (final key in keysToRemove) {
      _feeds.remove(key);
    }
  }

  Future<void> _enqueueWrite() {
    final completer = Completer<void>();
    _saveQueue = _saveQueue.catchError((_) {}).then((_) async {
      try {
        await _writeToDisk();
      } finally {
        completer.complete();
      }
    });
    return completer.future;
  }

  Future<void> _writeToDisk() async {
    try {
      final payload = jsonEncode({
        'feeds': <String, String>{
          for (final entry in _feeds.entries)
            if (entry.value == FeedOrder.oldestFirst) entry.key: 'oldest',
        },
      });
      await _box.write(payload);
    } catch (_) {
      // Ignore disk write errors.
    }
  }
}
