import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/app.dart';
import 'package:music_stream/playback.dart';

import 'fakes.dart';

void main() {
  testWidgets('tapping song in results plays it right away', (tester) async {
    // Owner bug September 18: picking a track did not start playback, in mini player
    // Play button appeared, requiring a second tap.
    final playback = FakePlayback(['http://192.0.2.1:8088/v1/stream/tok']);
    final audio = FakeAudio();
    addTearDown(audio.close);
    await tester.pumpWidget(
      MusicApp(catalog: const [duality], playback: playback, audio: audio),
    );

    await tester.enterText(find.byKey(const Key('search-field')), 'duality');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.tap(find.text('Duality').first);
    await tester.pump();

    expect(playback.started, [duality.id]);
    expect(audio.played.single.$1, 'http://192.0.2.1:8088/v1/stream/tok');
    expect(find.text('Готовим звук'), findsOneWidget);
    expect(find.byKey(const Key('play-button')), findsNothing);

    audio.emit(AudioPhase.playing);
    await tester.pump();
    expect(find.text('Играет'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const Key('mini-player')),
        matching: find.text('Slipknot'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('pause-button')), findsOneWidget);
    expect(find.textContaining('torrent'), findsNothing);
  });
}
