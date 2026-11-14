// FT-864: duplicates of one book (different releases) are told apart by size.
// Lead check — do not edit (P-A7).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/book_client.dart';
import 'package:music_stream/screens/books_page.dart';
import 'package:music_stream/screens/books_screen.dart' show bookSizeText;

import 'books_page_test.dart' as bp;

void main() {
  test('size reads in megabytes, then gigabytes with one decimal', () {
    expect(bookSizeText(412 * 1024 * 1024, 'ru'), '412 МБ');
    expect(bookSizeText((1.25 * 1024 * 1024 * 1024).round(), 'ru'), '1,3 ГБ');
    expect(bookSizeText((1.25 * 1024 * 1024 * 1024).round(), 'en'), '1.3 GB');
    expect(bookSizeText(412 * 1024 * 1024, 'en'), '412 MB');
  });

  testWidgets('a search row shows the release size after author and narrator', (
    tester,
  ) async {
    final wire = bp.Wire()
      ..replies['GET /v1/books/shelf'] = const BookReply(200, {'books': []})
      ..replies['GET /v1/books/search'] = BookReply(200, {
        'books': [
          {...bp.foundRow('a'), 'size_bytes': 412 * 1024 * 1024},
          {...bp.foundRow('b'), 'size_bytes': 980 * 1024 * 1024},
        ],
      });
    final h = bp.Harness(wire);
    const t = bp.texts;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BooksPage(
            shelf: h.shelf,
            search: h.search,
            texts: BooksPageTexts(
              searchHint: t.searchHint,
              shelfTitle: t.shelfTitle,
              emptyShelf: t.emptyShelf,
              loadFailed: t.loadFailed,
              retry: t.retry,
              searching: t.searching,
              searchFailed: t.searchFailed,
              nothingFound: t.nothingFound,
              add: t.add,
              adding: t.adding,
              onShelf: t.onShelf,
              listen: t.listen,
              failure: t.failure,
              languages: t.languages,
              allLanguages: t.allLanguages,
              noBooksInLanguages: t.noBooksInLanguages,
              searchAllLanguages: t.searchAllLanguages,
              size: (bytes) => bookSizeText(bytes, 'ru'),
            ),
            onOpenBook: (_) {},
            onListen: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
    await bp.typeQuery(tester, 'война');

    expect(find.text('Толстой · Клюквин · 2011 · 412 МБ'), findsOneWidget);
    expect(find.text('Толстой · Клюквин · 2011 · 980 МБ'), findsOneWidget);
  });
}
