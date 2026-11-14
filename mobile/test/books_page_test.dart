// FT-718 (Кн-6, P-A108): "Audiobooks" page — shelf and book search.
//
// "Audiobooks" tile in "Browse" opens this page. It connects two
// existing models from `main`: shelf (`BookShelfModel`, FT-677) and search
// (`BookSearchModel`). Page has no network; test mocks server in client.
//
// Contract `lib/screens/books_page.dart`:
// - `BooksPageTexts(searchHint, shelfTitle, emptyShelf, loadFailed, retry,
//   searching, searchFailed, nothingFound, add, adding, onShelf, listen,
//   failure: String Function(BookFailure))`;
// - `BooksPage(shelf, search, texts, onOpenBook, onListen, continueSection?)`;
// - keys: `books-search`, `book-<id>`, `listen-<id>`, `found-<ref>`,
//   `add-<ref>`, `books-retry`, `books-empty`, `books-load-error`,
//   `books-search-error`, `books-nothing`, `books-add-error`.
//
// Guarded (mandatory cases P-A109 — retry, late response,
// error announcement — plus):
// - page requests shelf automatically if not loaded yet, and does not request
//   again if already loaded;
// - book row: title and "author · narrator · year"; tap — `onOpenBook`,
//   "Listen" — `onListen`, and TalkBack announces "Listen: <title>";
// - empty shelf, failed load with "Retry" that actually retries;
// - search: under two letters shows shelf, not search; results, "nothing found",
//   search error — all announced via accessibility;
// - "Add to shelf": in progress — "Adding…" with button disabled, second tap does not send
//   second request, success — "On shelf", server error — reason in words and
//   button becomes available again;
// - response after leaving page does not break anything; logout
//   during adding does not show false "On shelf"; book removed elsewhere —
//   button reverts to "Add to shelf"; new query clears previous adding error;
// - buttons at least 48 dp, no overflow on 360 dp with ×2 font scale;
// - "Continue" block displayed above shelf and hidden during search.
//
// What test does not prove: real book server does not exist yet (separate
// backend card); book language and download progress absent in data — these are Яз-4 and
// Кн-9, not part of this card.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/book_client.dart';
import 'package:music_stream/book_search.dart';
import 'package:music_stream/book_shelf.dart';
import 'package:music_stream/listening_languages.dart';
import 'package:music_stream/screens/books_page.dart';
import 'package:music_stream/screens/languages_sheet.dart';

String bookId(int n) =>
    '0b0c1d2e-0000-4000-8000-${n.toString().padLeft(12, '0')}';

Map<String, Object?> shelfRow(int n, {String title = 'Мастер и Маргарита'}) => {
  'id': bookId(n),
  'title': title,
  'author': 'Булгаков',
  'narrator': 'Абдулов',
  'year': 2019,
  'size_bytes': 100,
  'parts': 3,
};

Map<String, Object?> foundRow(String ref, {String title = 'Война и мир'}) => {
  'ref': ref,
  'title': title,
  'author': 'Толстой',
  'narrator': 'Клюквин',
  'year': 2011,
  'size_bytes': 10,
};

class Wire {
  final calls = <String>[];
  final replies = <String, BookReply>{};
  final gates = <String, Completer<void>>{};

  Future<BookReply> send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
  }) async {
    final key = '$method $path';
    calls.add(key);
    final gate = gates[key];
    if (gate != null) await gate.future;
    return replies[key] ?? const BookReply(500, null);
  }

  int count(String key) => calls.where((c) => c == key).length;
}

const texts = BooksPageTexts(
  searchHint: 'Название или автор',
  shelfTitle: 'Моя полка',
  emptyShelf: 'На полке пока пусто',
  loadFailed: 'Полка не загрузилась',
  retry: 'Повторить',
  searching: 'Ищу',
  searchFailed: 'Поиск не удался',
  nothingFound: 'Ничего не нашлось',
  add: 'На полку',
  adding: 'Ставлю…',
  onShelf: 'На полке',
  listen: 'Слушать',
  failure: _failure,
  languages: 'Языки',
  allLanguages: 'Все языки',
  noBooksInLanguages: 'Нет книг на выбранных языках',
  searchAllLanguages: 'Искать на всех языках',
);

String _failure(BookFailure f) => 'отказ: ${f.name}';

class Harness {
  Harness(this.wire, {this.languages})
    : client = BookClient(wire.send),
      opened = [],
      listened = [] {
    shelf = BookShelfModel(client);
    search = BookSearchModel(
      client,
      pause: const Duration(milliseconds: 10),
      languages: languages,
    );
  }
  final Wire wire;
  final BookClient client;
  final ListeningLanguages? languages;
  late final BookShelfModel shelf;
  late final BookSearchModel search;
  final List<String> opened;
  final List<String> listened;

  Widget page({Widget? continueSection}) => MaterialApp(
    home: Scaffold(
      body: BooksPage(
        shelf: shelf,
        search: search,
        languages: languages,
        texts: texts,
        onOpenBook: (b) => opened.add(b.id),
        onListen: (b) => listened.add(b.id),
        continueSection: continueSection,
      ),
    ),
  );
}

Harness withShelf(List<Map<String, Object?>> rows) {
  final wire = Wire()
    ..replies['GET /v1/books/shelf'] = BookReply(200, {'books': rows});
  return Harness(wire);
}

Future<void> typeQuery(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const ValueKey('books-search')), text);
  await tester.pump(const Duration(milliseconds: 20));
  await tester.pump();
}

void expectLive(WidgetTester tester, String text) {
  expect(tester.getSemantics(find.text(text)), isSemantics(isLiveRegion: true));
}

void main() {
  testWidgets('page loads shelf on its own and displays audiobooks', (
    tester,
  ) async {
    final h = withShelf([shelfRow(1), shelfRow(2, title: 'Собачье сердце')]);
    await tester.pumpWidget(h.page());
    await tester.pump();
    expect(h.wire.count('GET /v1/books/shelf'), 1);
    expect(find.text('Моя полка'), findsOneWidget);
    expect(find.text('Мастер и Маргарита'), findsOneWidget);
    expect(find.text('Собачье сердце'), findsOneWidget);
    expect(find.text('Булгаков · Абдулов · 2019'), findsNWidgets(2));
  });

  testWidgets('already loaded shelf is not requested twice', (tester) async {
    final h = withShelf([shelfRow(1)]);
    await h.shelf.load();
    await tester.pumpWidget(h.page());
    await tester.pump();
    expect(h.wire.count('GET /v1/books/shelf'), 1);
    expect(find.text('Мастер и Маргарита'), findsOneWidget);
  });

  testWidgets('shelf header is heading for TalkBack', (tester) async {
    final h = withShelf([shelfRow(1)]);
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(h.page());
    await tester.pump();
    expect(
      tester.getSemantics(find.text('Моя полка')),
      matchesSemantics(label: 'Моя полка', isHeader: true),
    );
    handle.dispose();
  });

  testWidgets('tapping book opens it, listen button starts playback', (
    tester,
  ) async {
    final h = withShelf([shelfRow(1)]);
    await tester.pumpWidget(h.page());
    await tester.pump();
    await tester.tap(find.text('Мастер и Маргарита'));
    expect(h.opened, [bookId(1)]);
    expect(h.listened, isEmpty);
    await tester.tap(find.byKey(ValueKey('listen-${bookId(1)}')));
    expect(h.listened, [bookId(1)]);
    expect(h.opened, [bookId(1)]);
  });

  testWidgets('TalkBack announces listen with book title', (tester) async {
    final h = withShelf([shelfRow(1)]);
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(h.page());
    await tester.pump();
    expect(
      find.bySemanticsLabel('Слушать: Мастер и Маргарита'),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('empty shelf displays message', (tester) async {
    final h = withShelf([]);
    await tester.pumpWidget(h.page());
    await tester.pump();
    expect(find.byKey(const ValueKey('books-empty')), findsOneWidget);
    expect(find.text('На полке пока пусто'), findsOneWidget);
  });

  testWidgets('shelf load failed: voiced error, retry button retries', (
    tester,
  ) async {
    final wire = Wire()
      ..replies['GET /v1/books/shelf'] = const BookReply(503, null);
    final h = Harness(wire);
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(h.page());
    await tester.pump();
    expect(find.text('Полка не загрузилась'), findsOneWidget);
    expectLive(tester, 'Полка не загрузилась');
    wire.replies['GET /v1/books/shelf'] = BookReply(200, {
      'books': [shelfRow(1)],
    });
    await tester.tap(find.byKey(const ValueKey('books-retry')));
    await tester.pump();
    await tester.pump();
    expect(wire.count('GET /v1/books/shelf'), 2);
    expect(find.text('Мастер и Маргарита'), findsOneWidget);
    expect(find.byKey(const ValueKey('books-load-error')), findsNothing);
    handle.dispose();
  });

  testWidgets('spinner with label shown while shelf loads', (tester) async {
    final h = withShelf([shelfRow(1)]);
    final gate = Completer<void>();
    h.wire.gates['GET /v1/books/shelf'] = gate;
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(h.page());
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.bySemanticsLabel('Ищу'), findsOneWidget);
    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    handle.dispose();
  });

  testWidgets('single letter is not search, shelf remains', (tester) async {
    final h = withShelf([shelfRow(1)]);
    await tester.pumpWidget(h.page());
    await tester.pump();
    await typeQuery(tester, 'в');
    expect(h.wire.calls.where((c) => c.contains('search')), isEmpty);
    expect(find.text('Мастер и Маргарита'), findsOneWidget);
  });

  testWidgets('search displays results instead of shelf', (tester) async {
    final h = withShelf([shelfRow(1)]);
    h.wire.replies['GET /v1/books/search'] = BookReply(200, {
      'books': [foundRow('ref-1')],
    });
    await tester.pumpWidget(h.page());
    await tester.pump();
    await typeQuery(tester, 'война');
    expect(find.byKey(const ValueKey('found-ref-1')), findsOneWidget);
    expect(find.text('Война и мир'), findsOneWidget);
    expect(find.text('Толстой · Клюквин · 2011'), findsOneWidget);
    expect(find.text('Мастер и Маргарита'), findsNothing);
    expect(find.text('Моя полка'), findsNothing);
  });

  testWidgets('clearing search restores shelf', (tester) async {
    final h = withShelf([shelfRow(1)]);
    h.wire.replies['GET /v1/books/search'] = BookReply(200, {
      'books': [foundRow('ref-1')],
    });
    await tester.pumpWidget(h.page());
    await tester.pump();
    await typeQuery(tester, 'война');
    await typeQuery(tester, '');
    expect(find.text('Мастер и Маргарита'), findsOneWidget);
    expect(find.text('Война и мир'), findsNothing);
  });

  testWidgets('nothing found is voiced', (tester) async {
    final h = withShelf([]);
    h.wire.replies['GET /v1/books/search'] = const BookReply(200, {
      'books': [],
    });
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(h.page());
    await tester.pump();
    await typeQuery(tester, 'нечто');
    expect(find.byKey(const ValueKey('books-nothing')), findsOneWidget);
    expectLive(tester, 'Ничего не нашлось');
    handle.dispose();
  });

  testWidgets('search error is voiced', (tester) async {
    final h = withShelf([]);
    h.wire.replies['GET /v1/books/search'] = const BookReply(503, null);
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(h.page());
    await tester.pump();
    await typeQuery(tester, 'война');
    expect(find.byKey(const ValueKey('books-search-error')), findsOneWidget);
    expectLive(tester, 'Поиск не удался');
    handle.dispose();
  });

  testWidgets('spinner shown while searching, no hits yet', (tester) async {
    final h = withShelf([]);
    h.wire.replies['GET /v1/books/search'] = BookReply(200, {
      'books': [foundRow('ref-1')],
    });
    final gate = Completer<void>();
    h.wire.gates['GET /v1/books/search'] = gate;
    await tester.pumpWidget(h.page());
    await tester.pump();
    await typeQuery(tester, 'война');
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Война и мир'), findsNothing);
    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('Война и мир'), findsOneWidget);
  });

  group('add to shelf', () {
    Harness found() {
      final h = withShelf([]);
      h.wire.replies['GET /v1/books/search'] = BookReply(200, {
        'books': [foundRow('ref-1')],
      });
      return h;
    }

    Finder addButton() => find.byKey(const ValueKey('add-ref-1'));

    TextButton button(WidgetTester tester) =>
        tester.widget<TextButton>(addButton());

    testWidgets('success: adding during request, then on shelf shown', (
      tester,
    ) async {
      final h = found();
      h.wire.replies['POST /v1/books/shelf'] = BookReply(200, {
        'state': 'ok',
        'book': shelfRow(7, title: 'Война и мир'),
      });
      final gate = Completer<void>();
      h.wire.gates['POST /v1/books/shelf'] = gate;
      await tester.pumpWidget(h.page());
      await tester.pump();
      await typeQuery(tester, 'война');
      expect(find.text('На полку'), findsOneWidget);
      await tester.tap(addButton());
      await tester.pump();
      expect(find.text('Ставлю…'), findsOneWidget);
      expect(button(tester).onPressed, isNull);
      gate.complete();
      await tester.pump();
      await tester.pump();
      expect(find.text('На полке'), findsOneWidget);
      expect(button(tester).onPressed, isNull);
      expect(h.shelf.has(bookId(7)), isTrue);
    });

    testWidgets('second tap while waiting does not send second call', (
      tester,
    ) async {
      final h = found();
      h.wire.replies['POST /v1/books/shelf'] = BookReply(200, {
        'state': 'ok',
        'book': shelfRow(7),
      });
      final gate = Completer<void>();
      h.wire.gates['POST /v1/books/shelf'] = gate;
      await tester.pumpWidget(h.page());
      await tester.pump();
      await typeQuery(tester, 'война');
      await tester.tap(addButton());
      await tester.pump();
      await tester.tap(addButton(), warnIfMissed: false);
      await tester.pump();
      gate.complete();
      await tester.pump();
      await tester.pump();
      await tester.tap(addButton(), warnIfMissed: false);
      await tester.pump();
      expect(h.wire.count('POST /v1/books/shelf'), 1);
    });

    testWidgets('server error: spoken reason, button enabled again', (
      tester,
    ) async {
      final h = found();
      h.wire.replies['POST /v1/books/shelf'] = const BookReply(409, {
        'status': 'no_space',
      });
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(h.page());
      await tester.pump();
      await typeQuery(tester, 'война');
      await tester.tap(addButton());
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('books-add-error')), findsOneWidget);
      expect(find.text('отказ: noSpace'), findsOneWidget);
      expectLive(tester, 'отказ: noSpace');
      expect(find.text('На полку'), findsOneWidget);
      expect(button(tester).onPressed, isNotNull);
      handle.dispose();
    });

    testWidgets('subsequent success clears previous error', (tester) async {
      final h = found();
      h.wire.replies['POST /v1/books/shelf'] = const BookReply(409, {
        'status': 'limit',
      });
      await tester.pumpWidget(h.page());
      await tester.pump();
      await typeQuery(tester, 'война');
      await tester.tap(addButton());
      await tester.pump();
      await tester.pump();
      expect(find.text('отказ: limit'), findsOneWidget);
      h.wire.replies['POST /v1/books/shelf'] = BookReply(200, {
        'state': 'exists',
        'book': shelfRow(7),
      });
      await tester.tap(addButton());
      await tester.pump();
      expect(find.byKey(const ValueKey('books-add-error')), findsNothing);
      await tester.pump();
      expect(find.text('На полке'), findsOneWidget);
    });

    testWidgets('logout during adding does not result in on shelf', (
      tester,
    ) async {
      final h = found();
      h.wire.replies['POST /v1/books/shelf'] = BookReply(200, {
        'state': 'ok',
        'book': shelfRow(7),
      });
      final gate = Completer<void>();
      h.wire.gates['POST /v1/books/shelf'] = gate;
      await tester.pumpWidget(h.page());
      await tester.pump();
      await typeQuery(tester, 'война');
      await tester.tap(addButton());
      await tester.pump();
      h.shelf.reset();
      gate.complete();
      await tester.pump();
      await tester.pump();
      expect(h.shelf.has(bookId(7)), isFalse);
      expect(find.text('На полке'), findsNothing);
      expect(find.text('На полку'), findsOneWidget);
      expect(button(tester).onPressed, isNotNull);
    });

    testWidgets('book removed elsewhere shows add to shelf again', (
      tester,
    ) async {
      final h = found();
      h.wire.replies['POST /v1/books/shelf'] = BookReply(200, {
        'state': 'ok',
        'book': shelfRow(7),
      });
      h.wire.replies['POST /v1/books/shelf/${bookId(7)}/remove'] =
          const BookReply(204, null);
      await tester.pumpWidget(h.page());
      await tester.pump();
      await typeQuery(tester, 'война');
      await tester.tap(addButton());
      await tester.pump();
      await tester.pump();
      expect(find.text('На полке'), findsOneWidget);
      await h.shelf.remove(bookId(7));
      await tester.pump();
      expect(find.text('На полку'), findsOneWidget);
      expect(button(tester).onPressed, isNotNull);
    });

    testWidgets('new query clears previous addition error message', (
      tester,
    ) async {
      final h = found();
      h.wire.replies['POST /v1/books/shelf'] = const BookReply(409, {
        'status': 'limit',
      });
      await tester.pumpWidget(h.page());
      await tester.pump();
      await typeQuery(tester, 'война');
      await tester.tap(addButton());
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('books-add-error')), findsOneWidget);
      await typeQuery(tester, 'мир');
      expect(find.byKey(const ValueKey('books-add-error')), findsNothing);
    });

    testWidgets('response after leaving screen causes no side effect', (
      tester,
    ) async {
      final h = found();
      h.wire.replies['POST /v1/books/shelf'] = const BookReply(409, {
        'status': 'limit',
      });
      final gate = Completer<void>();
      h.wire.gates['POST /v1/books/shelf'] = gate;
      await tester.pumpWidget(h.page());
      await tester.pump();
      await typeQuery(tester, 'война');
      await tester.tap(addButton());
      await tester.pump();
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      gate.complete();
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('TalkBack button read with book title', (tester) async {
      final h = found();
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(h.page());
      await tester.pump();
      await typeQuery(tester, 'война');
      expect(find.bySemanticsLabel('На полку: Война и мир'), findsOneWidget);
      handle.dispose();
    });
  });

  testWidgets('resume sits above shelf, hidden during search', (tester) async {
    final h = withShelf([shelfRow(1)]);
    h.wire.replies['GET /v1/books/search'] = const BookReply(200, {
      'books': [],
    });
    await tester.pumpWidget(
      h.page(continueSection: const Text('Продолжить', key: ValueKey('cont'))),
    );
    await tester.pump();
    final cont = tester.getTopLeft(find.byKey(const ValueKey('cont')));
    final shelfTitle = tester.getTopLeft(find.text('Моя полка'));
    expect(cont.dy, lessThan(shelfTitle.dy));
    await typeQuery(tester, 'война');
    expect(find.byKey(const ValueKey('cont')), findsNothing);
  });

  testWidgets('buttons are at least 48 dp high', (tester) async {
    final h = withShelf([shelfRow(1)]);
    h.wire.replies['GET /v1/books/search'] = BookReply(200, {
      'books': [foundRow('ref-1')],
    });
    await tester.pumpWidget(h.page());
    await tester.pump();
    expect(
      tester.getSize(find.byKey(ValueKey('listen-${bookId(1)}'))).height,
      greaterThanOrEqualTo(48),
    );
    await typeQuery(tester, 'война');
    expect(
      tester.getSize(find.byKey(const ValueKey('add-ref-1'))).height,
      greaterThanOrEqualTo(48),
    );
  });

  testWidgets('360 dp and font x2: no overflow', (tester) async {
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final long = 'Очень длинное название аудиокниги ' * 3;
    final h = withShelf([shelfRow(1, title: long)]);
    h.wire.replies['GET /v1/books/search'] = BookReply(200, {
      'books': [foundRow('ref-1', title: long)],
    });
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: h.page(),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    await typeQuery(tester, 'война');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'empty result due to languages shows search all languages button',
    (tester) async {
      final languages = ListeningLanguages(phoneLanguage: () => 'ru');
      addTearDown(languages.dispose);
      final wire = Wire()
        ..replies['GET /v1/books/shelf'] = const BookReply(200, {'books': []})
        ..replies['GET /v1/books/search'] = BookReply(200, {
          'books': [
            {
              'ref': 'ref-en',
              'title': 'Dune',
              'author': 'Herbert',
              'narrator': 'Reader',
              'year': 2011,
              'size_bytes': 100,
              'language': 'en',
            },
          ],
        });
      final h = Harness(wire, languages: languages);
      await tester.pumpWidget(h.page());
      await tester.pump();
      await typeQuery(tester, 'dune');
      expect(find.byKey(const ValueKey('books-all-languages')), findsOneWidget);
      expect(find.text('Нет книг на выбранных языках'), findsOneWidget);
      expect(find.text('Dune'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('books-all-languages')));
      await tester.pump();
      expect(find.text('Dune'), findsOneWidget);
      expect(find.byKey(const ValueKey('books-all-languages')), findsNothing);
    },
  );

  testWidgets('languages button above results opens language sheet', (
    tester,
  ) async {
    final languages = ListeningLanguages(phoneLanguage: () => 'ru');
    addTearDown(languages.dispose);
    final wire = Wire()
      ..replies['GET /v1/books/shelf'] = const BookReply(200, {'books': []})
      ..replies['GET /v1/books/search'] = BookReply(200, {
        'books': [foundRow('ref-1', title: 'Мастер')],
      });
    final h = Harness(wire, languages: languages);
    await tester.pumpWidget(h.page());
    await tester.pump();
    await typeQuery(tester, 'мастер');
    expect(find.byKey(const ValueKey('books-languages')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('books-languages')));
    await tester.pumpAndSettle();
    expect(find.byType(LanguagesSheet), findsOneWidget);
  });
}
