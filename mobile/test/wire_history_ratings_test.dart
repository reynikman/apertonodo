import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'back.dart';
import 'fake_server.dart';
import 'player_fixes_test.dart' show openPlayer, playing;

/// Wire 2 (11.10): history (FT-630/634) and ratings (FT-629/638/642)
/// were implemented, but screens did not open them. Now in real app:
/// history row removed by swipe and synced to server with exact timestamp;
/// pause and "Clear" on history screen; "Rate" in player
/// menu; "Rated" and "Disliked" in "My Music".
const songId = '33333333-3333-3333-3333-333333333333';
const playedAt = '2026-09-19T18:04:11.532000+00:00';

Future<Rig> openHistory(WidgetTester tester) async {
  final rig = Rig();
  rig.server
    ..on('GET /v1/history/pause', (_) => answer(200, {'paused': false}))
    ..on('POST /v1/history/remove', (_) => answer(200, {'removed': 1}))
    ..on('POST /v1/history/clear', (_) => answer(200, {'removed': 1}))
    ..on(
      'POST /v1/history/pause',
      (_) => answer(200, {
        'paused': true,
        'until': DateTime.now()
            .toUtc()
            .add(const Duration(hours: 3))
            .toIso8601String(),
      }),
    );
  await rig.start(tester);
  await tester.pumpAndSettle();
  await openTab(tester, 'library');
  await tapAndSettle(tester, find.byKey(const Key('library-history')));
  return rig;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('swipe removes row, after 5s sent to server with exact '
      'timestamp', (tester) async {
    final rig = await openHistory(tester);
    expect(find.text('Duality'), findsOneWidget);
    await tester.drag(find.text('Duality'), const Offset(-600, 0));
    await tester.pumpAndSettle();
    await tapAndSettle(tester, find.byKey(const Key('trash-reveal-button')));
    expect(find.text('Duality'), findsNothing);
    expect(rig.server.calls('POST /v1/history/remove'), isEmpty);

    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    final sent = rig.server.bodies('POST /v1/history/remove');
    expect(sent, hasLength(1));
    expect(sent.single['track_id'], songId);
    expect(
      DateTime.parse(sent.single['played_at'] as String),
      DateTime.parse(playedAt),
    );
  });

  testWidgets('Undo restores row, nothing sent to server', (tester) async {
    final rig = await openHistory(tester);
    await tester.drag(find.text('Duality'), const Offset(-600, 0));
    await tester.pumpAndSettle();
    await tapAndSettle(tester, find.byKey(const Key('trash-reveal-button')));
    await tapAndSettle(tester, find.text('Отменить'));
    expect(find.text('Duality'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    expect(rig.server.calls('POST /v1/history/remove'), isEmpty);
  });

  testWidgets('history pause toggle sent to server', (tester) async {
    final rig = await openHistory(tester);
    await tapAndSettle(tester, find.text('Не записывать историю'));
    // FT-853: first the person picks how long.
    expect(rig.server.calls('POST /v1/history/pause'), isEmpty);
    await tapAndSettle(tester, find.byKey(const Key('history-pause-hour')));
    final sent = rig.server.bodies('POST /v1/history/pause').single;
    expect(sent['paused'], true);
    final until = DateTime.parse(sent['until'] as String);
    expect(
      until.isUtc,
      isTrue,
      reason: 'the server refuses a time without zone',
    );
    expect(
      until.difference(DateTime.now()).inMinutes,
      inInclusiveRange(58, 60),
    );
    expect(find.textContaining('До '), findsOneWidget);
  });

  testWidgets('Clear prompts, clears history and reloads list', (tester) async {
    final rig = await openHistory(tester);
    rig.server.on('GET /v1/history', (_) => answer(200, {'tracks': []}));
    await tapAndSettle(tester, find.byKey(const Key('history-clear')));
    await tapAndSettle(tester, find.text('Стереть'));
    expect(rig.server.calls('POST /v1/history/clear'), hasLength(1));
    expect(find.text('Duality'), findsNothing);
  });

  testWidgets('Rate in player menu: rating sent to server', (tester) async {
    final rig = await playing(tester);
    rig.server
      ..on('POST /v1/ratings/of', (_) => answer(200, {'ratings': {}}))
      ..on(
        'POST /v1/ratings',
        (_) => answer(200, {'stars': 4, 'disliked': false}),
      );
    await openPlayer(tester);
    await tapAndSettle(tester, find.byKey(const Key('player-menu')));
    await tapAndSettle(tester, find.byKey(const Key('player-rate')));
    await tapAndSettle(tester, find.byKey(const Key('rating-star-4')));
    final sent = rig.server.bodies('POST /v1/ratings');
    expect(sent, hasLength(1));
    expect(sent.single['stars'], 4);
    expect(sent.single.containsKey('disliked'), isFalse);
  });

  testWidgets('My Music: Rated and Disliked query server', (tester) async {
    final rig = Rig();
    final song = songLike('library-history', songId, 'Duality');
    rig.server.on(
      'GET /v1/ratings',
      (request) => answer(200, {
        'tracks': [
          {...song, 'stars': 5, 'disliked': false},
        ],
        'total': 1,
      }),
    );
    await rig.start(tester);
    await tester.pumpAndSettle();
    await openTab(tester, 'library');
    // With "Books" row moved below test viewport — scroll down to it.
    await tester.scrollUntilVisible(
      find.byKey(const Key('library-rated')),
      200,
    );
    await tapAndSettle(tester, find.byKey(const Key('library-rated')));
    expect(find.text('Duality'), findsOneWidget);
    expect(
      rig.server.calls('GET /v1/ratings').last.url.queryParameters['min_stars'],
      '1',
    );

    await tapBack(tester);
    await tester.pumpAndSettle();
    // With "Books" row moved below test viewport — scroll down to it.
    await tester.scrollUntilVisible(
      find.byKey(const Key('library-disliked')),
      200,
    );
    await tapAndSettle(tester, find.byKey(const Key('library-disliked')));
    expect(
      rig.server.calls('GET /v1/ratings').last.url.queryParameters['disliked'],
      'true',
    );
  });
}
