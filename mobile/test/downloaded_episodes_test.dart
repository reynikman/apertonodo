import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/offline/download_queue.dart';
import 'package:music_stream/offline/track_store.dart';
import 'package:music_stream/podcast_downloads.dart';
import 'package:music_stream/screens/downloads_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

/// FT-803 (owner finding 12.10, item 12): downloaded podcast episodes appear
/// in "Downloaded" next to tracks. For this phone remembers episode
/// metadata (title, podcast name): file itself stored by numeric ID, and
/// after restart app would not know what it contains.
class _Store implements EpisodeStore {
  _Store(this.dir);

  final Directory dir;
  final Set<String> ready = {};

  File _file(String id) => File('${dir.path}/${id.replaceAll(':', '_')}');

  @override
  File partFile(String id, {required String format}) =>
      File('${_file(id).path}.$format.part');

  @override
  Future<File> commit(
    String id, {
    required String format,
    required Hold hold,
  }) async {
    ready.add(id);
    return _file(id);
  }

  @override
  Future<File?> fileFor(String id) async =>
      ready.contains(id) ? _file(id) : null;

  @override
  Future<void> remove(String id) async => ready.remove(id);

  @override
  Future<bool> roomForDownload() async => true;
}

class _NoTransfer implements FileTransfer {
  @override
  Future<bool> fetch(TransferJob job) async => false;

  @override
  Future<void> cancel(String trackId) async {}
}

void main() {
  const feed = 'https://feeds.example/show.xml';
  const guid = 'episode-42';
  const audio = 'https://cdn.example/episode-42.mp3';
  final id = PodcastDownloads.idFor(feed, guid);

  late Directory dir;
  late _Store store;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    dir = await Directory.systemTemp.createTemp('ft803');
    store = _Store(dir);
  });

  tearDown(() => dir.delete(recursive: true));

  PodcastDownloads fresh() => PodcastDownloads(
    store: store,
    transfer: _NoTransfer(),
    isMetered: () async => false,
    allowMobile: () async => true,
    prefs: prefs,
    namespace: 'test',
  );

  void describe(
    PodcastDownloads downloads, {
    String title = 'Выпуск сорок два',
  }) => downloads.describe(
    feedUrl: feed,
    guid: guid,
    enclosureUrl: audio,
    title: title,
    show: 'Передача о музыке',
    durationMs: 1800000,
  );

  /// File already on phone: `download` detects this and marks episode downloaded.
  Future<PodcastDownloads> withEpisode() async {
    store.ready.add(id);
    final downloads = fresh();
    describe(downloads);
    await downloads.download(feedUrl: feed, guid: guid, enclosureUrl: audio);
    return downloads;
  }

  group('downloaded episodes list', () {
    test('downloaded episode is named human-readably', () async {
      final downloads = await withEpisode();
      expect(downloads.episodes, hasLength(1));
      final episode = downloads.episodes.single;
      expect(episode.id, id);
      expect(episode.title, 'Выпуск сорок два');
      expect(episode.show, 'Передача о музыке');
      expect(episode.durationMs, 1800000);
      expect(episode.feedUrl, feed);
      expect(episode.guid, guid);
    });

    test('episode stays in place after app restart', () async {
      await withEpisode();
      final again = fresh();
      expect(again.episodes, isEmpty, reason: 'list empty before restore');
      await again.restore();
      expect(again.episodes.single.title, 'Выпуск сорок два');
      expect(
        again.stateOf(feed, guid),
        EpisodeDownloadState.onPhone,
        reason: 'podcast screen must also see episode downloaded',
      );
    });

    test('file missing: row gone after app restart', () async {
      await withEpisode();
      store.ready.clear();
      final again = fresh();
      await again.restore();
      expect(again.episodes, isEmpty);
      // And record does not persist: if file returned — row does not unasked.
      store.ready.add(id);
      final third = fresh();
      await third.restore();
      expect(third.episodes, isEmpty);
    });

    test('deleted: absent from list after restart', () async {
      final downloads = await withEpisode();
      await downloads.remove(feed, guid);
      expect(downloads.episodes, isEmpty);
      final again = fresh();
      await again.restore();
      expect(again.episodes, isEmpty);
    });

    test('downloading episode: absent from downloaded list', () async {
      final downloads = fresh();
      describe(downloads);
      expect(downloads.episodes, isEmpty);
    });

    test('class works as before without preferences store', () async {
      store.ready.add(id);
      final downloads = PodcastDownloads(
        store: store,
        transfer: _NoTransfer(),
        isMetered: () async => false,
        allowMobile: () async => true,
      );
      describe(downloads);
      await downloads.download(feedUrl: feed, guid: guid, enclosureUrl: audio);
      expect(downloads.episodes, hasLength(1));
      await downloads.restore();
    });
  });

  group('Downloaded screen', () {
    final played = <DownloadedEpisode>[];

    Future<PodcastDownloads> open(
      WidgetTester tester, {
      bool song = false,
    }) async {
      played.clear();
      late PodcastDownloads episodes;
      await tester.runAsync(() async => episodes = await withEpisode());
      await tester.pumpWidget(
        MaterialApp(
          home: DownloadsScreen(
            downloads: FakeDownloads(song ? [duality] : const []),
            play: (_, _) {},
            episodes: episodes,
            playEpisode: played.add,
          ),
        ),
      );
      await tester.pump();
      return episodes;
    }

    final row = find.byKey(Key('download-episode-row-$id'));

    testWidgets('episode in list with its episode title and podcast feed', (
      tester,
    ) async {
      await open(tester, song: true);
      expect(find.byKey(const Key('downloads-episodes-title')), findsOneWidget);
      expect(row, findsOneWidget);
      expect(
        find.descendant(of: row, matching: find.text('Выпуск сорок два')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: row,
          matching: find.textContaining('Передача о музыке'),
        ),
        findsOneWidget,
      );
      // Tracks have not gone anywhere.
      expect(find.byKey(Key('download-row-${duality.id}')), findsOneWidget);
      // Episodes header is below tracks.
      expect(
        tester.getTopLeft(find.byKey(const Key('downloads-episodes-title'))).dy,
        greaterThan(
          tester.getTopLeft(find.byKey(Key('download-row-${duality.id}'))).dy,
        ),
      );
    });

    testWidgets('no songs but episode present: does not show no downloads', (
      tester,
    ) async {
      await open(tester);
      expect(find.byKey(const Key('downloads-empty')), findsNothing);
      expect(row, findsOneWidget);
    });

    testWidgets('tap plays episode', (tester) async {
      await open(tester);
      await tester.tap(row);
      await tester.pump();
      expect(played.single.id, id);
    });

    testWidgets('trash bin removes episode from phone and from the list', (
      tester,
    ) async {
      final episodes = await open(tester);
      final remove = find.byKey(Key('download-episode-remove-$id'));
      expect(tester.getSize(remove).shortestSide, greaterThanOrEqualTo(48));
      await tester.runAsync(() async {
        await tester.tap(remove);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      expect(episodes.episodes, isEmpty);
      expect(store.ready, isEmpty);
      expect(row, findsNothing);
      expect(find.byKey(const Key('downloads-empty')), findsOneWidget);
    });

    testWidgets('screen remains unchanged without podcasts', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: DownloadsScreen(
            downloads: FakeDownloads([duality]),
            play: (_, _) {},
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('downloads-episodes-title')), findsNothing);
      expect(find.byKey(Key('download-row-${duality.id}')), findsOneWidget);
    });
  });
}
