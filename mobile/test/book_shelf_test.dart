// FT-677 (P-A99, contracts D5 and D5a): audiobooks — bookshelf model in app.
//
// "My shelf" screen and "Add to shelf" button in book search share one model:
// it manages user's book list, adds book to shelf, removes it, and reports
// busy state and outcome to UI. Talks to server via FT-675
// client (`BookClient`); no network in module.
//
// Contract `lib/book_shelf.dart`:
// - `BookShelfModel(BookClient client) extends ChangeNotifier`;
// - `books`, `loaded`, `loading`, `failure`, `totalBytes`, `has(id)`,
//   `isBusy(key)`;
// - `load()`, `add(ref) -> Future<BookFailure?>`,
//   `remove(id) -> Future<BookFailure?>`, `reset()`.
//
// Guarded:
// - failed refresh does not wipe shelf already visible to user;
// - removed book disappears immediately, and on server error returns to its
//   place;
// - double tap does not send second request;
// - response arriving after logout brings nothing to next
//   user;
// - after `dispose()`, listeners are never invoked.
//
// What test does not prove: real server and screen are absent.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/book_client.dart';
import 'package:music_stream/book_shelf.dart';

String book(int n) =>
    '0b0c1d2e-0000-4000-8000-${n.toString().padLeft(12, '0')}';

final id1 = book(1);
final id2 = book(2);
final id3 = book(3);
const ref1 = 'Zm9v-YmFy_ref1';
const ref2 = 'Zm9v-YmFy_ref2';

Map<String, Object?> row(String id, {int size = 100, String title = 'T'}) => {
  'id': id,
  'title': title,
  'author': 'A',
  'narrator': 'N',
  'year': 2019,
  'size_bytes': size,
  'parts': 3,
  'shelved_at': '2026-10-01T11:00:00.000Z',
};

Map<String, Object?> shelf(List<String> ids) => {
  'books': [for (final id in ids) row(id)],
};

class Wire {
  final List<String> calls = [];
  final Map<String, BookReply> replies = {};
  final Map<String, Completer<void>> gates = {};
  final Map<String, Object> errors = {};

  Future<BookReply> send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
  }) async {
    final key = '$method $path';
    calls.add(key);
    final reply = replies[key];
    final error = errors[key];
    final gate = gates[key];
    if (gate != null) await gate.future;
    if (error != null) throw error;
    return reply ?? const BookReply(200, <String, Object?>{'books': []});
  }

  void on(String key, Object? json, [int status = 200]) {
    replies[key] = BookReply(status, json);
  }

  Completer<void> hold(String key) => gates[key] = Completer<void>();

  void release(String key) => gates.remove(key)!.complete();

  int count(String key) => calls.where((call) => call == key).length;
}

const getShelf = 'GET /v1/books/shelf';
const postShelf = 'POST /v1/books/shelf';
String deleteShelf(String id) => 'POST /v1/books/shelf/$id/remove';

void main() {
  late Wire wire;
  late BookShelfModel model;
  late int notified;

  setUp(() {
    wire = Wire();
    model = BookShelfModel(BookClient(wire.send));
    notified = 0;
    model.addListener(() => notified++);
  });

  List<String> ids() => [for (final book in model.books) book.id];

  Future<void> loaded(List<String> books) async {
    wire.on(getShelf, shelf(books));
    await model.load();
  }

  group('loading', () {
    test('before first load shelf is empty and not loaded', () {
      expect(model.books, isEmpty);
      expect(model.loaded, isFalse);
      expect(model.loading, isFalse);
      expect(model.failure, isNull);
      expect(model.totalBytes, 0);
    });

    test('books arrive in server order', () async {
      await loaded([id2, id1]);
      expect(ids(), [id2, id1]);
      expect(model.loaded, isTrue);
      expect(model.loading, isFalse);
      expect(model.failure, isNull);
      expect(model.has(id1), isTrue);
      expect(model.has(id3), isFalse);
    });

    test('while running is loading, listeners know start and end', () async {
      wire.hold(getShelf);
      final loading = model.load();
      expect(model.loading, isTrue);
      expect(notified, 1);
      wire.release(getShelf);
      await loading;
      expect(model.loading, isFalse);
      expect(notified, 2);
    });

    test('second call during first makes single request', () async {
      wire.hold(getShelf);
      final first = model.load();
      final second = model.load();
      expect(identical(first, second), isTrue);
      wire.release(getShelf);
      await first;
      expect(wire.count(getShelf), 1);
      await model.load();
      expect(wire.count(getShelf), 2);
    });

    test('total size is sum of book sizes', () async {
      wire.on(getShelf, {
        'books': [row(id1, size: 700), row(id2, size: 50)],
      });
      await model.load();
      expect(model.totalBytes, 750);
    });

    test('list cannot be modified externally', () async {
      await loaded([id1]);
      expect(() => model.books.clear(), throwsUnsupportedError);
    });

    test('failure: reason visible, empty shelf not loaded', () async {
      wire.on(getShelf, null, 503);
      await model.load();
      expect(model.failure, BookFailure.unavailable);
      expect(model.loaded, isFalse);
      expect(model.loading, isFalse);
    });

    test('no network: offline', () async {
      wire.errors[getShelf] = const SocketException('down');
      await model.load();
      expect(model.failure, BookFailure.offline);
    });

    test('failed refresh does not clear displayed shelf', () async {
      await loaded([id1, id2]);
      wire.on(getShelf, null, 401);
      await model.load();
      expect(ids(), [id1, id2]);
      expect(model.loaded, isTrue);
      expect(model.failure, BookFailure.signedOut);
    });

    test('successful refresh clears previous failure', () async {
      wire.on(getShelf, null, 503);
      await model.load();
      await loaded([id1]);
      expect(model.failure, isNull);
      expect(model.loaded, isTrue);
    });
  });

  group('add to shelf', () {
    test('new book is placed first', () async {
      await loaded([id1]);
      wire.on(postShelf, {'book': row(id2), 'state': 'ok'});
      expect(await model.add(ref1), isNull);
      expect(ids(), [id2, id1]);
      expect(model.isBusy(ref1), isFalse);
    });

    test(
      'book already on shelf: does not duplicate or move position',
      () async {
        await loaded([id1, id2]);
        wire.on(postShelf, {'book': row(id2), 'state': 'exists'});
        expect(await model.add(ref1), isNull);
        expect(ids(), [id1, id2]);
      },
    );

    test('in flight: token busy, listeners notified', () async {
      wire.on(postShelf, {'book': row(id2), 'state': 'ok'});
      wire.hold(postShelf);
      final adding = model.add(ref1);
      expect(model.isBusy(ref1), isTrue);
      expect(model.isBusy(ref2), isFalse);
      expect(notified, 1);
      wire.release(postShelf);
      await adding;
      expect(model.isBusy(ref1), isFalse);
      expect(notified, greaterThan(1));
    });

    test('double tap makes single request', () async {
      wire.on(postShelf, {'book': row(id2), 'state': 'ok'});
      wire.hold(postShelf);
      final first = model.add(ref1);
      expect(await model.add(ref1), isNull);
      wire.release(postShelf);
      await first;
      expect(wire.count(postShelf), 1);
      expect(ids(), [id2]);
    });

    test('failures returned to screen, shelf does not change', () async {
      await loaded([id1]);
      final cases = {
        'no_space': BookFailure.noSpace,
        'limit': BookFailure.limit,
        'not_a_book': BookFailure.notABook,
        'unavailable': BookFailure.unavailable,
      };
      for (final entry in cases.entries) {
        wire.on(postShelf, {'status': entry.key}, 409);
        expect(await model.add(ref1), entry.value, reason: entry.key);
      }
      wire.on(postShelf, null, 410);
      expect(await model.add(ref1), BookFailure.expired);
      expect(ids(), [id1]);
      expect(model.isBusy(ref1), isFalse);
      expect(model.failure, isNull);
    });

    test('invalid token is broken, server not contacted', () async {
      expect(await model.add('плохой пропуск'), BookFailure.broken);
      expect(wire.calls, isEmpty);
      expect(model.isBusy('плохой пропуск'), isFalse);
    });

    test('after failure same token can be tapped again', () async {
      wire.on(postShelf, null, 503);
      expect(await model.add(ref1), BookFailure.unavailable);
      wire.on(postShelf, {'book': row(id2), 'state': 'ok'});
      expect(await model.add(ref1), isNull);
      expect(ids(), [id2]);
    });
  });

  group('remove from shelf', () {
    test('book disappears immediately before server response', () async {
      await loaded([id1, id2, id3]);
      wire.hold(deleteShelf(id2));
      wire.on(deleteShelf(id2), null, 204);
      final before = notified;
      final removing = model.remove(id2);
      expect(ids(), [id1, id3]);
      expect(model.isBusy(id2), isTrue);
      expect(notified, before + 1);
      wire.release(deleteShelf(id2));
      expect(await removing, isNull);
      expect(ids(), [id1, id3]);
      expect(model.isBusy(id2), isFalse);
    });

    test('server error: book returns to original position', () async {
      await loaded([id1, id2, id3]);
      wire.on(deleteShelf(id2), null, 503);
      expect(await model.remove(id2), BookFailure.unavailable);
      expect(ids(), [id1, id2, id3]);
      expect(model.isBusy(id2), isFalse);
    });

    test('last item in list is restored at last position', () async {
      await loaded([id1, id2]);
      wire.errors[deleteShelf(id2)] = const SocketException('down');
      expect(await model.remove(id2), BookFailure.offline);
      expect(ids(), [id1, id2]);
    });

    test('book not on shelf: server not contacted', () async {
      await loaded([id1]);
      expect(await model.remove(id2), isNull);
      expect(wire.count(deleteShelf(id2)), 0);
    });

    test('double tap makes single request', () async {
      await loaded([id1]);
      wire.on(deleteShelf(id1), null, 204);
      wire.hold(deleteShelf(id1));
      final first = model.remove(id1);
      expect(await model.remove(id1), isNull);
      wire.release(deleteShelf(id1));
      await first;
      expect(wire.count(deleteShelf(id1)), 1);
    });

    test(
      'refresh arriving during removal does not restore book entry',
      () async {
        await loaded([id1, id2]);
        wire.on(deleteShelf(id2), null, 204);
        wire.hold(deleteShelf(id2));
        final removing = model.remove(id2);
        await model.load();
        expect(ids(), [id1]);
        wire.release(deleteShelf(id2));
        await removing;
        expect(ids(), [id1]);
      },
    );

    test(
      'failure after such refresh does not produce duplicate books',
      () async {
        await loaded([id1, id2]);
        wire.on(deleteShelf(id2), null, 503);
        wire.hold(deleteShelf(id2));
        final removing = model.remove(id2);
        await model.load();
        wire.release(deleteShelf(id2));
        expect(await removing, BookFailure.unavailable);
        expect(ids(), [id1, id2]);
      },
    );

    test('total size is reduced immediately', () async {
      await loaded([id1, id2]);
      wire.on(deleteShelf(id2), null, 204);
      await model.remove(id2);
      expect(model.totalBytes, 100);
    });
  });

  group('account sign out', () {
    test('reset clears everything and notifies listeners', () async {
      wire.on(getShelf, null, 503);
      await model.load();
      await loaded([id1]);
      final before = notified;
      model.reset();
      expect(model.books, isEmpty);
      expect(model.loaded, isFalse);
      expect(model.loading, isFalse);
      expect(model.failure, isNull);
      expect(notified, before + 1);
    });

    test('load response after sign out produces no effect', () async {
      wire.on(getShelf, shelf([id1]));
      wire.hold(getShelf);
      final loading = model.load();
      model.reset();
      final before = notified;
      wire.release(getShelf);
      await loading;
      expect(model.books, isEmpty);
      expect(model.loaded, isFalse);
      expect(model.loading, isFalse);
      expect(notified, before);
    });

    test('load failure after sign out is not displayed', () async {
      wire.on(getShelf, null, 503);
      wire.hold(getShelf);
      final loading = model.load();
      model.reset();
      wire.release(getShelf);
      await loading;
      expect(model.failure, isNull);
    });

    test('after sign out new load does not wait for old', () async {
      wire.on(getShelf, shelf([id1]));
      final gate = wire.hold(getShelf);
      final old = model.load();
      model.reset();
      wire.gates.remove(getShelf);
      wire.on(getShelf, shelf([id2]));
      await model.load();
      expect(ids(), [id2]);
      gate.complete();
      await old;
      expect(ids(), [id2]);
      expect(model.loading, isFalse);
    });

    test('add shelf response after sign out produces no effect', () async {
      wire.on(postShelf, {'book': row(id2), 'state': 'ok'});
      wire.hold(postShelf);
      final adding = model.add(ref1);
      model.reset();
      final before = notified;
      wire.release(postShelf);
      expect(await adding, isNull);
      expect(model.books, isEmpty);
      expect(model.isBusy(ref1), isFalse);
      expect(notified, before);
    });

    test('reset clears displayed failure state', () async {
      wire.on(getShelf, null, 503);
      await model.load();
      expect(model.failure, isNotNull);
      model.reset();
      expect(model.failure, isNull);
    });

    test('add failure after sign out is not shown to screen', () async {
      wire.on(postShelf, {'status': 'no_space'}, 409);
      wire.hold(postShelf);
      final adding = model.add(ref1);
      model.reset();
      wire.release(postShelf);
      expect(await adding, isNull);
    });

    test('removal failure after sign out does not restore book', () async {
      await loaded([id1]);
      wire.on(deleteShelf(id1), null, 503);
      wire.hold(deleteShelf(id1));
      final removing = model.remove(id1);
      model.reset();
      wire.release(deleteShelf(id1));
      expect(await removing, isNull);
      expect(model.books, isEmpty);
      expect(model.isBusy(id1), isFalse);
    });
  });

  group('no unnecessary side effects', () {
    test('after dispose listeners not notified and nothing crashes', () async {
      wire.on(getShelf, shelf([id1]));
      wire.hold(getShelf);
      final loading = model.load();
      model.dispose();
      wire.release(getShelf);
      await loading;
      model = BookShelfModel(BookClient(wire.send));
    });

    test('module does not access network or log directly', () {
      final source = File('lib/book_shelf.dart').readAsStringSync();
      for (final banned in [
        'dart:io',
        'package:http',
        'print(',
        'debugPrint',
        'dart:developer',
      ]) {
        expect(source.contains(banned), isFalse, reason: banned);
      }
    });
  });
}
