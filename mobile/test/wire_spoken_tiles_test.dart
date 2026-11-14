import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/l10n/app_localizations.dart';
import 'package:music_stream/models/track.dart';
import 'package:music_stream/player.dart';
import 'package:music_stream/screens/player_screen.dart';
import 'package:music_stream/screens/skip_buttons.dart';
import 'package:music_stream/screens/spoken_controls.dart';

import 'fakes.dart';

/// FT-764: podcast tiles (FT-708) on player screen.
///
/// Under episode control buttons — four tiles "Speed / Download / Sleep timer /
/// Queue"; absent on music track. While download progress unknown, tile does not
/// falsely display "0 %".
void main() {
  const episode = Track(
    id: 'podcast:ep',
    title: 'Episode',
    artist: 'Show',
    durationMs: 3600000,
    artworkUrl: '',
  );
  const song = Track(
    id: 't1',
    title: 'Song',
    artist: 'Band',
    durationMs: 200000,
    artworkUrl: '',
  );

  Future<Player> open(WidgetTester tester, Track track) async {
    final audio = FakeAudio();
    addTearDown(audio.close);
    final player = Player(
      playback: FakePlayback(List.filled(4, 'https://example.test/s/1')),
      audio: audio,
    );
    addTearDown(player.dispose);
    await player.select(track);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: PlayerScreen(player: player),
      ),
    );
    await tester.pump();
    return player;
  }

  testWidgets('podcast episode has four labeled tiles', (tester) async {
    await open(tester, episode);
    expect(find.byType(SpokenTiles), findsOneWidget);
    final tiles = find.byType(SpokenTiles);
    for (final label in ['Speed', 'Download', 'Sleep timer', 'Queue']) {
      expect(
        find.descendant(of: tiles, matching: find.text(label)),
        findsOneWidget,
        reason: label,
      );
    }
  });

  testWidgets('regular track has no action tiles', (tester) async {
    await open(tester, song);
    expect(find.byType(SpokenTiles), findsNothing);
  });

  testWidgets('download with unknown fraction omits "0 %"', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SpokenTiles(
            kind: SpokenKind.podcast,
            speed: 1,
            sleepActive: false,
            download: SpokenDownload.downloading,
            texts: const SpokenTexts(
              skip: SkipTexts(back: 'Back 15', forward: 'Forward 30'),
              speed: 'Speed',
              download: 'Download',
              downloaded: 'Downloaded',
              sleep: 'Sleep timer',
              queue: 'Queue',
              parts: 'Parts',
              remaining: 'Left',
            ),
          ),
        ),
      ),
    );
    expect(find.text('0 %'), findsNothing);
    expect(find.text('Download'), findsOneWidget);
  });
}
