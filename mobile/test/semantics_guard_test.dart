import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/playback.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';

/// B-2 (FT-741): every tap target has TalkBack label. Guarded via
/// Flutter `labeledTapTargetGuideline` on primary screens: artist "more"
/// arrows and search clear button lacked labels, causing TalkBack to read
/// "button" without description.
Future<void> labeled(WidgetTester tester) =>
    expectLater(tester, meetsGuideline(labeledTapTargetGuideline));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Home', (tester) async {
    final handle = tester.ensureSemantics();
    await Rig().start(tester);
    await tester.pumpAndSettle();
    await labeled(tester);
    handle.dispose();
  });

  testWidgets('Browse and genre', (tester) async {
    final handle = tester.ensureSemantics();
    await Rig().start(tester);
    await openTab(tester, 'browse');
    await labeled(tester);
    await tapAndSettle(tester, find.text('Рок'));
    await labeled(tester);
    handle.dispose();
  });

  testWidgets('Search with query - clear icon labeled', (tester) async {
    final handle = tester.ensureSemantics();
    await Rig().start(tester);
    await typeSearch(tester, 'metallica');
    expect(find.byKey(const Key('search-clear')), findsOneWidget);
    await labeled(tester);
    handle.dispose();
  });

  testWidgets('Artist - "more" arrows labeled', (tester) async {
    final handle = tester.ensureSemantics();
    final rig = Rig();
    // "More" arrow for popular tracks only shown with 6+ tracks (FT-566).
    final body = sample('catalog-artist-lastfm');
    final song = (body['top_tracks'] as List).first as Map<String, dynamic>;
    body['top_tracks'] = [
      for (var i = 0; i < 6; i++)
        {...song, 'id': '00000000-0000-4000-8000-0000000000${i + 10}'},
    ];
    rig.server.on('GET /v1/artist', (_) => answer(200, body));
    await rig.start(tester);
    await openTab(tester, 'browse');
    await tapAndSettle(tester, find.text('Рок'));
    await tapAndSettle(tester, find.text('Кино'));
    expect(
      find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            ((w.key! as ValueKey<String>).value == 'popular-more' ||
                (w.key! as ValueKey<String>).value.startsWith('albums-more-')),
      ),
      findsWidgets,
      reason: 'page must have at least one "more" arrow',
    );
    await labeled(tester);
    handle.dispose();
  });

  testWidgets('Album', (tester) async {
    final handle = tester.ensureSemantics();
    await openAlbum(tester, Rig());
    await labeled(tester);
    handle.dispose();
  });

  testWidgets('Full player', (tester) async {
    final handle = tester.ensureSemantics();
    final rig = Rig();
    await rig.start(tester);
    await typeSearch(tester, 'metallica');
    await tester.tap(find.text('Nothing Else Matters'));
    await tester.pump();
    rig.audio.emit(AudioPhase.playing);
    await tester.pumpAndSettle();
    await tapAndSettle(
      tester,
      find.descendant(
        of: find.byKey(const Key('mini-player')),
        matching: find.text('Nothing Else Matters'),
      ),
    );
    expect(find.byKey(const Key('player-screen')), findsOneWidget);
    await labeled(tester);
    handle.dispose();
  });
}
