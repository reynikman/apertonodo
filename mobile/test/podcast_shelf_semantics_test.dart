// FT-759: podcast shelf TalkBack row — single button with title and
// subtitle. Lead check — do not edit (P-A7).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/podcast_catalog_client.dart';
import 'package:music_stream/podcast_client.dart';
import 'package:music_stream/screens/podcasts_page.dart';

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

Future<List<String>> pump(WidgetTester tester) async {
  final opened = <String>[];
  await tester.pumpWidget(
    MaterialApp(
      home: PodcastsPage(
        texts: texts,
        search: (q, {required bool allLanguages}) async => <FoundPodcast>[],
        subscribed: const {},
        onSubscribe: (_) async => true,
        onOpenPodcast: (_) {},
        onOpenCategory: (_) {},
        onOpenItem: (i) => opened.add(i.id),
        onLanguages: () {},
        languagesFiltered: true,
        continueItems: const [
          PodcastShelfItem(
            id: 'c1',
            title: 'Выпуск 7',
            subtitle: 'Осталось 18 мин',
          ),
        ],
        newEpisodes: const [
          PodcastShelfItem(
            id: 'n1',
            title: 'Новый выпуск',
            subtitle: 'Подкаст А',
          ),
        ],
        subscriptions: const [],
        popular: const [],
        categories: const <PodcastCategory>[],
      ),
    ),
  );
  await tester.pump();
  return opened;
}

Finder key(String k) => find.byKey(ValueKey(k));

void main() {
  for (final (row, title, subtitle) in [
    ('continue-c1', 'Выпуск 7', 'Осталось 18 мин'),
    ('new-n1', 'Новый выпуск', 'Подкаст А'),
  ]) {
    testWidgets('$row: single button combining title and subtitle', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(tester);
      expect(
        tester.getSemantics(key(row)),
        isSemantics(
          label: '$title\n$subtitle',
          isButton: true,
          hasTapAction: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('$row: title and subtitle are not separate TalkBack stops', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(tester);
      final row_ = tester.getSemantics(key(row));
      expect(tester.getSemantics(find.text(title)).id, row_.id);
      expect(tester.getSemantics(find.text(subtitle)).id, row_.id);
      handle.dispose();
    });
  }

  testWidgets('TalkBack tap opens episode', (tester) async {
    final handle = tester.ensureSemantics();
    final opened = await pump(tester);
    tester.semantics.tap(find.semantics.byLabel('Выпуск 7\nОсталось 18 мин'));
    await tester.pump();
    expect(opened, ['c1']);
    handle.dispose();
  });
}
