import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/screens/search_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';
import 'golden_support.dart';

/// P-A52 (owner 02.10, remark 17): idle search shows recent queries and
/// 4 recent tracks on a single screen without scrolling, like Home. Row
/// "recently listened artists" removed — duplicates Home screen.
const heard = [
  ('Slipknot', 'Duality'),
  ('Queen', 'Bohemian Rhapsody'),
  ('Slipknot', 'Psychosocial'),
  ('Nirvana', 'Smells Like Teen Spirit'),
  ('Radiohead', 'Creep'),
  ('Linkin Park', 'Numb'),
];

Map<String, dynamic> history() => {
  'tracks': [
    for (final (artist, song) in heard)
      songLike('library-history', songId(song), song)..['artist'] = artist,
  ],
  'total': heard.length,
};

final screen = find.byType(SearchScreen);
final mini = find.byKey(const Key('mini-player'));

Finder keyed(String prefix) => find.descendant(
  of: screen,
  matching: find.byWidgetPredicate(
    (widget) =>
        widget.key is ValueKey<String> &&
        (widget.key! as ValueKey<String>).value.startsWith(prefix),
  ),
);

Future<Rig> openSearch(WidgetTester tester) async {
  // Full list of recent queries is 10 (`RecentQueries.limit`).
  SharedPreferences.setMockInitialValues({
    'recent-queries': [for (var i = 1; i <= 10; i++) 'запрос $i'],
  });
  usePhone(tester, phones['360']!);
  final rig = Rig();
  rig.server.on('GET /v1/history', (_) => answer(200, history()));
  await rig.start(tester);
  await tester.pumpAndSettle();
  await openTab(tester, 'search');
  return rig;
}

void main() {
  testWidgets('no query: 4 recent songs, no artist row', (tester) async {
    await openSearch(tester);

    expect(keyed('heard-artist-'), findsNothing);
    expect(
      [
        for (final tile in tester.widgetList(keyed('heard-track-')))
          (tile.key! as ValueKey<String>).value,
      ],
      [for (final (_, song) in heard.take(4)) 'heard-track-${songId(song)}'],
    );
    expect(find.byKey(const Key('recent-запрос 1')), findsOneWidget);
  });

  testWidgets('on 360 dp with mini-player fits without scroll', (tester) async {
    final rig = await openSearch(tester);
    await tester.tap(
      find.descendant(of: screen, matching: find.text('Duality')),
    );
    await tester.pump();
    rig.audio.emit(AudioPhase.playing);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(mini, findsOneWidget);
    for (final scroll in tester.stateList<ScrollableState>(
      find.descendant(of: screen, matching: find.byType(Scrollable)),
    )) {
      if (scroll.position.axis == Axis.vertical) {
        expect(
          scroll.position.maxScrollExtent,
          0,
          reason: 'idle search scrolls',
        );
      }
    }
    final last = keyed('heard-track-').last;
    expect(
      tester.getRect(last).bottom,
      lessThanOrEqualTo(tester.getRect(mini).top),
      reason: 'last song under mini-player',
    );
  });
}
