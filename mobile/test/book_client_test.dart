// FT-675 (P-A99, contracts D5 and D5a): audiobooks — app communication with server.
//
// Server serves books via eight endpoints (contract D5a). Here is their client side on
// phone: parse responses into models, translate server errors into reasons
// understandable by UI, and supply book progress sync with ready FT-670 records.
// No network in module: request sent by `BookSend` function, wired by lead.
//
// Contract `lib/book_client.dart`:
// - `BookReply(status, json)`; `typedef BookSend = Future<BookReply>
//   Function(String method, String path, {Map<String, String>? query,
//   Object? body})`;
// - `enum BookFailure { offline, unavailable, searchUnavailable, expired,
//   noSpace, limit, notABook, notOnShelf, signedOut, broken }`;
//   `BookException(reason)`;
// - `isBookId(Object?)`, `isBookRef(Object?)`, `bookText(Object?, maxLength:)`;
// - `FoundBook`, `ShelfBook`, `BookPartInfo` with `static T? fromJson(Object?)`;
//   `BookDetails(book, parts)`, `BookShelved(book, isNew:)`,
//   `BookPlay(token, state)`, `BookChanges(items, mark)`;
// - `BookClient(send)`: `search`, `shelf`, `shelve`, `unshelve`, `details`,
//   `play`, `put`, `changes`.
//
// Guarded:
// - third-party server does not crash app: any junk in response is skipped
//   row or `broken`, never an unhandled exception;
// - book parts arrive strictly ordered 1, 2, 3…: player never receives
//   a gapped list;
// - invisible and bidi control characters in titles do not reach screen;
// - progress changes page is not silently truncated: cursor would advance while records
//   would be lost;
// - `toString()` of models and exceptions contains neither titles nor skips.
//
// What test does not prove: real network and real server are absent.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/book_client.dart';
import 'package:music_stream/book_position.dart';

const id1 = '0b0c1d2e-0000-4000-8000-000000000001';
const id2 = '0b0c1d2e-0000-4000-8000-000000000002';
const ref1 = 'Zm9v-YmFy_ref1';
const stamp = '2026-10-01T11:00:00.000Z';

class Call {
  final String method;
  final String path;
  final Map<String, String>? query;
  final Object? body;
  Call(this.method, this.path, this.query, this.body);
}

class Wire {
  final List<Call> calls = [];
  BookReply reply = const BookReply(200, <String, Object?>{});
  Object? error;

  Future<BookReply> send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
  }) async {
    calls.add(Call(method, path, query, body));
    if (error != null) throw error!;
    return reply;
  }

  void answer(Object? json, [int status = 200]) {
    reply = BookReply(status, json);
  }
}

Map<String, Object?> found([Map<String, Object?> over = const {}]) => {
  'ref': ref1,
  'title': 'Secret Book',
  'author': 'Secret Author',
  'narrator': 'Secret Reader',
  'year': 2019,
  'size_bytes': 734003200,
  ...over,
};

Map<String, Object?> shelved([Map<String, Object?> over = const {}]) => {
  'id': id1,
  'title': 'Secret Book',
  'author': 'Secret Author',
  'narrator': 'Secret Reader',
  'year': 2019,
  'size_bytes': 734003200,
  'parts': 3,
  'shelved_at': stamp,
  ...over,
};

Map<String, Object?> part(int number, [Map<String, Object?> over = const {}]) =>
    {'number': number, 'title': 'Глава $number', ...over};

Map<String, Object?> place(String id, [Map<String, Object?> over = const {}]) =>
    {
      'book_id': id,
      'part': 2,
      'position_ms': 61000,
      'finished': false,
      'updated_at': stamp,
      ...over,
    };

BookPosition position({int part = 2, int ms = 61000, bool finished = false}) =>
    BookPosition(
      part: part,
      positionMs: ms,
      finished: finished,
      updatedAt: DateTime.utc(2026, 10, 1, 11),
    );

Matcher fails(BookFailure reason) =>
    throwsA(isA<BookException>().having((e) => e.reason, 'reason', reason));

void main() {
  late Wire wire;
  late BookClient client;

  setUp(() {
    wire = Wire();
    client = BookClient(wire.send);
  });

  test('limits match contract', () {
    expect(bookMaxText, 500);
    expect(bookMaxRows, 500);
    expect(bookMaxBatch, 500);
    expect(bookSearchMinChars, 2);
    expect(bookSearchMaxChars, 200);
    expect(bookSearchMaxLimit, 50);
  });

  group('book id and token', () {
    test('id is standard lowercase UUID string', () {
      expect(isBookId(id1), isTrue);
      for (final bad in <Object?>[
        null,
        5,
        '',
        id1.toUpperCase(),
        id1.replaceAll('-', ''),
        '{$id1}',
        ' $id1',
        '$id1\n',
        '${id1}0',
        id1.replaceFirst('0', 'g'),
        '../$id1'.substring(0, 36),
      ]) {
        expect(isBookId(bad), isFalse, reason: '$bad');
      }
    });

    test('token is alphanumeric string with hyphens and underscores', () {
      expect(isBookRef(ref1), isTrue);
      expect(isBookRef('a'), isTrue);
      expect(isBookRef('a' * 128), isTrue);
      for (final bad in <Object?>[
        null,
        7,
        '',
        'a' * 129,
        'a b',
        'a/b',
        'a?b',
        'a\nb',
        'a.b',
        'ключ',
        'a%2F',
      ]) {
        expect(isBookRef(bad), isFalse, reason: '$bad');
      }
    });
  });

  group('text', () {
    test('non-string parses to empty', () {
      expect(bookText(null), '');
      expect(bookText(5), '');
      expect(bookText(['a']), '');
    });

    test('whitespace trimmed, standard characters preserved', () {
      expect(bookText('  Война и мир  '), 'Война и мир');
      expect(bookText('Ünïcödé 日本語 😀'), 'Ünïcödé 日本語 😀');
      expect(bookText('   '), '');
    });

    test('invisible and bidi override characters filtered out', () {
      final codes = [
        0x00, 0x07, 0x09, 0x0a, 0x0d, 0x1b, 0x1f, 0x7f, 0x85, 0x9f, //
        0x200e, 0x200f, 0x202a, 0x202b, 0x202c, 0x202d, 0x202e, //
        0x2066, 0x2067, 0x2068, 0x2069,
      ];
      for (final code in codes) {
        final raw = 'a${String.fromCharCode(code)}b';
        expect(bookText(raw), 'a b', reason: code.toRadixString(16));
      }
      expect(bookText('${String.fromCharCode(0x202e)}txt.exe'), 'txt.exe');
    });

    test('unpaired surrogate replaced to prevent rendering crash', () {
      final lone = String.fromCharCode(0xd83d);
      final cleaned = bookText('a${lone}b');
      expect(cleaned.codeUnits, [0x61, 0xfffd, 0x62]);
      final tail = bookText('ab${String.fromCharCode(0xde00)}');
      expect(tail.codeUnits, [0x61, 0x62, 0xfffd]);
    });

    test('long text truncated by code points, not surrogate halves', () {
      expect(bookText('a' * 600).length, bookMaxText);
      expect(bookText('a' * 500).length, 500);
      final smiles = '😀' * 600;
      final cut = bookText(smiles);
      expect(cut.runes.length, bookMaxText);
      expect(cut.runes.every((r) => r == 0x1f600), isTrue);
      expect(bookText('abcdef', maxLength: 3), 'abc');
      expect(bookText('ab cdef', maxLength: 3), 'ab');
    });
  });

  group('search result book', () {
    test('parses completely', () {
      final book = FoundBook.fromJson(found())!;
      expect(book.ref, ref1);
      expect(book.title, 'Secret Book');
      expect(book.author, 'Secret Author');
      expect(book.narrator, 'Secret Reader');
      expect(book.year, 2019);
      expect(book.sizeBytes, 734003200);
    });

    test('optional fields may be omitted', () {
      final book = FoundBook.fromJson({'ref': ref1, 'title': 'Книга'})!;
      expect(book.author, '');
      expect(book.narrator, '');
      expect(book.year, isNull);
      expect(book.sizeBytes, 0);
    });

    test('missing token or title yields null', () {
      for (final bad in <Object?>[
        null,
        'книга',
        <Object?>[],
        found({'ref': null}),
        found({'ref': 'a b'}),
        found({'ref': 5}),
        found({'title': null}),
        found({'title': '  '}),
        found({'title': 7}),
        found({'title': String.fromCharCode(0x202e)}),
      ]) {
        expect(FoundBook.fromJson(bad), isNull, reason: '$bad');
      }
    });

    test('malformed fields cleared rather than crashing parser', () {
      final book = FoundBook.fromJson(
        found({
          'author': 5,
          'narrator': ['x'],
          'year': '2019',
          'size_bytes': -1,
        }),
      )!;
      expect(book.author, '');
      expect(book.narrator, '');
      expect(book.year, isNull);
      expect(book.sizeBytes, 0);
      expect(FoundBook.fromJson(found({'year': 999}))!.year, isNull);
      expect(FoundBook.fromJson(found({'year': 1000}))!.year, 1000);
      expect(FoundBook.fromJson(found({'year': 2100}))!.year, 2100);
      expect(FoundBook.fromJson(found({'year': 2101}))!.year, isNull);
      expect(FoundBook.fromJson(found({'year': 2019.0}))!.year, isNull);
      expect(FoundBook.fromJson(found({'size_bytes': 1.5}))!.sizeBytes, 0);
      expect(FoundBook.fromJson(found({'size_bytes': 0}))!.sizeBytes, 0);
    });

    test('title, author, and narrator stripped of bidi overrides', () {
      final rlo = String.fromCharCode(0x202e);
      final book = FoundBook.fromJson(
        found({'title': 'a${rlo}b', 'author': '${rlo}c', 'narrator': 'd$rlo'}),
      )!;
      expect(book.title, 'a b');
      expect(book.author, 'c');
      expect(book.narrator, 'd');
    });
  });

  group('shelf book', () {
    test('parses completely', () {
      final book = ShelfBook.fromJson(shelved())!;
      expect(book.id, id1);
      expect(book.title, 'Secret Book');
      expect(book.author, 'Secret Author');
      expect(book.narrator, 'Secret Reader');
      expect(book.year, 2019);
      expect(book.sizeBytes, 734003200);
      expect(book.parts, 3);
      expect(book.shelvedAt, DateTime.utc(2026, 10, 1, 11));
      expect(book.shelvedAt!.isUtc, isTrue);
    });

    test('missing id, title, or parts count yields null', () {
      for (final bad in <Object?>[
        null,
        7,
        shelved({'id': null}),
        shelved({'id': id1.toUpperCase()}),
        shelved({'id': 'книга'}),
        shelved({'title': ''}),
        shelved({'title': 5}),
        shelved({'parts': null}),
        shelved({'parts': 0}),
        shelved({'parts': -1}),
        shelved({'parts': maxBookParts + 1}),
        shelved({'parts': '3'}),
        shelved({'parts': 3.0}),
      ]) {
        expect(ShelfBook.fromJson(bad), isNull, reason: '$bad');
      }
      expect(ShelfBook.fromJson(shelved({'parts': 1}))!.parts, 1);
      expect(
        ShelfBook.fromJson(shelved({'parts': maxBookParts}))!.parts,
        maxBookParts,
      );
    });

    test('invalid optional fields cleared to null', () {
      final book = ShelfBook.fromJson(
        shelved({
          'author': null,
          'narrator': 1,
          'year': 'x',
          'size_bytes': 'много',
          'shelved_at': 'вчера',
        }),
      )!;
      expect(book.author, '');
      expect(book.narrator, '');
      expect(book.year, isNull);
      expect(book.sizeBytes, 0);
      expect(book.shelvedAt, isNull);
    });

    test('timestamp without Z not treated as local', () {
      expect(
        ShelfBook.fromJson(
          shelved({'shelved_at': '2026-10-01T11:00:00'}),
        )!.shelvedAt,
        isNull,
      );
      expect(ShelfBook.fromJson(shelved({'shelved_at': 5}))!.shelvedAt, isNull);
    });
  });

  group('part', () {
    test('full file: no offset bounds', () {
      final info = BookPartInfo.fromJson(part(4))!;
      expect(info.number, 4);
      expect(info.title, 'Глава 4');
      expect(info.startMs, isNull);
      expect(info.endMs, isNull);
    });

    test('chapter in file: both start and end bounds', () {
      final info = BookPartInfo.fromJson(
        part(2, {'start_ms': 0, 'end_ms': 90000}),
      )!;
      expect(info.startMs, 0);
      expect(info.endMs, 90000);
    });

    test('invalid offset bounds treated as absent', () {
      for (final over in <Map<String, Object?>>[
        {'start_ms': 5},
        {'end_ms': 5},
        {'start_ms': -1, 'end_ms': 5},
        {'start_ms': 5, 'end_ms': 5},
        {'start_ms': 9, 'end_ms': 5},
        {'start_ms': '0', 'end_ms': 5},
        {'start_ms': 0, 'end_ms': 5.5},
      ]) {
        final info = BookPartInfo.fromJson(part(1, over))!;
        expect(info.startMs, isNull, reason: '$over');
        expect(info.endMs, isNull, reason: '$over');
      }
    });

    test('valid part index required; title can be empty', () {
      for (final bad in <Object?>[
        null,
        'часть',
        part(0),
        part(-2),
        part(maxBookParts + 1),
        {'number': '1'},
        {'number': 1.0},
        {'title': 'x'},
      ]) {
        expect(BookPartInfo.fromJson(bad), isNull, reason: '$bad');
      }
      expect(BookPartInfo.fromJson({'number': 1})!.title, '');
      expect(BookPartInfo.fromJson(part(1, {'title': 5}))!.title, '');
      final rlo = String.fromCharCode(0x202e);
      expect(
        BookPartInfo.fromJson(part(1, {'title': 'a${rlo}b'}))!.title,
        'a b',
      );
      expect(BookPartInfo.fromJson(part(maxBookParts))!.number, maxBookParts);
    });
  });

  group('search', () {
    test('queries server and parses response', () async {
      wire.answer({
        'books': [
          found(),
          found({'ref': 'second', 'title': 'Другая'}),
        ],
      });
      final books = await client.search('  война и мир ');
      expect(books.map((b) => b.ref), [ref1, 'second']);
      expect(books[1].title, 'Другая');
      final call = wire.calls.single;
      expect(call.method, 'GET');
      expect(call.path, '/v1/books/search');
      expect(call.query, {'q': 'война и мир', 'limit': '20'});
      expect(call.body, isNull);
    });

    test('short query is not sent to server', () async {
      expect(await client.search(''), isEmpty);
      expect(await client.search(' а '), isEmpty);
      expect(wire.calls, isEmpty);
      wire.answer({'books': <Object?>[]});
      await client.search('аб');
      expect(wire.calls, hasLength(1));
    });

    test('query limit and length are bounded', () async {
      wire.answer({'books': <Object?>[]});
      await client.search('книга', limit: 0);
      await client.search('книга', limit: -3);
      await client.search('книга', limit: 999);
      await client.search('книга', limit: 50);
      expect(wire.calls.map((c) => c.query!['limit']), ['1', '1', '50', '50']);
      await client.search('я' * 300);
      expect(wire.calls.last.query!['q'], 'я' * bookSearchMaxChars);
      await client.search('😀' * 300);
      expect(wire.calls.last.query!['q']!.runes.length, bookSearchMaxChars);
    });

    test('malformed items skipped, duplicates deduplicated', () async {
      wire.answer({
        'books': [
          null,
          5,
          found({'title': ''}),
          found(),
          found({'title': 'Повтор'}),
          found({'ref': 'other'}),
        ],
      });
      final books = await client.search('книга');
      expect(books.map((b) => b.ref), [ref1, 'other']);
      expect(books.first.title, 'Secret Book');
    });

    test('book source unavailable mapped to distinct error', () async {
      wire.answer({'status': 'book_search_unavailable'}, 503);
      await expectLater(
        client.search('книга'),
        fails(BookFailure.searchUnavailable),
      );
      wire.answer({'status': 'unavailable'}, 503);
      await expectLater(client.search('книга'), fails(BookFailure.unavailable));
      wire.answer(null, 503);
      await expectLater(client.search('книга'), fails(BookFailure.unavailable));
    });

    test('excessive list truncated and made unmodifiable', () async {
      wire.answer({
        'books': [
          for (var i = 0; i < bookMaxRows + 50; i++) found({'ref': 'r$i'}),
        ],
      });
      final books = await client.search('книга');
      expect(books, hasLength(bookMaxRows));
      expect(books.last.ref, 'r${bookMaxRows - 1}');
      expect(() => books.clear(), throwsUnsupportedError);
    });
  });

  group('shelf', () {
    test('list', () async {
      wire.answer({
        'books': [
          shelved(),
          'мусор',
          shelved({'id': id2, 'parts': 0}),
          shelved({'title': 'Повтор'}),
          shelved({'id': id2, 'title': 'Вторая'}),
        ],
      });
      final books = await client.shelf();
      expect(books.map((b) => b.id), [id1, id2]);
      expect(books.first.title, 'Secret Book');
      expect(books.last.title, 'Вторая');
      expect(() => books.removeLast(), throwsUnsupportedError);
      final call = wire.calls.single;
      expect(call.method, 'GET');
      expect(call.path, '/v1/books/shelf');
      expect(call.query, isNull);
      expect(call.body, isNull);
    });

    test('empty shelf', () async {
      wire.answer({'books': <Object?>[]});
      expect(await client.shelf(), isEmpty);
    });

    test('add: new book and existing book', () async {
      wire.answer({'book': shelved(), 'state': 'ok'});
      final fresh = await client.shelve(ref1);
      expect(fresh.isNew, isTrue);
      expect(fresh.book.id, id1);
      final call = wire.calls.single;
      expect(call.method, 'POST');
      expect(call.path, '/v1/books/shelf');
      expect(call.query, isNull);
      expect(call.body, {'ref': ref1});
      wire.answer({'book': shelved(), 'state': 'exists'});
      expect((await client.shelve(ref1)).isNew, isFalse);
    });

    test('add: server errors', () async {
      final refusals = {
        'no_space': BookFailure.noSpace,
        'limit': BookFailure.limit,
        'not_a_book': BookFailure.notABook,
        'unavailable': BookFailure.unavailable,
        'что-то новое': BookFailure.unavailable,
      };
      for (final entry in refusals.entries) {
        wire.answer({'status': entry.key}, 409);
        await expectLater(
          client.shelve(ref1),
          fails(entry.value),
          reason: entry.key,
        );
      }
      wire.answer('текст', 409);
      await expectLater(client.shelve(ref1), fails(BookFailure.unavailable));
      wire.answer({'status': 'gone'}, 410);
      await expectLater(client.shelve(ref1), fails(BookFailure.expired));
    });

    test('add: unexpected response mapped to broken', () async {
      for (final bad in <Object?>[
        null,
        <Object?>[],
        {'state': 'ok'},
        {'book': shelved()},
        {'book': shelved(), 'state': 'queued'},
        {'book': shelved(), 'state': true},
        {
          'book': shelved({'id': 'x'}),
          'state': 'ok',
        },
      ]) {
        wire.answer(bad);
        await expectLater(
          client.shelve(ref1),
          fails(BookFailure.broken),
          reason: '$bad',
        );
      }
    });

    test('add: invalid token not sent to server', () async {
      await expectLater(client.shelve(''), fails(BookFailure.broken));
      await expectLater(client.shelve('a/../b'), fails(BookFailure.broken));
      expect(wire.calls, isEmpty);
    });

    test('remove', () async {
      wire.answer(null, 204);
      await client.unshelve(id1);
      final call = wire.calls.single;
      expect(call.method, 'POST');
      expect(call.path, '/v1/books/shelf/$id1/remove');
      expect(call.query, isNull);
      expect(call.body, isNull);
      wire.answer(<String, Object?>{});
      await client.unshelve(id1);
    });

    test('remove: invalid book id not sent to server', () async {
      await expectLater(client.unshelve('../users'), fails(BookFailure.broken));
      await expectLater(
        client.unshelve(id1.toUpperCase()),
        fails(BookFailure.broken),
      );
      expect(wire.calls, isEmpty);
    });
  });

  group('book and its parts', () {
    Map<String, Object?> answer([List<Object?>? parts]) => {
      'book': shelved(),
      'parts': parts ?? [part(1), part(2), part(3)],
    };

    test('book with parts in sequential order', () async {
      wire.answer(answer());
      final details = await client.details(id1);
      expect(details.book.id, id1);
      expect(details.parts.map((p) => p.number), [1, 2, 3]);
      expect(details.parts[1].title, 'Глава 2');
      expect(() => details.parts.clear(), throwsUnsupportedError);
      final call = wire.calls.single;
      expect(call.method, 'GET');
      expect(call.path, '/v1/books/$id1');
      expect(call.query, isNull);
      expect(call.body, isNull);
    });

    test('gapped or out-of-order parts list is broken', () async {
      for (final parts in <List<Object?>>[
        [],
        [part(1), part(2)],
        [part(1), part(2), part(3), part(4)],
        [part(1), part(3), part(2)],
        [part(1), part(1), part(2)],
        [part(2), part(3), part(4)],
        [part(1), null, part(3)],
        [part(1), part(2), 'три'],
      ]) {
        wire.answer(answer(parts));
        await expectLater(
          client.details(id1),
          fails(BookFailure.broken),
          reason: '$parts',
        );
      }
    });

    test('mismatched book or invalid payload is broken', () async {
      for (final bad in <Object?>[
        null,
        'книга',
        {'book': shelved()},
        {
          'parts': [part(1)],
        },
        {'book': shelved(), 'parts': 'три'},
        {
          'book': shelved({'id': id2}),
          'parts': [part(1), part(2), part(3)],
        },
        {
          'book': shelved({'title': ''}),
          'parts': [part(1), part(2), part(3)],
        },
      ]) {
        wire.answer(bad);
        await expectLater(
          client.details(id1),
          fails(BookFailure.broken),
          reason: '$bad',
        );
      }
    });

    test('book not on user shelf mapped to distinct error', () async {
      wire.answer({'status': 'not_found'}, 404);
      await expectLater(client.details(id1), fails(BookFailure.notOnShelf));
      await expectLater(client.play(id1, 1), fails(BookFailure.notOnShelf));
    });

    test('invalid book id is not sent to server', () async {
      await expectLater(client.details('x'), fails(BookFailure.broken));
      await expectLater(client.play('x/../y', 1), fails(BookFailure.broken));
      expect(wire.calls, isEmpty);
    });
  });

  group('part audio playback', () {
    test('playback stream token', () async {
      wire.answer({'token': 'tok-1_2.3~4', 'state': 'ready'});
      final play = await client.play(id1, 7);
      expect(play.token, 'tok-1_2.3~4');
      expect(play.state, 'ready');
      final call = wire.calls.single;
      expect(call.method, 'POST');
      expect(call.path, '/v1/books/$id1/play');
      expect(call.query, isNull);
      expect(call.body, {'part': 7});
    });

    test('invalid part index is not sent to server', () async {
      await expectLater(client.play(id1, 0), fails(BookFailure.broken));
      await expectLater(client.play(id1, -1), fails(BookFailure.broken));
      await expectLater(
        client.play(id1, maxBookParts + 1),
        fails(BookFailure.broken),
      );
      expect(wire.calls, isEmpty);
      wire.answer({'token': 't', 'state': 'preparing'});
      expect((await client.play(id1, maxBookParts)).state, 'preparing');
    });

    test('token and status omit unnecessary fields', () async {
      for (final bad in <Object?>[
        null,
        {'state': 'ready'},
        {'token': 't'},
        {'token': '', 'state': 'ready'},
        {'token': 5, 'state': 'ready'},
        {'token': 'a/b', 'state': 'ready'},
        {'token': 'a b', 'state': 'ready'},
        {'token': 'a?x=1', 'state': 'ready'},
        {'token': 'a\n', 'state': 'ready'},
        {'token': 't' * 513, 'state': 'ready'},
        {'token': 't', 'state': ''},
        {'token': 't', 'state': 'Ready'},
        {'token': 't', 'state': 'готово'},
        {'token': 't', 'state': 's' * 33},
        {'token': 't', 'state': 7},
      ]) {
        wire.answer(bad);
        await expectLater(
          client.play(id1, 1),
          fails(BookFailure.broken),
          reason: '$bad',
        );
      }
      wire.answer({'token': 't' * 512, 'state': 's' * 32});
      expect((await client.play(id1, 1)).token, hasLength(512));
    });
  });

  group('general failures', () {
    final calls = <String, Future<Object?> Function(BookClient)>{
      'search': (c) => c.search('книга'),
      'shelf': (c) => c.shelf(),
      'shelve': (c) => c.shelve(ref1),
      'unshelve': (c) => c.unshelve(id1),
      'details': (c) => c.details(id1),
      'play': (c) => c.play(id1, 1),
      'put': (c) => c.put({id1: position()}),
      'changes': (c) => c.changes(0),
    };
    for (final entry in calls.entries) {
      final shelfOnly = entry.key == 'details' || entry.key == 'play';

      test('${entry.key}: offline network', () async {
        wire.error = const SocketException('no route to secret.example.org');
        await expectLater(entry.value(client), fails(BookFailure.offline));
        wire.error = TimeoutException('slow');
        await expectLater(entry.value(client), fails(BookFailure.offline));
        wire.error = StateError('closed');
        await expectLater(entry.value(client), fails(BookFailure.offline));
      });

      test('${entry.key}: transport error message passed through', () async {
        wire.error = const BookException(BookFailure.signedOut);
        await expectLater(entry.value(client), fails(BookFailure.signedOut));
      });

      test('${entry.key}: status codes', () async {
        final statuses = {
          401: BookFailure.signedOut,
          400: BookFailure.broken,
          422: BookFailure.broken,
          404: shelfOnly ? BookFailure.notOnShelf : BookFailure.unavailable,
          409: BookFailure.unavailable,
          410: BookFailure.expired,
          403: BookFailure.unavailable,
          429: BookFailure.unavailable,
          500: BookFailure.unavailable,
          502: BookFailure.unavailable,
          503: BookFailure.unavailable,
          201: BookFailure.unavailable,
          301: BookFailure.unavailable,
        };
        for (final status in statuses.entries) {
          wire.answer({'detail': 'x'}, status.key);
          await expectLater(
            entry.value(client),
            fails(status.value),
            reason: '${status.key}',
          );
          wire.answer('<html>', status.key);
          await expectLater(
            entry.value(client),
            fails(status.value),
            reason: '${status.key} html',
          );
        }
      });

      if (entry.key != 'unshelve') {
        test('${entry.key}: invalid 200 payload is broken', () async {
          for (final bad in <Object?>[
            null,
            'текст',
            42,
            <Object?>[],
            {'books': 'x', 'items': 5, 'parts': 1, 'book': 2, 'mark': 'a'},
          ]) {
            wire.answer(bad);
            await expectLater(
              entry.value(client),
              fails(BookFailure.broken),
              reason: '$bad',
            );
          }
        });
      }
    }
  });

  group('playback progress sync', () {
    test('batch upload and server response', () async {
      wire.answer({
        'items': [
          place(id1, {'part': 5, 'position_ms': 9000}),
          place(id2, {'finished': true}),
        ],
      });
      final mine = position();
      final stored = await client.put({id1: mine, id2: position(part: 1)});
      expect(stored, {
        id1: position(part: 5, ms: 9000),
        id2: position(finished: true),
      });
      final call = wire.calls.single;
      expect(call.method, 'POST');
      expect(call.path, '/v1/books/positions');
      expect(call.query, isNull);
      expect(call.body, {
        'items': [
          {'book_id': id1, ...mine.toJson()},
          {'book_id': id2, ...position(part: 1).toJson()},
        ],
      });
    });

    test('empty batch and invalid ids not sent to server', () async {
      expect(await client.put({}), isEmpty);
      expect(await client.put({'не номер': position()}), isEmpty);
      expect(wire.calls, isEmpty);
      wire.answer({'items': <Object?>[]});
      await client.put({'мусор': position(), id1: position()});
      expect((wire.calls.single.body as Map)['items'], hasLength(1));
    });

    test('batch size capped at limit per request', () async {
      wire.answer({'items': <Object?>[]});
      String book(int n) =>
          '0b0c1d2e-0000-4000-8000-${n.toString().padLeft(12, '0')}';
      final batch = {
        for (var n = 0; n < bookMaxBatch + 20; n++) book(n): position(),
      };
      await client.put(batch);
      final items = (wire.calls.single.body as Map)['items'] as List;
      expect(items, hasLength(bookMaxBatch));
      expect((items.first as Map)['book_id'], book(0));
      expect((items.last as Map)['book_id'], book(bookMaxBatch - 1));
    });

    test('corrupted response items are skipped', () async {
      wire.answer({
        'items': [
          null,
          'строка',
          place('не номер'),
          place(id1.toUpperCase()),
          place(id1, {'part': 0}),
          place(id1, {'updated_at': '2026-10-01T11:00:00'}),
          place(id2),
        ],
      });
      expect(await client.put({id1: position()}), {id2: position()});
    });

    test('two entries for same book: later timestamp wins', () async {
      wire.answer({
        'items': [
          place(id1, {'part': 9, 'updated_at': '2026-10-01T12:00:00.000Z'}),
          place(id1, {'part': 4}),
        ],
      });
      final stored = await client.put({id1: position()});
      expect(stored[id1]!.part, 9);
    });

    test('...regardless of the order they arrive', () async {
      wire.answer({
        'items': [
          place(id1, {'part': 4}),
          place(id1, {'part': 9, 'updated_at': '2026-10-01T12:00:00.000Z'}),
        ],
      });
      final stored = await client.put({id1: position()});
      expect(stored[id1]!.part, 9);
    });

    test('changes since timestamp mark', () async {
      wire.answer({
        'items': [
          place(id1),
          place(id2, {'part': 8}),
        ],
        'mark': 42,
      });
      final changes = await client.changes(7);
      expect(changes.items, {id1: position(), id2: position(part: 8)});
      expect(changes.mark, 42);
      final call = wire.calls.single;
      expect(call.method, 'GET');
      expect(call.path, '/v1/books/positions');
      expect(call.query, {'after': '7', 'limit': '$bookMaxRows'});
      expect(call.body, isNull);
    });

    test('empty page with same mark is valid response', () async {
      wire.answer({'items': <Object?>[], 'mark': 7});
      final changes = await client.changes(7);
      expect(changes.items, isEmpty);
      expect(changes.mark, 7);
    });

    test('mark present without items list is broken', () async {
      wire.answer({'mark': 9});
      await expectLater(client.changes(0), fails(BookFailure.broken));
      wire.answer({'items': 'x', 'mark': 9});
      await expectLater(client.changes(0), fails(BookFailure.broken));
    });

    test('negative timestamp sent as zero', () async {
      wire.answer({'items': <Object?>[], 'mark': 0});
      await client.changes(-5);
      expect(wire.calls.single.query!['after'], '0');
    });

    test('non-numeric or regressing mark is broken', () async {
      for (final mark in <Object?>[6, -1, '42', 42.0, null]) {
        wire.answer({'items': <Object?>[], 'mark': mark});
        await expectLater(
          client.changes(7),
          fails(BookFailure.broken),
          reason: '$mark',
        );
      }
    });

    test('page exceeding limit not silently truncated: broken', () async {
      String book(int n) =>
          '0b0c1d2e-0000-4000-8000-${n.toString().padLeft(12, '0')}';
      final rows = [for (var n = 0; n <= bookMaxRows; n++) place(book(n))];
      wire.answer({'items': rows, 'mark': 900});
      await expectLater(client.changes(0), fails(BookFailure.broken));
      wire.answer({'items': rows});
      await expectLater(
        client.put({id1: position()}),
        fails(BookFailure.broken),
      );
      wire.answer({'items': rows.sublist(1), 'mark': 900});
      expect((await client.changes(0)).items, hasLength(bookMaxRows));
    });
  });

  group('no sensitive data in strings', () {
    test('models and exception do not print raw data', () {
      final texts = [
        FoundBook.fromJson(found())!.toString(),
        ShelfBook.fromJson(shelved())!.toString(),
        BookPartInfo.fromJson(part(1, {'title': 'Secret Chapter'}))!.toString(),
        BookDetails(ShelfBook.fromJson(shelved())!, const []).toString(),
        BookShelved(ShelfBook.fromJson(shelved())!, isNew: true).toString(),
        const BookPlay('secret-token', 'ready').toString(),
        BookChanges({id1: position()}, 5).toString(),
        const BookReply(200, {'title': 'Secret Book'}).toString(),
        const BookException(BookFailure.noSpace).toString(),
      ];
      for (final text in texts) {
        for (final word in ['Secret', 'secret', ref1, id1, '734003200']) {
          expect(text.contains(word), isFalse, reason: text);
        }
      }
      expect(
        const BookException(BookFailure.noSpace).toString(),
        'BookException(noSpace)',
      );
    });

    test('error reason omits raw transport failure message', () async {
      wire.error = const SocketException('host secret.example.org down');
      try {
        await client.shelf();
        fail('expected request failure');
      } on BookException catch (e) {
        expect(e.toString(), 'BookException(offline)');
      }
    });

    test('module does not access network directly or log', () {
      final source = File('lib/book_client.dart').readAsStringSync();
      for (final word in [
        'dart:io',
        'package:http',
        'print(',
        'debugPrint',
        'developer.log',
        'podcast',
      ]) {
        expect(source.contains(word), isFalse, reason: word);
      }
    });
  });
}
