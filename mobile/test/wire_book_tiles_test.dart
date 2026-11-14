import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/l10n/app_localizations.dart';
import 'package:music_stream/models/track.dart';
import 'package:music_stream/player.dart';
import 'package:music_stream/screens/player_screen.dart';
import 'package:music_stream/screens/spoken_controls.dart';

import 'fakes.dart';

/// FT-784: audiobook parts in player show -15/+30 seek instead of
/// "prev/next" and book tiles (FT-708): "Speed / Parts / Sleep timer /
/// Remaining". "Remaining" counts until end of book, not part.
void main() {
  Track part(int n) => Track(
    id: 'book:b1:$n',
    title: 'Part $n',
    artist: 'Author',
    durationMs: 600000,
    artworkUrl: '',
  );
  const song = Track(
    id: 't1',
    title: 'Song',
    artist: 'Band',
    durationMs: 200000,
    artworkUrl: '',
  );

  Future<void> open(WidgetTester tester, List<Track> queue, int start) async {
    final audio = FakeAudio();
    addTearDown(audio.close);
    final player = Player(
      playback: FakePlayback(List.filled(6, 'https://example.test/s/1')),
      audio: audio,
    );
    addTearDown(player.dispose);
    await player.playQueue(queue, start: start);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: PlayerScreen(player: player),
      ),
    );
    await tester.pump();
  }

  testWidgets('book part has seek instead of prev/next', (tester) async {
    await open(tester, [part(1), part(2), part(3)], 1);
    expect(find.byKey(const ValueKey('player-skip-back')), findsOneWidget);
    expect(find.byKey(const ValueKey('player-skip-forward')), findsOneWidget);
    expect(find.byKey(const Key('previous-button')), findsNothing);
    expect(find.byKey(const Key('next-button')), findsNothing);
  });

  testWidgets('book part has four book action tiles', (tester) async {
    await open(tester, [part(1), part(2), part(3)], 1);
    final tiles = find.byType(SpokenTiles);
    expect(tiles, findsOneWidget);
    expect(tester.widget<SpokenTiles>(tiles).kind, SpokenKind.book);
    for (final label in ['Speed', 'Parts', 'Sleep timer', 'Left']) {
      expect(
        find.descendant(of: tiles, matching: find.text(label)),
        findsOneWidget,
        reason: label,
      );
    }
  });

  testWidgets('Remaining calculates time to book end', (tester) async {
    // Second of three 10-minute parts, just started listening: 20 minutes.
    await open(tester, [part(1), part(2), part(3)], 1);
    final tiles = find.byType(SpokenTiles);
    expect(
      find.descendant(of: tiles, matching: find.text('20 min')),
      findsOneWidget,
    );
  });

  testWidgets('regular track has no book tiles or seek', (tester) async {
    await open(tester, [song], 0);
    expect(find.byType(SpokenTiles), findsNothing);
    expect(find.byKey(const ValueKey('player-skip-back')), findsNothing);
  });
}
