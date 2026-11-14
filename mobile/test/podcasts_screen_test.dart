import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/feed_order.dart';
import 'package:music_stream/listening_languages.dart';
import 'package:music_stream/podcast_catalog_client.dart';
import 'package:music_stream/podcast_client.dart';
import 'package:music_stream/screens/catalog_screens.dart';
import 'package:music_stream/screens/parts.dart';
import 'package:music_stream/screens/podcast_screen.dart';
import 'package:music_stream/screens/podcasts_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';

/// FT-717: "Podcasts" screen assembles FT-714 page from server, while Browse
/// opens it via tile (P-A108: entry point like genre, separate page).
class FakeSource implements PodcastsSource {
  List<PodcastSubscription>? subs = const [
    PodcastSubscription(feedUrl: 'https://a.example/feed', title: 'Подписка А'),
  ];
  List<FoundPodcast>? popular = const [
    FoundPodcast(feedUrl: 'https://b.example/feed', title: 'Популярный Б'),
  ];
  List<PodcastCategory>? cats = const [
    PodcastCategory(id: 1301, ru: 'Искусство', en: 'Arts'),
  ];
  final subscribed = <String>[];
  final orders = <FeedOrder>[];

  /// Hold `episodes` responses: each request awaits its own Completer.
  bool holdEpisodes = false;
  final heldEpisodes = <Completer<List<PodcastEpisode>>>[];
  final topCategories = <int?>[];
  final topCountries = <String?>[];
  final holdTop = <String?, Completer<List<FoundPodcast>>>{};
  Completer<List<PodcastSubscription>>? holdSubs;
  List<FoundPodcast> categoryTop = const [
    FoundPodcast(feedUrl: 'https://d.example/feed', title: 'Из категории'),
  ];
  bool subscribeFails = false;
  List<PodcastEpisode>? episodeList = const [
    PodcastEpisode(
      guid: 'e1',
      title: 'Первый выпуск',
      audioUrl: 'https://a.example/1.mp3',
    ),
  ];
  int episodeCalls = 0;

  /// FT-752: new subscription episodes; `null` — server did not respond.
  List<NewPodcastEpisode>? fresh = const [];

  @override
  Future<List<NewPodcastEpisode>> newEpisodes() async =>
      fresh ?? (throw const PodcastException(PodcastFailure.broken));

  /// FT-756: in-progress episodes; `null` — server did not respond.
  List<ContinuePodcastEpisode>? resume = const [];

  @override
  Future<List<ContinuePodcastEpisode>> continueEpisodes() async =>
      resume ?? (throw const PodcastException(PodcastFailure.broken));
  int subsCalls = 0;

  @override
  Future<List<PodcastSubscription>> subscriptions() async {
    subsCalls++;
    final hold = holdSubs;
    if (hold != null) return hold.future;
    return subs ?? (throw const PodcastException(PodcastFailure.broken));
  }

  @override
  Future<List<FoundPodcast>> search(String query) async => const [
    FoundPodcast(feedUrl: 'https://c.example/feed', title: 'Найденный В'),
  ];

  @override
  Future<bool> subscribe(String feedUrl) async {
    if (subscribeFails) throw const PodcastException(PodcastFailure.broken);
    subscribed.add(feedUrl);
    return true;
  }

  @override
  Future<List<FoundPodcast>> top({int? category, String? country}) async {
    topCategories.add(category);
    topCountries.add(country);
    final hold = category == null ? holdTop.remove(country) : null;
    if (hold != null) return hold.future;
    if (category != null) return categoryTop;
    return popular ?? (throw const PodcastException(PodcastFailure.broken));
  }

  @override
  Future<List<PodcastEpisode>> episodes(
    String feedUrl, {
    FeedOrder order = FeedOrder.newestFirst,
  }) async {
    orders.add(order);
    episodeCalls++;
    if (holdEpisodes) {
      final held = Completer<List<PodcastEpisode>>();
      heldEpisodes.add(held);
      return held.future;
    }
    return episodeList ?? (throw const PodcastException(PodcastFailure.broken));
  }

  @override
  Future<List<PodcastCategory>> categories() async =>
      cats ?? (throw const PodcastException(PodcastFailure.broken));
}

class MemoryOrderBox implements FeedOrderBox {
  String? data;

  @override
  Future<String?> read() async => data;

  @override
  Future<void> write(String value) async => data = value;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<List<(String, String)>> pump(
    WidgetTester tester,
    FakeSource source, {
    ListeningLanguages? languages,
  }) async {
    final played = <(String, String)>[];
    await tester.pumpWidget(
      MaterialApp(
        home: PodcastsScreen(
          source: source,
          languages: languages ?? ListeningLanguages(phoneLanguage: () => 'ru'),
          orders: FeedOrderStore(MemoryOrderBox()),
          onPlay: (podcast, episode) =>
              played.add((podcast.feedUrl, episode.guid)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return played;
  }

  testWidgets('subscriptions, popular, and categories arrive from server', (
    tester,
  ) async {
    await pump(tester, FakeSource());
    expect(find.text('Подписка А'), findsOneWidget);
    expect(find.text('Популярный Б'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('category-1301')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const ValueKey('category-1301')), findsOneWidget);
  });

  testWidgets('failed shelf does not hide the rest', (tester) async {
    await pump(tester, FakeSource()..popular = null);
    expect(find.text('Подписка А'), findsOneWidget);
    expect(find.text('Популярный Б'), findsNothing);
  });

  testWidgets('all failed: message and retry, retry loads again', (
    tester,
  ) async {
    final source = FakeSource()
      ..subs = null
      ..popular = null
      ..cats = null
      ..fresh = null
      ..resume = null;
    await pump(tester, source);
    expect(find.text('Подписка А'), findsNothing);
    expect(find.byType(Message), findsOneWidget);
    source
      ..subs = const [
        PodcastSubscription(feedUrl: 'https://a.example/feed', title: 'Снова'),
      ]
      ..popular = const [];
    await tester.tap(find.byType(FilledButton).last);
    await tester.pumpAndSettle();
    expect(source.subsCalls, 2);
    expect(find.text('Снова'), findsOneWidget);
  });

  testWidgets('spinner shown while loading instead of empty page', (
    tester,
  ) async {
    final source = FakeSource()..holdSubs = Completer();
    await tester.pumpWidget(
      MaterialApp(
        home: PodcastsScreen(
          source: source,
          languages: ListeningLanguages(phoneLanguage: () => 'ru'),
          orders: FeedOrderStore(MemoryOrderBox()),
          onPlay: (_, _) {},
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('podcasts-loading')), findsOneWidget);
    source.holdSubs!.complete(const []);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('podcasts-loading')), findsNothing);
  });

  testWidgets('subscribing in popular pushes to server and adds to subs', (
    tester,
  ) async {
    final source = FakeSource();
    await pump(tester, source);
    await tester.tap(
      find.byKey(const ValueKey('popular-subscribe-https://b.example/feed')),
    );
    await tester.pumpAndSettle();
    expect(source.subscribed, ['https://b.example/feed']);
    expect(find.text('Популярный Б'), findsNWidgets(2));
  });

  testWidgets('category opens its page with top items for category', (
    tester,
  ) async {
    final source = FakeSource();
    await pump(tester, source);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('category-1301')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const ValueKey('category-1301')));
    await tester.pumpAndSettle();
    expect(source.topCategories, contains(1301));
    expect(find.text('Из категории'), findsOneWidget);
  });

  testWidgets('home subscription is visible on category page too', (
    tester,
  ) async {
    final source = FakeSource()
      ..categoryTop = const [
        FoundPodcast(feedUrl: 'https://b.example/feed', title: 'Популярный Б'),
      ];
    await pump(tester, source);
    await tester.tap(
      find.byKey(const ValueKey('popular-subscribe-https://b.example/feed')),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('category-1301')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const ValueKey('category-1301')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('subscribed-https://b.example/feed')),
      findsOneWidget,
    );
  });

  testWidgets('section has one header and one Back button', (tester) async {
    await pump(tester, FakeSource());
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('category-1301')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const ValueKey('category-1301')));
    await tester.pumpAndSettle();
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);
  });

  testWidgets('podcast page sub visible in section after Back', (tester) async {
    final source = FakeSource()
      ..categoryTop = const [
        FoundPodcast(feedUrl: 'https://b.example/feed', title: 'Популярный Б'),
      ];
    await pump(tester, source);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('category-1301')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const ValueKey('category-1301')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('subscribe-https://b.example/feed')),
      findsOneWidget,
    );
    await tester.tap(find.text('Популярный Б').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('podcast-subscribe')));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('subscribed-https://b.example/feed')),
      findsOneWidget,
    );
    expect(source.subscribed, ['https://b.example/feed']);
  });

  testWidgets('podcast opens episodes page, Listen callback wired', (
    tester,
  ) async {
    final played = await pump(tester, FakeSource());
    await tester.tap(find.text('Популярный Б'));
    await tester.pumpAndSettle();
    expect(find.byType(PodcastScreen), findsOneWidget);
    expect(find.text('Первый выпуск'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('episode-play-e1')));
    expect(played, [('https://b.example/feed', 'e1')]);
  });

  testWidgets('episodes failed: message and retry', (tester) async {
    final source = FakeSource()..episodeList = null;
    await pump(tester, source);
    await tester.tap(find.text('Популярный Б'));
    await tester.pumpAndSettle();
    expect(find.text('Первый выпуск'), findsNothing);
    source.episodeList = const [
      PodcastEpisode(
        guid: 'e2',
        title: 'Второй',
        audioUrl: 'https://a.example/2.mp3',
      ),
    ];
    await tester.tap(find.byType(FilledButton).last);
    await tester.pumpAndSettle();
    expect(source.episodeCalls, 2);
    expect(find.text('Второй'), findsOneWidget);
  });

  testWidgets('oldest-first fetches opposite feed end from server (FT-732)', (
    tester,
  ) async {
    final source = FakeSource();
    await pump(tester, source);
    await tester.tap(find.text('Популярный Б'));
    await tester.pumpAndSettle();
    expect(source.orders, [FeedOrder.newestFirst]);
    await tester.ensureVisible(find.byKey(const ValueKey('podcast-order')));
    await tester.tap(find.byKey(const ValueKey('podcast-order')));
    await tester.pumpAndSettle();
    expect(source.orders, [FeedOrder.newestFirst, FeedOrder.oldestFirst]);
    expect(find.text('Первый выпуск'), findsOneWidget);
  });

  testWidgets('order toggled thrice, stale error response — screen '
      'shows episodes (FT-732, review)', (tester) async {
    final source = FakeSource();
    await pump(tester, source);
    await tester.tap(find.text('Популярный Б'));
    await tester.pumpAndSettle();
    source.holdEpisodes = true;
    final order = find.byKey(const ValueKey('podcast-order'));
    await tester.ensureVisible(order);
    for (var i = 0; i < 3; i++) {
      await tester.tap(order);
      await tester.pump();
    }
    expect(source.heldEpisodes, hasLength(3));
    // First ("from 1st") fails while third ("from 1st") is still in flight.
    source.heldEpisodes[0].completeError(
      const PodcastException(PodcastFailure.broken),
    );
    await tester.pump();
    source.heldEpisodes[1].complete(source.episodeList!);
    source.heldEpisodes[2].complete(source.episodeList!);
    await tester.pumpAndSettle();
    expect(find.text('Не удалось загрузить выпуски'), findsNothing);
    expect(find.text('Первый выпуск'), findsOneWidget);
  });

  testWidgets('subscription from podcast page sent to server', (tester) async {
    final source = FakeSource();
    await pump(tester, source);
    await tester.tap(find.text('Популярный Б'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('podcast-subscribe')));
    await tester.pumpAndSettle();
    expect(source.subscribed, ['https://b.example/feed']);
  });

  testWidgets('subscribed podcast opens already subscribed', (tester) async {
    await pump(tester, FakeSource());
    await tester.tap(find.text('Подписка А'));
    await tester.pumpAndSettle();
    final button = tester.widget<ButtonStyleButton>(
      find
          .descendant(
            of: find.byKey(const ValueKey('podcast-subscribe')),
            matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
            matchRoot: true,
          )
          .first,
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('Languages opens language selection sheet', (tester) async {
    await pump(tester, FakeSource());
    await tester.tap(find.text('Языки'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('lang-all')), findsOneWidget);
  });

  group('catalog country by language (FT-723)', () {
    test('language gives country, all uses phone, other has no country', () {
      expect(podcastCountry(['ru'], 'en'), 'ru');
      expect(podcastCountry(['en', 'ru'], 'ru'), 'us');
      expect(podcastCountry(['uk'], 'ru'), 'ua');
      expect(podcastCountry(null, 'ru'), 'ru');
      expect(podcastCountry(null, 'xx'), isNull);
      for (final lang in knownLanguages) {
        expect(
          podcastCountryByLanguage[lang.code],
          matches(RegExp(r'^[a-z]{2}$')),
          reason: lang.code,
        );
      }
    });

    testWidgets('Russian: Popular and categories from Russian catalog', (
      tester,
    ) async {
      final source = FakeSource();
      await pump(tester, source);
      expect(source.topCountries, ['ru']);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('category-1301')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const ValueKey('category-1301')));
      await tester.pumpAndSettle();
      expect(source.topCountries.last, 'ru');
    });

    testWidgets('changing language reloads Popular for its country', (
      tester,
    ) async {
      final source = FakeSource();
      final languages = ListeningLanguages(phoneLanguage: () => 'ru');
      await pump(tester, source, languages: languages);
      languages.toggle(LanguageScope.podcasts, 'en');
      languages.toggle(LanguageScope.podcasts, 'ru');
      await tester.pumpAndSettle();
      expect(source.topCountries.last, 'us');
      final calls = source.topCountries.length;
      languages.toggle(LanguageScope.podcasts, 'de');
      await tester.pumpAndSettle();
      // German added second — initial country unchanged, no redundant request.
      expect(source.topCountries.length, calls);
    });

    testWidgets('late response from old country does not replace new', (
      tester,
    ) async {
      final source = FakeSource();
      final slowRu = source.holdTop['ru'] = Completer();
      final languages = ListeningLanguages(phoneLanguage: () => 'ru');
      await tester.pumpWidget(
        MaterialApp(
          home: PodcastsScreen(
            source: source,
            languages: languages,
            orders: FeedOrderStore(MemoryOrderBox()),
            onPlay: (_, _) {},
          ),
        ),
      );
      await tester.pump();
      source.popular = const [
        FoundPodcast(feedUrl: 'https://us.example/feed', title: 'Американский'),
      ];
      languages.toggle(LanguageScope.podcasts, 'en');
      languages.toggle(LanguageScope.podcasts, 'ru');
      await tester.pumpAndSettle();
      expect(find.text('Американский'), findsOneWidget);
      slowRu.complete(const [
        FoundPodcast(feedUrl: 'https://ru.example/feed', title: 'Российский'),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('Российский'), findsNothing);
      expect(find.text('Американский'), findsOneWidget);
    });
  });

  group('episodes without subscription (FT-723)', () {
    ServerPodcastsSource source(
      Future<PodcastReply> Function(String path) answer,
      List<String> paths,
    ) {
      Future<PodcastReply> send(
        String method,
        String path, {
        Map<String, String>? query,
        Object? body,
      }) {
        paths.add(path);
        return answer(path);
      }

      return ServerPodcastsSource(
        PodcastClient(send),
        PodcastCatalogClient(send),
      );
    }

    const episode = {
      'guid': 'g1',
      'title': 'Выпуск',
      'audio_url': 'https://a.example/1.mp3',
    };

    test('unsubscribed: episodes from feed via preview', () async {
      final paths = <String>[];
      final got = await source(
        (path) async => path == '/v1/podcasts/episodes'
            ? const PodcastReply(404, {'status': 'not_subscribed'})
            : const PodcastReply(200, {
                'episodes': [episode],
              }),
        paths,
      ).episodes('https://f.example/feed');
      expect(paths, ['/v1/podcasts/episodes', '/v1/podcasts/preview']);
      expect(got.single.guid, 'g1');
    });

    test('subscribed but crawl pending: also preview', () async {
      final paths = <String>[];
      final got = await source(
        (path) async => path == '/v1/podcasts/episodes'
            ? const PodcastReply(200, {'episodes': <Object>[]})
            : const PodcastReply(200, {
                'episodes': [episode],
              }),
        paths,
      ).episodes('https://f.example/feed');
      expect(paths.last, '/v1/podcasts/preview');
      expect(got, hasLength(1));
    });

    test('own episodes present: preview not needed', () async {
      final paths = <String>[];
      final got = await source(
        (_) async => const PodcastReply(200, {
          'episodes': [episode],
        }),
        paths,
      ).episodes('https://f.example/feed');
      expect(paths, ['/v1/podcasts/episodes']);
      expect(got, hasLength(1));
    });

    test('subscribed, empty feed, preview failed: empty, not error', () async {
      final got = await source(
        (path) async => path == '/v1/podcasts/episodes'
            ? const PodcastReply(200, {'episodes': <Object>[]})
            : const PodcastReply(503, {'status': 'podcast_feed_unavailable'}),
        [],
      ).episodes('https://f.example/feed');
      expect(got, isEmpty);
    });

    test('other error is not disguised as preview', () async {
      final paths = <String>[];
      await expectLater(
        source(
          (_) async => const PodcastReply(503, {'status': 'x'}),
          paths,
        ).episodes('https://f.example/feed'),
        throwsA(isA<PodcastException>()),
      );
      expect(paths, ['/v1/podcasts/episodes']);
    });

    test('preview failed: error, not empty list', () async {
      await expectLater(
        source(
          (path) async => path == '/v1/podcasts/episodes'
              ? const PodcastReply(404, {'status': 'not_subscribed'})
              : const PodcastReply(503, {'status': 'podcast_feed_unavailable'}),
          [],
        ).episodes('https://f.example/feed'),
        throwsA(isA<PodcastException>()),
      );
    });
  });

  group('tile in Browse', () {
    Future<void> browse(WidgetTester tester, {required bool podcasts}) async {
      final rig = Rig();
      rig.server.on(
        'GET /v1/genres',
        (_) => answer(200, {
          'genres': [
            {'id': 'rock', 'name': 'Рок', 'artists': 1},
          ],
        }),
      );
      final services = Services(
        server: rig.server.api(),
        search: rig.server.catalog().search,
        play: (_, _) {},
        prepare: (_) {},
        podcasts: podcasts
            ? (_) => const Scaffold(body: Text('ЭКРАН ПОДКАСТОВ'))
            : null,
      );
      await tester.pumpWidget(
        MaterialApp(home: GenresScreen(services: services)),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('has Podcasts: tile opens screen', (tester) async {
      await browse(tester, podcasts: true);
      expect(find.byKey(const Key('browse-podcasts')), findsOneWidget);
      await tester.tap(find.byKey(const Key('browse-podcasts')));
      await tester.pumpAndSettle();
      expect(find.text('ЭКРАН ПОДКАСТОВ'), findsOneWidget);
    });

    testWidgets('no Podcasts: no tile', (tester) async {
      await browse(tester, podcasts: false);
      expect(find.byKey(const Key('browse-podcasts')), findsNothing);
      expect(find.byKey(const ValueKey('genre-card-rock')), findsOneWidget);
    });

    testWidgets('360 dp and 2x font: tile does not overflow', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await browse(tester, podcasts: true);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('browse-podcasts')), findsOneWidget);
    });

    testWidgets('tile at least 48 dp with TalkBack label', (tester) async {
      await browse(tester, podcasts: true);
      final size = tester.getSize(find.byKey(const Key('browse-podcasts')));
      expect(size.height, greaterThanOrEqualTo(48));
      expect(find.bySemanticsLabel(RegExp('Подкасты')), findsOneWidget);
    });
  });

  // FT-752: "New Episodes" shelf — from server (`/v1/podcasts/new`).

  const freshOne = NewPodcastEpisode(
    feedUrl: 'https://a.example/feed',
    feedTitle: 'Подписка А',
    episode: PodcastEpisode(
      guid: 'n1',
      title: 'Свежий выпуск',
      audioUrl: 'https://a.example/n1.mp3',
    ),
  );

  testWidgets('fresh episodes: shelf with episode and podcast title, '
      'tap plays it', (tester) async {
    final played = await pump(tester, FakeSource()..fresh = const [freshOne]);
    expect(find.text('Новые выпуски'), findsOneWidget);
    expect(find.text('Свежий выпуск'), findsOneWidget);
    await tester.tap(find.text('Свежий выпуск'));
    await tester.pumpAndSettle();
    expect(played, [('https://a.example/feed', 'n1')]);
  });

  testWidgets('no fresh episodes: shelf omitted', (tester) async {
    await pump(tester, FakeSource());
    expect(find.text('Новые выпуски'), findsNothing);
    expect(find.text('Подписка А'), findsOneWidget);
  });

  testWidgets('fresh episodes failed: other shelves remain', (tester) async {
    await pump(tester, FakeSource()..fresh = null);
    expect(find.text('Новые выпуски'), findsNothing);
    expect(find.text('Подписка А'), findsOneWidget);
    expect(find.text('Популярный Б'), findsOneWidget);
  });

  // FT-752, second glance (Gemini 1).

  testWidgets('only fresh episodes arrived: shelf, not error screen', (
    tester,
  ) async {
    final source = FakeSource()
      ..subs = null
      ..popular = null
      ..cats = null
      ..fresh = const [freshOne];
    await pump(tester, source);
    expect(find.byType(Message), findsNothing);
    expect(find.text('Свежий выпуск'), findsOneWidget);
  });

  testWidgets('subscribed: fresh episodes shelf refreshed', (tester) async {
    final source = FakeSource();
    await pump(tester, source);
    expect(find.text('Свежий выпуск'), findsNothing);
    source.fresh = const [freshOne];
    await tester.scrollUntilVisible(
      find.text('Популярный Б'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Подписаться').first);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Свежий выпуск'),
      -200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Свежий выпуск'), findsOneWidget);
  });

  // FT-756: "Continue" shelf — from server (`/v1/podcasts/continue`).

  const resumeOne = ContinuePodcastEpisode(
    feedUrl: 'https://a.example/feed',
    feedTitle: 'Подписка А',
    positionMs: 125000,
    episode: PodcastEpisode(
      guid: 'c1',
      title: 'Начатый выпуск',
      audioUrl: 'https://a.example/c1.mp3',
    ),
  );

  testWidgets('in-progress episodes: Continue shelf with title and '
      'podcast, tap plays it', (tester) async {
    final played = await pump(tester, FakeSource()..resume = const [resumeOne]);
    expect(find.text('Продолжить'), findsOneWidget);
    expect(find.text('Начатый выпуск'), findsOneWidget);
    await tester.tap(find.text('Начатый выпуск'));
    await tester.pumpAndSettle();
    expect(played, [('https://a.example/feed', 'c1')]);
  });

  testWidgets('no in-progress: no Continue shelf', (tester) async {
    await pump(tester, FakeSource());
    expect(find.text('Продолжить'), findsNothing);
    expect(find.text('Подписка А'), findsOneWidget);
  });

  testWidgets('Continue failed: other shelves remain', (tester) async {
    await pump(
      tester,
      FakeSource()
        ..resume = null
        ..fresh = const [freshOne],
    );
    expect(find.text('Продолжить'), findsNothing);
    expect(find.text('Свежий выпуск'), findsOneWidget);
    expect(find.text('Популярный Б'), findsOneWidget);
  });

  testWidgets('only Continue arrived: shelf, not error screen', (tester) async {
    final source = FakeSource()
      ..subs = null
      ..popular = null
      ..cats = null
      ..fresh = null
      ..resume = const [resumeOne];
    await pump(tester, source);
    expect(find.byType(Message), findsNothing);
    expect(find.text('Начатый выпуск'), findsOneWidget);
  });

  testWidgets('episode both fresh and in-progress: both shelves, keys agree', (
    tester,
  ) async {
    const same = ContinuePodcastEpisode(
      feedUrl: 'https://a.example/feed',
      feedTitle: 'Подписка А',
      positionMs: 1000,
      episode: PodcastEpisode(
        guid: 'n1',
        title: 'Свежий выпуск',
        audioUrl: 'https://a.example/n1.mp3',
      ),
    );
    await pump(
      tester,
      FakeSource()
        ..fresh = const [freshOne]
        ..resume = const [same],
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Свежий выпуск'), findsNWidgets(2));
  });
}
