import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';

/// P-A82 item 4 (FT-568): "Preparing audio" seconds — single timer per tap.
///
/// Owner finding 05.10: opened player — timer starts; collapsed — mini
/// player shows another starting from zero; returned — a third one. Each screen had its own
/// clock, and mini player unmounted during full player restarted from scratch.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final player = find.byKey(const Key('player-screen'));
  final mini = find.byKey(const Key('mini-player'));

  Future<void> frames(WidgetTester tester) async {
    // Loading bar animates infinitely — pumpAndSettle will never finish.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> wait(WidgetTester tester, int ms) async {
    await tester.runAsync(
      () => Future<void>.delayed(Duration(milliseconds: ms)),
    );
    await tester.pump(const Duration(seconds: 1));
  }

  String shown(WidgetTester tester, Finder where, String key) => tester
      .widget<Text>(find.descendant(of: where, matching: find.byKey(Key(key))))
      .data!;

  // Seconds on the wait label. The clock is real: on a loaded machine `wait` lasts longer,
  // so checks say "not reset" (at least N), not "exactly N".
  int secs(String label) =>
      int.parse(RegExp(r'· (\d+) с').firstMatch(label)!.group(1)!);

  testWidgets('mini-player → player → mini-player: timer continues', (
    tester,
  ) async {
    final rig = Rig();
    await rig.start(tester);
    await tester.pumpAndSettle();
    await typeSearch(tester, 'metallica');
    await tester.tap(find.text('Nothing Else Matters'));
    await frames(tester);
    await wait(tester, 2100);
    final before = secs(shown(tester, mini, 'play-wait'));
    expect(before, greaterThanOrEqualTo(2));

    await tester.tap(
      find.descendant(of: mini, matching: find.text('Nothing Else Matters')),
    );
    await frames(tester);
    expect(player, findsOneWidget);
    final inPlayer = secs(shown(tester, player, 'player-wait'));
    expect(
      inPlayer,
      greaterThanOrEqualTo(before),
      reason: 'full player started timer from zero',
    );

    await wait(tester, 1100);
    await tester.tap(find.byKey(const Key('player-close')));
    await frames(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(player, findsNothing);
    expect(
      secs(shown(tester, mini, 'play-wait')),
      greaterThanOrEqualTo(inPlayer + 1),
      reason: 'mini-player restarted timer after player',
    );
  });

  testWidgets('new tap resets timer to zero', (tester) async {
    final rig = Rig();
    // Only one track in search sample — second track needed for second tap.
    rig.server.on('GET /v1/search', (_) {
      final body = sample('search');
      final first = (body['tracks'] as List).first as Map<String, dynamic>;
      body['tracks'] = [
        first,
        {
          ...first,
          'id': '11111112-1111-1111-1111-111111111111',
          'title': 'One',
        },
      ];
      return answer(200, body);
    });
    await rig.start(tester);
    await tester.pumpAndSettle();
    await typeSearch(tester, 'metallica');
    await tester.tap(find.text('Nothing Else Matters'));
    await frames(tester);
    await wait(tester, 2100);
    final before = secs(shown(tester, mini, 'play-wait'));
    expect(before, greaterThanOrEqualTo(2));

    await tester.tap(find.text('One').first);
    await frames(tester);
    expect(shown(tester, mini, 'play-wait'), contains('· 0 с'));
  });
}
