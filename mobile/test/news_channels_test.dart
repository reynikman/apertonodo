import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/screens/news_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';
import 'golden_support.dart';

/// FT-582 (P-A83): "Channels" screen — curated list, custom link, popular.
///
/// Contract:
/// - from feed `news-channels` button opens channels screen;
/// - curated list is `GET /v1/news/curated`, channel has toggle
///   `curated-<id>`; tap sends `POST /v1/news/curated {"id", "enabled"}`;
/// - custom link: `channel-link` field, `channel-add` button ->
///   `POST /v1/news/channels {"link"}`; accepted channel appears in custom
///   channels list (`GET /v1/news/channels`); error `{"error": "not_public"}` gives
///   clear explanation about internal address, `{"error": "too_many"}` about limit;
/// - popular is `GET /v1/news/channels/popular`: name and subscriber count.
void main() {
  // News captions are bilingual (P-A84); Russian ones verified here.
  final dispatcher =
      TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher;
  setUp(() => dispatcher.localeTestValue = const Locale('ru'));
  tearDown(dispatcher.clearLocaleTestValue);
  setUp(
    () => SharedPreferences.setMockInitialValues({
      'news-consent': true,
      'news-enabled': true,
    }),
  );

  Future<Rig> channels(WidgetTester tester) async {
    usePhone(tester, phones['360']!);
    final rig = Rig();
    final own = <Map<String, Object?>>[];
    final curated = {'loud': true, 'zine': true};
    rig.server
      ..on('GET /v1/news', (_) => answer(200, sample('news')))
      ..on(
        'GET /v1/news/curated',
        (_) => answer(200, {
          'channels': [
            {
              'id': 'loud',
              'name': 'Loud Pages',
              'lang': 'en',
              'enabled': curated['loud'],
            },
            {
              'id': 'zine',
              'name': 'Zine Weekly',
              'lang': 'en',
              'enabled': curated['zine'],
            },
          ],
        }),
      )
      ..on('POST /v1/news/curated', (request) {
        final body = bodyOf(request);
        curated[body['id'] as String] = body['enabled'] as bool;
        return answer(200, {'status': 'ok'});
      })
      ..on('GET /v1/news/channels', (_) => answer(200, {'channels': own}))
      ..on('POST /v1/news/channels', (request) {
        final link = bodyOf(request)['link'] as String;
        if (link.contains('192.168.')) {
          return answer(400, {'error': 'not_public'});
        }
        final channel = {
          'id': '${own.length + 1}',
          'kind': 'telegram',
          'name': 'qlo_band',
          'feed_url': 'https://t.me/s/qlo_band',
          'artist': null,
        };
        own.add(channel);
        return answer(200, {'channel': channel});
      })
      ..on(
        'GET /v1/news/channels/popular',
        (_) => answer(200, {
          'channels': [
            {
              'kind': 'rss',
              'feed_url': 'https://three.example.org/rss',
              'name': 'Shared zine',
              'people': 3,
            },
          ],
        }),
      );
    await rig.screen(tester, (services) => NewsScreen(services: services));
    await tapAndSettle(tester, find.byKey(const Key('news-channels')));
    return rig;
  }

  testWidgets('curated channel toggle', (tester) async {
    final rig = await channels(tester);
    expect(find.text('Loud Pages'), findsOneWidget);
    await tapAndSettle(tester, find.byKey(const Key('curated-loud')));
    expect(rig.server.bodies('POST /v1/news/curated'), [
      {'id': 'loud', 'enabled': false},
    ]);
    expect(
      tester.widget<Switch>(find.byKey(const Key('curated-loud'))).value,
      isFalse,
    );
  });

  testWidgets('custom link: added to list, internal rejected with words', (
    tester,
  ) async {
    final rig = await channels(tester);
    final field = find.byKey(const Key('channel-link'));
    final add = find.byKey(const Key('channel-add'));

    await tester.ensureVisible(field);
    await tester.enterText(field, 'http://192.168.1.1/');
    await tapAndSettle(tester, add);
    expect(find.textContaining('внутренн'), findsOneWidget);
    expect(find.text('qlo_band'), findsNothing);

    await tester.enterText(field, '@qlo_band');
    await tapAndSettle(tester, add);
    expect(rig.server.bodies('POST /v1/news/channels').last, {
      'link': '@qlo_band',
    });
    expect(find.text('qlo_band'), findsOneWidget);
    expect(find.textContaining('внутренн'), findsNothing);
  });

  testWidgets('popular — name and subscriber count', (tester) async {
    await channels(tester);
    final popular = find.text('Shared zine');
    await tester.scrollUntilVisible(popular, 300);
    expect(popular, findsOneWidget);
    expect(find.textContaining('3'), findsWidgets);
  });
}
