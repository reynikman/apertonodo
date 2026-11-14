import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/app.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';

/// FT-800 (owner finding 12.10, item 11): books or podcasts unconfigured on
/// server — tile in "Browse" remains in place dimmed, explains this
/// in words, and does not navigate to screen that would only answer "unavailable".
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  FakeServer serverWith(Map<String, Object?>? features) {
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
    server.on('GET /v1/books/shelf', (_) => answer(200, {'books': []}));
    if (features != null) {
      server.on('GET /v1/features', (_) => answer(200, features));
    }
    return server;
  }

  Future<void> openBrowse(WidgetTester tester, FakeServer server) async {
    await tester.pumpWidget(
      MusicApp(
        catalogSource: server.catalog(),
        server: server.api(),
        onAccountAction: (_) async {},
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tab-browse')));
    await tester.pumpAndSettle();
  }

  final podcasts = find.byKey(const Key('browse-podcasts'));
  final books = find.byKey(const Key('browse-books'));
  final browse = find.byKey(const Key('browse-title'));
  const notSetUp = 'Не настроено на сервере';

  Finder dimOf(Finder tile) =>
      find.descendant(of: tile, matching: find.byType(Opacity));

  testWidgets('books not configured: tile dimmed and does not open', (
    tester,
  ) async {
    await openBrowse(tester, serverWith({'books': false, 'podcasts': true}));
    expect(books, findsOneWidget);
    expect(
      tester.widget<Opacity>(dimOf(books).first).opacity,
      lessThanOrEqualTo(0.5),
    );
    expect(
      find.descendant(of: books, matching: find.text(notSetUp)),
      findsOneWidget,
    );
    await tester.tap(books, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(browse.hitTestable(), findsOneWidget);
    // Configured feature is not dimmed and carries no subtitle.
    expect(dimOf(podcasts), findsNothing);
    expect(
      find.descendant(of: podcasts, matching: find.text(notSetUp)),
      findsNothing,
    );
  });

  testWidgets('podcasts not configured: tile dimmed and does not open', (
    tester,
  ) async {
    await openBrowse(tester, serverWith({'books': true, 'podcasts': false}));
    expect(podcasts, findsOneWidget);
    expect(
      tester.widget<Opacity>(dimOf(podcasts).first).opacity,
      lessThanOrEqualTo(0.5),
    );
    expect(
      find.descendant(of: podcasts, matching: find.text(notSetUp)),
      findsOneWidget,
    );
    await tester.tap(podcasts, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(browse.hitTestable(), findsOneWidget);
    expect(dimOf(books), findsNothing);
  });

  testWidgets('everything configured: both tiles active', (tester) async {
    await openBrowse(tester, serverWith({'books': true, 'podcasts': true}));
    expect(dimOf(books), findsNothing);
    expect(dimOf(podcasts), findsNothing);
    expect(find.text(notSetUp), findsNothing);
    await tester.tap(books);
    await tester.pumpAndSettle();
    expect(browse.hitTestable(), findsNothing);
  });

  testWidgets('server did not reply about config: tiles active as before', (
    tester,
  ) async {
    // Legacy server is unaware of this route; network hiccup is also no reason
    // to shut down what is working.
    await openBrowse(tester, serverWith(null));
    expect(dimOf(books), findsNothing);
    expect(dimOf(podcasts), findsNothing);
    expect(find.text(notSetUp), findsNothing);
  });

  testWidgets('English phone reads subtitle in English', (tester) async {
    tester.platformDispatcher.localeTestValue = const Locale('en');
    tester.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.platformDispatcher.clearLocaleTestValue);
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    await openBrowse(tester, serverWith({'books': false, 'podcasts': false}));
    expect(find.text('Not set up on the server'), findsNWidgets(2));
    expect(find.text(notSetUp), findsNothing);
  });
}
