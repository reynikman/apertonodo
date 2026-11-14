// FT-860: podcast and episode pictures in the app go through our server.
// Lead check — do not edit (P-A7).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/feed_order.dart';
import 'package:music_stream/podcast_client.dart';
import 'package:music_stream/podcast_downloads.dart';
import 'package:music_stream/screens/parts.dart' show podcastCoverPath;
import 'package:music_stream/screens/podcast_page.dart';
import 'package:music_stream/screens/podcasts_page.dart';

import 'podcast_page_test.dart' as page;
import 'podcasts_page_test.dart' as list;

const picture = 'https://cdn.example/show.jpg';

Widget art(String? image, String title, double size) => SizedBox(
  key: ValueKey('art-${image ?? 'none'}-$title'),
  width: size,
  height: size,
);

void main() {
  test('the phone asks our server, never the podcast site', () {
    expect(
      podcastCoverPath(picture),
      '/v1/covers/podcast/image?u=https%3A%2F%2Fcdn.example%2Fshow.jpg',
    );
    expect(podcastCoverPath(null), isNull);
    expect(podcastCoverPath(''), isNull);
  });

  testWidgets('every shelf row of the podcasts page has a picture', (
    tester,
  ) async {
    final podcast = FoundPodcast.fromJson({
      'feed_url': 'https://s1.example/feed.xml',
      'title': 'Подкаст s1',
      'image': picture,
    })!;
    await tester.pumpWidget(
      MaterialApp(
        home: PodcastsPage(
          texts: list.texts,
          search: (q, {required bool allLanguages}) async => const [],
          subscribed: const {},
          onSubscribe: (_) async => true,
          onOpenPodcast: (_) {},
          onOpenCategory: (_) {},
          onOpenItem: (_) {},
          onLanguages: () {},
          languagesFiltered: false,
          continueItems: const [
            PodcastShelfItem(
              id: 'c1',
              title: 'Выпуск 7',
              subtitle: 'Подкаст А',
              image: picture,
            ),
          ],
          subscriptions: [podcast],
          art: art,
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('art-$picture-Подкаст А')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('art-$picture-Подкаст s1')),
      findsOneWidget,
    );
  });

  testWidgets('the podcast page header shows the podcast picture', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PodcastPage(
          info: const PodcastPageInfo(
            feedUrl: page.feedA,
            title: 'Наука вслух',
            image: picture,
          ),
          episodes: const [],
          subscribed: false,
          onSubscribe: () async => true,
          order: FeedOrder.newestFirst,
          onOrder: (_) {},
          downloadState: (_) => EpisodeDownloadState.none,
          onDownload: (_) async => EpisodeDownloadResult.started,
          onPlay: (_) {},
          texts: page.texts,
          art: art,
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('art-$picture-Наука вслух')),
      findsOneWidget,
    );
  });
}
