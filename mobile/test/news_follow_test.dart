import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/screens/catalog_screens.dart';
import 'package:music_stream/screens/news_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';
import 'golden_support.dart';

/// FT-580 (P-A83): "Follow" artist and empty feed suggestions.
///
/// Contract:
/// - on artist page button `artist-follow`: "Follow" / "Following";
///   state from `GET /v1/news/follows` (by artist `id`), tap sends
///   `POST /v1/news/follows` or `/v1/news/follows/remove` with `{"artist_id"}`;
/// - empty feed requests `GET /v1/news/suggestions` ->
///   `{"source": "history"|"popular", "artists": [{"id", "name"}]}`; for
///   `history` — header "You often listen to", names and `news-follow-all`,
///   which follows all displayed artists.
void main() {
  // News captions are bilingual (P-A84); Russian ones verified here.
  final dispatcher =
      TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher;
  setUp(() => dispatcher.localeTestValue = const Locale('ru'));
  tearDown(dispatcher.clearLocaleTestValue);
  // News consent already granted: consent screen is FT-581, here is feed.
  setUp(
    () => SharedPreferences.setMockInitialValues({
      'news-consent': true,
      'news-enabled': true,
    }),
  );

  const metallica = '65f4f0c5-ef9e-490c-aee3-909e7ae6b2ab';

  Rig withFollows() {
    final rig = Rig();
    final follows = <String>{};
    rig.server
      ..on(
        'GET /v1/news/follows',
        (_) => answer(200, {
          'artists': [
            for (final id in follows) {'id': id, 'name': 'Metallica'},
          ],
        }),
      )
      ..on('POST /v1/news/follows', (request) {
        follows.add(bodyOf(request)['artist_id'] as String);
        return answer(200, {'status': 'ok'});
      })
      ..on('POST /v1/news/follows/remove', (request) {
        follows.remove(bodyOf(request)['artist_id']);
        return answer(200, {'status': 'ok'});
      });
    return rig;
  }

  Future<void> artist(WidgetTester tester, Rig rig) async {
    await rig.screen(
      tester,
      (services) => ArtistScreen(services: services, name: 'Metallica'),
    );
  }

  final follow = find.byKey(const Key('artist-follow'));

  testWidgets('«Follow» toggles and persists across new screen', (
    tester,
  ) async {
    usePhone(tester, phones['360']!);
    final rig = withFollows();
    await artist(tester, rig);
    expect(
      find.descendant(of: follow, matching: find.text('Следить')),
      findsOneWidget,
    );

    await tester.ensureVisible(follow);
    await tapAndSettle(tester, follow);
    expect(rig.server.bodies('POST /v1/news/follows'), [
      {'artist_id': metallica},
    ]);
    expect(
      find.descendant(of: follow, matching: find.text('Вы следите')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
    await artist(tester, rig);
    expect(
      find.descendant(of: follow, matching: find.text('Вы следите')),
      findsOneWidget,
      reason: 'follow lost after screen restart',
    );

    await tester.ensureVisible(follow);
    await tapAndSettle(tester, follow);
    expect(rig.server.bodies('POST /v1/news/follows/remove'), [
      {'artist_id': metallica},
    ]);
    expect(
      find.descendant(of: follow, matching: find.text('Следить')),
      findsOneWidget,
    );
  });

  testWidgets('empty feed: shows «Often listened» and «Follow all»', (
    tester,
  ) async {
    usePhone(tester, phones['360']!);
    final rig = withFollows();
    rig.server
      ..on('GET /v1/news', (_) => answer(200, {'items': const []}))
      ..on(
        'GET /v1/news/suggestions',
        (_) => answer(200, {
          'source': 'history',
          'artists': [
            {'id': metallica, 'name': 'Metallica'},
            {'id': '4d02e204-826c-47b8-bfd3-2c8c0e1d1355', 'name': 'Кино'},
          ],
        }),
      );
    await rig.screen(tester, (services) => NewsScreen(services: services));

    expect(find.textContaining('Ты часто слушаешь'), findsOneWidget);
    expect(find.text('Metallica'), findsOneWidget);
    expect(find.text('Кино'), findsOneWidget);
    await tapAndSettle(tester, find.byKey(const Key('news-follow-all')));
    expect(
      {
        for (final body in rig.server.bodies('POST /v1/news/follows'))
          body['artist_id'],
      },
      {metallica, '4d02e204-826c-47b8-bfd3-2c8c0e1d1355'},
    );
  });
}
