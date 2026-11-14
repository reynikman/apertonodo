import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'book_position.dart';

const List<double> bookSpeeds = [
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

double nearestBookSpeed(num v) {
  if (v.isNaN || v.isInfinite) {
    return 1.0;
  }
  final val = v.toDouble();
  var best = bookSpeeds.first;
  var minDiff = (val - best).abs();
  for (final speed in bookSpeeds) {
    final diff = (val - speed).abs();
    if (diff < minDiff) {
      minDiff = diff;
      best = speed;
    } else if (diff == minDiff && speed < best) {
      best = speed;
    }
  }
  return best;
}

abstract class BookProgressBox {
  Future<String?> read();
  Future<void> write(String data);
}

class BookProgressStore extends ChangeNotifier {
  static const int maxBooks = 5000;
  static const Duration saveEvery = Duration(seconds: 5);

  final BookProgressBox _box;
  final DateTime Function() _clock;

  final Map<String, BookPosition> _books = {};
  final Map<String, double> _speeds = {};
  final Set<String> _dirty = {};
  final Set<String> _speedsSetThisRun = {};

  bool _closed = false;
  bool _disposed = false;
  int _clearEpoch = 0;
  int _restoreEpoch = 0;

  DateTime? _lastSaveTime;
  bool _dirtyDisk = false;
  bool _writing = false;
  bool _microtaskScheduled = false;

  Completer<bool>? _activeWriteCompleter;
  Completer<bool>? _pendingWriteCompleter;

  BookProgressStore(this._box, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  BookPosition? of(String bookId) => _books[bookId];

  double speedOf(String bookId) => _speeds[bookId] ?? 1.0;

  Map<String, BookPosition> pending() {
    final result = <String, BookPosition>{};
    for (final id in _dirty) {
      final pos = _books[id];
      if (pos != null) {
        result[id] = pos;
      }
    }
    return result;
  }

  DateTime _nextTimestamp(String bookId) {
    var now = _clock().toUtc();
    final prev = _books[bookId];
    if (prev != null && !now.isAfter(prev.updatedAt)) {
      now = prev.updatedAt.add(const Duration(milliseconds: 1));
    }
    return now;
  }

  bool _shouldSaveNow({bool immediate = false}) {
    if (immediate) return true;
    if (_lastSaveTime == null) return true;
    final now = _clock().toUtc();
    if (now.isBefore(_lastSaveTime!)) return true;
    return now.difference(_lastSaveTime!) >= saveEvery;
  }

  void _evictOldIfNeeded() {
    if (_books.length <= maxBooks) return;

    final keys = _books.keys.toList();
    keys.sort((a, b) {
      final aDirty = _dirty.contains(a);
      final bDirty = _dirty.contains(b);
      if (aDirty != bDirty) {
        return aDirty ? 1 : -1;
      }
      return _books[a]!.updatedAt.compareTo(_books[b]!.updatedAt);
    });

    final toRemoveCount = _books.length - maxBooks;
    for (var i = 0; i < toRemoveCount; i++) {
      final key = keys[i];
      _books.remove(key);
      _dirty.remove(key);
      _speeds.remove(key);
      _speedsSetThisRun.remove(key);
    }
  }

  String _encodeJson() {
    final booksMap = <String, Object?>{};
    for (final entry in _books.entries) {
      booksMap[entry.key] = entry.value.toJson();
    }

    final speedsMap = <String, double>{};
    for (final entry in _speeds.entries) {
      if (entry.value != 1.0) {
        speedsMap[entry.key] = entry.value;
      }
    }

    final dirtyList = <String>[];
    for (final id in _dirty) {
      if (_books.containsKey(id)) {
        dirtyList.add(id);
      }
    }

    return jsonEncode({
      'v': 1,
      'books': booksMap,
      'speeds': speedsMap,
      'dirty': dirtyList,
    });
  }

  Future<bool> _requestSave() {
    if (_writing) {
      if (_dirtyDisk) {
        _pendingWriteCompleter ??= Completer<bool>();
        return _pendingWriteCompleter!.future;
      } else {
        if (_pendingWriteCompleter != null) {
          return _pendingWriteCompleter!.future;
        }
        return _activeWriteCompleter?.future ??
            (_pendingWriteCompleter ??= Completer<bool>()).future;
      }
    }

    _pendingWriteCompleter ??= Completer<bool>();
    final future = _pendingWriteCompleter!.future;

    if (!_microtaskScheduled) {
      _microtaskScheduled = true;
      scheduleMicrotask(_drainWrites);
    }

    return future;
  }

  Future<void> _drainWrites() async {
    _microtaskScheduled = false;
    if (_writing) return;
    _writing = true;

    try {
      while (_dirtyDisk || _pendingWriteCompleter != null) {
        final completer = _pendingWriteCompleter ?? Completer<bool>();
        _activeWriteCompleter = completer;
        _pendingWriteCompleter = null;
        _dirtyDisk = false;

        final payload = _encodeJson();
        var success = false;
        try {
          await _box.write(payload);
          _lastSaveTime = _clock().toUtc();
          success = true;
        } catch (_) {
          _dirtyDisk = true;
          success = false;
        } finally {
          _activeWriteCompleter = null;
          if (!completer.isCompleted) {
            completer.complete(success);
          }
        }

        if (!success) {
          final pending = _pendingWriteCompleter;
          _pendingWriteCompleter = null;
          if (pending != null && !pending.isCompleted) {
            pending.complete(false);
          }
          break;
        }
      }
    } finally {
      _writing = false;
      final pending = _pendingWriteCompleter;
      _pendingWriteCompleter = null;
      if (pending != null && !pending.isCompleted) {
        pending.complete(false);
      }
    }
  }

  Future<void> setSpeed(String bookId, num v) async {
    if (_closed) return;
    final speed = nearestBookSpeed(v);
    _speedsSetThisRun.add(bookId);

    final current = _speeds[bookId] ?? 1.0;
    if (speed == current) return;

    if (speed == 1.0) {
      _speeds.remove(bookId);
    } else {
      _speeds[bookId] = speed;
    }

    _dirtyDisk = true;
    if (!_disposed) {
      notifyListeners();
    }
    await _requestSave();
  }

  Future<void> report(
    String bookId,
    int part,
    int positionMs, {
    bool force = false,
  }) async {
    if (_closed) return;
    if (part < 1 ||
        part > maxBookParts ||
        positionMs < 0 ||
        positionMs > maxBookPartMs) {
      return;
    }

    final isNewBook = !_books.containsKey(bookId);
    final prev = _books[bookId];
    final isPartChanged = prev != null && prev.part != part;
    final isUnfinished = prev != null && prev.finished;

    final pos = BookPosition(
      part: part,
      positionMs: positionMs,
      finished: false,
      updatedAt: _nextTimestamp(bookId),
    );

    _books[bookId] = pos;
    _dirty.add(bookId);
    _evictOldIfNeeded();

    if (isNewBook || isPartChanged || isUnfinished) {
      if (!_disposed) {
        notifyListeners();
      }
    }

    final immediate = force || isNewBook || isPartChanged || isUnfinished;
    if (_shouldSaveNow(immediate: immediate)) {
      _dirtyDisk = true;
      await _requestSave();
    } else {
      _dirtyDisk = true;
    }
  }

  Future<void> finish(String bookId) async {
    if (_closed) return;
    final prev = _books[bookId];
    final part = prev?.part ?? 1;
    final positionMs = prev?.positionMs ?? 0;

    final pos = BookPosition(
      part: part,
      positionMs: positionMs,
      finished: true,
      updatedAt: _nextTimestamp(bookId),
    );

    _books[bookId] = pos;
    _dirty.add(bookId);
    _evictOldIfNeeded();

    _dirtyDisk = true;
    if (!_disposed) {
      notifyListeners();
    }
    await _requestSave();
  }

  Future<void> restart(String bookId) async {
    if (_closed) return;
    final pos = BookPosition(
      part: 1,
      positionMs: 0,
      finished: false,
      updatedAt: _nextTimestamp(bookId),
    );

    _books[bookId] = pos;
    _dirty.add(bookId);
    _evictOldIfNeeded();

    _dirtyDisk = true;
    if (!_disposed) {
      notifyListeners();
    }
    await _requestSave();
  }

  Future<void> ack(String bookId, BookPosition sent) async {
    if (_closed) return;
    if (!_dirty.contains(bookId)) return;
    final current = _books[bookId];
    if (current == sent) {
      _dirty.remove(bookId);
      _dirtyDisk = true;
      await _requestSave();
    }
  }

  Future<void> applyRemote(Map<String, BookPosition> remote) async {
    if (_closed) return;
    var changed = false;

    for (final entry in remote.entries) {
      final bookId = entry.key;
      final remotePos = entry.value;
      final localPos = _books[bookId];

      if (localPos == null) {
        _books[bookId] = remotePos;
        _dirty.remove(bookId);
        changed = true;
      } else {
        final best = newerBookPosition(localPos, remotePos);
        if (best == remotePos && best != localPos) {
          _books[bookId] = remotePos;
          _dirty.remove(bookId);
          changed = true;
        }
      }
    }

    if (changed) {
      _evictOldIfNeeded();
      _dirtyDisk = true;
      if (!_disposed) {
        notifyListeners();
      }
      await _requestSave();
    }
  }

  Future<void> restore() async {
    final epochAtStart = _clearEpoch;
    final restoreId = ++_restoreEpoch;

    String? raw;
    try {
      raw = await _box.read();
    } catch (_) {
      raw = null;
    }

    if (_clearEpoch != epochAtStart || restoreId != _restoreEpoch) {
      return;
    }

    _closed = false;

    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final dirtyData = decoded['dirty'];
          final diskDirtySet = <String>{};
          if (dirtyData is List) {
            for (final item in dirtyData) {
              if (item is String) {
                diskDirtySet.add(item);
              }
            }
          }

          final booksData = decoded['books'];
          if (booksData is Map) {
            for (final entry in booksData.entries) {
              final key = entry.key;
              if (key is! String) continue;
              final pos = BookPosition.fromJson(entry.value);
              if (pos == null) continue;

              final existing = _books[key];
              if (existing == null) {
                _books[key] = pos;
                if (diskDirtySet.contains(key)) {
                  _dirty.add(key);
                }
              } else {
                final best = newerBookPosition(existing, pos);
                _books[key] = best;
                if (best == pos && best != existing) {
                  if (diskDirtySet.contains(key)) {
                    _dirty.add(key);
                  } else {
                    _dirty.remove(key);
                  }
                }
              }
            }
          }

          final speedsData = decoded['speeds'];
          if (speedsData is Map) {
            for (final entry in speedsData.entries) {
              final key = entry.key;
              if (key is! String) continue;
              if (_speedsSetThisRun.contains(key)) continue;

              final val = entry.value;
              if (val is num) {
                final speed = nearestBookSpeed(val);
                if (speed != 1.0) {
                  _speeds[key] = speed;
                } else {
                  _speeds.remove(key);
                }
              }
            }
          }
        }
      } catch (_) {}
    }

    _dirty.removeWhere((id) => !_books.containsKey(id));
    _evictOldIfNeeded();

    if (!_disposed) {
      notifyListeners();
    }
  }

  Future<bool> flush() async {
    if (!_dirtyDisk && !_writing && _pendingWriteCompleter == null) {
      return true;
    }
    return _requestSave();
  }

  Future<bool> clear() async {
    _closed = true;
    _clearEpoch++;

    _books.clear();
    _speeds.clear();
    _dirty.clear();
    _speedsSetThisRun.clear();

    _dirtyDisk = true;
    if (!_disposed) {
      notifyListeners();
    }

    return flush();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
