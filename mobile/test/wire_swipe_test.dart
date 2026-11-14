import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/models/track.dart';
import 'package:music_stream/screens/parts.dart';
import 'package:music_stream/screens/swipe_row.dart';
import 'package:music_stream/theme.dart';

import 'fake_server.dart';

/// Wire FT-695: swipe right on track row — "play next"
/// with brief "Will play next". In History no swipe right: row
/// dismissed via swipe left.
void main() {
  const track = Track(
    id: 'swipe-1',
    title: 'Song Swipe',
    artist: 'Band',
    durationMs: 1000,
    artworkUrl: '',
  );

  late List<String> next;

  Future<void> pump(WidgetTester tester, {bool swipe = true}) async {
    next = [];
    final server = FakeServer();
    final services = Services(
      server: server.api(),
      search: server.catalog().search,
      play: (_, _) {},
      prepare: (_) {},
      playNext: (t) => next.add(t.id),
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
            swipe: swipe,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('swipe right queues track next and announces it now', (
    tester,
  ) async {
    await pump(tester);

    await tester.drag(find.text('Song Swipe'), const Offset(500, 0));
    await tester.pumpAndSettle();

    expect(next, [track.id]);
    expect(find.text('Сыграет следующей'), findsOneWidget);
  });

  testWidgets('History list has no swipe', (tester) async {
    await pump(tester, swipe: false);

    expect(find.byType(SwipeRow), findsNothing);
  });
}
