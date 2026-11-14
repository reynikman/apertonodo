import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/screens/parts.dart';
import 'package:music_stream/screens/player_screen.dart';

import 'fake_server.dart';

/// P-A53 (owner 02.10, remark 5): album playing — queue shows track numbers
/// without covers, shared artwork; mixed queue (playlist, favorites,
/// search) — small cover thumbnails, as currently.
const titles = ['Звезда', 'Ночь', 'Кукушка'];

Finder row(int index) => find.byKey(Key('queue-row-$index'));

/// Playing — open full player from mini player and scroll to the last row.
Future<void> openQueue(WidgetTester tester, Rig rig) async {
  rig.audio.emit(AudioPhase.playing);
  await tester.pump();
  await tapAndSettle(tester, find.byKey(const Key('mini-player')));
  expect(find.byType(PlayerScreen), findsOneWidget);
  await tester.scrollUntilVisible(
    row(titles.length - 1),
    200,
    scrollable: find.descendant(
      of: find.byKey(const Key('queue')),
      matching: find.byType(Scrollable),
    ),
  );
}

void main() {
  testWidgets('album: song numbers in queue, no covers', (tester) async {
    final rig = Rig();
    rig.server.on('GET /v1/albums/*', (_) => answer(200, albumOf(titles)));
    await openAlbum(tester, rig);
    await tester.tap(find.text('Играть альбом'));
    await tester.pump();

    await openQueue(tester, rig);

    for (var i = 0; i < titles.length; i++) {
      expect(
        find.descendant(of: row(i), matching: find.text('${i + 1}')),
        findsOneWidget,
        reason: 'row ${i + 1} without number',
      );
      expect(
        find.descendant(of: row(i), matching: find.byType(Cover)),
        findsNothing,
        reason: 'album row ${i + 1} has own cover',
      );
    }
  });

  testWidgets('playlist: small covers, no numbers', (tester) async {
    final rig = Rig();
    final playlist = playlistOf(titles);
    // Tracks from different albums: one has cover art, others do not.
    ((playlist['tracks'] as List<dynamic>).first
            as Map<String, dynamic>)['artwork_url'] =
        '/v1/covers/${songId('a')}';
    rig.server.on('GET /v1/playlists/*', (_) => answer(200, playlist));
    await rig.start(tester);
    await openTab(tester, 'library');
    await tapAndSettle(tester, find.text('Плейлисты'));
    await tapAndSettle(tester, find.text('В дорогу'));
    await tester.tap(find.text('Играть плейлист'));
    await tester.pump();

    await openQueue(tester, rig);

    for (var i = 0; i < titles.length; i++) {
      expect(
        find.descendant(of: row(i), matching: find.byType(Cover)),
        findsOneWidget,
        reason: 'row ${i + 1} has no cover',
      );
      expect(
        find.descendant(of: row(i), matching: find.text('${i + 1}')),
        findsNothing,
      );
    }
  });
}
