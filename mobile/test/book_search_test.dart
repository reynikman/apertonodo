// FT-678 (P-A99, contracts D5 and D5a): audiobooks — book search model.
//
// User types title — model debounces input pause, queries server
// via FT-675 client, and provides UI with list, "searching", or error reason.
//
// Contract `lib/book_search.dart`:
// - `BookSearchModel(BookClient client, {Duration pause = defaultPause})
//   extends ChangeNotifier`; `BookSearchModel.defaultPause` — 400 ms;
// - `query`, `results`, `searching`, `searched`, `failure`;
// - `setQuery(text)`, `submit() -> Future<void>`, `reset()`.
//
// Guarded:
// - request is not sent on every keystroke: only after debounce pause;
// - response to stale query does not overwrite newer query results;
// - short query does not hit server and clears previous list;
// - failure does not clear query, and can be retried;
// - after navigation away and after `dispose()`, late response does nothing.
//
// What test does not prove: real server and screen are absent.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/book_client.dart';
import 'package:music_stream/book_search.dart';

const pause = Duration(milliseconds: 30);
const beforePause = Duration(milliseconds: 10);
const afterPause = Duration(milliseconds: 80);

Map<String, Object?> hit(String ref) => {
  'ref': ref,
  'title': 'T',
  'author': 'A',
  'narrator': 'N',
  'year': 2019,
  'size_bytes': 100,
};

class Wire {
  final List<String> asked = [];
  final Map<String, Object?> answers = {};
  final Map<String, Completer<void>> gates = {};
  int status = 200;
  Object? error;

  Future<BookReply> send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
  }) async {
    final q = query!['q']!;
    asked.add(q);
    final number = asked.length;
    final failWith = error;
    final code = status;
    final gate = gates[q];
    if (gate != null) await gate.future;
    if (failWith != null) throw failWith;
    if (code != 200) return BookReply(code, null);
    return BookReply(200, {
      'books': answers[q] ?? [hit('ref-$number')],
    });
  }

  Completer<void> hold(String q) => gates[q] = Completer<void>();
}

void main() {
  late Wire wire;
  late BookSearchModel model;
  late int notified;

  setUp(() {
    wire = Wire();
    model = BookSearchModel(BookClient(wire.send), pause: pause);
    notified = 0;
    model.addListener(() => notified++);
  });

  List<String> refs() => [for (final book in model.results) book.ref];

  Future<void> settle() => Future<void>.delayed(afterPause);

  test('default debounce is 400 ms', () {
    expect(BookSearchModel.defaultPause, const Duration(milliseconds: 400));
  });

  test('initially empty', () {
    expect(model.query, '');
    expect(model.results, isEmpty);
    expect(model.searching, isFalse);
    expect(model.searched, isFalse);
    expect(model.failure, isNull);
  });

  group('set', () {
    test('request sent after debounce, not immediately', () async {
      model.setQuery('дюна');
      expect(model.searching, isTrue);
      expect(model.query, 'дюна');
      expect(notified, 1);
      await Future<void>.delayed(beforePause);
      expect(wire.asked, isEmpty);
      await settle();
      expect(wire.asked, ['дюна']);
      expect(refs(), ['ref-1']);
      expect(model.searching, isFalse);
      expect(model.searched, isTrue);
      expect(notified, 2);
    });

    test('fast typing: single request with latest query', () async {
      model.setQuery('дю');
      model.setQuery('дюн');
      model.setQuery('дюна');
      await settle();
      expect(wire.asked, ['дюна']);
    });

    test('leading and trailing spaces are trimmed', () async {
      model.setQuery('  дюна ');
      expect(model.query, 'дюна');
      final before = notified;
      model.setQuery('дюна  ');
      expect(notified, before);
      await settle();
      expect(wire.asked, ['дюна']);
    });

    test('same query a second time: no call, no notify', () async {
      model.setQuery('дюна');
      await settle();
      final before = notified;
      model.setQuery('дюна');
      await settle();
      expect(wire.asked, ['дюна']);
      expect(notified, before);
      expect(model.searching, isFalse);
    });

    test('short query does not hit server', () async {
      model.setQuery('д');
      expect(model.searching, isFalse);
      await settle();
      expect(wire.asked, isEmpty);
      expect(model.searched, isFalse);
    });

    test('backspacing to short query clears list immediately', () async {
      model.setQuery('дюна');
      await settle();
      model.setQuery('д');
      expect(model.results, isEmpty);
      expect(model.searched, isFalse);
      expect(model.searching, isFalse);
    });

    test('backspacing to short query during debounce cancels call', () async {
      model.setQuery('дюна');
      model.setQuery('');
      await settle();
      expect(wire.asked, isEmpty);
      expect(model.searching, isFalse);
    });

    test('previous results stay on screen while searching anew', () async {
      model.setQuery('дюна');
      await settle();
      model.setQuery('дюна 2');
      expect(refs(), ['ref-1']);
      expect(model.searching, isTrue);
    });

    test('nothing found: empty list, searched flag true', () async {
      wire.answers['дюна'] = <Object?>[];
      model.setQuery('дюна');
      await settle();
      expect(model.results, isEmpty);
      expect(model.searched, isTrue);
      expect(model.failure, isNull);
    });
  });

  group('response ordering', () {
    test('stale response does not overwrite fresh response', () async {
      final slow = wire.hold('дюна');
      model.setQuery('дюна');
      await settle();
      model.setQuery('дюна 2');
      await settle();
      expect(refs(), ['ref-2']);
      final before = notified;
      slow.complete();
      await settle();
      expect(refs(), ['ref-2']);
      expect(notified, before);
    });

    test('stale failure is not displayed over newer response', () async {
      final slow = wire.hold('дюна');
      wire.error = const SocketException('down');
      model.setQuery('дюна');
      await settle();
      wire.error = null;
      model.setQuery('дюна 2');
      await settle();
      slow.complete();
      await settle();
      expect(model.failure, isNull);
      expect(refs(), ['ref-2']);
    });

    test('stale response does not clear searching indicator', () async {
      final slow = wire.hold('дюна');
      model.setQuery('дюна');
      await settle();
      model.setQuery('дюна 2');
      slow.complete();
      await Future<void>.delayed(beforePause);
      expect(model.searching, isTrue);
      await settle();
    });
  });

  group('failure', () {
    test('reason visible, query and previous list intact', () async {
      model.setQuery('дюна');
      await settle();
      wire.status = 503;
      model.setQuery('дюна 2');
      await settle();
      expect(model.failure, BookFailure.unavailable);
      expect(model.query, 'дюна 2');
      expect(model.searching, isFalse);
      expect(refs(), ['ref-1']);
    });

    test('no network: offline', () async {
      wire.error = const SocketException('down');
      model.setQuery('дюна');
      await settle();
      expect(model.failure, BookFailure.offline);
      expect(model.searched, isFalse);
      expect(notified, 2);
    });

    test('typing new query clears failure immediately', () async {
      wire.status = 503;
      model.setQuery('дюна');
      await settle();
      model.setQuery('дюна 2');
      expect(model.failure, isNull);
      await settle();
    });

    test('successful response clears error', () async {
      wire.status = 503;
      model.setQuery('дюна');
      await settle();
      wire.status = 200;
      await model.submit();
      expect(model.failure, isNull);
      expect(refs(), ['ref-2']);
    });
  });

  group('search button', () {
    test('searches immediately, cancels pending debounce', () async {
      model.setQuery('дюна');
      final done = model.submit();
      expect(model.searching, isTrue);
      await done;
      expect(wire.asked, ['дюна']);
      expect(refs(), ['ref-1']);
      expect(model.searching, isFalse);
      await settle();
      expect(wire.asked, ['дюна']);
    });

    test('retries same query after failure', () async {
      wire.status = 503;
      model.setQuery('дюна');
      await settle();
      wire.status = 200;
      final before = notified;
      final done = model.submit();
      expect(model.failure, isNull);
      expect(model.searching, isTrue);
      expect(notified, before + 1);
      await done;
      expect(wire.asked, ['дюна', 'дюна']);
    });

    test(
      'response from pre-tap request does not overwrite newer result',
      () async {
        final slow = wire.hold('дюна');
        model.setQuery('дюна');
        await settle();
        wire.gates.remove('дюна');
        await model.submit();
        expect(refs(), ['ref-2']);
        slow.complete();
        await settle();
        expect(refs(), ['ref-2']);
      },
    );

    test('does nothing on short query', () async {
      model.setQuery('д');
      final before = notified;
      await model.submit();
      expect(wire.asked, isEmpty);
      expect(notified, before);
      expect(model.searching, isFalse);
    });

    test('no uncaught exceptions', () async {
      wire.error = StateError('boom');
      model.setQuery('дюна');
      await model.submit();
      expect(model.failure, BookFailure.offline);
    });
  });

  group('reset and disposal', () {
    test('reset clears everything and notifies listeners', () async {
      model.setQuery('дюна');
      await settle();
      final before = notified;
      model.reset();
      expect(model.query, '');
      expect(model.results, isEmpty);
      expect(model.searched, isFalse);
      expect(model.searching, isFalse);
      expect(model.failure, isNull);
      expect(notified, before + 1);
    });

    test('reset clears displayed failure', () async {
      wire.status = 503;
      model.setQuery('дюна');
      await settle();
      model.reset();
      expect(model.failure, isNull);
    });

    test('reset during debounce: request is not sent', () async {
      model.setQuery('дюна');
      model.reset();
      await settle();
      expect(wire.asked, isEmpty);
      expect(model.searching, isFalse);
    });

    test('response after reset produces no effect', () async {
      final slow = wire.hold('дюна');
      model.setQuery('дюна');
      await settle();
      model.reset();
      final before = notified;
      slow.complete();
      await settle();
      expect(model.results, isEmpty);
      expect(model.searched, isFalse);
      expect(notified, before);
    });

    test('same text searches anew after reset', () async {
      model.setQuery('дюна');
      await settle();
      model.reset();
      model.setQuery('дюна');
      await settle();
      expect(wire.asked, ['дюна', 'дюна']);
    });

    test('dispose during debounce: request is not sent', () async {
      model.setQuery('дюна');
      model.dispose();
      await settle();
      expect(wire.asked, isEmpty);
      model = BookSearchModel(BookClient(wire.send), pause: pause);
    });

    test('response after dispose does not throw or notify', () async {
      final slow = wire.hold('дюна');
      model.setQuery('дюна');
      await settle();
      final before = notified;
      model.dispose();
      slow.complete();
      await settle();
      expect(notified, before);
      model = BookSearchModel(BookClient(wire.send), pause: pause);
    });
  });

  test(
    'module makes no network calls itself, does not log, and prints no query',
    () {
      final source = File('lib/book_search.dart').readAsStringSync();
      for (final banned in [
        'dart:io',
        'package:http',
        'print(',
        'debugPrint',
        'dart:developer',
        'toString',
      ]) {
        expect(source.contains(banned), isFalse, reason: banned);
      }
    },
  );
}
