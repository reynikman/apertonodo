// FT-714: "Podcasts" page (Pk-2). Lead check — do not edit (P-A7).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/podcast_catalog_client.dart';
import 'package:music_stream/podcast_client.dart';
import 'package:music_stream/screens/podcasts_page.dart';

FoundPodcast pod(String id, {String author = ''}) => FoundPodcast.fromJson({
  'feed_url': 'https://$id.example/feed.xml',
  'title': 'Подкаст $id',
  'author': author,
})!;

String feed(String id) => 'https://$id.example/feed.xml';

final texts = PodcastsPageTexts(
  searchHint: 'Найти подкаст',
  languages: 'Языки контента · 2 выбрано',
  continueTitle: 'Продолжить',
  newEpisodes: 'Новые выпуски',
  subscriptions: 'Подписки',
  popular: 'Популярное',
  categories: 'Категории',
  subscribe: 'Подписаться',
  subscribed: 'Вы подписаны',
  subscribeFailed: 'Не удалось подписаться',
  searchFailed: 'Поиск не удался',
  nothingFound: 'Ничего не нашлось',
  searchAllLanguages: 'Искать на всех языках',
  categoryTitle: (c) => c.ru,
);

class Call {
  Call(this.query, this.allLanguages);
  final String query;
  final bool allLanguages;
  final completer = Completer<List<FoundPodcast>>();
}

class Harness {
  final calls = <Call>[];
  bool autoAnswer = true;
  List<FoundPodcast> Function(String q, bool all) answer = (q, all) => [
    pod('r1'),
    pod('r2'),
  ];
  Set<String> subscribed = {};
  int subscribeCalls = 0;
  Future<bool> Function(FoundPodcast) subscribeAnswer = (_) async => true;
  final opened = <String>[];
  final categoriesOpened = <int>[];
  final items = <String>[];
  int languagesTaps = 0;
  bool languagesFiltered = true;
  List<PodcastShelfItem> continueItems = const [
    PodcastShelfItem(id: 'c1', title: 'Выпуск 7', subtitle: 'Осталось 18 мин'),
  ];
  List<PodcastShelfItem> newEpisodes = const [
    PodcastShelfItem(id: 'n1', title: 'Новый выпуск', subtitle: 'Подкаст А'),
  ];
  List<FoundPodcast> subscriptions = [pod('s1')];
  List<FoundPodcast> popular = [pod('p1', author: 'Автор П')];
  List<PodcastCategory> categories = const [
    PodcastCategory(id: 1533, ru: 'Наука', en: 'Science'),
    PodcastCategory(id: 1487, ru: 'История', en: 'History'),
  ];

  Widget Function(String? image, String title, double size)? art;

  Widget build() => MaterialApp(
    home: PodcastsPage(
      texts: texts,
      search: (q, {required bool allLanguages}) {
        final c = Call(q, allLanguages);
        calls.add(c);
        if (autoAnswer) c.completer.complete(answer(q, allLanguages));
        return c.completer.future;
      },
      subscribed: subscribed,
      onSubscribe: (p) {
        subscribeCalls++;
        return subscribeAnswer(p);
      },
      onOpenPodcast: (p) => opened.add(p.feedUrl),
      onOpenCategory: (c) => categoriesOpened.add(c.id),
      onOpenItem: (i) => items.add(i.id),
      onLanguages: () => languagesTaps++,
      languagesFiltered: languagesFiltered,
      continueItems: continueItems,
      newEpisodes: newEpisodes,
      subscriptions: subscriptions,
      popular: popular,
      categories: categories,
      art: art,
    ),
  );
}

Future<Harness> pump(
  WidgetTester tester, [
  void Function(Harness h)? setup,
]) async {
  final h = Harness();
  setup?.call(h);
  await tester.pumpWidget(h.build());
  await tester.pump();
  return h;
}

Future<void> search(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const ValueKey('podcasts-search')), text);
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pump();
}

Finder key(String k) => find.byKey(ValueKey(k));

bool enabled(WidgetTester tester, Finder f) {
  final w = tester.widget(f);
  if (w is ButtonStyleButton) return w.onPressed != null;
  throw StateError('not a button: $w');
}

void main() {
  group('home', () {
    testWidgets(
      'sections in order: field, languages, continue, fresh, subs, popular, categories',
      (tester) async {
        await pump(tester);
        double y(String text) => tester.getTopLeft(find.text(text)).dy;
        final order = [
          'Найти подкаст',
          'Языки контента · 2 выбрано',
          'Продолжить',
          'Новые выпуски',
          'Подписки',
          'Популярное',
          'Категории',
        ];
        await tester.binding.setSurfaceSize(const Size(800, 3000));
        await tester.pump();
        for (var i = 1; i < order.length; i++) {
          expect(
            y(order[i - 1]) < y(order[i]),
            isTrue,
            reason: '${order[i - 1]} is above ${order[i]}',
          );
        }
        await tester.binding.setSurfaceSize(null);
      },
    );

    testWidgets('section titles are TalkBack headings', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester);
      expect(
        tester.getSemantics(find.text('Продолжить')),
        isSemantics(label: 'Продолжить', isHeader: true),
      );
      expect(
        tester.getSemantics(find.text('Категории')),
        isSemantics(label: 'Категории', isHeader: true),
      );
      handle.dispose();
    });

    testWidgets('empty sections are not drawn', (tester) async {
      await pump(tester, (h) {
        h.continueItems = const [];
        h.newEpisodes = const [];
        h.subscriptions = const [];
        h.popular = const [];
        h.categories = const [];
      });
      for (final t in [
        'Продолжить',
        'Новые выпуски',
        'Подписки',
        'Популярное',
        'Категории',
      ]) {
        expect(find.text(t), findsNothing, reason: t);
      }
      expect(find.text('Найти подкаст'), findsOneWidget);
      expect(key('podcasts-languages'), findsOneWidget);
    });

    testWidgets('no For You or Editors Choice (P-A108 p.2)', (tester) async {
      await pump(tester);
      expect(find.textContaining('Для вас'), findsNothing);
      expect(find.textContaining('редакц'), findsNothing);
    });

    testWidgets('language row opens selector', (tester) async {
      final h = await pump(tester);
      await tester.tap(key('podcasts-languages'));
      expect(h.languagesTaps, 1);
    });

    testWidgets('Continue and New Episodes open their episode, with subtitle', (
      tester,
    ) async {
      final h = await pump(tester);
      expect(find.text('Осталось 18 мин'), findsOneWidget);
      await tester.tap(key('continue-c1'));
      await tester.tap(key('new-n1'));
      expect(h.items, ['c1', 'n1']);
    });

    testWidgets('subscriptions: no subscribe button, openable', (tester) async {
      final h = await pump(tester);
      expect(key('sub-subscribe-${feed('s1')}'), findsNothing);
      // Shelves of tiles are taller than rows: scroll to the tile first.
      await tester.ensureVisible(key('sub-${feed('s1')}'));
      await tester.tap(key('sub-${feed('s1')}'));
      expect(h.opened, [feed('s1')]);
    });

    testWidgets('popular: with author and subscribe button', (tester) async {
      final h = await pump(tester);
      expect(find.text('Автор П'), findsOneWidget);
      await tester.ensureVisible(key('popular-subscribe-${feed('p1')}'));
      await tester.tap(key('popular-subscribe-${feed('p1')}'));
      await tester.pump();
      expect(h.subscribeCalls, 1);
      expect(
        find.descendant(
          of: key('popular-subscribe-${feed('p1')}'),
          matching: find.text('Вы подписаны'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('category opens its section, title localized via texts', (
      tester,
    ) async {
      final h = await pump(tester);
      expect(find.text('История'), findsOneWidget);
      await tester.ensureVisible(key('category-1487'));
      await tester.pumpAndSettle();
      await tester.tap(key('category-1487'));
      expect(h.categoriesOpened, [1487]);
    });
  });

  group('search', () {
    testWidgets('query: search results replace main, with sub', (tester) async {
      final h = await pump(tester);
      await search(tester, '  наука  ');
      expect(h.calls.single.query, 'наука');
      expect(h.calls.single.allLanguages, isFalse);
      expect(key('result-${feed('r1')}'), findsOneWidget);
      expect(key('result-subscribe-${feed('r2')}'), findsOneWidget);
      expect(find.text('Продолжить'), findsNothing);
      expect(find.text('Категории'), findsNothing);
    });

    testWidgets('empty query does not hit server', (tester) async {
      final h = await pump(tester);
      await search(tester, '   ');
      expect(h.calls, isEmpty);
      expect(find.text('Продолжить'), findsOneWidget);
    });

    testWidgets('spinner shown while searching', (tester) async {
      await pump(tester, (h) => h.autoAnswer = false);
      await search(tester, 'наука');
      expect(key('podcasts-searching'), findsOneWidget);
    });

    testWidgets('cleared query restores home page', (tester) async {
      await pump(tester);
      await search(tester, 'наука');
      await tester.enterText(key('podcasts-search'), '');
      await tester.pump();
      expect(find.text('Продолжить'), findsOneWidget);
      expect(key('result-${feed('r1')}'), findsNothing);
    });

    testWidgets('late response for old query does not overwrite new', (
      tester,
    ) async {
      final h = await pump(tester, (h) => h.autoAnswer = false);
      await search(tester, 'первый');
      await search(tester, 'второй');
      h.calls[1].completer.complete([pod('new')]);
      await tester.pump();
      h.calls[0].completer.complete([pod('old')]);
      await tester.pump();
      expect(key('result-${feed('new')}'), findsOneWidget);
      expect(key('result-${feed('old')}'), findsNothing);
    });

    testWidgets(
      'late response after clearing query does not replace home page',
      (tester) async {
        final h = await pump(tester, (h) => h.autoAnswer = false);
        await search(tester, 'наука');
        await tester.enterText(key('podcasts-search'), '');
        await tester.pump();
        h.calls[0].completer.complete([pod('late')]);
        await tester.pump();
        expect(find.text('Продолжить'), findsOneWidget);
        expect(key('result-${feed('late')}'), findsNothing);
      },
    );

    testWidgets('late error from old query is not displayed', (tester) async {
      final h = await pump(tester, (h) => h.autoAnswer = false);
      await search(tester, 'первый');
      await search(tester, 'второй');
      h.calls[1].completer.complete([pod('new')]);
      await tester.pump();
      h.calls[0].completer.completeError(StateError('net'));
      await tester.pump();
      expect(find.text('Поиск не удался'), findsNothing);
    });

    testWidgets('response after leaving page does not crash app', (
      tester,
    ) async {
      final h = await pump(tester, (h) => h.autoAnswer = false);
      await search(tester, 'наука');
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      h.calls[0].completer.complete([pod('x')]);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'search error text announced to TalkBack; new search clears it',
      (tester) async {
        final handle = tester.ensureSemantics();
        final h = await pump(tester, (h) => h.autoAnswer = false);
        await search(tester, 'наука');
        h.calls[0].completer.completeError(StateError('net'));
        await tester.pump();
        expect(find.text('Поиск не удался'), findsOneWidget);
        expect(
          key('podcasts-nothing'),
          findsNothing,
          reason: 'failure is not treated as nothing found',
        );
        expect(
          tester.getSemantics(find.text('Поиск не удался')),
          isSemantics(isLiveRegion: true),
        );
        await search(tester, 'наука');
        expect(find.text('Поиск не удался'), findsNothing);
        handle.dispose();
      },
    );

    testWidgets(
      'empty with language filter: Search all languages, filter stays',
      (tester) async {
        final h = await pump(
          tester,
          (h) => h.answer = (q, all) => all ? [pod('any')] : [],
        );
        await search(tester, 'редкое');
        expect(key('podcasts-nothing'), findsOneWidget);
        await tester.tap(key('podcasts-all-languages'));
        await tester.pump();
        expect(h.calls.last.query, 'редкое');
        expect(h.calls.last.allLanguages, isTrue);
        expect(h.languagesTaps, 0);
        expect(key('result-${feed('any')}'), findsOneWidget);
      },
    );

    testWidgets('empty on all languages: button disappears', (tester) async {
      await pump(tester, (h) => h.answer = (q, all) => []);
      await search(tester, 'редкое');
      await tester.tap(key('podcasts-all-languages'));
      await tester.pump();
      expect(key('podcasts-nothing'), findsOneWidget);
      expect(key('podcasts-all-languages'), findsNothing);
    });

    testWidgets('new query searches filtered languages again', (tester) async {
      final h = await pump(tester, (h) => h.answer = (q, all) => []);
      await search(tester, 'редкое');
      await tester.tap(key('podcasts-all-languages'));
      await tester.pump();
      await search(tester, 'другое');
      expect(h.calls.last.allLanguages, isFalse);
      expect(key('podcasts-all-languages'), findsOneWidget);
    });

    testWidgets('no languages selected (all): no Search all languages button', (
      tester,
    ) async {
      await pump(tester, (h) {
        h.languagesFiltered = false;
        h.answer = (q, all) => [];
      });
      await search(tester, 'редкое');
      expect(key('podcasts-nothing'), findsOneWidget);
      expect(key('podcasts-all-languages'), findsNothing);
    });
  });

  group('subscription', () {
    testWidgets('already subscribed: disabled Subscribed', (tester) async {
      final h = await pump(tester, (h) => h.subscribed = {feed('r1')});
      await search(tester, 'наука');
      final b = key('result-subscribe-${feed('r1')}');
      expect(
        find.descendant(of: b, matching: find.text('Вы подписаны')),
        findsOneWidget,
      );
      expect(enabled(tester, b), isFalse);
      expect(h.subscribeCalls, 0);
    });

    testWidgets(
      'second tap while subscribing does not call again; others not blocked',
      (tester) async {
        final c = Completer<bool>();
        final h = await pump(
          tester,
          (h) => h.subscribeAnswer = (_) => c.future,
        );
        await search(tester, 'наука');
        final b = key('result-subscribe-${feed('r1')}');
        await tester.tap(b);
        await tester.pump();
        expect(enabled(tester, b), isFalse);
        await tester.tap(b, warnIfMissed: false);
        await tester.pump();
        expect(h.subscribeCalls, 1);
        expect(enabled(tester, key('result-subscribe-${feed('r2')}')), isTrue);
        c.complete(true);
        await tester.pump();
        expect(
          find.descendant(of: b, matching: find.text('Вы подписаны')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'rejection and exception: error announced to TalkBack, retryable',
      (tester) async {
        final handle = tester.ensureSemantics();
        var n = 0;
        await pump(
          tester,
          (h) =>
              h.subscribeAnswer = (_) async =>
                  n++ == 0 ? false : throw StateError('x'),
        );
        await search(tester, 'наука');
        final b = key('result-subscribe-${feed('r1')}');
        await tester.tap(b);
        await tester.pump();
        expect(find.text('Не удалось подписаться'), findsOneWidget);
        expect(
          tester.getSemantics(find.text('Не удалось подписаться')),
          isSemantics(isLiveRegion: true),
        );
        expect(enabled(tester, b), isTrue);
        await tester.tap(b);
        await tester.pump();
        expect(find.text('Не удалось подписаться'), findsOneWidget);
        expect(tester.takeException(), isNull);
        handle.dispose();
      },
    );

    testWidgets('subscription in search shows in popular for same podcast', (
      tester,
    ) async {
      await pump(tester, (h) => h.answer = (q, all) => [pod('p1')]);
      await search(tester, 'п');
      await tester.tap(key('result-subscribe-${feed('p1')}'));
      await tester.pump();
      await tester.enterText(key('podcasts-search'), '');
      await tester.pump();
      expect(
        find.descendant(
          of: key('popular-subscribe-${feed('p1')}'),
          matching: find.text('Вы подписаны'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('subscribe response after leaving page does not crash app', (
      tester,
    ) async {
      final c = Completer<bool>();
      await pump(tester, (h) => h.subscribeAnswer = (_) => c.future);
      await tester.tap(key('popular-subscribe-${feed('p1')}'));
      await tester.pump();
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      c.complete(false);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('dimensions', () {
    testWidgets('buttons and rows at least 48 dp', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 3000));
      await pump(tester);
      for (final k in [
        'podcasts-languages',
        'continue-c1',
        'new-n1',
        'sub-${feed('s1')}',
        'popular-subscribe-${feed('p1')}',
        'category-1533',
      ]) {
        expect(
          tester.getSize(key(k)).height,
          greaterThanOrEqualTo(48),
          reason: k,
        );
      }
      expect(
        tester.getSize(key('popular-subscribe-${feed('p1')}')).width,
        greaterThanOrEqualTo(48),
      );
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('360 dp and 2x large font: no overflow', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final h = Harness()
        ..popular = [
          pod(
            'очень-длинный-адрес-подкаста',
            author: 'Очень длинное имя автора подкаста ' * 2,
          ),
        ]
        ..categories = const [
          PodcastCategory(
            id: 1,
            ru: 'Общество и культура',
            en: 'Society & Culture',
          ),
        ];
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 800),
            textScaler: TextScaler.linear(2),
          ),
          child: h.build(),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('return 1: second glance', () {
    testWidgets('unsubscribe at parent re-enables subscribe', (tester) async {
      final h = await pump(tester);
      await search(tester, 'наука');
      final b = key('result-subscribe-${feed('r1')}');
      await tester.tap(b);
      await tester.pump();
      h.subscribed = {feed('r1')};
      await tester.pumpWidget(h.build());
      await tester.pump();
      h.subscribed = {};
      await tester.pumpWidget(h.build());
      await tester.pump();
      expect(
        find.descendant(of: b, matching: find.text('Подписаться')),
        findsOneWidget,
      );
      expect(enabled(tester, b), isTrue);
    });

    testWidgets('nothing found announced to TalkBack', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester, (h) => h.answer = (q, all) => []);
      await search(tester, 'наука');
      expect(
        tester.getSemantics(key('podcasts-nothing')),
        isSemantics(isLiveRegion: true),
      );
      handle.dispose();
    });

    testWidgets('subscribe button names podcast', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester);
      await search(tester, 'наука');
      expect(
        tester.getSemantics(key('result-subscribe-${feed('r1')}')).label,
        contains('Подкаст r1'),
      );
      handle.dispose();
    });
  });
}
