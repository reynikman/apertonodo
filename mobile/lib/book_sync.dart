import 'dart:async';

import 'book_position.dart';
import 'book_progress.dart';

class BookSyncPage {
  final Map<String, BookPosition> items;
  final int mark;

  const BookSyncPage(this.items, this.mark);

  @override
  String toString() => 'BookSyncPage';
}

abstract class BookSyncPort {
  Future<Map<String, BookPosition>> put(Map<String, BookPosition> batch);
  Future<BookSyncPage> changes(int after);
}

enum BookSyncResult { done, failed, stale }

class BookSync {
  static const int batch = 500;
  static const int maxPages = 50;

  final BookProgressStore _store;
  final BookSyncPort _port;
  final BookProgressBox _markBox;

  int _mark = 0;
  bool _markLoaded = false;
  int _currentEpoch = 0;
  Future<BookSyncResult>? _running;

  BookSync(this._store, this._port, this._markBox);

  int get mark => _mark;

  Future<BookSyncResult> run() {
    final existing = _running;
    if (existing != null) {
      return existing;
    }

    final epoch = _currentEpoch;
    late final Future<BookSyncResult> future;
    future = (() async {
      try {
        return await _execute(epoch);
      } catch (_) {
        if (epoch != _currentEpoch) {
          return BookSyncResult.stale;
        }
        return BookSyncResult.failed;
      } finally {
        if (identical(_running, future)) {
          _running = null;
        }
      }
    })();

    _running = future;
    return future;
  }

  Future<void> reset() async {
    _currentEpoch++;
    _running = null;
    _mark = 0;
    _markLoaded = true;
    try {
      await _markBox.write('0');
    } catch (_) {
      // Ignore disk write failure
    }
  }

  Future<BookSyncResult> _execute(int epoch) async {
    if (!_markLoaded) {
      var initialMark = 0;
      try {
        final raw = await _markBox.read();
        if (raw != null) {
          final parsed = int.tryParse(raw.trim());
          if (parsed != null && parsed >= 0) {
            initialMark = parsed;
          }
        }
      } catch (_) {
        initialMark = 0;
      }
      if (epoch != _currentEpoch) {
        return BookSyncResult.stale;
      }
      _mark = initialMark;
      _markLoaded = true;
    }

    // 1. Sending
    final pending = _store.pending();
    if (pending.isNotEmpty) {
      final entries = pending.entries.toList();
      for (var i = 0; i < entries.length; i += batch) {
        final end = (i + batch < entries.length) ? i + batch : entries.length;
        final chunkEntries = entries.sublist(i, end);
        final batchMap = Map<String, BookPosition>.fromEntries(chunkEntries);

        final Map<String, BookPosition> remote;
        try {
          remote = await _port.put(batchMap);
        } catch (_) {
          if (epoch != _currentEpoch) {
            return BookSyncResult.stale;
          }
          return BookSyncResult.failed;
        }
        if (epoch != _currentEpoch) {
          return BookSyncResult.stale;
        }

        for (final entry in batchMap.entries) {
          await _store.ack(entry.key, entry.value);
          if (epoch != _currentEpoch) {
            return BookSyncResult.stale;
          }
        }

        await _store.applyRemote(remote);
        if (epoch != _currentEpoch) {
          return BookSyncResult.stale;
        }
      }
    }

    // 2. Receiving
    var pagesCount = 0;
    var rolledBack = false;

    while (pagesCount < maxPages) {
      final asked = _mark;
      final BookSyncPage page;
      try {
        page = await _port.changes(asked);
      } catch (_) {
        if (epoch != _currentEpoch) {
          return BookSyncResult.stale;
        }
        return BookSyncResult.failed;
      }
      if (epoch != _currentEpoch) {
        return BookSyncResult.stale;
      }

      pagesCount++;

      if (page.mark < asked) {
        if (rolledBack) {
          return BookSyncResult.failed;
        }
        rolledBack = true;
        _mark = 0;
        await _saveMark(epoch, 0);
        if (epoch != _currentEpoch) {
          return BookSyncResult.stale;
        }
        continue;
      }

      await _store.applyRemote(page.items);
      if (epoch != _currentEpoch) {
        return BookSyncResult.stale;
      }

      if (page.mark > asked) {
        _mark = page.mark;
        await _saveMark(epoch, page.mark);
        if (epoch != _currentEpoch) {
          return BookSyncResult.stale;
        }
      } else {
        // page.mark == asked
        return BookSyncResult.done;
      }
    }

    return BookSyncResult.done;
  }

  Future<void> _saveMark(int epoch, int mark) async {
    if (epoch != _currentEpoch) return;
    try {
      await _markBox.write(mark.toString());
    } catch (_) {
      // Ignore disk write failure
    }
  }
}
