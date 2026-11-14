import 'dart:async';

import 'package:flutter/foundation.dart';
import 'book_position.dart';

const int bookMaxText = 500;
const int bookMaxRows = 500;
const int bookMaxBatch = 500;
const int bookSearchMinChars = 2;
const int bookSearchMaxChars = 200;
const int bookSearchMaxLimit = 50;

enum BookFailure {
  offline,
  unavailable,
  searchUnavailable,
  expired,
  noSpace,
  limit,
  notABook,
  notOnShelf,
  signedOut,
  broken,
}

class BookException implements Exception {
  final BookFailure reason;

  const BookException(this.reason);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BookException && other.reason == reason;

  @override
  int get hashCode => reason.hashCode;

  @override
  String toString() => 'BookException(${reason.name})';
}

class BookReply {
  final int status;
  final Object? json;

  const BookReply(this.status, this.json);

  @override
  String toString() => 'BookReply';
}

typedef BookSend =
    Future<BookReply> Function(
      String method,
      String path, {
      Map<String, String>? query,
      Object? body,
    });

final _bookIdRegex = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

final _bookRefRegex = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

final _playTokenRegex = RegExp(r'^[A-Za-z0-9._~-]{1,512}$');

final _playStateRegex = RegExp(r'^[a-z_]{1,32}$');

bool isBookId(Object? raw) {
  if (raw is! String || raw.length != 36) return false;
  return _bookIdRegex.hasMatch(raw);
}

bool isBookRef(Object? raw) {
  if (raw is! String || raw.isEmpty || raw.length > 128) return false;
  return _bookRefRegex.hasMatch(raw);
}

bool _isControlOrBidi(int code) {
  if (code <= 0x1f || code == 0x7f || (code >= 0x80 && code <= 0x9f)) {
    return true;
  }
  if (code == 0x061c || code == 0x200e || code == 0x200f) {
    return true;
  }
  if (code >= 0x202a && code <= 0x202e) {
    return true;
  }
  if (code >= 0x2066 && code <= 0x2069) {
    return true;
  }
  return false;
}

String bookText(Object? raw, {int maxLength = bookMaxText}) {
  if (raw is! String) return '';
  final buffer = StringBuffer();
  final len = raw.length;
  var i = 0;
  while (i < len) {
    final cu = raw.codeUnitAt(i);
    if (cu >= 0xd800 && cu <= 0xdbff) {
      if (i + 1 < len) {
        final next = raw.codeUnitAt(i + 1);
        if (next >= 0xdc00 && next <= 0xdfff) {
          final rune = 0x10000 + ((cu - 0xd800) << 10) + (next - 0xdc00);
          if (_isControlOrBidi(rune)) {
            buffer.write(' ');
          } else {
            buffer.writeCharCode(rune);
          }
          i += 2;
          continue;
        }
      }
      buffer.writeCharCode(0xfffd);
      i++;
    } else if (cu >= 0xdc00 && cu <= 0xdfff) {
      buffer.writeCharCode(0xfffd);
      i++;
    } else {
      if (_isControlOrBidi(cu)) {
        buffer.write(' ');
      } else {
        buffer.writeCharCode(cu);
      }
      i++;
    }
  }
  var text = buffer.toString().trim();
  if (text.runes.length > maxLength) {
    text = String.fromCharCodes(text.runes.take(maxLength)).trimRight();
  }
  return text;
}

@immutable
class FoundBook {
  final String ref;
  final String title;
  final String author;
  final String narrator;
  final int? year;
  final int sizeBytes;
  final String language;

  const FoundBook({
    required this.ref,
    required this.title,
    this.author = '',
    this.narrator = '',
    this.year,
    this.sizeBytes = 0,
    this.language = 'ru',
  });

  static FoundBook? fromJson(Object? json) {
    if (json is! Map) return null;
    final ref = json['ref'];
    if (!isBookRef(ref)) return null;
    final title = bookText(json['title']);
    if (title.isEmpty) return null;
    final author = bookText(json['author']);
    final narrator = bookText(json['narrator']);
    final rawYear = json['year'];
    final year = (rawYear is int && rawYear >= 1000 && rawYear <= 2100)
        ? rawYear
        : null;
    final rawSize = json['size_bytes'];
    final sizeBytes = (rawSize is int && rawSize >= 0) ? rawSize : 0;
    final rawLang = json['language'];
    final language =
        (rawLang is String && RegExp(r'^[a-z]{2}$').hasMatch(rawLang))
        ? rawLang
        : 'ru';
    return FoundBook(
      ref: ref as String,
      title: title,
      author: author,
      narrator: narrator,
      year: year,
      sizeBytes: sizeBytes,
      language: language,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FoundBook &&
          other.ref == ref &&
          other.title == title &&
          other.author == author &&
          other.narrator == narrator &&
          other.year == year &&
          other.sizeBytes == sizeBytes &&
          other.language == language;

  @override
  int get hashCode =>
      Object.hash(ref, title, author, narrator, year, sizeBytes, language);

  @override
  String toString() => 'FoundBook';
}

@immutable
class ShelfBook {
  final String id;
  final String title;
  final String author;
  final String narrator;
  final int? year;
  final int sizeBytes;
  final int parts;
  final DateTime? shelvedAt;

  const ShelfBook({
    required this.id,
    required this.title,
    this.author = '',
    this.narrator = '',
    this.year,
    this.sizeBytes = 0,
    required this.parts,
    this.shelvedAt,
  });

  static ShelfBook? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    if (!isBookId(id)) return null;
    final title = bookText(json['title']);
    if (title.isEmpty) return null;
    final parts = json['parts'];
    if (parts is! int || parts < 1 || parts > maxBookParts) return null;

    final author = bookText(json['author']);
    final narrator = bookText(json['narrator']);
    final rawYear = json['year'];
    final year = (rawYear is int && rawYear >= 1000 && rawYear <= 2100)
        ? rawYear
        : null;
    final rawSize = json['size_bytes'];
    final sizeBytes = (rawSize is int && rawSize >= 0) ? rawSize : 0;

    DateTime? shelvedAt;
    final rawShelvedAt = json['shelved_at'];
    if (rawShelvedAt is String && rawShelvedAt.endsWith('Z')) {
      shelvedAt = DateTime.tryParse(rawShelvedAt)?.toUtc();
    }

    return ShelfBook(
      id: id as String,
      title: title,
      author: author,
      narrator: narrator,
      year: year,
      sizeBytes: sizeBytes,
      parts: parts,
      shelvedAt: shelvedAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ShelfBook &&
          other.id == id &&
          other.title == title &&
          other.author == author &&
          other.narrator == narrator &&
          other.year == year &&
          other.sizeBytes == sizeBytes &&
          other.parts == parts &&
          other.shelvedAt == shelvedAt;

  @override
  int get hashCode => Object.hash(
    id,
    title,
    author,
    narrator,
    year,
    sizeBytes,
    parts,
    shelvedAt,
  );

  @override
  String toString() => 'ShelfBook';
}

@immutable
class BookPartInfo {
  final int number;
  final String title;
  final int? startMs;
  final int? endMs;

  const BookPartInfo({
    required this.number,
    this.title = '',
    this.startMs,
    this.endMs,
  });

  static BookPartInfo? fromJson(Object? json) {
    if (json is! Map) return null;
    final number = json['number'];
    if (number is! int || number < 1 || number > maxBookParts) return null;
    final title = bookText(json['title']);

    final rawStart = json['start_ms'];
    final rawEnd = json['end_ms'];
    int? startMs;
    int? endMs;
    if (rawStart is int &&
        rawEnd is int &&
        rawStart >= 0 &&
        rawEnd > rawStart) {
      startMs = rawStart;
      endMs = rawEnd;
    }

    return BookPartInfo(
      number: number,
      title: title,
      startMs: startMs,
      endMs: endMs,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BookPartInfo &&
          other.number == number &&
          other.title == title &&
          other.startMs == startMs &&
          other.endMs == endMs;

  @override
  int get hashCode => Object.hash(number, title, startMs, endMs);

  @override
  String toString() => 'BookPartInfo';
}

class BookDetails {
  final ShelfBook book;
  final List<BookPartInfo> parts;

  BookDetails(this.book, List<BookPartInfo> parts)
    : parts = List.unmodifiable(parts);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BookDetails &&
          other.book == book &&
          listEquals(other.parts, parts);

  @override
  int get hashCode => Object.hash(book, Object.hashAll(parts));

  @override
  String toString() => 'BookDetails';
}

@immutable
class BookShelved {
  final ShelfBook book;
  final bool isNew;

  const BookShelved(this.book, {this.isNew = false});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BookShelved && other.book == book && other.isNew == isNew;

  @override
  int get hashCode => Object.hash(book, isNew);

  @override
  String toString() => 'BookShelved';
}

@immutable
class BookPlay {
  final String token;
  final String state;

  const BookPlay(this.token, this.state);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BookPlay && other.token == token && other.state == state;

  @override
  int get hashCode => Object.hash(token, state);

  @override
  String toString() => 'BookPlay';
}

@immutable
class BookChanges {
  final Map<String, BookPosition> items;
  final int mark;

  const BookChanges(this.items, this.mark);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BookChanges &&
          other.mark == mark &&
          mapEquals(other.items, items);

  @override
  int get hashCode => Object.hash(mark, items.length);

  @override
  String toString() => 'BookChanges';
}

class BookClient {
  final BookSend _send;

  BookClient(this._send);

  Future<BookReply> _request(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    bool isShelfSpecific = false,
  }) async {
    final BookReply reply;
    try {
      reply = await _send(method, path, query: query, body: body);
    } on BookException {
      rethrow;
    } catch (_) {
      throw const BookException(BookFailure.offline);
    }

    final status = reply.status;
    if (status == 200 || status == 204) {
      return reply;
    }

    if (status == 401) {
      throw const BookException(BookFailure.signedOut);
    }
    if (status == 400 || status == 422) {
      throw const BookException(BookFailure.broken);
    }
    if (status == 404) {
      throw BookException(
        isShelfSpecific ? BookFailure.notOnShelf : BookFailure.unavailable,
      );
    }
    if (status == 409) {
      final json = reply.json;
      if (json is Map) {
        final reasonStatus = json['status'];
        if (reasonStatus == 'no_space') {
          throw const BookException(BookFailure.noSpace);
        }
        if (reasonStatus == 'limit') {
          throw const BookException(BookFailure.limit);
        }
        if (reasonStatus == 'not_a_book') {
          throw const BookException(BookFailure.notABook);
        }
      }
      throw const BookException(BookFailure.unavailable);
    }
    if (status == 410) {
      throw const BookException(BookFailure.expired);
    }
    if (status == 503) {
      final json = reply.json;
      if (json is Map && json['status'] == 'book_search_unavailable') {
        throw const BookException(BookFailure.searchUnavailable);
      }
      throw const BookException(BookFailure.unavailable);
    }

    throw const BookException(BookFailure.unavailable);
  }

  Map<String, BookPosition> _parsePositions(Object? json) {
    if (json is! Map) throw const BookException(BookFailure.broken);
    final rawItems = json['items'];
    if (rawItems is! List || rawItems.length > bookMaxRows) {
      throw const BookException(BookFailure.broken);
    }
    final result = <String, BookPosition>{};
    for (final raw in rawItems) {
      if (raw is! Map) continue;
      final bookId = raw['book_id'];
      if (!isBookId(bookId)) continue;
      final pos = BookPosition.fromJson(raw);
      if (pos == null) continue;
      final idStr = bookId as String;
      final existing = result[idStr];
      if (existing != null) {
        result[idStr] = newerBookPosition(existing, pos);
      } else {
        result[idStr] = pos;
      }
    }
    return result;
  }

  Future<List<FoundBook>> search(String query, {int limit = 20}) async {
    final trimmed = query.trim();
    if (trimmed.runes.length < bookSearchMinChars) {
      return const [];
    }
    final q = trimmed.runes.length > bookSearchMaxChars
        ? String.fromCharCodes(trimmed.runes.take(bookSearchMaxChars))
        : trimmed;
    final clampedLimit = limit.clamp(1, bookSearchMaxLimit);
    final reply = await _request(
      'GET',
      '/v1/books/search',
      query: {'q': q, 'limit': '$clampedLimit'},
    );
    final json = reply.json;
    if (json is! Map) throw const BookException(BookFailure.broken);
    final rawBooks = json['books'];
    if (rawBooks is! List) throw const BookException(BookFailure.broken);

    final books = <FoundBook>[];
    final seen = <String>{};
    for (final item in rawBooks) {
      final book = FoundBook.fromJson(item);
      if (book != null && seen.add(book.ref)) {
        books.add(book);
        if (books.length == bookMaxRows) break;
      }
    }
    return List.unmodifiable(books);
  }

  Future<List<ShelfBook>> shelf() async {
    final reply = await _request('GET', '/v1/books/shelf');
    final json = reply.json;
    if (json is! Map) throw const BookException(BookFailure.broken);
    final rawBooks = json['books'];
    if (rawBooks is! List) throw const BookException(BookFailure.broken);

    final books = <ShelfBook>[];
    final seen = <String>{};
    for (final item in rawBooks) {
      final book = ShelfBook.fromJson(item);
      if (book != null && seen.add(book.id)) {
        books.add(book);
        if (books.length == bookMaxRows) break;
      }
    }
    return List.unmodifiable(books);
  }

  Future<BookShelved> shelve(String ref) async {
    if (!isBookRef(ref)) {
      throw const BookException(BookFailure.broken);
    }
    final reply = await _request('POST', '/v1/books/shelf', body: {'ref': ref});
    final json = reply.json;
    if (json is! Map) throw const BookException(BookFailure.broken);
    final state = json['state'];
    if (state != 'ok' && state != 'exists') {
      throw const BookException(BookFailure.broken);
    }
    final book = ShelfBook.fromJson(json['book']);
    if (book == null) {
      throw const BookException(BookFailure.broken);
    }
    return BookShelved(book, isNew: state == 'ok');
  }

  Future<void> unshelve(String bookId) async {
    if (!isBookId(bookId)) {
      throw const BookException(BookFailure.broken);
    }
    await _request('POST', '/v1/books/shelf/$bookId/remove');
  }

  Future<BookDetails> details(String bookId) async {
    if (!isBookId(bookId)) {
      throw const BookException(BookFailure.broken);
    }
    final reply = await _request(
      'GET',
      '/v1/books/$bookId',
      isShelfSpecific: true,
    );
    final json = reply.json;
    if (json is! Map) throw const BookException(BookFailure.broken);
    final book = ShelfBook.fromJson(json['book']);
    if (book == null || book.id != bookId) {
      throw const BookException(BookFailure.broken);
    }
    final rawParts = json['parts'];
    if (rawParts is! List || rawParts.length != book.parts) {
      throw const BookException(BookFailure.broken);
    }
    final parts = <BookPartInfo>[];
    for (var i = 0; i < rawParts.length; i++) {
      final part = BookPartInfo.fromJson(rawParts[i]);
      if (part == null || part.number != i + 1) {
        throw const BookException(BookFailure.broken);
      }
      parts.add(part);
    }
    return BookDetails(book, parts);
  }

  Future<BookPlay> play(String bookId, int part) async {
    if (!isBookId(bookId) || part < 1 || part > maxBookParts) {
      throw const BookException(BookFailure.broken);
    }
    final reply = await _request(
      'POST',
      '/v1/books/$bookId/play',
      body: {'part': part},
      isShelfSpecific: true,
    );
    final json = reply.json;
    if (json is! Map) throw const BookException(BookFailure.broken);
    final token = json['token'];
    final state = json['state'];
    if (token is! String || !_playTokenRegex.hasMatch(token)) {
      throw const BookException(BookFailure.broken);
    }
    if (state is! String || !_playStateRegex.hasMatch(state)) {
      throw const BookException(BookFailure.broken);
    }
    return BookPlay(token, state);
  }

  Future<Map<String, BookPosition>> put(
    Map<String, BookPosition> positions,
  ) async {
    final items = <Map<String, Object?>>[];
    for (final entry in positions.entries) {
      if (isBookId(entry.key)) {
        items.add({'book_id': entry.key, ...entry.value.toJson()});
        if (items.length == bookMaxBatch) break;
      }
    }
    if (items.isEmpty) return const {};

    final reply = await _request(
      'POST',
      '/v1/books/positions',
      body: {'items': items},
    );
    return _parsePositions(reply.json);
  }

  Future<BookChanges> changes(int after) async {
    final sentAfter = after < 0 ? 0 : after;
    final reply = await _request(
      'GET',
      '/v1/books/positions',
      query: {'after': '$sentAfter', 'limit': '$bookMaxRows'},
    );
    final json = reply.json;
    if (json is! Map) throw const BookException(BookFailure.broken);
    final mark = json['mark'];
    if (mark is! int || mark < sentAfter) {
      throw const BookException(BookFailure.broken);
    }
    final items = _parsePositions(json);
    return BookChanges(items, mark);
  }

  @override
  String toString() => 'BookClient';
}
