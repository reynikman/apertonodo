import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'book_position.dart';
import 'podcast_progress.dart';

/// Item kind on the "Continue" shelf.
enum ContinueKind { podcast, book }

/// Metadata of the "Continue" shelf item.
@immutable
class ContinueMeta {
  final ContinueKind kind;
  final String key;
  final String title;
  final String subtitle;
  final String? imageUrl;
  final int? durationMs;
  final int? partCount;

  const ContinueMeta({
    required this.kind,
    required this.key,
    required this.title,
    required this.subtitle,
    this.imageUrl,
    this.durationMs,
    this.partCount,
  });

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'key': key,
    'title': title,
    'subtitle': subtitle,
    'image': imageUrl,
    'duration_ms': durationMs,
    'parts': partCount,
  };

  static ContinueMeta? fromJson(Object? json) {
    if (json is! Map) return null;

    final kindRaw = json['kind'];
    if (kindRaw is! String) return null;
    final ContinueKind kind;
    if (kindRaw == 'podcast') {
      kind = ContinueKind.podcast;
    } else if (kindRaw == 'book') {
      kind = ContinueKind.book;
    } else {
      return null;
    }

    final key = json['key'];
    if (key is! String) return null;

    final title = json['title'];
    if (title is! String) return null;

    final subtitle = json['subtitle'];
    if (subtitle is! String) return null;

    final image = json['image'];
    if (image != null && image is! String) return null;

    final durationMs = json['duration_ms'];
    if (durationMs != null && durationMs is! int) return null;

    final parts = json['parts'];
    if (parts != null && parts is! int) return null;

    return ContinueMeta(
      kind: kind,
      key: key,
      title: title,
      subtitle: subtitle,
      imageUrl: image,
      durationMs: durationMs,
      partCount: parts,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ContinueMeta &&
        other.kind == kind &&
        other.key == key &&
        other.title == title &&
        other.subtitle == subtitle &&
        other.imageUrl == imageUrl &&
        other.durationMs == durationMs &&
        other.partCount == partCount;
  }

  @override
  int get hashCode =>
      Object.hash(kind, key, title, subtitle, imageUrl, durationMs, partCount);

  @override
  String toString() => 'ContinueMeta($key, $kind)';
}

/// "Continue" shelf item with current playback position.
@immutable
class ContinueItem {
  final ContinueMeta meta;
  final int positionMs;
  final DateTime updatedAt;
  final int? part;
  final int? remainingMs;

  const ContinueItem({
    required this.meta,
    required this.positionMs,
    required this.updatedAt,
    this.part,
    this.remainingMs,
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ContinueItem &&
        other.meta == meta &&
        other.positionMs == positionMs &&
        other.updatedAt.isAtSameMomentAs(updatedAt) &&
        other.part == part &&
        other.remainingMs == remainingMs;
  }

  @override
  int get hashCode => Object.hash(
    meta,
    positionMs,
    updatedAt.microsecondsSinceEpoch,
    part,
    remainingMs,
  );

  @override
  String toString() =>
      'ContinueItem(${meta.key}, pos: $positionMs, part: $part)';
}

/// Abstract storage of "Continue" shelf data on disk.
abstract class ContinueBox {
  Future<String?> read();
  Future<void> write(String data);
}

/// "Continue" shelf model for podcasts and audiobooks.
class ContinueShelf extends ChangeNotifier {
  static const int maxEntries = 50;
  static const int minPositionMs = 10000;

  final ContinueBox _box;
  final EpisodeProgress? Function(String key) podcast;
  final BookPosition? Function(String key) book;
  final bool Function(ContinueMeta)? available;

  final Map<String, ContinueMeta> _entries = {};
  bool _restored = false;
  bool _cleared = false;
  int _epoch = 0;
  bool _disposed = false;
  Future<void> _writeQueue = Future.value();

  ContinueShelf(
    this._box, {
    required this.podcast,
    required this.book,
    this.available,
  });

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  /// Remembers or refreshes an item on the shelf.
  Future<void> remember(ContinueMeta meta) async {
    if (_cleared) return;

    _entries.remove(meta.key);
    _entries[meta.key] = meta;

    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }

    _notify();

    if (_restored) {
      await _enqueueSave();
    }
  }

  /// Removes item from the shelf.
  Future<void> forget(String key) async {
    if (!_entries.containsKey(key)) return;

    _entries.remove(key);
    _notify();

    if (_restored) {
      await _enqueueSave();
    }
  }

  /// Clears shelf in memory and on disk on user logout.
  Future<void> clear() async {
    _epoch++;
    _cleared = true;
    _restored = false;
    _entries.clear();
    _notify();
    await _enqueueSave();
  }

  /// Restores shelf state from disk.
  Future<void> restore() async {
    final epoch = ++_epoch;
    _cleared = false;
    _restored = false;

    String? raw;
    try {
      raw = await _box.read();
    } catch (_) {
      return;
    }

    if (epoch != _epoch || _cleared) return;

    final diskItems = <ContinueMeta>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final itemsRaw = decoded['items'];
          if (itemsRaw is List) {
            for (final item in itemsRaw) {
              final meta = ContinueMeta.fromJson(item);
              if (meta != null) {
                diskItems.add(meta);
              }
            }
          }
        }
      } catch (_) {
        // Corrupted JSON is ignored.
      }
    }

    final inMemory = Map<String, ContinueMeta>.from(_entries);

    final merged = <String, ContinueMeta>{};
    for (final d in diskItems) {
      if (!inMemory.containsKey(d.key)) {
        merged[d.key] = d;
      }
    }
    for (final entry in inMemory.entries) {
      merged[entry.key] = entry.value;
    }

    while (merged.length > maxEntries) {
      merged.remove(merged.keys.first);
    }

    _entries
      ..clear()
      ..addAll(merged);

    _restored = true;
    _notify();

    if (inMemory.isNotEmpty) {
      await _enqueueSave();
    }
  }

  /// Returns list of items to display, sorted by recent position.
  List<ContinueItem> items({int limit = 10}) {
    if (limit <= 0) return const [];

    final result = <ContinueItem>[];

    final isAvailable = available;
    for (final meta in _entries.values) {
      if (isAvailable != null && !isAvailable(meta)) continue;

      switch (meta.kind) {
        case ContinueKind.podcast:
          final progress = podcast(meta.key);
          if (progress == null) continue;
          if (progress.positionMs < minPositionMs) continue;
          if (progress.done) continue;
          if (podcastFinished(progress.positionMs, meta.durationMs)) continue;

          final int? remainingMs;
          if (meta.durationMs != null && meta.durationMs! > 0) {
            final rem = meta.durationMs! - progress.positionMs;
            remainingMs = rem < 0 ? 0 : rem;
          } else {
            remainingMs = null;
          }

          result.add(
            ContinueItem(
              meta: meta,
              positionMs: progress.positionMs,
              updatedAt: progress.updatedAt,
              remainingMs: remainingMs,
            ),
          );

        case ContinueKind.book:
          final position = book(meta.key);
          if (position == null) continue;
          if (position.finished) continue;
          if (position.part <= 1 && position.positionMs < minPositionMs) {
            continue;
          }

          result.add(
            ContinueItem(
              meta: meta,
              positionMs: position.positionMs,
              updatedAt: position.updatedAt,
              part: position.part,
            ),
          );
      }
    }

    result.sort((a, b) {
      final cmp = b.updatedAt.compareTo(a.updatedAt);
      if (cmp != 0) return cmp;
      return a.meta.key.compareTo(b.meta.key);
    });

    if (result.length > limit) {
      return result.sublist(0, limit);
    }
    return result;
  }

  Future<void> _enqueueSave() {
    final jsonStr = jsonEncode({
      'items': [for (final meta in _entries.values) meta.toJson()],
    });
    final completer = Completer<void>();
    _writeQueue = _writeQueue
        .then((_) async {
          try {
            await _box.write(jsonStr);
          } catch (_) {
            // Disk errors do not crash callers.
          } finally {
            completer.complete();
          }
        })
        .catchError((_) {
          if (!completer.isCompleted) {
            completer.complete();
          }
        });
    return completer.future;
  }
}
