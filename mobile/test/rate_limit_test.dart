import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_stream/catalog.dart';
import 'package:music_stream/screens/catalog_screens.dart';
import 'package:music_stream/screens/search_screen.dart';

import 'fake_server.dart';
import 'fakes.dart';

/// 429 — "Too many requests", not "Connection error" (FT-458).
///
/// Production address sits behind proxy with 2 req/s rate limit: fast typing or
/// scrolling hits rate limit and proxy returns 429. Device displayed
/// "Server not responding — check connection", prompting user to check network
/// when it works a second later. Explain what happened and allow retrying.
const tooMany = 'Слишком много запросов — подождите и повторите';

void main() {
  testWidgets('catalog screen: 429 - \'too frequent\' and working retry', (
    tester,
  ) async {
    final rig = Rig();
    final repair = rig.server.fail('GET /v1/genres', 429, 'too_many_requests');
    await rig.screen(tester, (services) => GenresScreen(services: services));

    expect(find.text(tooMany), findsOneWidget);
    expect(find.text('Сервер не ответил'), findsNothing);
    expect(find.text('Жанров пока нет'), findsNothing);

    repair();
    await tapAndSettle(tester, find.text('Повторить'));
    expect(find.text(tooMany), findsNothing);
    expect(find.text('Рок'), findsWidgets);
  });

  testWidgets('search: 429 - \'too frequent\', not \'check connection\'', (
    tester,
  ) async {
    const base = 'http://192.0.2.1:8088';
    final catalog = HttpCatalog(
      base,
      tokens: tokensFor(base),
      client: MockClient((_) async => http.Response('{}', 429)),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SearchScreen(onSearch: catalog.search, onSelect: (_, _) {}),
      ),
    );
    await tester.enterText(find.byKey(const Key('search-field')), 'metallica');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('search-error')), findsOneWidget);
    expect(find.textContaining(tooMany), findsOneWidget);
    expect(find.textContaining('проверьте связь'), findsNothing);
    expect(find.text('Ничего не найдено'), findsNothing);
  });
}
