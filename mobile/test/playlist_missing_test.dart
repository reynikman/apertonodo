import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/screens/library_screens.dart';
import 'package:music_stream/screens/search_screen.dart';

import 'fake_server.dart';

/// P5, step 6 (`plan/p5-import.md`, P-A48): unresolved import items remain in
/// playlist as dimmed row in position, tapping initiates search with that text.
/// Server returns row with `missing: true` (FT-493); custom ID, not catalog
/// track — cannot be played, added to favorites, or put in another playlist.
const playlistId = '9b7d8f0e-2c1a-4e5b-8d3f-6a1b2c3d4e5f';
const missingId = 'b0000000-0000-4000-8000-000000000077';

Map<String, dynamic> withMissing() {
  final playlist = playlistOf(['Звезда', 'Кукушка']);
  final tracks = playlist['tracks'] as List<dynamic>;
  tracks.insert(1, {
    ...tracks.first as Map<String, dynamic>,
    'id': missingId,
    'title': 'No Such Song',
    'artist': 'Nobody Band',
    'duration_ms': 0,
    'artwork_url': '',
    'playable': false,
    'missing': true,
  });
  return playlist;
}

/// Through app like a user: "My Music" -> "Playlists" -> "Road Trip".
Future<Rig> openPlaylist(WidgetTester tester) async {
  final rig = Rig();
  rig.server.on('GET /v1/playlists/*', (_) => answer(200, withMissing()));
  await rig.start(tester);
  await openTab(tester, 'library');
  await tapAndSettle(tester, find.text('Плейлисты'));
  await tapAndSettle(tester, find.text('В дорогу'));
  expect(find.byType(PlaylistScreen), findsOneWidget);
  return rig;
}

void main() {
  testWidgets('not found track — dim, in place, with missing badge', (
    tester,
  ) async {
    await openPlaylist(tester);

    final star = tester.getTopLeft(find.text('Звезда')).dy;
    final lost = tester.getTopLeft(find.text('No Such Song')).dy;
    final cuckoo = tester.getTopLeft(find.text('Кукушка')).dy;
    expect(star < lost && lost < cuckoo, isTrue);
    expect(alphaOf(tester, 'No Such Song'), lessThan(0.5));
    expect(find.textContaining('не нашлось'), findsOneWidget);
  });

  testWidgets('tap on not found — search by artist and title, '
      'not Play', (tester) async {
    final rig = await openPlaylist(tester);

    await tapAndSettle(tester, find.text('No Such Song'));

    expect(find.byType(SearchScreen), findsOneWidget);
    expect(
      rig.server.calls('GET /v1/search').single.url.queryParameters['q'],
      'Nobody Band No Such Song',
    );
    expect(rig.playback.started, isEmpty);
    expect(rig.server.calls('POST /v1/playback'), isEmpty);
  });

  testWidgets('«Play playlist» skips not found', (tester) async {
    final rig = await openPlaylist(tester);

    await tester.tap(find.text('Играть плейлист'));
    await tester.pump();
    expect(rig.playback.started, [songId('Звезда')]);
    rig.audio.emit(AudioPhase.playing);
    await tester.pump();
    rig.audio.finish();
    await tester.pump();
    expect(rig.playback.started, [songId('Звезда'), songId('Кукушка')]);
  });

  testWidgets('not found has no heart: nothing to add to favorites', (
    tester,
  ) async {
    await openPlaylist(tester);

    expect(find.byKey(const ValueKey('heart-$missingId')), findsNothing);
    expect(find.byKey(ValueKey('heart-${songId('Звезда')}')), findsOneWidget);
  });
}
