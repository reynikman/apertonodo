import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';
import 'player_fixes_test.dart' show openPlayer, playing;

/// Wire 3b (11.10): lyrics view (FT-623) and core endpoint (FT-624) were
/// implemented, but app did not request lyrics or open screen. Now —
/// "Lyrics" option in player menu.
final menu = find.byKey(const Key('player-menu'));

Future<void> openLyrics(WidgetTester tester) async {
  await openPlayer(tester);
  // FT-805: "Lyrics" is quick actions row icon below buttons, not menu item.
  await tester.ensureVisible(find.byKey(const Key('player-quick-lyrics')));
  await tapAndSettle(tester, find.byKey(const Key('player-quick-lyrics')));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Lyrics in player menu displays song words', (tester) async {
    final rig = await playing(tester);
    rig.server.on(
      'GET /v1/lyrics/*',
      (_) => answer(200, {
        'found': true,
        'instrumental': false,
        'plain': 'Первая строка\nВторая строка',
        'synced': '[00:01.00] Первая строка\n[00:05.00] Вторая строка',
      }),
    );
    await openLyrics(tester);

    expect(find.text('Первая строка'), findsOneWidget);
    expect(find.text('Вторая строка'), findsOneWidget);
    expect(rig.server.calls('GET /v1/lyrics/*'), hasLength(1));
  });

  testWidgets('lyrics service failed - sheet reports that no lyrics '
      'are found', (tester) async {
    final rig = await playing(tester);
    rig.server.on(
      'GET /v1/lyrics/*',
      (_) => answer(503, {'error': 'lyrics_off'}),
    );
    await openLyrics(tester);
    expect(find.text('Текста этой песни пока нет'), findsOneWidget);
  });
}
