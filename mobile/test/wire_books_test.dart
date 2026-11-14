import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/app.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';
import 'fakes.dart';

/// FT-773, FT-793: "Audiobooks" in "Browse" opens shelf, "Listen" requests
/// book part from server and plays token.
void main() {
  const bookId = '0b0f6a52-7f3e-4d7a-9a51-3c2f1e8d7a10';
  const title = 'Мастер и Маргарита';

  // Storage responds on device; otherwise "Listen" would hang indefinitely.
  setUp(() => SharedPreferences.setMockInitialValues({}));

  FakeServer withBook() {
    final server = FakeServer();
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
      (_) => answer(200, {'token': 'book-token-773', 'state': 'ready'}),
    );
    return server;
  }

  Future<void> openBooks(
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
    await tester.tap(find.byKey(const Key('browse-books')));
    await tester.pumpAndSettle();
  }

  testWidgets('Audiobooks in Browse displays server shelf', (tester) async {
    final server = withBook();
    await openBooks(tester, server);

    expect(server.calls('GET /v1/books/shelf'), isNotEmpty);
    expect(find.text(title), findsWidgets);
    expect(server.unknown, isEmpty);
  });

  testWidgets('Listen requests first part from server and plays it', (
    tester,
  ) async {
    final server = withBook();
    final audio = FakeAudio();
    await openBooks(tester, server, audio: audio);

    await tester.tap(find.byKey(const ValueKey('listen-$bookId')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(server.bodies('POST /v1/books/*/play'), [
      {'part': 1},
    ]);
    expect(
      audio.played.map((p) => Uri.parse(p.$1).path),
      contains('/v1/stream/book-token-773'),
      reason: 'player acquired stream using book part token',
    );
    expect(server.unknown, isEmpty);
  });
  testWidgets('book search in app hides books not in selected languages', (
    tester,
  ) async {
    // FT-785: only Russian selected in book settings.
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
    await openBooks(tester, server);

    await tester.enterText(find.byKey(const ValueKey('books-search')), 'книга');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(server.calls('GET /v1/books/search'), isNotEmpty);
    expect(find.text('Русская книга'), findsOneWidget);
    expect(
      find.text('Deutsches Buch'),
      findsNothing,
      reason: 'app passes configured languages to book search',
    );
    expect(server.unknown, isEmpty);
  });
}
