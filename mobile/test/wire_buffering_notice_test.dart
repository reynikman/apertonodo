import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/playback.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';

/// Wire FT-696: brief mid-track buffering suppresses "Preparing
/// audio" — text previously flickered. Before first sound — immediate (guarded by
/// `mini_player_test.dart`), mid-track — only when exceeding 1.5 s.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final mini = find.byKey(const Key('mini-player'));
  Finder inMini(Finder what) => find.descendant(of: mini, matching: what);

  Future<Rig> stalled(WidgetTester tester) async {
    final rig = Rig();
    await rig.start(tester);
    await tester.pumpAndSettle();
    await typeSearch(tester, 'metallica');
    await tester.tap(find.text('Nothing Else Matters'));
    await tester.pump();
    rig.audio.emit(AudioPhase.playing);
    await tester.pump();
    await openTab(tester, 'home');
    rig.audio.emit(AudioPhase.buffering);
    // First frame delivers state, second frame renders it.
    await tester.pump();
    await tester.pump();
    return rig;
  }

  testWidgets('brief mid-track buffering: status unchanged', (tester) async {
    await stalled(tester);

    expect(inMini(find.text('Готовим звук')), findsNothing);
    expect(inMini(find.byKey(const Key('play-wait'))), findsNothing);
    expect(inMini(find.text('Metallica')), findsOneWidget);
  });

  testWidgets('buffering over 1.5s: Preparing audio with seconds', (
    tester,
  ) async {
    await stalled(tester);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1700)),
    );
    await tester.pump(const Duration(seconds: 1));

    expect(inMini(find.text('Готовим звук')), findsOneWidget);
    expect(inMini(find.byKey(const Key('play-wait'))), findsOneWidget);
  });
}
