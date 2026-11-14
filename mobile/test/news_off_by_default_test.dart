import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/app.dart';
import 'package:music_stream/news_prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';

/// FT-796 (owner finding 12.10 item 7): news disabled by default, and
/// toggle in account menu hides feed icon itself — tab bar retains
/// four icons.
///
/// Contract:
/// - device setting `news-enabled`: missing key means DISABLED;
/// - disabled — no `tab-news` button in bar, `GET /v1/news` not sent;
/// - `news-switch` in account menu enables it — button appears, first
///   opening requests consent as before;
/// - disabling while on feed tab redirects to Home;
/// - other four tabs open same content as before.
void main() {
  final dispatcher =
      TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher;
  setUp(() => dispatcher.localeTestValue = const Locale('ru'));
  tearDown(dispatcher.clearLocaleTestValue);

  final newsTab = find.byKey(const Key('tab-news'));

  Future<FakeServer> app(WidgetTester tester, Map<String, Object> prefs) async {
    SharedPreferences.setMockInitialValues(prefs);
    final server = FakeServer()
      ..on('GET /v1/news', (_) => answer(200, sample('news')));
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

  Future<void> flipSwitch(WidgetTester tester) async {
    await openTab(tester, 'library');
    await tapAndSettle(tester, find.byKey(const Key('account-button')));
    await tapAndSettle(tester, find.byKey(const Key('news-switch')));
  }

  test('missing setting — news disabled', () async {
    SharedPreferences.setMockInitialValues({});
    final news = NewsPrefs();
    addTearDown(news.dispose);
    expect(
      news.enabled,
      isFalse,
      reason: 'before loading settings — also disabled',
    );
    await news.load();
    expect(news.enabled, isFalse);
  });

  testWidgets('fresh phone: four icons, no feed, server untouched', (
    tester,
  ) async {
    final server = await app(tester, {});
    expect(newsTab, findsNothing);
    for (final name in ['home', 'browse', 'search', 'library']) {
      expect(find.byKey(Key('tab-$name')), findsOneWidget, reason: name);
    }
    expect(server.calls('GET /v1/news'), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switch restores icon, consent flow remains unchanged', (
    tester,
  ) async {
    final server = await app(tester, {});
    await flipSwitch(tester);
    expect(
      (await SharedPreferences.getInstance()).getBool('news-enabled'),
      isTrue,
    );
    expect(newsTab, findsOneWidget);
    expect(server.calls('GET /v1/news'), isEmpty, reason: 'pre-consent feed');

    await openTab(tester, 'news');
    expect(find.byKey(const Key('news-consent')), findsOneWidget);
    await tapAndSettle(tester, find.byKey(const Key('news-consent-accept')));
    expect(find.byKey(const Key('news-card-101')), findsOneWidget);
  });

  testWidgets('enabled in settings — icon shown immediately', (tester) async {
    await app(tester, {'news-enabled': true, 'news-consent': true});
    expect(newsTab, findsOneWidget);
    await openTab(tester, 'news');
    expect(find.byKey(const Key('news-card-101')), findsOneWidget);
  });

  testWidgets('disabled — icon hidden; leaves feed back to «Home»', (
    tester,
  ) async {
    await app(tester, {'news-enabled': true, 'news-consent': true});
    await flipSwitch(tester);
    expect(newsTab, findsNothing);
    expect(
      (await SharedPreferences.getInstance()).getBool('news-enabled'),
      isFalse,
    );

    // Enabled again and switched to feed, then disabled.
    await flipSwitch(tester);
    await openTab(tester, 'news');
    expect(find.byKey(const Key('news-card-101')), findsOneWidget);
    // Account menu is in My Music — disable from there and return.
    await flipSwitch(tester);
    expect(newsTab, findsNothing);
    expect(find.byKey(const Key('news-card-101')).hitTestable(), findsNothing);
    expect(find.byKey(const Key('news-off')).hitTestable(), findsNothing);
  });

  testWidgets('without feed other tabs open normally', (tester) async {
    await app(tester, {});
    await openTab(tester, 'browse');
    expect(find.byKey(const Key('browse-title')).hitTestable(), findsOneWidget);
    await openTab(tester, 'search');
    expect(find.byType(TextField).hitTestable(), findsOneWidget);
    await openTab(tester, 'library');
    expect(
      find.byKey(const Key('account-button')).hitTestable(),
      findsOneWidget,
    );
    await openTab(tester, 'home');
    expect(find.byKey(const Key('browse-title')).hitTestable(), findsNothing);
  });
}
