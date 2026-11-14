import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/app.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';

/// FT-581 (P-A83): news consent — prompt once; toggle; server without news.
///
/// Contract:
/// - device settings: `news-consent` (bool, missing — not prompted) and
///   `news-enabled` (bool, missing — enabled);
/// - first opening of `tab-news` tab shows `news-consent` screen with button
///   `news-consent-accept`; before consent `GET /v1/news` not sent; after —
///   feed opens, and subsequent app launches bypass consent screen;
/// - `news-switch` toggle in account menu (alongside `auto-reports`);
///   when off — tab displays `news-off` with tip on how to enable,
///   and does not query server;
/// - server returned `{"enabled": false}` — `news-server-off`
///   ("disabled on this server"), without error screen.
void main() {
  // News captions are bilingual (P-A84); Russian ones verified here.
  final dispatcher =
      TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher;
  setUp(() => dispatcher.localeTestValue = const Locale('ru'));
  tearDown(dispatcher.clearLocaleTestValue);
  Future<FakeServer> app(
    WidgetTester tester,
    Map<String, Object> prefs, {
    Object? news,
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    final server = FakeServer()
      ..on('GET /v1/news', (_) => answer(200, news ?? sample('news')));
    addTearDown(() => expect(server.unknown, isEmpty));
    await tester.pumpWidget(
      MusicApp(
        catalogSource: server.catalog(),
        server: server.api(),
        onAccountAction: (_) async {},
      ),
    );
    await tester.pumpAndSettle();
    return server;
  }

  testWidgets('consent requested once and before first network query', (
    tester,
  ) async {
    var server = await app(tester, {'news-enabled': true});
    await openTab(tester, 'news');
    expect(find.byKey(const Key('news-consent')), findsOneWidget);
    expect(server.calls('GET /v1/news'), isEmpty, reason: 'pre-consent feed');

    await tapAndSettle(tester, find.byKey(const Key('news-consent-accept')));
    expect(find.byKey(const Key('news-card-101')), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('news-consent'), isTrue);

    await tester.pumpWidget(const SizedBox());
    server = await app(tester, {'news-consent': true, 'news-enabled': true});
    await openTab(tester, 'news');
    expect(find.byKey(const Key('news-consent')), findsNothing);
    expect(find.byKey(const Key('news-card-101')), findsOneWidget);
  });

  testWidgets('switch hides feed without hitting server', (tester) async {
    final server = await app(tester, {
      'news-consent': true,
      'news-enabled': true,
    });
    await openTab(tester, 'library');
    await tapAndSettle(tester, find.byKey(const Key('account-button')));
    await tapAndSettle(tester, find.byKey(const Key('news-switch')));
    expect(
      (await SharedPreferences.getInstance()).getBool('news-enabled'),
      isFalse,
    );

    expect(find.byKey(const Key('tab-news')), findsNothing);
    expect(server.calls('GET /v1/news'), isEmpty);
  });

  testWidgets('server without news — custom text, not error', (tester) async {
    await app(
      tester,
      {'news-consent': true, 'news-enabled': true},
      news: {'enabled': false},
    );
    await openTab(tester, 'news');
    expect(find.byKey(const Key('news-server-off')), findsOneWidget);
    expect(find.textContaining('выключено на этом сервере'), findsOneWidget);
  });
}
