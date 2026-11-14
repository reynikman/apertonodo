// FT-713: podcast page (Pk-4). Lead check — do not edit (P-A7).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/feed_order.dart';
import 'package:music_stream/podcast_client.dart';
import 'package:music_stream/podcast_downloads.dart';
import 'package:music_stream/screens/podcast_page.dart';

const feedA = 'https://a.example/feed.xml';
const feedB = 'https://b.example/feed.xml';

PodcastEpisode ep(
  String guid, {
  String? title,
  DateTime? published,
  int? durationMs,
}) => PodcastEpisode.fromJson({
  'guid': guid,
  'title': title ?? 'Выпуск $guid',
  'audio_url': 'https://a.example/$guid.mp3',
  'published': ?published?.toUtc().toIso8601String(),
  'duration_ms': ?durationMs,
})!;

const texts = PodcastPageTexts(
  subscribe: 'Подписаться',
  subscribed: 'Вы подписаны',
  subscribeFailed: 'Не удалось подписаться',
  about: 'О подкасте',
  episodes: 'Выпуски',
  newestFirst: 'Сначала новые',
  oldestFirst: 'С первого',
  empty: 'Выпусков пока нет',
  untitled: 'Без названия',
  download: 'Скачать',
  downloading: 'Качается',
  onPhone: 'На телефоне',
  downloadFailed: 'Не удалось скачать',
  noRoom: 'Нет места',
  metered: 'Только по Wi-Fi',
  play: 'Играть',
  duration: _dur,
);

String _dur(int ms) => '${ms ~/ 60000} мин';

class Harness {
  PodcastPageInfo info = const PodcastPageInfo(
    feedUrl: feedA,
    title: 'Наука вслух',
    author: 'Автор А',
    description: 'Подробное описание подкаста',
    chips: ['Наука', 'Русский'],
  );
  List<PodcastEpisode> episodes = [
    ep('1', published: DateTime.utc(2026, 1, 1), durationMs: 30 * 60000),
    ep('2', published: DateTime.utc(2026, 3, 1)),
    ep('3', published: DateTime.utc(2026, 2, 1)),
  ];
  bool subscribed = false;
  FeedOrder order = FeedOrder.newestFirst;
  final orders = <FeedOrder>[];
  int subscribeCalls = 0;
  Future<bool> Function() subscribeAnswer = () async => true;
  final downloadCalls = <String>[];
  Future<EpisodeDownloadResult> Function(PodcastEpisode) downloadAnswer =
      (_) async => EpisodeDownloadResult.started;
  final states = <String, EpisodeDownloadState>{};
  final played = <String>[];
  Map<String, double?> progress = {};
  final notifier = ChangeNotifier();

  Widget build() => MaterialApp(
    home: PodcastPage(
      info: info,
      episodes: episodes,
      subscribed: subscribed,
      onSubscribe: () {
        subscribeCalls++;
        return subscribeAnswer();
      },
      order: order,
      onOrder: orders.add,
      downloadState: (e) => states[e.guid] ?? EpisodeDownloadState.none,
      onDownload: (e) {
        downloadCalls.add(e.guid);
        return downloadAnswer(e);
      },
      onPlay: (e) => played.add(e.guid),
      progress: (e) => progress[e.guid],
      downloads: notifier,
      texts: texts,
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

List<String> episodeOrder(WidgetTester tester) => tester
    .widgetList<Padding>(
      find.byWidgetPredicate(
        (w) =>
            w is Padding &&
            w.key is ValueKey<String> &&
            (w.key as ValueKey<String>).value.startsWith('episode-') &&
            !(w.key as ValueKey<String>).value.contains('-', 'episode-'.length),
      ),
    )
    .map((w) => (w.key as ValueKey<String>).value.substring('episode-'.length))
    .toList();

Finder episodeRow(String guid) => find.byKey(ValueKey('episode-$guid'));

Finder downloadButton(String guid) =>
    find.byKey(ValueKey('episode-download-$guid'));

/// FT-862 (Astra layout): download is an icon; its state is the tooltip TalkBack reads.
String downloadTip(WidgetTester tester, String guid) =>
    tester.widget<IconButton>(downloadButton(guid)).tooltip ?? '';

bool enabled(WidgetTester tester, Finder f) {
  final w = tester.widget(f);
  if (w is ButtonStyleButton) return w.onPressed != null;
  if (w is IconButton) return w.onPressed != null;
  throw StateError('not a button: $w');
}

void main() {
  group('header', () {
    testWidgets('title, author and chips', (tester) async {
      await pump(tester);
      expect(find.text('Наука вслух'), findsOneWidget);
      expect(find.text('Автор А'), findsOneWidget);
      expect(find.byKey(const ValueKey('podcast-chip-Наука')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('podcast-chip-Русский')),
        findsOneWidget,
      );
    });

    testWidgets('title is heading for TalkBack', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester);
      expect(
        tester.getSemantics(find.text('Наука вслух')),
        isSemantics(label: 'Наука вслух', isHeader: true),
      );
      handle.dispose();
    });

    testWidgets('About opens description sheet', (tester) async {
      await pump(tester);
      expect(find.text('Подробное описание подкаста'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('podcast-about')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('podcast-about-sheet')), findsOneWidget);
      expect(find.text('Подробное описание подкаста'), findsOneWidget);
    });

    testWidgets('no About button without description', (tester) async {
      await pump(
        tester,
        (h) => h.info = const PodcastPageInfo(
          feedUrl: feedA,
          title: 'Т',
          description: '  ',
        ),
      );
      expect(find.byKey(const ValueKey('podcast-about')), findsNothing);
    });

    testWidgets('empty author is not drawn as blank line', (tester) async {
      await pump(
        tester,
        (h) => h.info = const PodcastPageInfo(
          feedUrl: feedA,
          title: 'Т',
          author: '  ',
        ),
      );
      expect(find.text('  '), findsNothing);
    });
  });

  group('subscription', () {
    testWidgets('tap subscribes, button becomes Subscribed and dims', (
      tester,
    ) async {
      final h = await pump(tester);
      expect(find.text('Подписаться'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('podcast-subscribe')));
      await tester.pump();
      expect(h.subscribeCalls, 1);
      expect(find.text('Вы подписаны'), findsOneWidget);
      expect(
        enabled(tester, find.byKey(const ValueKey('podcast-subscribe'))),
        isFalse,
      );
    });

    testWidgets('already subscribed: disabled Subscribed', (tester) async {
      final h = await pump(tester, (h) => h.subscribed = true);
      expect(find.text('Вы подписаны'), findsOneWidget);
      expect(
        enabled(tester, find.byKey(const ValueKey('podcast-subscribe'))),
        isFalse,
      );
      expect(h.subscribeCalls, 0);
    });

    testWidgets('second tap while subscribing does not call again', (
      tester,
    ) async {
      final c = Completer<bool>();
      final h = await pump(tester, (h) => h.subscribeAnswer = () => c.future);
      await tester.tap(find.byKey(const ValueKey('podcast-subscribe')));
      await tester.pump();
      expect(
        enabled(tester, find.byKey(const ValueKey('podcast-subscribe'))),
        isFalse,
      );
      await tester.tap(
        find.byKey(const ValueKey('podcast-subscribe')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(h.subscribeCalls, 1);
      c.complete(true);
      await tester.pump();
      expect(find.text('Вы подписаны'), findsOneWidget);
    });

    testWidgets(
      'rejection: error text announced to TalkBack, button active again',
      (tester) async {
        final handle = tester.ensureSemantics();
        await pump(tester, (h) => h.subscribeAnswer = () async => false);
        await tester.tap(find.byKey(const ValueKey('podcast-subscribe')));
        await tester.pump();
        expect(find.text('Не удалось подписаться'), findsOneWidget);
        expect(
          tester.getSemantics(find.text('Не удалось подписаться')),
          isSemantics(isLiveRegion: true),
        );
        expect(find.text('Подписаться'), findsOneWidget);
        expect(
          enabled(tester, find.byKey(const ValueKey('podcast-subscribe'))),
          isTrue,
        );
        handle.dispose();
      },
    );

    testWidgets('exception: same error, page stays alive', (tester) async {
      await pump(
        tester,
        (h) => h.subscribeAnswer = () async => throw StateError('net'),
      );
      await tester.tap(find.byKey(const ValueKey('podcast-subscribe')));
      await tester.pump();
      expect(find.text('Не удалось подписаться'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('retry after rejection clears old error', (tester) async {
      var answer = false;
      await pump(tester, (h) => h.subscribeAnswer = () async => answer);
      await tester.tap(find.byKey(const ValueKey('podcast-subscribe')));
      await tester.pump();
      expect(find.text('Не удалось подписаться'), findsOneWidget);
      answer = true;
      await tester.tap(find.byKey(const ValueKey('podcast-subscribe')));
      await tester.pump();
      expect(find.text('Не удалось подписаться'), findsNothing);
      expect(find.text('Вы подписаны'), findsOneWidget);
    });

    testWidgets('late reply for other podcast: neither Subscribed nor error', (
      tester,
    ) async {
      final c = Completer<bool>();
      final h = await pump(tester, (h) => h.subscribeAnswer = () => c.future);
      await tester.tap(find.byKey(const ValueKey('podcast-subscribe')));
      await tester.pump();
      h.info = const PodcastPageInfo(feedUrl: feedB, title: 'Другой');
      await tester.pumpWidget(h.build());
      expect(find.text('Подписаться'), findsOneWidget);
      expect(
        enabled(tester, find.byKey(const ValueKey('podcast-subscribe'))),
        isTrue,
      );
      c.complete(true);
      await tester.pump();
      expect(find.text('Вы подписаны'), findsNothing);
      expect(find.text('Подписаться'), findsOneWidget);
    });

    testWidgets('late rejection for old podcast shows no error on new', (
      tester,
    ) async {
      final c = Completer<bool>();
      final h = await pump(tester, (h) => h.subscribeAnswer = () => c.future);
      await tester.tap(find.byKey(const ValueKey('podcast-subscribe')));
      await tester.pump();
      h.info = const PodcastPageInfo(feedUrl: feedB, title: 'Другой');
      await tester.pumpWidget(h.build());
      c.complete(false);
      await tester.pump();
      expect(find.text('Не удалось подписаться'), findsNothing);
    });

    testWidgets('subscription on one podcast does not move to another', (
      tester,
    ) async {
      final h = await pump(tester);
      await tester.tap(find.byKey(const ValueKey('podcast-subscribe')));
      await tester.pump();
      expect(find.text('Вы подписаны'), findsOneWidget);
      h.info = const PodcastPageInfo(feedUrl: feedB, title: 'Другой');
      await tester.pumpWidget(h.build());
      expect(find.text('Подписаться'), findsOneWidget);
      expect(
        enabled(tester, find.byKey(const ValueKey('podcast-subscribe'))),
        isTrue,
      );
    });

    testWidgets('retry immediately clears previous error', (tester) async {
      var c = Completer<bool>()..complete(false);
      await pump(tester, (h) => h.subscribeAnswer = () => c.future);
      await tester.tap(find.byKey(const ValueKey('podcast-subscribe')));
      await tester.pump();
      expect(find.text('Не удалось подписаться'), findsOneWidget);
      c = Completer<bool>();
      await tester.tap(find.byKey(const ValueKey('podcast-subscribe')));
      await tester.pump();
      expect(find.text('Не удалось подписаться'), findsNothing);
      c.complete(true);
      await tester.pump();
    });

    testWidgets('late response after leaving page does not crash app', (
      tester,
    ) async {
      final c = Completer<bool>();
      await pump(tester, (h) => h.subscribeAnswer = () => c.future);
      await tester.tap(find.byKey(const ValueKey('podcast-subscribe')));
      await tester.pump();
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      c.complete(false);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('episode order', () {
    testWidgets('Newest first: descending date order', (tester) async {
      await pump(tester);
      expect(episodeOrder(tester), ['2', '3', '1']);
      expect(find.text('Сначала новые'), findsOneWidget);
    });

    testWidgets('Oldest first: ascending date order', (tester) async {
      await pump(tester, (h) => h.order = FeedOrder.oldestFirst);
      expect(episodeOrder(tester), ['1', '3', '2']);
      expect(find.text('С первого'), findsOneWidget);
    });

    testWidgets(
      'undated episodes: at the end in either order, in original order',
      (tester) async {
        void setup(Harness h) => h.episodes = [
          ep('x'),
          ep('1', published: DateTime.utc(2026, 1, 1)),
          ep('y'),
          ep('2', published: DateTime.utc(2026, 2, 1)),
        ];
        await pump(tester, setup);
        expect(episodeOrder(tester), ['2', '1', 'x', 'y']);
        await pump(tester, (h) {
          setup(h);
          h.order = FeedOrder.oldestFirst;
        });
        expect(episodeOrder(tester), ['1', '2', 'x', 'y']);
      },
    );

    testWidgets('toggle requests reverse order', (tester) async {
      final h = await pump(tester);
      await tester.tap(find.byKey(const ValueKey('podcast-order')));
      expect(h.orders, [FeedOrder.oldestFirst]);
      final h2 = await pump(tester, (h) => h.order = FeedOrder.oldestFirst);
      await tester.tap(find.byKey(const ValueKey('podcast-order')));
      expect(h2.orders, [FeedOrder.newestFirst]);
    });

    test('orderEpisodes does not mutate given list', () {
      final list = [
        ep('1', published: DateTime.utc(2026, 1, 1)),
        ep('2', published: DateTime.utc(2026, 2, 1)),
      ];
      final sorted = orderEpisodes(list, FeedOrder.newestFirst);
      expect(sorted.map((e) => e.guid), ['2', '1']);
      expect(list.map((e) => e.guid), ['1', '2']);
    });

    testWidgets('empty list: No episodes yet', (tester) async {
      await pump(tester, (h) => h.episodes = []);
      expect(find.text('Выпусков пока нет'), findsOneWidget);
    });
  });

  group('episode', () {
    testWidgets('duration and Untitled', (tester) async {
      await pump(
        tester,
        (h) => h.episodes = [
          ep('1', durationMs: 30 * 60000),
          ep('2', title: '   '),
        ],
      );
      expect(
        find.descendant(of: episodeRow('1'), matching: find.text('30 мин')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: episodeRow('2'),
          matching: find.text('Без названия'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('progress is drawn only when started', (tester) async {
      await pump(tester, (h) => h.progress = {'1': 0.5, '2': 0.0});
      final bar = tester.widget<LinearProgressIndicator>(
        find.byKey(const ValueKey('episode-progress-1')),
      );
      expect(bar.value, 0.5);
      expect(find.byKey(const ValueKey('episode-progress-2')), findsNothing);
      expect(find.byKey(const ValueKey('episode-progress-3')), findsNothing);
    });

    testWidgets('Play emits this episode', (tester) async {
      final h = await pump(tester);
      await tester.tap(find.byKey(const ValueKey('episode-play-3')));
      expect(h.played, ['3']);
    });
  });

  group('download', () {
    testWidgets('labels and availability by state', (tester) async {
      await pump(tester, (h) {
        h.states['1'] = EpisodeDownloadState.downloading;
        h.states['2'] = EpisodeDownloadState.onPhone;
        h.states['3'] = EpisodeDownloadState.failed;
      });
      expect(downloadTip(tester, '1'), startsWith('Качается'));
      expect(enabled(tester, downloadButton('1')), isFalse);
      expect(downloadTip(tester, '2'), startsWith('На телефоне'));
      expect(enabled(tester, downloadButton('2')), isFalse);
      expect(downloadTip(tester, '3'), startsWith('Скачать'));
      expect(enabled(tester, downloadButton('3')), isTrue);
    });

    testWidgets('tap downloads this episode', (tester) async {
      final h = await pump(tester);
      await tester.tap(downloadButton('3'));
      await tester.pump();
      expect(h.downloadCalls, ['3']);
      expect(find.text('Не удалось скачать'), findsNothing);
    });

    testWidgets('second tap before start responds does not download twice', (
      tester,
    ) async {
      final c = Completer<EpisodeDownloadResult>();
      final h = await pump(tester, (h) => h.downloadAnswer = (_) => c.future);
      await tester.tap(downloadButton('1'));
      await tester.pump();
      expect(enabled(tester, downloadButton('1')), isFalse);
      expect(downloadTip(tester, '1'), startsWith('Качается'));
      await tester.tap(downloadButton('1'), warnIfMissed: false);
      await tester.pump();
      expect(h.downloadCalls, ['1']);
      expect(
        enabled(tester, downloadButton('2')),
        isTrue,
        reason: 'other episodes are not blocked',
      );
      c.complete(EpisodeDownloadResult.started);
      await tester.pump();
    });

    testWidgets('state change in downloads repaints button', (tester) async {
      final h = await pump(tester);
      h.states['1'] = EpisodeDownloadState.onPhone;
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      h.notifier.notifyListeners();
      await tester.pump();
      expect(downloadTip(tester, '1'), startsWith('На телефоне'));
    });

    for (final (result, message) in [
      (EpisodeDownloadResult.noRoom, 'Нет места'),
      (EpisodeDownloadResult.metered, 'Только по Wi-Fi'),
      (EpisodeDownloadResult.badUrl, 'Не удалось скачать'),
    ]) {
      testWidgets('rejection $result: "$message", announced to TalkBack', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await pump(tester, (h) => h.downloadAnswer = (_) async => result);
        await tester.tap(downloadButton('1'));
        await tester.pump();
        expect(find.text(message), findsOneWidget);
        expect(
          tester.getSemantics(find.text(message)),
          isSemantics(isLiveRegion: true),
        );
        expect(enabled(tester, downloadButton('1')), isTrue);
        handle.dispose();
      });
    }

    testWidgets('already on phone: no error', (tester) async {
      await pump(
        tester,
        (h) =>
            h.downloadAnswer = (_) async => EpisodeDownloadResult.alreadyThere,
      );
      await tester.tap(downloadButton('1'));
      await tester.pump();
      expect(find.byKey(const ValueKey('podcast-error')), findsNothing);
    });

    testWidgets('start exception: Failed to download, page alive', (
      tester,
    ) async {
      await pump(
        tester,
        (h) => h.downloadAnswer = (_) async => throw StateError('disk'),
      );
      await tester.tap(downloadButton('1'));
      await tester.pump();
      expect(find.text('Не удалось скачать'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('late rejection for old podcast shows no error on new', (
      tester,
    ) async {
      final c = Completer<EpisodeDownloadResult>();
      final h = await pump(tester, (h) => h.downloadAnswer = (_) => c.future);
      await tester.tap(downloadButton('1'));
      await tester.pump();
      h.info = const PodcastPageInfo(feedUrl: feedB, title: 'Другой');
      await tester.pumpWidget(h.build());
      expect(
        enabled(tester, downloadButton('1')),
        isTrue,
        reason: 'new podcast had nothing started',
      );
      c.complete(EpisodeDownloadResult.noRoom);
      await tester.pump();
      expect(find.text('Нет места'), findsNothing);
    });

    testWidgets('late response after leaving page does not crash app', (
      tester,
    ) async {
      final c = Completer<EpisodeDownloadResult>();
      await pump(tester, (h) => h.downloadAnswer = (_) => c.future);
      await tester.tap(downloadButton('1'));
      await tester.pump();
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      c.complete(EpisodeDownloadResult.noRoom);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('return 1', () {
    testWidgets(
      'failed download: episode error text, TalkBack announced, Download available',
      (tester) async {
        final handle = tester.ensureSemantics();
        await pump(tester, (h) => h.states['1'] = EpisodeDownloadState.failed);
        final failed = find.byKey(const ValueKey('episode-failed-1'));
        expect(
          find.descendant(of: episodeRow('1'), matching: failed),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: failed,
            matching: find.text('Не удалось скачать'),
          ),
          findsOneWidget,
        );
        expect(tester.getSemantics(failed), isSemantics(isLiveRegion: true));
        expect(find.byKey(const ValueKey('episode-failed-2')), findsNothing);
        expect(downloadTip(tester, '1'), startsWith('Скачать'));
        expect(enabled(tester, downloadButton('1')), isTrue);
        handle.dispose();
      },
    );

    testWidgets('episode buttons name episode for TalkBack', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester);
      for (final k in ['episode-play-3', 'episode-download-3']) {
        final node = tester.getSemantics(find.byKey(ValueKey(k)));
        final spoken = '${node.label} ${node.tooltip}';
        expect(spoken, contains('Выпуск 3'), reason: k);
      }
      final play = tester.getSemantics(
        find.byKey(const ValueKey('episode-play-3')),
      );
      expect('${play.label} ${play.tooltip}', contains('Играть'));
      final dl = tester.getSemantics(
        find.byKey(const ValueKey('episode-download-3')),
      );
      expect('${dl.label} ${dl.tooltip}', contains('Скачать'));
      handle.dispose();
    });
  });

  group('dimensions', () {
    testWidgets('all buttons at least 48 dp', (tester) async {
      await pump(tester);
      for (final key in [
        const ValueKey('podcast-subscribe'),
        const ValueKey('podcast-about'),
        const ValueKey('podcast-order'),
        const ValueKey('episode-download-1'),
        const ValueKey('episode-play-1'),
      ]) {
        final size = tester.getSize(find.byKey(key));
        expect(size.height, greaterThanOrEqualTo(48), reason: '$key');
        expect(size.width, greaterThanOrEqualTo(48), reason: '$key');
      }
    });

    testWidgets('360 dp and 2x large font: no overflow', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final h = Harness()
        ..info = const PodcastPageInfo(
          feedUrl: feedA,
          title:
              'Очень длинное название подкаста, которое никак не помещается в одну строку',
          author: 'Очень длинное имя автора подкаста',
          description: 'Описание',
          chips: ['Общество и культура', 'Русский', 'English'],
        )
        ..episodes = [
          ep(
            '1',
            title: 'Длинное-предлинное название выпуска ' * 3,
            durationMs: 90 * 60000,
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
}
