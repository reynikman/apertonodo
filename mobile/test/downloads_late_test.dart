import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/app.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';
import 'fakes.dart';

/// "Downloads" arrive in app asynchronously: `main.dart` initializes them once
/// storage opens on phone — after first frame. Screen with
/// tabs is built by Flutter once, and late "Downloads" never reached
/// it: phone had neither "download" buttons nor "Downloaded" row
/// (FT-530, `device-smoke` MR !247). Screen tests provided "Downloads" synchronously and
/// never saw this.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('downloads arriving after frame 1 are visible on screens', (
    tester,
  ) async {
    final rig = Rig();
    addTearDown(rig.audio.close);
    rig.server.on(
      'GET /v1/favorites',
      (_) => answer(200, {
        'tracks': [songLike('library-favorites', duality.id, duality.title)],
      }),
    );
    rig.server.on('GET /v1/history', (_) => answer(200, {'tracks': []}));
    rig.server.on('GET /v1/playlists', (_) => answer(200, {'playlists': []}));
    final server = rig.server.api();
    final catalog = rig.server.catalog();

    Widget app({FakeDownloads? downloads}) => MusicApp(
      catalogSource: catalog,
      playback: rig.playback,
      audio: rig.audio,
      server: server,
      namespace: 'test',
      onAccountAction: (_) async {},
      downloads: downloads,
    );

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await openTab(tester, 'library');
    // FT-798: unavailable tile remains in place dimmed rather than disappearing.
    final tile = find.byKey(const Key('library-downloads'));
    final dimmed = find.descendant(of: tile, matching: find.byType(Opacity));
    expect(tile, findsOneWidget);
    expect(dimmed, findsWidgets);

    await tester.pumpWidget(app(downloads: FakeDownloads()));
    await tester.pumpAndSettle();
    expect(tile, findsOneWidget);
    expect(
      dimmed,
      findsNothing,
      reason: 'downloads tile did not activate when downloads arrived',
    );

    await tester.tap(find.byKey(const Key('library-favorites')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('download-favorites')),
      findsOneWidget,
      reason: 'no download button in favorites',
    );
  });
}
