import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/screens/artist_avatar.dart';
import 'package:music_stream/screens/catalog_screens.dart';
import 'package:music_stream/screens/parts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';
import 'golden_support.dart';

/// P-A51 (owner 02.10, comments 3, 9, 10, 11, 16): albums in three horizontal
/// rows: "Albums", "EPs & Singles", "Live & Compilations"; "Popular" — five
/// songs, arrow opens modal with all (P-A72, FT-553; previously "More" expanded
/// up to ten); "Similar artists" — horizontal row, no expansion;
/// section headers — single rule across the whole page.
const kinds = [
  ('Master of Puppets', 'album', 1986),
  ('Garage Days', 'ep', 1987),
  ('One', 'single', 1989),
  ('Metallica', 'album', 1991),
  ('Live Shit', 'live', 1993),
  ('Garage Inc.', 'compilation', 1998),
];

String albumId(int i) => 'e8f70201-8899-3f0c-9e07-5d6495bc80${i + 10}';

Map<String, dynamic> page({
  int songs = 10,
  List<(String, String, int)> albums = kinds,
  int similar = 6,
}) {
  final body = sample('catalog-artist-lastfm');
  final song = (body['top_tracks'] as List).first as Map<String, dynamic>;
  body['top_tracks'] = [
    for (var i = 0; i < songs; i++)
      {
        ...song,
        'id': '00000000-0000-4000-8000-0000000000${i + 10}',
        'title': 'Song ${i + 1}',
        'duration_ms': 200000,
      },
  ];
  final album = (body['albums'] as List).first as Map<String, dynamic>;
  body['albums'] = [
    for (final (i, (title, kind, year)) in albums.indexed)
      {...album, 'id': albumId(i), 'title': title, 'kind': kind, 'year': year},
  ];
  body['similar'] = [
    for (var i = 1; i <= similar; i++) {'name': 'Band $i'},
  ];
  return body;
}

Future<Rig> openArtist(WidgetTester tester, Map<String, dynamic> body) async {
  usePhone(tester, phones['360']!);
  final rig = Rig();
  rig.server.on('GET /v1/artist', (_) => answer(200, body));
  await rig.screen(
    tester,
    (services) => ArtistScreen(services: services, name: 'Metallica'),
  );
  return rig;
}

Finder heading(String text) => find.widgetWithText(Heading, text);
Finder tile(int i) => find.byKey(ValueKey('album-tile-${albumId(i)}'));
Finder top(int i) => find.byKey(Key('top-track-$i'));
final more = find.byKey(const Key('popular-more'));
final similarRow = find.byKey(const Key('artist-similar'));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('albums: three rows by type from top to bottom', (tester) async {
    await openArtist(tester, page());

    final rows = {
      'Альбомы': (const Key('artist-albums'), [0, 3]),
      'EP и синглы': (const Key('artist-albums-small'), [1, 2]),
      'Концерты и сборники': (const Key('artist-albums-live'), [4, 5]),
    };
    double? above;
    for (final MapEntry(key: title, value: (key, members)) in rows.entries) {
      final row = find.byKey(key);
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      expect(heading(title), findsOneWidget, reason: title);
      final top = tester.getRect(heading(title)).top;
      if (above != null) expect(top, greaterThan(above), reason: title);
      above = top;
      expect(
        tester.widget<ListView>(row).scrollDirection,
        Axis.horizontal,
        reason: title,
      );
      for (final i in members) {
        expect(
          find.descendant(of: row, matching: tile(i)),
          findsOneWidget,
          reason: '${kinds[i].$1} not in row $title',
        );
      }
    }
  });

  testWidgets('empty row has no heading', (tester) async {
    await openArtist(
      tester,
      page(albums: [('Master of Puppets', 'album', 1986)]),
    );

    expect(heading('Альбомы'), findsOneWidget);
    expect(heading('EP и синглы'), findsNothing);
    expect(heading('Концерты и сборники'), findsNothing);
  });

  testWidgets('Popular: five and arrow to view with all', (tester) async {
    await openArtist(tester, page());

    expect(top(4), findsOneWidget);
    expect(top(5), findsNothing);
    expect(
      find.descendant(of: more, matching: find.byIcon(Icons.chevron_right)),
      findsOneWidget,
    );
    expect(find.text('Ещё'), findsNothing);
  });

  testWidgets('five songs or fewer: no button', (tester) async {
    await openArtist(tester, page(songs: 5));

    expect(top(4), findsOneWidget);
    expect(more, findsNothing);
  });

  testWidgets('similar: horizontal row without show all', (tester) async {
    await openArtist(tester, page(similar: 8));

    await tester.ensureVisible(similarRow);
    await tester.pumpAndSettle();
    expect(heading('Похожие исполнители'), findsOneWidget);
    final scrollable = find.descendant(
      of: similarRow,
      matching: find.byType(Scrollable),
    );
    expect(
      tester.state<ScrollableState>(scrollable.first).position.axis,
      Axis.horizontal,
    );
    expect(find.text('Показать все'), findsNothing);
    await tester.drag(similarRow, const Offset(-2000, 0));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: similarRow, matching: find.text('Band 8')),
      findsOneWidget,
    );
  });

  testWidgets('similar: circle 80, width 88, gap 12 (R-A73 item 2)', (
    tester,
  ) async {
    // Owner finding 04.10: circles are small, while spacing between them is large.
    await openArtist(tester, page());
    await tester.ensureVisible(similarRow);
    await tester.pumpAndSettle();

    Finder tile(int n) => find.byKey(ValueKey('artist-row-Band $n'));
    final avatar = find.descendant(
      of: tile(1),
      matching: find.byType(ArtistAvatar),
    );
    expect(tester.getSize(avatar), const Size(80, 80));
    expect(tester.getSize(tile(1)).width, 88);
    expect(tester.getRect(tile(2)).left - tester.getRect(tile(1)).right, 12);
    final name = find.descendant(of: tile(1), matching: find.text('Band 1'));
    expect(
      tester.getRect(name).top,
      greaterThanOrEqualTo(tester.getRect(avatar).bottom),
    );
    expect(
      tester.getRect(name).bottom,
      lessThanOrEqualTo(tester.getRect(similarRow).bottom),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('section headings follow one rule: padding and font', (
    tester,
  ) async {
    await openArtist(tester, page());

    final titles = [
      'Популярное',
      'Альбомы',
      'EP и синглы',
      'Концерты и сборники',
      'Похожие исполнители',
      'Об исполнителе',
    ];
    final first = find.text(titles.first);
    final left = tester.getRect(first).left;
    final size = tester.widget<Text>(first).style?.fontSize;
    // Gap from header to its content — also unified for all.
    final blocks = {
      'Популярное': top(0),
      'Альбомы': find.byKey(const Key('artist-albums')),
      'EP и синглы': find.byKey(const Key('artist-albums-small')),
      'Концерты и сборники': find.byKey(const Key('artist-albums-live')),
      'Похожие исполнители': similarRow,
    };
    double? gap;
    for (final title in titles) {
      final text = find.text(title);
      await tester.ensureVisible(text);
      await tester.pumpAndSettle();
      expect(tester.getRect(text).left, left, reason: title);
      expect(tester.widget<Text>(text).style?.fontSize, size, reason: title);
      if (blocks[title] case final block?) {
        final now = tester.getRect(block).top - tester.getRect(text).bottom;
        gap ??= now;
        expect(now, moreOrLessEquals(gap, epsilon: 0.5), reason: title);
      }
    }
  });
}
