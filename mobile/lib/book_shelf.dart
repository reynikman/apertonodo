import 'dart:async';

import 'package:flutter/foundation.dart';

import 'book_client.dart';

class BookShelfModel extends ChangeNotifier {
  final BookClient _client;

  List<ShelfBook> _books = [];
  List<ShelfBook> _unmodifiableBooks = const [];
  bool _loaded = false;
  bool _loading = false;
  BookFailure? _failure;
  Future<void>? _loadFuture;

  final Set<String> _busyKeys = {};
  final Set<String> _removingIds = {};

  int _generation = 0;
  bool _disposed = false;

  BookShelfModel(this._client);

  List<ShelfBook> get books => _unmodifiableBooks;
  bool get loaded => _loaded;
  bool get loading => _loading;
  BookFailure? get failure => _failure;
  int get totalBytes => _books.fold<int>(0, (sum, b) => sum + b.sizeBytes);

  bool has(String bookId) => _books.any((b) => b.id == bookId);

  bool isBusy(String key) => _busyKeys.contains(key);

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  Future<void> load() {
    if (_disposed) return Future.value();
    if (_loadFuture != null) {
      return _loadFuture!;
    }
    _loading = true;
    _notify();

    final gen = _generation;
    final future = _loadInternal(gen);
    _loadFuture = future;
    return future;
  }

  Future<void> _loadInternal(int gen) async {
    try {
      final list = await _client.shelf();
      if (_disposed || gen != _generation) return;
      final filtered = list.where((b) => !_removingIds.contains(b.id)).toList();
      _books = filtered;
      _unmodifiableBooks = List.unmodifiable(_books);
      _loaded = true;
      _failure = null;
    } on BookException catch (e) {
      if (_disposed || gen != _generation) return;
      _failure = e.reason;
    } catch (_) {
      if (_disposed || gen != _generation) return;
      _failure = BookFailure.offline;
    } finally {
      if (!_disposed && gen == _generation) {
        _loading = false;
        _loadFuture = null;
        _notify();
      }
    }
  }

  Future<BookFailure?> add(String ref) async {
    if (_disposed) return null;
    if (!isBookRef(ref)) {
      return BookFailure.broken;
    }
    if (_busyKeys.contains(ref)) {
      return null;
    }
    _busyKeys.add(ref);
    _notify();

    final gen = _generation;
    try {
      final result = await _client.shelve(ref);
      if (_disposed || gen != _generation) {
        return null;
      }
      _busyKeys.remove(ref);
      final exists = _books.any((b) => b.id == result.book.id);
      if (!exists) {
        _books.insert(0, result.book);
        _unmodifiableBooks = List.unmodifiable(_books);
      }
      _notify();
      return null;
    } on BookException catch (e) {
      if (_disposed || gen != _generation) {
        return null;
      }
      _busyKeys.remove(ref);
      _notify();
      return e.reason;
    } catch (_) {
      if (_disposed || gen != _generation) {
        return null;
      }
      _busyKeys.remove(ref);
      _notify();
      return BookFailure.offline;
    }
  }

  Future<BookFailure?> remove(String bookId) async {
    if (_disposed) return null;
    if (_busyKeys.contains(bookId)) {
      return null;
    }
    final index = _books.indexWhere((b) => b.id == bookId);
    if (index == -1) {
      return null;
    }
    final book = _books.removeAt(index);
    _unmodifiableBooks = List.unmodifiable(_books);
    _busyKeys.add(bookId);
    _removingIds.add(bookId);
    _notify();

    final gen = _generation;
    try {
      await _client.unshelve(bookId);
      if (_disposed || gen != _generation) {
        return null;
      }
      _busyKeys.remove(bookId);
      _removingIds.remove(bookId);
      _notify();
      return null;
    } on BookException catch (e) {
      if (_disposed || gen != _generation) {
        return null;
      }
      _busyKeys.remove(bookId);
      _removingIds.remove(bookId);
      if (!_books.any((b) => b.id == book.id)) {
        final insertIndex = index.clamp(0, _books.length);
        _books.insert(insertIndex, book);
        _unmodifiableBooks = List.unmodifiable(_books);
      }
      _notify();
      return e.reason;
    } catch (_) {
      if (_disposed || gen != _generation) {
        return null;
      }
      _busyKeys.remove(bookId);
      _removingIds.remove(bookId);
      if (!_books.any((b) => b.id == book.id)) {
        final insertIndex = index.clamp(0, _books.length);
        _books.insert(insertIndex, book);
        _unmodifiableBooks = List.unmodifiable(_books);
      }
      _notify();
      return BookFailure.offline;
    }
  }

  void reset() {
    if (_disposed) return;
    _generation++;
    _books = [];
    _unmodifiableBooks = const [];
    _loaded = false;
    _loading = false;
    _failure = null;
    _loadFuture = null;
    _busyKeys.clear();
    _removingIds.clear();
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
