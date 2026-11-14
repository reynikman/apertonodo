import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/prefetch_policy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';
import 'player_fixes_test.dart' show openPlayer, song;

/// FT-804: owner 12.10 — general audio quality does not belong in player, it belongs
/// in general settings next to equalizer. Player menu is for current track.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('\'Sound quality\' in account menu, with all sections', (
    tester,
  ) async {
    final rig = Rig(account: true, prefetch: PrefetchPolicy());
    await rig.start(tester);
    await tester.pumpAndSettle();

    await openSoundQuality(tester);

    expect(find.text('Качество звука'), findsOneWidget);
    expect(find.byKey(const Key('quality-lossless')), findsOneWidget);
    expect(find.text('Подгрузка следующей песни'), findsOneWidget);
  });

  testWidgets('no general quality in player menu anymore', (tester) async {
    final rig = Rig(account: true);
    await rig.start(tester);
    await tester.pumpAndSettle();
    await typeSearch(tester, 'metallica');
    await tester.tap(find.text(song));
    await tester.pump();
    rig.audio.emit(AudioPhase.playing);
    await tester.pump();
    await openTab(tester, 'home');
    await tester.pumpAndSettle();
    await openPlayer(tester);

    await tapAndSettle(tester, find.byKey(const Key('player-menu')));

    expect(find.byKey(const Key('player-problem')), findsOneWidget);
    expect(find.byKey(const Key('player-quality')), findsNothing);
    expect(find.text('Качество звука'), findsNothing);
  });
}
