import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/screens/catalog_screens.dart';

import 'fake_server.dart';

/// FT-552 (owner decision 06.10): duplicate albums — single tile,
/// edition selection inside.
///
/// Contract: for an artist page album, `editions` is a list of
/// `{"id", "title", "year", "kind"}`. On the album screen opened from a tile,
/// each edition has an `edition-<id>` row with year and kind in words
/// ("live", "single", "compilation", "EP", "album"); tapping opens that
/// edition (`GET /v1/albums/<id>`). No editions — no rows.
const liveId = 'b0000000-0000-4000-8000-0000000000aa';

Map<String, dynamic> kinoWithLiveEdition() {
  final page = sample('catalog-artist');
  final albums = page['albums'] as List<dynamic>;
  final first = albums.first as Map<String, dynamic>;
  albums[0] = {
    ...first,
    'editions': [
      {
        'id': liveId,
        'title': first['title'],
        'year': first['year'],
        'kind': 'live',
      },
    ],
  };
  return page;
}

void main() {
  testWidgets('album with editions: concert edition row opens concert', (
    tester,
  ) async {
    final rig = Rig();
    final page = kinoWithLiveEdition();
    final first =
        (page['albums'] as List<dynamic>).first as Map<String, dynamic>;
    rig.server
      ..on('GET /v1/artist', (_) => answer(200, page))
      ..on('GET /v1/albums/*', (_) => answer(200, albumOf(['Звезда'])));
    await rig.screen(
      tester,
      (services) => ArtistScreen(services: services, name: 'Кино'),
    );

    await tapAndSettle(
      tester,
      find.byKey(ValueKey('album-tile-${first['id']}')),
    );
    final edition = find.byKey(const ValueKey('edition-$liveId'));
    await tester.scrollUntilVisible(edition, 200);
    expect(edition, findsOneWidget);
    expect(
      find.descendant(of: edition, matching: find.textContaining('концерт')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: edition,
        matching: find.textContaining('${first['year']}'),
      ),
      findsOneWidget,
    );

    await tapAndSettle(tester, edition);
    expect(
      rig.server.calls('GET /v1/albums/*').last.url.path,
      endsWith('/v1/albums/$liveId'),
    );
  });

  testWidgets('album without editions: no edition rows', (tester) async {
    final rig = Rig();
    final page = sample('catalog-artist');
    final first =
        (page['albums'] as List<dynamic>).first as Map<String, dynamic>;
    rig.server
      ..on('GET /v1/artist', (_) => answer(200, page))
      ..on('GET /v1/albums/*', (_) => answer(200, albumOf(['Звезда'])));
    await rig.screen(
      tester,
      (services) => ArtistScreen(services: services, name: 'Кино'),
    );

    await tapAndSettle(
      tester,
      find.byKey(ValueKey('album-tile-${first['id']}')),
    );
    expect(
      find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('edition-'),
      ),
      findsNothing,
    );
  });
}
