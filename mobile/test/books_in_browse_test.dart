import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/app.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';
import 'fakes.dart';

/// FT-793 (owner findings 12.10, items 6, 9, 12; P-A108): books live in
/// "Browse" as a tile next to podcasts, not as a row in "My music";
/// books screen has "back" button.
void main() {
  const bookId = '0b0f6a52-7f3e-4d7a-9a51-3c2f1e8d7a10';
  const title = 'Мастер и Маргарита';

  setUp(() => SharedPreferences.setMockInitialValues({}));

  FakeServer withBook() {
    final server = FakeServer();
    server.on(
      'GET /v1/genres',
      (_) => answer(200, {
        'genres': [
          {'id': 'rock', 'name': 'Рок', 'artists': 63120},
          {'id': 'pop', 'name': 'Поп', 'artists': 41250},
        ],
      }),
    );
    server.on(
      'GET /v1/books/shelf',
      (_) => answer(200, {
        'books': [
          {
            'id': bookId,
            'title': title,
            'author': 'Михаил Булгаков',
            'narrator': '',
            'year': 2011,
            'size_bytes': 52428800,
            'parts': 3,
            'shelved_at': '2026-10-12T10:00:00.000Z',
          },
        ],
      }),
    );
    server.on(
      'POST /v1/books/*/play',
      (_) => answer(200, {'token': 'book-token-793', 'state': 'ready'}),
    );
    return server;
  }

  Future<void> openBrowse(
    WidgetTester tester,
    FakeServer server, {
    FakeAudio? audio,
  }) async {
    await tester.pumpWidget(
      MusicApp(
        catalogSource: server.catalog(),
        server: server.api(),
        audio: audio,
        onAccountAction: (_) async {},
      ),
    );
    await tester.tap(find.byKey(const Key('tab-browse')));
    await tester.pumpAndSettle();
  }

  final podcasts = find.byKey(const Key('browse-podcasts'));
  final books = find.byKey(const Key('browse-books'));

  testWidgets('audiobooks tile is placed in Browse alongside podcasts', (
    tester,
  ) async {
    await openBrowse(tester, withBook());

    expect(books, findsOneWidget);
    final left = tester.getRect(podcasts);
    final right = tester.getRect(books);
    expect(right.top, left.top);
    expect(right.size, left.size);
    expect(right.left, greaterThan(left.right));
    expect(
      find.descendant(of: books, matching: find.text('Аудиокниги')),
      findsOneWidget,
    );
  });

  testWidgets('tile opens shelf, back button returns to Browse view', (
    tester,
  ) async {
    final server = withBook();
    await openBrowse(tester, server);

    await tester.tap(books);
    await tester.pumpAndSettle();

    expect(server.calls('GET /v1/books/shelf'), isNotEmpty);
    expect(find.text(title), findsWidgets);
    final back = find.byType(BackButton);
    expect(back, findsOneWidget);
    expect(tester.getSize(back).width, greaterThanOrEqualTo(48));
    // Button in header, not somewhere at bottom.
    expect(tester.getRect(back).top, lessThan(120));

    await tester.tap(back);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('browse-title')), findsOneWidget);
    expect(find.text(title), findsNothing);
    expect(server.unknown, isEmpty);
  });

  testWidgets('Listen from the Browse shelf plays the first part', (
    tester,
  ) async {
    final server = withBook();
    final audio = FakeAudio();
    await openBrowse(tester, server, audio: audio);
    await tester.tap(books);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('listen-$bookId')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(server.bodies('POST /v1/books/*/play'), [
      {'part': 1},
    ]);
    expect(
      audio.played.map((p) => Uri.parse(p.$1).path),
      contains('/v1/stream/book-token-793'),
    );
    expect(server.unknown, isEmpty);
  });

  testWidgets('book search from Browse respects languages in settings', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'listen-langs-books': ['ru'],
    });
    final server = withBook();
    Map<String, Object?> found(String ref, String title, String lang) => {
      'ref': ref,
      'title': title,
      'author': 'Автор',
      'narrator': '',
      'year': 2011,
      'size_bytes': 100,
      'language': lang,
    };
    server.on(
      'GET /v1/books/search',
      (_) => answer(200, {
        'books': [
          found('ref-ru', 'Русская книга', 'ru'),
          found('ref-de', 'Deutsches Buch', 'de'),
        ],
      }),
    );
    await openBrowse(tester, server);
    await tester.tap(books);
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const ValueKey('books-search')), 'книга');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(find.text('Русская книга'), findsOneWidget);
    expect(find.text('Deutsches Buch'), findsNothing);
    expect(server.unknown, isEmpty);
  });

  testWidgets('in My Music book row is gone, the rest is in place', (
    tester,
  ) async {
    final server = withBook();
    await tester.pumpWidget(
      MusicApp(
        catalogSource: server.catalog(),
        server: server.api(),
        onAccountAction: (_) async {},
      ),
    );
    await tester.tap(find.byKey(const Key('tab-library')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('library-books')), findsNothing);
    for (final name in ['favorites', 'history', 'playlists', 'import']) {
      expect(find.byKey(Key('library-$name')), findsOneWidget, reason: name);
    }
    expect(server.calls('GET /v1/books/shelf'), isEmpty);
  });
}
