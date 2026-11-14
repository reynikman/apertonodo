import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_stream/auth/token_provider.dart';
import 'package:music_stream/models/track.dart';
import 'package:music_stream/offline/download_queue.dart';
import 'package:music_stream/offline/downloads.dart';
import 'package:music_stream/offline/track_store.dart';
import 'package:music_stream/screens/catalog_screens.dart';
import 'package:music_stream/screens/downloads_screen.dart';
import 'package:music_stream/screens/library_screens.dart';
import 'package:music_stream/screens/parts.dart';
import 'package:music_stream/server_api.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fake_server.dart';
import 'fakes.dart';

/// "Download" and Downloads properly (FT-528, P-A60, rules 3, 4, 6, 7, 9).
///
/// On track, album, playlist, and "Favorites" — "download" button: circle while
/// downloading, checkmark when downloaded on device. "Downloads" — list with progress,
/// size, and "delete", free space, toggle "download on
/// cellular", and cache size. Downloaded playlist auto-downloads new tracks.
/// Offline screens requiring server redirect to downloads.
const gib = 1024 * 1024 * 1024;

Track song(int n) => Track(
  id: '00000000-0000-4000-8000-00000000000$n',
  title: 'Song $n',
  artist: 'Band',
  durationMs: 200000,
  artworkUrl: '',
);

const albumId = 'aaaaaaaa-0000-4000-8000-000000000001';
const playlistId = 'bbbbbbbb-0000-4000-8000-000000000001';

/// Downloading spinner spins continuously, so `pumpAndSettle` will not wait
/// for animation end — pump several frames instead.
Future<void> frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
}

Finder state(String name) => find.byKey(Key('download-state-$name'));

void main() {
  group('«download» buttons', () {
    late Rig rig;
    late FakeDownloads downloads;
    late List<(List<Track>, int)> played;

    Future<void> screen(
      WidgetTester tester,
      Widget Function(Services services) build,
    ) async {
      addTearDown(() => expect(rig.server.unknown, isEmpty));
      final services = Services(
        server: rig.server.api(),
        search: rig.server.catalog().search,
        play: (tracks, index) => played.add((tracks, index)),
        prepare: (_) {},
        downloads: downloads,
      );
      await tester.pumpWidget(MaterialApp(home: build(services)));
      await frames(tester);
    }

    setUp(() {
      rig = Rig();
      downloads = FakeDownloads();
      played = [];
      rig.server.on(
        'GET /v1/albums/*',
        (_) => answer(200, sample('catalog-album')),
      );
      rig.server.on(
        'GET /v1/playlists/*',
        (_) => answer(200, sample('library-playlist')),
      );
      rig.server.on(
        'GET /v1/favorites',
        (_) => answer(200, sample('library-favorites')),
      );
    });

    List<String> idsOf(String name) => [
      for (final track in sample(name)['tracks'] as List)
        (track as Map)['id'] as String,
    ];

    testWidgets('album: button, then spinner, then checkmark', (tester) async {
      await screen(
        tester,
        (s) => AlbumScreen(services: s, id: albumId, title: 'Альбом'),
      );
      final button = find.byKey(const Key('download-album'));
      expect(button, findsOneWidget);
      expect(
        find.descendant(of: button, matching: state('none')),
        findsOneWidget,
      );

      await tester.tap(button);
      await frames(tester);
      // Record with nested list compares by reference — compare fields individually.
      expect(downloads.asked.single.$1, idsOf('catalog-album'));
      expect(downloads.asked.single.$2, isNull);
      expect(
        find.descendant(of: button, matching: state('progress')),
        findsOneWidget,
      );

      for (final id in idsOf('catalog-album')) {
        downloads.set(id, DownloadStatus.done);
      }
      await frames(tester);
      expect(
        find.descendant(of: button, matching: state('done')),
        findsOneWidget,
      );
    });

    testWidgets('downloaded song in list shows checkmark', (tester) async {
      final id = idsOf('catalog-album').first;
      downloads.tracks[id] = song(1);
      downloads.set(id, DownloadStatus.done);
      await screen(
        tester,
        (s) => AlbumScreen(services: s, id: albumId, title: 'Альбом'),
      );
      final mark = find.byKey(Key('track-download-$id'));
      expect(mark, findsOneWidget);
      expect(find.descendant(of: mark, matching: state('done')), findsOne);
    });

    testWidgets('playlist: download all and sync new songs', (tester) async {
      await screen(
        tester,
        (s) => PlaylistScreen(services: s, id: playlistId, name: 'Мой'),
      );
      expect(downloads.loadedPlaylists.single.$1, playlistId);
      expect(
        downloads.loadedPlaylists.single.$2,
        idsOf('library-playlist'),
        reason: 'opened playlist checked against downloads',
      );
      await tester.tap(find.byKey(const Key('download-playlist')));
      await frames(tester);
      expect(downloads.asked.single.$1, idsOf('library-playlist'));
      expect(downloads.asked.single.$2, playlistId);
    });

    testWidgets('«Favorites» downloaded entirely', (tester) async {
      await screen(tester, (s) => FavoritesScreen(services: s));
      await tester.tap(find.byKey(const Key('download-favorites')));
      await frames(tester);
      expect(downloads.asked.single.$1, idsOf('library-favorites'));
    });

    testWidgets('without «Downloads» buttons hidden', (tester) async {
      addTearDown(() => expect(rig.server.unknown, isEmpty));
      final services = Services(
        server: rig.server.api(),
        search: rig.server.catalog().search,
        play: (_, _) {},
        prepare: (_) {},
      );
      await tester.pumpWidget(
        MaterialApp(
          home: AlbumScreen(services: services, id: albumId, title: 'Альбом'),
        ),
      );
      await frames(tester);
      expect(find.byKey(const Key('download-album')), findsNothing);
    });

    testWidgets('offline screen links to downloads', (tester) async {
      rig.server.on(
        'GET /v1/albums/*',
        (_) => throw const SocketException('нет сети'),
      );
      await screen(
        tester,
        (s) => AlbumScreen(services: s, id: albumId, title: 'Альбом'),
      );
      expect(find.text('Сервер не ответил'), findsOneWidget);
      final offline = find.byKey(const Key('offline-downloads'));
      expect(offline, findsOneWidget);
      await tester.tap(offline);
      await frames(tester);
      expect(find.byType(DownloadsScreen), findsOneWidget);
    });
  });

  group('«Downloads» screen', () {
    late FakeDownloads downloads;
    late List<(List<Track>, int)> played;

    Future<void> open(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: DownloadsScreen(
            downloads: downloads,
            play: (tracks, index) => played.add((tracks, index)),
          ),
        ),
      );
      await frames(tester);
    }

    setUp(() {
      downloads = FakeDownloads([song(1), song(2)]);
      downloads.bytes[song(1).id] = 5 * 1024 * 1024;
      downloads.tracks[song(3).id] = song(3);
      downloads.statuses[song(3).id] = DownloadStatus.downloading;
      played = [];
    });

    testWidgets('list: title, artist, size, progress', (tester) async {
      await open(tester);
      final list = find.byKey(const Key('downloads-list'));
      for (final n in [1, 2, 3]) {
        final row = find.byKey(Key('download-row-${song(n).id}'));
        expect(find.descendant(of: list, matching: row), findsOneWidget);
        expect(
          find.descendant(of: row, matching: find.text('Song $n')),
          findsOneWidget,
        );
      }
      final first = find.byKey(Key('download-row-${song(1).id}'));
      expect(
        find.descendant(of: first, matching: find.textContaining('5')),
        findsWidgets,
        reason: 'size in megabytes',
      );
      final third = find.byKey(Key('download-row-${song(3).id}'));
      expect(find.descendant(of: third, matching: state('progress')), findsOne);
      final progress = tester.widget<Text>(
        find.byKey(const Key('downloads-progress')),
      );
      expect(progress.data, contains('2'));
      expect(progress.data, contains('3'));
    });

    testWidgets('tap plays downloaded tracks in order', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(Key('download-row-${song(2).id}')));
      await frames(tester);
      final (tracks, index) = played.single;
      expect([for (final t in tracks) t.id], [song(1).id, song(2).id]);
      expect(index, 1);
    });

    testWidgets('«delete» removes from phone', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(Key('download-remove-${song(1).id}')));
      await frames(tester);
      expect(downloads.removed.single, [song(1).id]);
      expect(find.byKey(Key('download-row-${song(1).id}')), findsNothing);
    });

    testWidgets('cellular data network toggle, turned off by default', (
      tester,
    ) async {
      await open(tester);
      final toggle = find.byKey(const Key('downloads-allow-mobile'));
      expect(tester.widget<Switch>(toggle).value, isFalse);
      await tester.tap(toggle);
      await frames(tester);
      expect(downloads.allowMobile, isTrue);
    });

    testWidgets('paused — explanation shown', (tester) async {
      downloads.hold = QueueHold.metered;
      await open(tester);
      final hold = tester.widget<Text>(find.byKey(const Key('downloads-hold')));
      expect(hold.data, contains('мобильн'));

      downloads.hold = QueueHold.noRoom;
      downloads.notifyListeners();
      await frames(tester);
      final room = tester.widget<Text>(find.byKey(const Key('downloads-hold')));
      expect(room.data, contains('мест'));
    });

    testWidgets('free space is visible', (tester) async {
      downloads.freeBytes = 12 * gib;
      await open(tester);
      final free = tester.widget<Text>(find.byKey(const Key('downloads-free')));
      expect(free.data, contains('12'));
    });

    testWidgets('empty message is shown', (tester) async {
      downloads = FakeDownloads();
      await open(tester);
      expect(find.byKey(const Key('downloads-empty')), findsOneWidget);
    });
  });

  group('real «Downloads» backed by queue', () {
    const base = 'https://music.example';
    const account = 'account/https%3A%2F%2Fmusic.example/42';
    late Directory root;
    late TrackStore store;
    late QueueServer server;

    Future<Downloads> open() async {
      final queue = DownloadQueue(
        server: ServerApi(
          base,
          tokens: TokenProvider(
            EmptySessionStore()..cachedToken = 'secret-session-token-01234',
            server: Uri.parse(base),
          ),
          client: server.client,
        ),
        store: store,
        transfer: Transfer(),
        isMetered: () async => false,
      );
      final downloads = Downloads(
        queue: queue,
        store: store,
        poll: const Duration(milliseconds: 10),
      );
      await downloads.load();
      return downloads;
    }

    Future<void> settle(Downloads downloads) async {
      for (
        var i = 0;
        i < 100 && downloads.progress.done < downloads.progress.total;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    setUpAll(sqfliteFfiInit);

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      root = await Directory.systemTemp.createTemp('offline_downloads_test');
      store = await TrackStore.open(
        root: root,
        namespace: account,
        databaseFactory: databaseFactoryFfi,
        now: DateTime.now,
        freeBytes: () async => 50 * gib,
      );
      server = QueueServer();
    });

    tearDown(() async {
      await store.close();
      if (root.existsSync()) await root.delete(recursive: true);
    });

    test('download polls until settled, then goes idle', () async {
      final downloads = await open();
      var changes = 0;
      downloads.addListener(() => changes++);
      await downloads.download([song(1), song(2)]);
      await settle(downloads);
      expect(downloads.progress, (done: 2, total: 2));
      expect(downloads.markOf([song(1).id, song(2).id]), DownloadMark.done);
      expect(downloads.items.map((i) => i.bytes), [2000, 2000]);
      expect(changes, greaterThan(0));
      final polls = server.polls;
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(server.polls, polls, reason: 'all downloaded — polling stops');
    });

    test('downloaded track titles survive offline restart', () async {
      final first = await open();
      await first.download([song(1)]);
      await settle(first);
      first.dispose();
      server.down = true;
      final again = await open();
      expect(again.items.single.track.title, 'Song 1');
      expect(again.items.single.status, DownloadStatus.done);
      again.dispose();
    });

    test('downloaded playlist syncs new tracks, others do not', () async {
      final downloads = await open();
      await downloads.download([song(1)], playlist: 'p1');
      await settle(downloads);
      server.asked.clear();
      await downloads.playlistLoaded('p1', [song(1), song(2)]);
      expect(server.asked, [
        [song(2).id],
      ]);
      await downloads.playlistLoaded('p2', [song(3)]);
      expect(server.asked, hasLength(1));
      downloads.dispose();
    });

    test(
      'playlist deleted from phone does not automatically re-sync (FT-540)',
      () async {
        final downloads = await open();
        await downloads.download([song(1)], playlist: 'p1');
        await settle(downloads);
        await downloads.remove([song(1).id], playlist: 'p1');
        server.asked.clear();
        await downloads.playlistLoaded('p1', [song(1), song(2)]);
        expect(
          server.asked,
          isEmpty,
          reason: 'deleted playlist re-downloaded upon open',
        );
        downloads.dispose();
        final again = await open();
        await again.playlistLoaded('p1', [song(1)]);
        expect(server.asked, isEmpty, reason: 'after restart as well');
        again.dispose();
      },
    );

    test('«delete» removes both file and entry', () async {
      final downloads = await open();
      await downloads.download([song(1)]);
      await settle(downloads);
      await downloads.remove([song(1).id]);
      expect(downloads.items, isEmpty);
      expect(await store.fileFor(song(1).id), isNull);
      downloads.dispose();
    });

    test('spinner while downloading; nothing beforehand', () async {
      final downloads = await open();
      expect(downloads.markOf([song(1).id]), DownloadMark.none);
      server.hold = true;
      await downloads.download([song(1)]);
      expect(downloads.markOf([song(1).id]), DownloadMark.progress);
      downloads.dispose();
    });

    test('cache reserve size saved to storage', () async {
      final downloads = await open();
      await downloads.setReserveLimit(4 * gib);
      expect(await store.reserveLimitBytes(), 4 * gib);
      expect(downloads.reserveLimitBytes, 4 * gib);
      downloads.dispose();
    });
  });

  group('app', () {
    test('MusicApp gets «Downloads», production wires real one', () {
      final main = File('lib/main.dart').readAsStringSync();
      expect(main, contains('Downloads('));
      expect(main, contains('BackgroundTransfer('));
      final app = File('lib/app.dart').readAsStringSync();
      expect(app, isNot(contains('AccountDownloads')));
    });
  });
}

/// Queue server: ready immediately, 2000 bytes, unless [hold].
class QueueServer {
  final asked = <List<String>>[];
  final items = <String, Map<String, Object?>>{};
  var polls = 0;
  var down = false;
  var hold = false;

  late final client = MockClient((request) async {
    if (down) return http.Response('{}', 503);
    final path = request.url.path;
    if (request.method == 'POST' && path == '/v1/downloads') {
      final ids = [
        for (final id in jsonDecode(request.body)['track_ids'] as List) '$id',
      ];
      asked.add(ids);
      for (final id in ids) {
        items[id] = {
          'track_id': id,
          'state': hold ? 'preparing' : 'ready',
          'format': hold ? null : 'opus',
          'bytes': hold ? null : 2000,
        };
      }
      return http.Response(
        jsonEncode({
          'items': [for (final id in ids) items[id]],
        }),
        202,
      );
    }
    if (request.method == 'GET' && path == '/v1/downloads') {
      polls++;
      return http.Response(jsonEncode({'items': items.values.toList()}), 200);
    }
    if (request.method == 'POST' && path == '/v1/downloads/remove') {
      for (final id in jsonDecode(request.body)['track_ids'] as List) {
        items.remove('$id');
      }
      return http.Response('', 204);
    }
    return http.Response('{}', 404);
  });
}

class Transfer implements FileTransfer {
  @override
  Future<bool> fetch(TransferJob job) async {
    await job.file.parent.create(recursive: true);
    await job.file.writeAsBytes(List.filled(job.expectedBytes, 7));
    return true;
  }

  @override
  Future<void> cancel(String trackId) async {}
}
