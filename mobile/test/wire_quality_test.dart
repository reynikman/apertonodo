import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/quality_prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';
import 'fakes.dart' show tokensFor;
import 'player_fixes_test.dart' show openPlayer, song;

/// Wire 3a (11.10): audio quality (FT-633) was implemented, but no
/// screen opened it, and server answered "lossless" with 422. Now sheet is
/// player menu item, and selected mode sent with each Play.
final menu = find.byKey(const Key('player-menu'));

Future<Map<String, dynamic>> sentBody({
  bool opus = false,
  bool lossless = false,
}) async {
  late Map<String, dynamic> body;
  final playback = HttpPlayback(
    'https://music.test',
    tokens: tokensFor('https://music.test'),
    client: MockClient((request) async {
      body = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode({'token': 't', 'state': 'ready', 'track': {}}),
        200,
      );
    }),
    preferOpus: () async => opus,
    preferLossless: () => lossless,
  );
  await playback.start('33333333-3333-3333-3333-333333333333');
  return body;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('"Lossless only" sends lossless to Play request', () async {
    expect((await sentBody(lossless: true))['prefer'], 'lossless');
  });

  test('compressed preferred: metered network sends opus', () async {
    expect((await sentBody(opus: true, lossless: true))['prefer'], 'opus');
  });

  test('no mode: field omitted as before', () async {
    expect((await sentBody()).containsKey('prefer'), isFalse);
  });

  testWidgets('Audio Quality player menu item persists selection', (
    tester,
  ) async {
    final quality = QualityPrefs();
    final rig = Rig(account: true, quality: quality);
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

    await openSoundQuality(tester);
    expect(find.text('Качество звука'), findsOneWidget);

    await tapAndSettle(tester, find.byKey(const Key('quality-lossless')));
    expect(quality.mode, QualityMode.lossless);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('quality-mode'), 'lossless');
  });
}
