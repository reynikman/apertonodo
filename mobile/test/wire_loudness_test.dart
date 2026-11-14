import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_stream/loudness.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/screens/player_screen.dart';
import 'package:music_stream/track_formats.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';
import 'fakes.dart' show tokensFor;
import 'player_fixes_test.dart' show openPlayer, song;

/// FT-765: loudness normalization (FT-650) wired.
///
/// Server includes `gain_db` adjustment in Play response (m27), app supported
/// calculating it (`loudness.dart`), but audio engine did not receive it. Now gain
/// stored with format, toggle placed in "Audio quality"
/// sheet, and enabling toggle immediately adjusts volume.
const id = '33333333-3333-3333-3333-333333333333';
final menu = find.byKey(const Key('player-menu'));

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

  test('gain from Play response saved with track', () async {
    final formats = await afterPlay({'format': 'mp3', 'gain_db': -6.0});
    expect(formats.gainOf(id), -6.0);
    expect(formats.of(id), 'mp3');
  });

  test('no gain in response means no gain value', () async {
    expect((await afterPlay({'format': 'mp3'})).gainOf(id), isNull);
    expect((await afterPlay(null)).gainOf(id), isNull);
  });

  testWidgets('Audio Quality toggle immediately lowers loud track', (
    tester,
  ) async {
    final formats = TrackFormats();
    final rig = Rig(account: true, formats: formats);
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

    final current = tester
        .widget<PlayerScreen>(find.byType(PlayerScreen))
        .player
        .current!;
    formats.note(current.id, {'format': 'mp3', 'gain_db': -6.0});
    await tester.pump();
    expect(
      rig.audio.volumes.where((v) => v < 1.0),
      isEmpty,
      reason: 'disabled by default (P-A96)',
    );

    await openSoundQuality(tester);
    await tapAndSettle(tester, find.byKey(const Key('quality-loudness')));

    expect(
      rig.audio.volumes.last,
      closeTo(loudnessVolume(enabled: true, gainDb: -6.0), 1e-6),
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('loudness-enabled'), isTrue);

    await tapAndSettle(tester, find.byKey(const Key('quality-loudness')));
    expect(rig.audio.volumes.last, 1.0, reason: 'disabled: volume restored');
  });
}
