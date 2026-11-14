import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/screens/player_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';
import 'player_fixes_test.dart' show openPlayer, playing;
import 'player_menu_links_test.dart' show albumId, withAlbum;

/// Wire 1 (11.10): sleep timer (FT-619) and "Report problem"
/// (FT-622/627) were implemented, but no screen opened them. Now both are
/// player menu items in real app, functioning properly: timer sets
/// pause, report sent to server.
final menu = find.byKey(const Key('player-menu'));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('sleep timer: menu item, sheet, End of Song reaches the '
      'player', (tester) async {
    await playing(tester);
    await openPlayer(tester);
    // FT-805: sleep timer is quick actions row icon, not menu item.
    await tester.ensureVisible(find.byKey(const Key('player-quick-sleep')));
    await tapAndSettle(tester, find.byKey(const Key('player-quick-sleep')));
    expect(find.text('Таймер сна'), findsOneWidget);

    await tapAndSettle(tester, find.byKey(const Key('sleep-end-of-track')));
    final player = tester.widget<PlayerScreen>(find.byType(PlayerScreen));
    expect(player.player.stopAfterCurrent, isTrue);
    expect(find.byKey(const Key('sleep-off')), findsOneWidget);

    await tapAndSettle(tester, find.byKey(const Key('sleep-off')));
    expect(player.player.stopAfterCurrent, isFalse);
  });

  testWidgets('Report Issue: problem report sent to server', (tester) async {
    final rig = await playing(tester);
    rig.server.on(
      'POST /v1/problems',
      (_) => answer(202, {'status': 'accepted'}),
    );
    await openPlayer(tester);
    final current = tester
        .widget<PlayerScreen>(find.byType(PlayerScreen))
        .player
        .current!;

    await tapAndSettle(tester, menu);
    await tapAndSettle(tester, find.byKey(const Key('player-problem')));
    await tapAndSettle(tester, find.byKey(const Key('problem-reason-no_play')));
    await tapAndSettle(tester, find.byKey(const Key('problem-send')));

    final sent = rig.server.bodies('POST /v1/problems');
    expect(sent, hasLength(1));
    expect(sent.single['place'], 'player');
    expect(sent.single['reason'], 'no_play');
    expect(sent.single['track_id'], current.id);
    expect(find.text('Спасибо, отчёт отправлен'), findsOneWidget);
  });

  testWidgets('server returned 429 - sheet reports it, report not lost '
      'silently', (tester) async {
    final rig = await playing(tester);
    rig.server.on(
      'POST /v1/problems',
      (_) => answer(429, {'status': 'too_many_requests'}),
    );
    await openPlayer(tester);
    await tapAndSettle(tester, menu);
    await tapAndSettle(tester, find.byKey(const Key('player-problem')));
    await tapAndSettle(tester, find.byKey(const Key('problem-reason-no_play')));
    await tapAndSettle(tester, find.byKey(const Key('problem-send')));
    expect(find.byKey(const Key('problem-send')), findsOneWidget);
    expect(find.textContaining('Слишком'), findsOneWidget);
  });

  Future<Map<String, dynamic>> report(
    WidgetTester tester,
    Rig rig,
    String button,
    String reason,
  ) async {
    await tester.scrollUntilVisible(
      find.byKey(Key(button)),
      300,
      scrollable: find
          .byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          )
          .last,
    );
    await tapAndSettle(tester, find.byKey(Key(button)));
    await tapAndSettle(tester, find.byKey(Key('problem-reason-$reason')));
    await tapAndSettle(tester, find.byKey(const Key('problem-send')));
    return rig.server.bodies('POST /v1/problems').single;
  }

  testWidgets('album page: report specifies this album', (tester) async {
    final rig = await withAlbum(tester);
    rig.server.on(
      'POST /v1/problems',
      (_) => answer(202, {'status': 'accepted'}),
    );
    await tapAndSettle(tester, menu);
    await tapAndSettle(tester, find.text('К альбому'));
    final sent = await report(tester, rig, 'album-problem', 'cover');
    expect(sent['place'], 'album');
    expect(sent['album_id'], albumId);
    expect(sent['reason'], 'cover');
  });

  testWidgets('artist page: report specifies this artist', (tester) async {
    final rig = await withAlbum(tester);
    rig.server.on(
      'POST /v1/problems',
      (_) => answer(202, {'status': 'accepted'}),
    );
    await tapAndSettle(tester, menu);
    await tapAndSettle(tester, find.text('К исполнителю'));
    final sent = await report(tester, rig, 'artist-problem', 'wrong_name');
    expect(sent['place'], 'artist');
    expect(sent['artist'], 'Metallica');
  });
}
