import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/models/track.dart';
import 'package:music_stream/player.dart';
import 'package:music_stream/screens/player_screen.dart';

/// Owner remark 02.10 (E 4, device screenshot): above "collapse" and heart
/// — dark bar, artwork glow below it. Glow is rendered in queue
/// list, while list started below button row, cutting off glow with a sharp
/// line. List must start at top of screen, buttons sit on top of it
/// and respond to taps, while song title must not be hidden under buttons.
Track song(int n) => Track(
  id: 't$n',
  title: 'Song $n',
  artist: 'Band',
  durationMs: 200000,
  artworkUrl: '',
);

void main() {
  final close = find.byKey(const Key('player-close'));
  final queue = find.byKey(const Key('queue'));
  final title = find.byKey(const Key('player-title'));

  Future<Player> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 24);
    addTearDown(tester.view.reset);
    final player = Player();
    addTearDown(player.dispose);
    await player.playQueue([for (var n = 1; n <= 20; n++) song(n)]);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => PlayerScreen(player: player),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return player;
  }

  testWidgets('queue with glow starts from top of screen, under buttons', (
    tester,
  ) async {
    await open(tester);
    expect(
      tester.getRect(queue).top,
      0,
      reason: 'list starts below button row — glow clipped by strip',
    );
    final button = tester.getRect(close);
    expect(
      button.top,
      greaterThanOrEqualTo(24),
      reason: 'buttons below status bar',
    );
    expect(
      tester.getRect(title).top,
      greaterThan(button.bottom),
      reason: 'title scrolled under buttons',
    );
  });

  testWidgets('«collapse» over queue is clickable even after scroll', (
    tester,
  ) async {
    await open(tester);
    await tester.drag(queue, const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.tap(close);
    await tester.pumpAndSettle();
    expect(find.byType(PlayerScreen), findsNothing);
  });
}
