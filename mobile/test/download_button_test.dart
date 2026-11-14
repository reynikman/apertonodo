import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/models/track.dart';
import 'package:music_stream/offline/download_queue.dart';
import 'package:music_stream/screens/catalog_screens.dart';
import 'package:music_stream/screens/library_screens.dart';
import 'package:music_stream/screens/parts.dart';

import 'fake_server.dart';
import 'fakes.dart';

/// "Download" button communicates with words (FT-540, P-A64).
///
/// Owner on 03.10 opened "Favorites" and saw a checkmark without a label: "What is this
/// checkmark about and why — unclear. Tapped it — everything got selected and won't deselect".
/// Now on "Favorites", playlist, and album button is labeled — "Download all",
/// "Downloading N of M", "Downloaded to device", and tapping downloaded item
/// opens sheet with "Delete from device".
const albumId = 'aaaaaaaa-0000-4000-8000-000000000001';
const playlistId = 'bbbbbbbb-0000-4000-8000-000000000001';

/// Progress spinner spins continuously — `pumpAndSettle` will never finish.
Future<void> frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  late Rig rig;
  late FakeDownloads downloads;

  setUp(() {
    rig = Rig();
    downloads = FakeDownloads();
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

  Future<void> screen(
    WidgetTester tester,
    Widget Function(Services services) build,
  ) async {
    addTearDown(() => expect(rig.server.unknown, isEmpty));
    final services = Services(
      server: rig.server.api(),
      search: rig.server.catalog().search,
      play: (_, _) {},
      prepare: (_) {},
      downloads: downloads,
    );
    await tester.pumpWidget(MaterialApp(home: build(services)));
    await frames(tester);
  }

  List<String> idsOf(String name) => [
    for (final track in sample(name)['tracks'] as List)
      (track as Map)['id'] as String,
  ];

  Finder label(Finder button, String text) =>
      find.descendant(of: button, matching: find.text(text));

  final remove = find.text('Удалить с телефона');

  /// Downloaded — icon only (FT-795, owner finding 12.10: "is text row
  /// even needed?"). No words on screen, they are in long-press tooltip.
  Finder doneMark(Finder button) => find.descendant(
    of: button,
    matching: find.byKey(const Key('download-state-done')),
  );

  void expectMarkOnly(WidgetTester tester, Finder button) {
    expect(label(button, 'Скачано на телефон'), findsNothing);
    expect(doneMark(button), findsOneWidget);
    expect(
      find.descendant(
        of: button,
        matching: find.byTooltip('Скачано на телефон'),
      ),
      findsOneWidget,
    );
    // Icon without words remains a touch-friendly button.
    expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(button).width, lessThan(100));
  }

  testWidgets('album: Download All -> Downloading N of M -> Downloaded', (
    tester,
  ) async {
    // Fixture has one track, while "1 of M" is shown only for two or more.
    final album = sample('catalog-album');
    final first = Map<String, dynamic>.of(
      (album['tracks'] as List).first as Map<String, dynamic>,
    );
    album['tracks'] = [
      first,
      {...first, 'id': '00000000-0000-4000-8000-000000000540', 'position': 2},
    ];
    rig.server.on('GET /v1/albums/*', (_) => answer(200, album));
    await screen(
      tester,
      (s) => AlbumScreen(services: s, id: albumId, title: 'Альбом'),
    );
    final ids = [
      for (final track in album['tracks'] as List)
        (track as Map)['id'] as String,
    ];
    final button = find.byKey(const Key('download-album'));
    expect(
      label(button, 'Скачать все'),
      findsOneWidget,
      reason: 'button without label: unclear what it does',
    );

    await tester.tap(button);
    await frames(tester);
    expect(downloads.asked, hasLength(1));
    expect(
      label(button, 'Скачивается 0 из ${ids.length}'),
      findsOneWidget,
      reason: 'while downloading, not visible how many on phone',
    );

    downloads.set(ids.first, DownloadStatus.done);
    await frames(tester);
    expect(label(button, 'Скачивается 1 из ${ids.length}'), findsOneWidget);

    for (final id in ids) {
      downloads.set(id, DownloadStatus.done);
    }
    await frames(tester);
    expectMarkOnly(tester, button);
    // Phone test looks for checkmark inside button — it remains.
    expect(
      find.descendant(
        of: button,
        matching: find.byKey(const Key('download-state-done')),
      ),
      findsOneWidget,
    );
  });

  testWidgets('album: downloaded deleted from phone via bottom sheet', (
    tester,
  ) async {
    final ids = idsOf('catalog-album');
    for (final id in ids) {
      downloads.set(id, DownloadStatus.done);
    }
    await screen(
      tester,
      (s) => AlbumScreen(services: s, id: albumId, title: 'Альбом'),
    );
    final button = find.byKey(const Key('download-album'));
    await tester.tap(button);
    await frames(tester);
    expect(downloads.asked, isEmpty, reason: 'downloaded is downloaded again');
    expect(
      remove,
      findsOneWidget,
      reason: 'tap on downloaded did not open Delete from phone sheet',
    );

    await tester.tap(remove);
    await frames(tester);
    expect(downloads.removed.single, ids);
    expect(downloads.removedPlaylists.single, isNull);
    expect(remove, findsNothing, reason: 'sheet did not close');
    expect(label(button, 'Скачать все'), findsOneWidget);
  });

  testWidgets('while downloading: same sheet allows cancel', (tester) async {
    await screen(tester, (s) => FavoritesScreen(services: s));
    final ids = idsOf('library-favorites');
    final button = find.byKey(const Key('download-favorites'));
    await tester.tap(button);
    await frames(tester);
    expect(label(button, 'Скачивается 0 из ${ids.length}'), findsOneWidget);

    await tester.tap(button);
    await frames(tester);
    expect(
      downloads.asked,
      hasLength(1),
      reason: 'second tap downloads yet another time',
    );
    expect(remove, findsOneWidget);
    await tester.tap(remove);
    await frames(tester);
    expect(downloads.removed.single, ids);
    expect(label(button, 'Скачать все'), findsOneWidget);
  });

  testWidgets('Favorites: label and removal', (tester) async {
    final ids = idsOf('library-favorites');
    for (final id in ids) {
      downloads.tracks[id] = Track(
        id: id,
        title: 'Song',
        artist: 'Band',
        durationMs: 200000,
        artworkUrl: '',
      );
      downloads.bytes[id] = 3 * 1024 * 1024;
      downloads.set(id, DownloadStatus.done);
    }
    await screen(tester, (s) => FavoritesScreen(services: s));
    final button = find.byKey(const Key('download-favorites'));
    expectMarkOnly(tester, button);
    await tester.tap(button);
    await frames(tester);
    // Promised to owner: sheet reports how much space will be freed.
    final n = ids.length;
    expect(
      find.text('На телефоне: $n ${n == 1 ? 'песня' : 'песни'} · ${3 * n} МБ'),
      findsOneWidget,
    );
    await tester.tap(remove);
    await frames(tester);
    expect(downloads.removed.single, ids);
  });

  testWidgets('playlist: removal forgets playlist itself', (tester) async {
    final ids = idsOf('library-playlist');
    for (final id in ids) {
      downloads.set(id, DownloadStatus.done);
    }
    await screen(
      tester,
      (s) => PlaylistScreen(services: s, id: playlistId, name: 'Мой'),
    );
    final button = find.byKey(const Key('download-playlist'));
    expectMarkOnly(tester, button);
    await tester.tap(button);
    await frames(tester);
    await tester.tap(remove);
    await frames(tester);
    expect(downloads.removed.single, ids);
    // Otherwise next time playlist opens it would "download new" — meaning
    // everything just deleted.
    expect(
      downloads.removedPlaylists.single,
      playlistId,
      reason: 'playlist removed from phone but kept in fetch new',
    );
  });

  testWidgets('Favorites: long press on icon speaks description words', (
    tester,
  ) async {
    for (final id in idsOf('library-favorites')) {
      downloads.set(id, DownloadStatus.done);
    }
    await screen(tester, (s) => FavoritesScreen(services: s));
    final button = find.byKey(const Key('download-favorites'));
    expect(find.text('Скачано на телефон'), findsNothing);
    await tester.longPress(doneMark(button));
    await frames(tester);
    expect(find.text('Скачано на телефон'), findsOneWidget);
    // Long press only explains: deletion sheet is not opened.
    expect(remove, findsNothing);
  });

  testWidgets('Favorites: before download, labeled button as before', (
    tester,
  ) async {
    await screen(tester, (s) => FavoritesScreen(services: s));
    final button = find.byKey(const Key('download-favorites'));
    expect(label(button, 'Скачать все'), findsOneWidget);
    downloads.set(idsOf('library-favorites').first, DownloadStatus.downloading);
    await frames(tester);
    expect(
      find.descendant(of: button, matching: find.textContaining('Скачивается')),
      findsOneWidget,
    );
  });
}
