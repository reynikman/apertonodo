import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/app.dart';
import 'package:music_stream/screens/parts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'back.dart';
import 'fake_server.dart';
import 'fakes.dart';
import 'golden_support.dart';

/// "My music" per owner mockup 12.10 (FT-798,
/// `docs/design/2026-10-12-library-ux/library-redesign-v1.png`):
/// wide "Favorite songs" tile with cover fan, "Library" 2x2 grid
/// (Playlists, History, Downloaded, Device music — on books spot,
/// books moved to "Browse"), "My ratings" block of two rows, "Import" at bottom.
/// Unavailable is dimmed, not hidden.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Finder key(String name) => find.byKey(Key('library-$name'));
  final favorites = key('favorites');
  final playlists = key('playlists');
  final history = key('history');
  final downloads = key('downloads');
  final device = key('device');
  final rated = key('rated');
  final disliked = key('disliked');
  final import = key('import');

  Future<Rig> openLibrary(
    WidgetTester tester,
    Size size, {
    double textScale = 1,
  }) async {
    usePhone(tester, size);
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final rig = Rig();
    rig.server.on(
      'GET /v1/favorites',
      (_) => answer(200, {
        'tracks': [
          for (var i = 1; i <= 4; i++)
            songLike(
              'library-favorites',
              '5e5e5e5e-0000-4000-8000-00000000000$i',
              'Любимая $i',
            )..['artwork_url'] = '/v1/covers/fav-$i',
        ],
      }),
    );
    rig.server.on(
      'GET /v1/history',
      (_) => answer(200, sample('library-history')),
    );
    rig.server.on(
      'GET /v1/playlists',
      (_) => answer(200, {
        'playlists': [
          for (var i = 1; i <= 2; i++)
            {
              'id': '0a0a0a0a-0000-4000-8000-00000000000$i',
              'name': 'Плейлист $i',
              'tracks': i,
            },
        ],
      }),
    );
    addTearDown(rig.audio.close);
    await tester.pumpWidget(
      MusicApp(
        catalogSource: rig.server.catalog(),
        playback: rig.playback,
        audio: rig.audio,
        server: rig.server.api(),
        namespace: 'test',
        onAccountAction: (_) async {},
        downloads: FakeDownloads([duality]),
      ),
    );
    await tester.pumpAndSettle();
    await openTab(tester, 'library');
    return rig;
  }

  testWidgets('layout matches mockup: tile, 2×2 grid, ratings, import', (
    tester,
  ) async {
    await openLibrary(tester, const Size(412, 915));
    final fav = tester.getRect(favorites);
    final pl = tester.getRect(playlists);
    final hi = tester.getRect(history);
    final dl = tester.getRect(downloads);
    final dv = tester.getRect(device);
    final ra = tester.getRect(rated);
    final di = tester.getRect(disliked);
    final im = tester.getRect(import);

    // Favorites — full width and noticeably taller than grid tile, with cover fan.
    expect(fav.left, moreOrLessEquals(16, epsilon: 0.5));
    expect(fav.right, moreOrLessEquals(412 - 16, epsilon: 0.5));
    expect(fav.height, greaterThanOrEqualTo(pl.height * 1.15));
    expect(
      find.descendant(of: favorites, matching: find.byType(Cover)),
      findsNWidgets(3),
    );
    expect(
      find.descendant(of: favorites, matching: find.text('4 трека')),
      findsOneWidget,
    );

    // "Library": two rows of two tiles, gap 12.
    expect(find.text('Медиатека'), findsOneWidget);
    expect(pl.top, greaterThan(fav.bottom));
    expect(hi.top, pl.top);
    expect(hi.left - pl.right, moreOrLessEquals(12, epsilon: 0.5));
    expect(pl.left, moreOrLessEquals(16, epsilon: 0.5));
    expect(hi.right, moreOrLessEquals(412 - 16, epsilon: 0.5));
    expect(dl.left, pl.left);
    expect(dv.left, hi.left);
    expect(dv.top, dl.top);
    expect(dl.top - pl.bottom, moreOrLessEquals(12, epsilon: 0.5));
    expect(pl.size, dl.size);
    expect(hi.size, dv.size);

    // "My ratings": two rows in single card, flush.
    expect(find.text('Мои оценки'), findsOneWidget);
    expect(ra.top, greaterThan(dl.bottom));
    expect(di.top - ra.bottom, lessThanOrEqualTo(2));
    expect(ra.width, greaterThan(300));

    // Import — separate row at the very bottom.
    expect(im.top, greaterThan(di.bottom));
    expect(im.width, greaterThan(300));
    for (final rect in [pl, hi, dl, dv, ra, di, im]) {
      expect(rect.height, greaterThanOrEqualTo(48));
    }
    expect(key('books'), findsNothing);
  });

  for (final size in const [Size(412, 915), Size(360, 800)]) {
    testWidgets('${size.width.toInt()}×${size.height.toInt()}: no scrolling', (
      tester,
    ) async {
      await openLibrary(tester, size);
      expect(tester.takeException(), isNull);
      final floor = tester.getRect(find.byKey(const Key('tab-library'))).top;
      expect(tester.getRect(import).bottom, lessThanOrEqualTo(floor + 0.5));
      for (final element in find.byType(Scrollable).evaluate()) {
        final state = (element as StatefulElement).state as ScrollableState;
        if (state.position.axis != Axis.vertical) continue;
        expect(state.position.maxScrollExtent, 0);
      }
    });
  }

  testWidgets('small screen and large font: scrolls, but all reachable', (
    tester,
  ) async {
    await openLibrary(tester, const Size(360, 640), textScale: 1.3);
    expect(tester.takeException(), isNull, reason: 'no overflow');
    await tester.scrollUntilVisible(
      import,
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tapAndSettle(tester, import);
    expect(find.byKey(const Key('library-title')).hitTestable(), findsNothing);
  });

  testWidgets('tiles open their screens', (tester) async {
    await openLibrary(tester, const Size(412, 915));
    for (final tile in [favorites, playlists, history, downloads, rated]) {
      await tapAndSettle(tester, tile);
      expect(
        find.byKey(const Key('library-title')).hitTestable(),
        findsNothing,
        reason: '$tile',
      );
      await tapBack(tester);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('library-title')).hitTestable(),
        findsOneWidget,
      );
    }
  });

  testWidgets('no local music — tile is dimmed and non-tappable', (
    tester,
  ) async {
    // In this run app was not given access to phone music at all.
    await openLibrary(tester, const Size(412, 915));
    expect(device, findsOneWidget);
    final dim = tester.widget<Opacity>(
      find.descendant(of: device, matching: find.byType(Opacity)).first,
    );
    expect(dim.opacity, lessThanOrEqualTo(0.5));
    await tester.tap(device, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('library-title')).hitTestable(),
      findsOneWidget,
    );
    // Available is not dimmed.
    expect(
      find.descendant(of: downloads, matching: find.byType(Opacity)),
      findsNothing,
    );
  });
}
