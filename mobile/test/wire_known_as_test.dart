import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/screens/catalog_screens.dart';

import 'fake_server.dart';

/// Wire FT-746: "Also known as" on artist page.
void main() {
  Future<void> open(WidgetTester tester, Object? aliases) async {
    tester.view.physicalSize = const Size(400, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final page = sample('catalog-artist-lastfm');
    final artist = page['artist'] as Map<String, dynamic>;
    if (aliases != null) artist['aliases'] = aliases;
    final rig = Rig();
    rig.server.on('GET /v1/artist', (_) => answer(200, page));
    await rig.screen(
      tester,
      (services) => ArtistScreen(services: services, name: 'Metallica'),
    );
  }

  testWidgets('aliases from server visible on page', (tester) async {
    await open(tester, [
      {'name': 'Металлика', 'locale': 'ru'},
      {'name': 'メタリカ', 'locale': 'ja'},
    ]);

    expect(find.byKey(const Key('known-as-names')), findsOneWidget);
    expect(find.textContaining('Металлика'), findsOneWidget);
  });

  testWidgets('no aliases block without aliases', (tester) async {
    await open(tester, null);

    expect(find.byKey(const Key('known-as-names')), findsNothing);
  });
}
