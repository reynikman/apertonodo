import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_stream/catalog.dart';
import 'package:music_stream/screens/search_screen.dart';

import 'fakes.dart';

/// Search explains why results are missing.
///
/// Audit September 18: any non-200 response — 401 after key rotation, 503
/// catalog outage, 500 — collapsed into empty list, masquerading as "nothing
/// found". Loading indicator was missing, and slow stale search clobbered
/// newer results.
void main() {
  group('HttpCatalog', () {
    Future<SearchFailure?> failureFor(
      http.Client client, {
      Duration? timeout,
    }) async {
      try {
        await HttpCatalog(
          'http://192.0.2.1:8088',
          tokens: tokensFor('http://192.0.2.1:8088'),
          client: client,
          timeout: timeout ?? HttpCatalog.searchTimeout,
        ).search('metallica');
        return null;
      } on SearchFailed catch (failed) {
        return failed.reason;
      }
    }

    http.Client answering(int status) =>
        MockClient((_) async => http.Response('{}', status));

    test('401 - no access, not "nothing found"', () async {
      expect(await failureFor(answering(401)), SearchFailure.noAccess);
    });

    test('503 - catalog not responding', () async {
      expect(await failureFor(answering(503)), SearchFailure.catalogDown);
    });

    test('500 and network drop - server did not reply', () async {
      expect(await failureFor(answering(500)), SearchFailure.noAnswer);
      final broken = MockClient(
        (_) async => throw http.ClientException('reset'),
      );
      expect(await failureFor(broken), SearchFailure.noAnswer);
    });

    test('hanging search aborted by timeout', () async {
      final hanging = MockClient((_) => Completer<http.Response>().future);
      expect(
        await failureFor(hanging, timeout: const Duration(milliseconds: 20)),
        SearchFailure.noAnswer,
      );
    });

    test('empty results is empty list, not error', () async {
      final empty = MockClient(
        (_) async => http.Response(jsonEncode({'tracks': const []}), 200),
      );
      expect(
        await HttpCatalog(
          'http://192.0.2.1:8088',
          tokens: tokensFor('http://192.0.2.1:8088'),
          client: empty,
        ).search('x'),
        isEmpty,
      );
    });
  });

  group('search screen', () {
    Future<void> search(WidgetTester tester, String query) async {
      await tester.enterText(find.byKey(const Key('search-field')), query);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
    }

    Widget screen(Future<SearchResult> Function(String) onSearch) {
      return MaterialApp(
        home: SearchScreen(onSearch: onSearch, onSelect: (_, _) {}),
      );
    }

    testWidgets('key invalid - clearly stated', (tester) async {
      await tester.pumpWidget(
        screen((_) async => throw const SearchFailed(SearchFailure.noAccess)),
      );
      await search(tester, 'metallica');
      await tester.pump();

      expect(
        find.text('Нет доступа: ключ сборки не подходит к серверу'),
        findsOneWidget,
      );
      expect(find.text('Ничего не найдено'), findsNothing);
    });

    testWidgets('catalog down - clearly stated', (tester) async {
      await tester.pumpWidget(
        screen(
          (_) async => throw const SearchFailed(SearchFailure.catalogDown),
        ),
      );
      await search(tester, 'metallica');
      await tester.pump();

      expect(find.byKey(const Key('search-error')), findsOneWidget);
      expect(find.textContaining('Каталог сейчас не отвечает'), findsOneWidget);
    });

    testWidgets('shows loading while searching; shows empty when empty', (
      tester,
    ) async {
      final answer = Completer<SearchResult>();
      await tester.pumpWidget(screen((_) => answer.future));
      await search(tester, 'qwertyuiop');

      expect(find.byKey(const Key('search-loading')), findsOneWidget);
      expect(find.text('Ничего не найдено'), findsNothing);

      answer.complete(const SearchResult());
      await tester.pump();
      expect(find.byKey(const Key('search-loading')), findsNothing);
      expect(find.text('Ничего не найдено'), findsOneWidget);
    });

    testWidgets('slow old search does not overwrite new', (tester) async {
      final old = Completer<SearchResult>();
      await tester.pumpWidget(
        screen(
          (query) => query == 'slipknot'
              ? old.future
              : Future.value(const SearchResult(tracks: [sandman])),
        ),
      );
      await search(tester, 'slipknot');
      await search(tester, 'metallica');
      await tester.pump();
      expect(find.text('Enter Sandman'), findsOneWidget);

      old.complete(const SearchResult(tracks: [duality]));
      await tester.pump();
      expect(find.text('Enter Sandman'), findsOneWidget);
      expect(find.text('Duality'), findsNothing);
    });
  });
}
