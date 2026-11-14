import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/models/track.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/player.dart';
import 'package:music_stream/screens/player_screen.dart';

import 'fakes.dart';

Track song(int n) => Track(
  id: 't$n',
  title: 'Song $n',
  artist: 'Band',
  durationMs: 200000,
  artworkUrl: '',
);

void main() {
  testWidgets('cover scrolls away, queue reachable', (tester) async {
    tester.view.physicalSize = const Size(400, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final songs = [for (var n = 1; n <= 20; n++) song(n)];
    final player = Player();
    addTearDown(player.dispose);
    await player.playQueue(songs);

    await tester.pumpWidget(MaterialApp(home: PlayerScreen(player: player)));
    await tester.pump();

    final title = find.byKey(const Key('player-title'));
    expect(title, findsOneWidget);
    expect(tester.getRect(title).bottom, greaterThan(0));

    await tester.fling(
      find.byKey(const Key('queue')),
      const Offset(0, -2500),
      8000,
    );
    await tester.pumpAndSettle();

    final titleAfter = find.byKey(const Key('player-title'));
    expect(
      titleAfter.evaluate().isEmpty || tester.getRect(titleAfter).bottom < 0,
      isTrue,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('queue')),
        matching: find.text('Song 12'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('dedicated pause button on player screen', (tester) async {
    final audio = FakeAudio();
    addTearDown(audio.close);
    final player = Player(playback: FakePlayback(), audio: audio);
    addTearDown(player.dispose);
    await player.playQueue([song(1)]);
    audio.emit(AudioPhase.playing);

    await tester.pumpWidget(MaterialApp(home: PlayerScreen(player: player)));
    await tester.pump();

    expect(find.byKey(const Key('player-pause-button')), findsOneWidget);
    final before = audio.pauses;
    await tester.tap(find.byKey(const Key('player-pause-button')));
    await tester.pump();
    expect(audio.pauses, before + 1);
  });

  testWidgets('«Download» reports result, not silent', (tester) async {
    final player = Player();
    addTearDown(player.dispose);
    await player.playQueue([song(1)]);
    final saved = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        home: PlayerScreen(
          player: player,
          onDownload: (track) async => saved.add(track.title),
        ),
      ),
    );
    await tester.pump();
    // "Download" is quick actions row icon below control buttons (FT-805).
    await tester.ensureVisible(find.byKey(const Key('player-quick-download')));
    await tester.tap(find.byKey(const Key('player-quick-download')));
    await tester.pumpAndSettle();

    expect(saved, ['Song 1']);
    expect(find.textContaining('Добавлено в «Загрузки»'), findsOneWidget);
    expect(find.text('Очередь'), findsOneWidget);
  });
}
