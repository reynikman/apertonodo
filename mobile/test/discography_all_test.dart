import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'artist_rows_test.dart' show albumId, heading, openArtist, page, tile;

/// P-A82 item 2 (FT-566): "Albums", "EPs & Singles", "Live &
/// Compilations" have "all" arrow like "Popular", but only when section has
/// more than three: that many fit on phone width (like "Show all" on
/// Spotify and "See all" on Apple Music). Arrow opens entire section in grid.
const many = [
  ('A1', 'album', 1986),
  ('A2', 'album', 1988),
  ('A3', 'album', 1991),
  ('A4', 'album', 1996),
  ('A5', 'album', 1997),
  ('E1', 'ep', 1987),
  ('S1', 'single', 1989),
  ('L1', 'live', 1993),
  ('L2', 'live', 1999),
  ('C1', 'compilation', 1998),
  ('C2', 'compilation', 2003),
];

Finder arrow(String row) => find.byKey(Key('albums-more-$row'));

// Inside page are horizontal rows; only scroll page itself top to bottom.
final down = find
    .byWidgetPredicate(
      (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
    )
    .last;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('arrow only on section with more than three', (tester) async {
    await openArtist(tester, page(albums: many));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(heading('Альбомы'), 200, scrollable: down);
    expect(arrow('artist-albums'), findsOneWidget, reason: 'five albums');
    expect(
      arrow('artist-albums-small'),
      findsNothing,
      reason: 'two EPs and singles',
    );
    await tester.scrollUntilVisible(
      heading('Концерты и сборники'),
      200,
      scrollable: down,
    );
    expect(
      arrow('artist-albums-live'),
      findsOneWidget,
      reason: 'four live albums and compilations',
    );
  });

  testWidgets('exactly three: no arrow', (tester) async {
    await openArtist(tester, page(albums: many.sublist(2, 7)));
    await tester.pumpAndSettle();
    expect(arrow('artist-albums'), findsNothing);
  });

  testWidgets('arrow opens entire section in order', (tester) async {
    await openArtist(tester, page(albums: many));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(heading('Альбомы'), 200, scrollable: down);
    await tester.tap(arrow('artist-albums'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, 'Альбомы'), findsOneWidget);
    final tops = <double>[];
    final lefts = <double>[];
    for (var i = 0; i < 5; i++) {
      await tester.scrollUntilVisible(tile(i), 200, scrollable: down);
      final rect = tester.getRect(tile(i));
      tops.add(rect.top);
      lefts.add(rect.left);
    }
    expect(tile(5), findsNothing, reason: 'EP in albums view');
    // Grid, not horizontal row: more than one tile per row, and more than one row.
    expect(lefts.toSet().length, greaterThan(1));
    expect(tops.toSet().length, greaterThan(1));
    expect(albumId(0), isNotEmpty);
  });
}
