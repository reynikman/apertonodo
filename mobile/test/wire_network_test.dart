import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/app.dart';
import 'package:music_stream/models/track.dart';
import 'package:music_stream/network_watch.dart';
import 'package:music_stream/playback.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';
import 'fakes.dart';

/// Wire 10 (12.10): "network returned" signal (FT-691) was implemented, but
/// player did not listen to it, waiting for scheduled backoff after disconnect —
/// after ten minutes offline remained in error until "Retry". Now restored
/// network triggers immediate retry.
class FakeNetwork implements NetworkPort {
  final changes = StreamController<bool>.broadcast();

  @override
  Stream<bool> get online => changes.stream;

  @override
  Future<bool> get isOnline async => true;
}

/// Server unresponsive: retry schedule 1, 2, 4, 8 s — requests at 0, 1, 3,
/// 7 s. Network dropped at 3.5 s and returned at 4 s; after 2 s (6 s) — signal.
Future<FakePlayback> lostAndBack(
  WidgetTester tester, {
  required bool wired,
}) async {
  final audio = FakeAudio();
  addTearDown(audio.close);
  final network = FakeNetwork();
  addTearDown(network.changes.close);
  final playback = FakePlayback([PlayFailure.noAnswer]);
  await tester.pumpWidget(
    MusicApp(
      catalog: [
        Track(
          id: '1',
          title: 'Duality',
          artist: 'Slipknot',
          durationMs: 252000,
          artworkUrl: '',
        ),
      ],
      playback: playback,
      audio: audio,
      server: FakeServer().api(),
      network: wired ? network : null,
    ),
  );
  await tester.pumpAndSettle();
  await typeSearch(tester, 'duality');
  await tester.tap(find.text('Duality').first);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 3500));
  network.changes.add(false);
  await tester.pump(const Duration(milliseconds: 500));
  network.changes.add(true);
  await tester.pump(const Duration(milliseconds: 2500));
  return playback;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('network returned: instant retry, not in 7s', (tester) async {
    final playback = await lostAndBack(tester, wired: true);
    expect(playback.started, hasLength(4));
  });

  testWidgets('no signal: retries only on schedule', (tester) async {
    final playback = await lostAndBack(tester, wired: false);
    expect(playback.started, hasLength(3));
  });
}
