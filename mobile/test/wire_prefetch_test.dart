import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/app.dart';
import 'package:music_stream/models/track.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/prefetch_policy.dart';
import 'package:music_stream/quality_prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';
import 'fakes.dart';
import 'player_fixes_test.dart' show openPlayer, song;

/// Wire 10 (12.10): prefetch policy (FT-692, P-A101) was implemented,
/// but player always preloaded next track, and setting section was absent from all
/// screens. Now player queries preference, and section is in "Audio
/// quality" sheet. In tests Android does not report metered status — treated as
/// metered, matching downloader (FT-522).
Future<void> playSong(WidgetTester tester, Rig rig) async {
  await rig.start(tester);
  await tester.pumpAndSettle();
  await typeSearch(tester, 'metallica');
  await tester.tap(find.text(song));
  await tester.pump();
  rig.audio.emit(AudioPhase.playing);
  await tester.pump();
  await tester.pump();
}

Track _song(int n) => Track(
  id: '$n',
  title: 'Duality $n',
  artist: 'Slipknot',
  durationMs: 252000,
  artworkUrl: '',
);

/// Three tracks in results: first playing — next (`2`) prepared in advance.
Future<FakePlayback> playFirst(
  WidgetTester tester,
  PrefetchPolicy prefetch,
) async {
  final audio = FakeAudio();
  addTearDown(audio.close);
  final playback = FakePlayback();
  await tester.pumpWidget(
    MusicApp(
      catalog: [_song(1), _song(2), _song(3)],
      playback: playback,
      audio: audio,
      server: FakeServer().api(),
      prefetch: prefetch,
    ),
  );
  await tester.pumpAndSettle();
  await typeSearch(tester, 'duality');
  await tester.tap(find.text('Duality 1').first);
  await tester.pump();
  await tester.pump();
  audio.emit(AudioPhase.playing);
  await tester.pump();
  await tester.pump();
  return playback;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('"Always": next track prefetched as before', (tester) async {
    final playback = await playFirst(tester, PrefetchPolicy());
    expect(playback.prepared, contains('2'));
  });

  testWidgets('"Never": next track is not prefetched', (tester) async {
    final prefetch = PrefetchPolicy();
    await prefetch.set(PrefetchMode.never);
    final playback = await playFirst(tester, prefetch);
    expect(playback.prepared, isNot(contains('2')));
  });

  testWidgets('"Wi-Fi only" on metered network does not prefetch', (
    tester,
  ) async {
    final prefetch = PrefetchPolicy();
    await prefetch.set(PrefetchMode.wifiOnly);
    final playback = await playFirst(tester, prefetch);
    expect(playback.prepared, isNot(contains('2')));
  });

  testWidgets('section in Audio Quality sheet, choice saved', (tester) async {
    final prefetch = PrefetchPolicy();
    final rig = Rig(account: true, prefetch: prefetch, quality: QualityPrefs());
    await playSong(tester, rig);
    await openTab(tester, 'home');
    await tester.pumpAndSettle();
    await openPlayer(tester);

    await openSoundQuality(tester);
    expect(find.text('Подгрузка следующей песни'), findsOneWidget);

    await tester.ensureVisible(find.text('Никогда'));
    await tapAndSettle(tester, find.text('Никогда'));
    expect(prefetch.mode, PrefetchMode.never);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('prefetch_mode'), 'never');
  });
}
