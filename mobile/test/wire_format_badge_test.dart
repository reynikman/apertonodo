import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/screens/player_screen.dart';
import 'package:music_stream/track_formats.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';
import 'fakes.dart' show tokensFor;
import 'player_fixes_test.dart' show openPlayer, song;

/// Wire 3a, badge (11.10): server specifies format in Play response
/// (FT-684), badge supported rendering it (FT-633), but wiring was missing.
/// Now format from response propagates to player screen.
const id = '33333333-3333-3333-3333-333333333333';

Future<TrackFormats> afterPlay(Object? audio) async {
  final formats = TrackFormats();
  final playback = HttpPlayback(
    'https://music.test',
    tokens: tokensFor('https://music.test'),
    client: MockClient(
      (_) async => http.Response(
        jsonEncode({
          'token': 't',
          'state': 'ready',
          'track': <String, Object>{},
          'audio': ?audio,
        }),
        200,
      ),
    ),
    formats: formats,
  );
  await playback.start(id);
  return formats;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('format from Play response stored with track', () async {
    expect((await afterPlay({'format': 'flac'})).of(id), 'flac');
  });

  test('missing block or unexpected word shows no badge', () async {
    expect((await afterPlay(null)).of(id), isNull);
    expect((await afterPlay({'format': 'magnet:?xt'})).of(id), isNull);
    expect((await afterPlay('flac')).of(id), isNull);
  });

  testWidgets('FLAC badge shown in player next to artist', (tester) async {
    final semantics = tester.ensureSemantics();
    final formats = TrackFormats();
    final rig = Rig(formats: formats);
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

    final badge = find.byKey(const Key('player-format'));
    expect(badge, findsNothing, reason: 'unknown format shows no badge');

    final current = tester
        .widget<PlayerScreen>(find.byType(PlayerScreen))
        .player
        .current!;
    formats.note(current.id, {'format': 'flac'});
    await tester.pumpAndSettle();
    expect(find.descendant(of: badge, matching: find.text('FLAC')), findsOne);
    expect(tester.getSemantics(badge).label, contains('Формат: FLAC'));
    semantics.dispose();
  });
}
