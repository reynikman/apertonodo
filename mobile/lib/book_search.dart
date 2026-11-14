import 'dart:async';

import 'package:flutter/foundation.dart';
import 'book_client.dart';
import 'listening_languages.dart';

class BookSearchModel extends ChangeNotifier {
  static const defaultPause = Duration(milliseconds: 400);

  final BookClient _client;
  final Duration pause;
  final ListeningLanguages? languages;

  String _query = '';
  List<FoundBook> _rawResults = const [];
  List<FoundBook> _results = const [];
  int _hiddenByLanguage = 0;
  bool _showingAllLanguages = false;
  bool _searching = false;
  bool _searched = false;
  BookFailure? _failure;

  Timer? _debounceTimer;
  int _nextRequestId = 0;
  bool _isDisposed = false;

  BookSearchModel(this._client, {this.pause = defaultPause, this.languages}) {
    languages?.addListener(_onLanguagesChanged);
  }

  String get query => _query;
  List<FoundBook> get results => _results;
  int get hiddenByLanguage => _hiddenByLanguage;
  bool get searching => _searching;
  bool get searched => _searched;
  BookFailure? get failure => _failure;

  void _applyFilter() {
    final chosen = languages?.chosen(LanguageScope.books);
    if (_showingAllLanguages || chosen == null) {
      _results = _rawResults;
      _hiddenByLanguage = 0;
    } else {
      final allowed = chosen.toSet();
      final filtered = <FoundBook>[];
      for (final book in _rawResults) {
        if (allowed.contains(book.language)) {
          filtered.add(book);
        }
      }
      _results = filtered;
      _hiddenByLanguage = _rawResults.length - filtered.length;
    }
  }

  void _onLanguagesChanged() {
    if (_isDisposed) return;
    _showingAllLanguages = false;
    _applyFilter();
    notifyListeners();
  }

  void showAllLanguages() {
    if (_isDisposed) return;
    _showingAllLanguages = true;
    _applyFilter();
    notifyListeners();
  }

  void setQuery(String text) {
    if (_isDisposed) return;
    final trimmed = text.trim();
    if (trimmed == _query) return;

    _debounceTimer?.cancel();
    _debounceTimer = null;
    final requestId = ++_nextRequestId;
    _failure = null;
    _query = trimmed;
    _showingAllLanguages = false;

    if (trimmed.runes.length < bookSearchMinChars) {
      _rawResults = const [];
      _results = const [];
      _hiddenByLanguage = 0;
      _searching = false;
      _searched = false;
    } else {
      _searching = true;
      _searched = false;
      _debounceTimer = Timer(pause, () {
        _performSearch(trimmed, requestId);
      });
    }
    notifyListeners();
  }

  Future<void> submit() async {
    if (_isDisposed) return;
    if (_query.runes.length < bookSearchMinChars) return;

    _debounceTimer?.cancel();
    _debounceTimer = null;
    final requestId = ++_nextRequestId;
    _failure = null;
    _showingAllLanguages = false;
    _searching = true;
    _searched = false;
    notifyListeners();

    await _performSearch(_query, requestId);
  }

  Future<void> _performSearch(String queryText, int requestId) async {
    try {
      final books = await _client.search(queryText);
      if (_isDisposed || requestId != _nextRequestId) return;
      _rawResults = books;
      _showingAllLanguages = false;
      _applyFilter();
      _searched = true;
      _searching = false;
      _failure = null;
      notifyListeners();
    } on BookException catch (e) {
      if (_isDisposed || requestId != _nextRequestId) return;
      _failure = e.reason;
      _searching = false;
      notifyListeners();
    } catch (_) {
      if (_isDisposed || requestId != _nextRequestId) return;
      _failure = BookFailure.offline;
      _searching = false;
      notifyListeners();
    }
  }

  void reset() {
    if (_isDisposed) return;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _nextRequestId++;
    _query = '';
    _rawResults = const [];
    _results = const [];
    _hiddenByLanguage = 0;
    _showingAllLanguages = false;
    _searching = false;
    _searched = false;
    _failure = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _nextRequestId++;
    languages?.removeListener(_onLanguagesChanged);
    super.dispose();
  }
}
