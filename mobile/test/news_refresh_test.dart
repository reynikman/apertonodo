import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/screens/news_screen.dart';
import 'package:music_stream/screens/parts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';
import 'golden_support.dart';

/// FT-791 (owner finding 12.10): feed could not be refreshed without
/// restarting the app. Now pull down to refresh — in any state: with
/// items, empty, and "disabled on server".
void main() {
  final dispatcher =
      TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher;
  setUp(() => dispatcher.localeTestValue = const Locale('ru'));
  tearDown(dispatcher.clearLocaleTestValue);
  setUp(() => SharedPreferences.setMockInitialValues({'news-consent': true}));

  /// Feed that returns next response from [pages] for each request;
  /// last one repeats.
  Future<int Function()> feed(
    WidgetTester tester,
    List<Map<String, dynamic>> pages,
  ) async {
    usePhone(tester, phones['360']!);
    final rig = Rig();
    var calls = 0;
    rig.server.on('GET /v1/news', (_) {
      final page = pages[calls < pages.length ? calls : pages.length - 1];
      calls++;
      return answer(200, page);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: NewsScreen(
          services: Services(
            server: rig.server.api(),
            search: rig.server.catalog().search,
            play: (_, _) {},
            prepare: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return () => calls;
  }

  Map<String, dynamic> withTitle(String title) {
    final page = sample('news');
    final items = [
      for (final item in page['items'] as List)
        Map<String, dynamic>.from(item as Map),
    ];
    items.first['title'] = title;
    return {...page, 'items': items};
  }

  Future<void> pull(WidgetTester tester) async {
    await tester.fling(
      find.byType(RefreshIndicator),
      const Offset(0, 400),
      1200,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('populated feed: pull down action fetches fresh news', (
    tester,
  ) async {
    final calls = await feed(tester, [
      withTitle('Старая новость'),
      withTitle('Свежая новость'),
    ]);
    expect(find.text('Старая новость'), findsOneWidget);
    expect(calls(), 1);

    await pull(tester);

    expect(calls(), 2);
    expect(find.text('Свежая новость'), findsOneWidget);
    expect(find.text('Старая новость'), findsNothing);
  });

  testWidgets('empty feed also refreshes via gesture', (tester) async {
    final empty = {...sample('news'), 'items': <Object>[]};
    final calls = await feed(tester, [empty, withTitle('Первая новость')]);
    expect(find.byKey(const Key('news-list')), findsNothing);

    await pull(tester);

    expect(calls(), 2);
    expect(find.text('Первая новость'), findsOneWidget);
  });

  testWidgets('«server-disabled» also refreshes via gesture', (tester) async {
    final off = {...sample('news'), 'enabled': false, 'items': <Object>[]};
    final calls = await feed(tester, [off, withTitle('Включили')]);
    expect(find.byKey(const Key('news-server-off')), findsOneWidget);

    await pull(tester);

    expect(calls(), 2);
    expect(find.text('Включили'), findsOneWidget);
  });

  testWidgets('refresh failure does not clear already displayed feed', (
    tester,
  ) async {
    usePhone(tester, phones['360']!);
    final rig = Rig();
    var calls = 0;
    rig.server.on('GET /v1/news', (_) {
      calls++;
      return calls == 1
          ? answer(200, withTitle('Уже на экране'))
          : answer(503, {'detail': 'busy'});
    });
    await tester.pumpWidget(
      MaterialApp(
        home: NewsScreen(
          services: Services(
            server: rig.server.api(),
            search: rig.server.catalog().search,
            play: (_, _) {},
            prepare: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await pull(tester);

    expect(calls, greaterThanOrEqualTo(2));
    expect(find.text('Уже на экране'), findsOneWidget);
  });
}
