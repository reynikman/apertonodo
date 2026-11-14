import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/playback.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';

/// P-A73 item 1 (FT-554): while audio has not started, full player shows
/// status and elapsed seconds since tap — like mini player. Owner finding 04.10:
/// random position elapsed time was shown, making it unclear whether to wait.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final screen = find.byKey(const Key('player-screen'));
  Finder inScreen(Finder what) => find.descendant(of: screen, matching: what);

  testWidgets('loading: status and seconds instead of song time', (
    tester,
  ) async {
    final rig = Rig();
    await rig.start(tester);
    await tester.pumpAndSettle();
    await typeSearch(tester, 'metallica');
    await tester.tap(find.text('Nothing Else Matters'));
    await tester.pump();
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('mini-player')),
        matching: find.text('Nothing Else Matters'),
      ),
    );
    // Loading bar animates infinitely — pumpAndSettle will never finish.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(screen, findsOneWidget);

    final wait = inScreen(find.byKey(const Key('player-wait')));
    expect(inScreen(find.textContaining('Готовим звук')), findsOneWidget);
    expect(wait, findsOneWidget);
    expect(tester.widget<Text>(wait).data, contains('· 0 с'));
    expect(
      inScreen(find.byKey(const Key('seek-position'))),
      findsNothing,
      reason: 'do not show song duration while there is no sound',
    );

    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1100)),
    );
    await tester.pump(const Duration(seconds: 1));
    // Real clock: on a loaded machine more than one second may pass — "grew", not "exactly 1".
    expect(
      tester.widget<Text>(wait).data,
      isNot(contains('· 0 с')),
      reason: 'seconds increase on their own, without player events',
    );

    rig.audio.emit(AudioPhase.playing);
    await tester.pump();
    await tester.pump();
    expect(wait, findsNothing);
    expect(inScreen(find.byKey(const Key('seek-position'))), findsOneWidget);
  });
}
