import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/models/track.dart';
import 'package:music_stream/offline/download_queue.dart';
import 'package:music_stream/screens/parts.dart';
import 'package:music_stream/theme.dart';

import 'fake_server.dart';
import 'fakes.dart';

/// P-A73 item 4 (FT-559): track three-dots menu — "Download", downloaded tracks —
/// "Delete from device"; "downloaded" icon in track row. Downloads screen
/// remains unchanged.
const _fresh = Track(
  id: 'fresh',
  title: 'Numb',
  artist: 'Linkin Park',
  durationMs: 187000,
  artworkUrl: '',
);
const _pale = Track(
  id: 'pale',
  title: 'Ёжик в тумане',
  artist: 'Queen',
  durationMs: 0,
  artworkUrl: '',
  playable: false,
);

void main() {
  late FakeDownloads downloads;

  Future<void> pump(
    WidgetTester tester,
    Track track, {
    bool withDownloads = true,
  }) async {
    final server = FakeServer();
    final services = Services(
      server: server.api(),
      search: server.catalog().search,
      play: (_, _) {},
      prepare: (_) {},
      downloads: withDownloads ? downloads : null,
    );
    final hearts = Hearts(services.server)..show([track]);
    addTearDown(hearts.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: apertonoTheme(),
        home: Scaffold(
          body: TrackTile(
            track: track,
            onTap: () {},
            services: services,
            hearts: hearts,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Downloading spinner animates continuously — `pumpAndSettle` will never finish.
  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Ещё'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  setUp(() => downloads = FakeDownloads());

  testWidgets('not downloaded: Download downloads track', (tester) async {
    await pump(tester, _fresh);
    expect(find.byKey(const Key('track-download-fresh')), findsNothing);
    await openMenu(tester);
    expect(find.text('Удалить с телефона'), findsNothing);
    await tester.tap(find.text('Скачать'));
    // Downloading spinner animates — skip pumpAndSettle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(downloads.asked.single.$1, ['fresh']);
    expect(downloads.asked.single.$2, isNull);
  });

  testWidgets('downloaded: badge in row, menu has Delete', (tester) async {
    downloads = FakeDownloads([_fresh]);
    await pump(tester, _fresh);
    expect(find.byKey(const Key('track-download-fresh')), findsOneWidget);
    await openMenu(tester);
    expect(find.text('Скачать'), findsNothing);
    await tester.tap(find.text('Удалить с телефона'));
    await tester.pumpAndSettle();
    expect(downloads.removed, [
      ['fresh'],
    ]);
    expect(find.byKey(const Key('track-download-fresh')), findsNothing);
    expect(downloads.asked, isEmpty);
  });

  testWidgets('downloading: Delete in menu, no duplicate download', (
    tester,
  ) async {
    await pump(tester, _fresh);
    await downloads.download([_fresh]);
    downloads.set('fresh', DownloadStatus.downloading);
    await tester.pump();
    await openMenu(tester);
    expect(find.text('Скачать'), findsNothing);
    expect(find.text('Удалить с телефона'), findsOneWidget);
  });

  testWidgets('cannot download unplayable track', (tester) async {
    await pump(tester, _pale);
    await openMenu(tester);
    expect(find.text('Скачать'), findsNothing);
    expect(find.text('Добавить в плейлист'), findsOneWidget);
  });

  testWidgets('no downloads when store absent: no menu items', (tester) async {
    await pump(tester, _fresh, withDownloads: false);
    await openMenu(tester);
    expect(find.text('Скачать'), findsNothing);
    expect(find.text('Удалить с телефона'), findsNothing);
    expect(find.text('Добавить в плейлист'), findsOneWidget);
  });
}
