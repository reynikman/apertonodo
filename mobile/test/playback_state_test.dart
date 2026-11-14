import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/app.dart';
import 'package:music_stream/playback.dart';

import 'fakes.dart';

Future<void> selectTrack(WidgetTester tester) async {
  await tester.enterText(find.byKey(const Key('search-field')), 'duality');
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pump();
  await tester.tap(find.text('Duality').first);
  await tester.pump();
}

void main() {
  late FakeAudio audio;

  setUp(() => audio = FakeAudio());
  tearDown(() => audio.close());

  testWidgets('«Playing» — only when real player plays', (tester) async {
    final answer = Completer<String>();
    await tester.pumpWidget(
      MusicApp(
        catalog: const [duality],
        playback: FakePlayback([answer]),
        audio: audio,
      ),
    );
    await selectTrack(tester);

    expect(find.text('Ищем источник'), findsOneWidget);
    // While server searches for source, no second tap allowed — no button either.
    expect(find.byKey(const Key('play-button')), findsNothing);

    answer.complete('https://example.test/stream/token');
    await tester.pump();
    expect(find.text('Играет'), findsNothing);

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

    await tester.tap(find.byKey(const Key('pause-button')));
    await tester.pump();
    expect(audio.pauses, 2);
  });

  testWidgets('server refusal gives reason and retry', (tester) async {
    final playback = FakePlayback([
      PlayFailure.noSource,
      'https://example.test/stream/retry',
    ]);
    await tester.pumpWidget(
      MusicApp(catalog: const [duality], playback: playback, audio: audio),
    );
    await selectTrack(tester);

    expect(find.text('Источник не нашёлся — повторить'), findsOneWidget);
    await tester.tap(find.byKey(const Key('retry-button')));
    await tester.pump();
    expect(playback.started, hasLength(2));
    expect(find.text('Готовим звук'), findsOneWidget);
  });

  testWidgets('broken stream shows retry instead of hanging on buffering', (
    tester,
  ) async {
    // Server granted token, but stream itself failed to open: expired token,
    // dropped network, container restart. Previously player exception
    // leaked unhandled and screen remained stuck on "Buffering" forever.
    audio.failNextPlay = StateError('поток оборвался');
    final playback = FakePlayback([
      'https://example.test/stream/stale',
      'https://example.test/stream/fresh',
    ]);
    await tester.pumpWidget(
      MusicApp(catalog: const [duality], playback: playback, audio: audio),
    );
    await selectTrack(tester);

    expect(find.text('Готовим звук'), findsNothing);
    expect(find.text('Не удалось — повторить'), findsOneWidget);

    // Retry acquires new token and reaches player this time.
    await tester.tap(find.byKey(const Key('retry-button')));
    await tester.pump();
    expect(playback.started, hasLength(2));
    expect(audio.played.single.$1, 'https://example.test/stream/fresh');
  });

  testWidgets('drop mid-song — not «Playing» in silence', (tester) async {
    await tester.pumpWidget(
      MusicApp(
        catalog: const [duality],
        playback: FakePlayback(),
        audio: audio,
      ),
    );
    await selectTrack(tester);
    audio.emit(AudioPhase.playing);
    await tester.pump();

    audio.emit(AudioPhase.error, position: const Duration(seconds: 42));
    await tester.pump();

    expect(find.text('Играет'), findsNothing);
    expect(find.text('Обрыв — повторить'), findsOneWidget);
    expect(find.byKey(const Key('retry-button')), findsOneWidget);
  });

  testWidgets('network failed — not endless «Finding source»', (tester) async {
    await tester.pumpWidget(
      MusicApp(
        catalog: const [duality],
        playback: FakePlayback([PlayFailure.noAnswer]),
        audio: audio,
      ),
    );
    await selectTrack(tester);

    expect(find.text('Ищем источник'), findsNothing);
    expect(find.text('Сервер не ответил — повторить'), findsOneWidget);
  });

  testWidgets(
    'while server searches — «Finding source», after — «Preparing audio»',
    (tester) async {
      final answer = Completer<String>();
      await tester.pumpWidget(
        MusicApp(
          catalog: const [duality],
          playback: FakePlayback([answer]),
          audio: audio,
        ),
      );
      await selectTrack(tester);

      expect(find.text('Ищем источник'), findsOneWidget);
      expect(find.text('Готовим звук'), findsNothing);

      answer.complete('https://example.test/stream/token');
      await tester.pump();
      expect(find.text('Ищем источник'), findsNothing);
      expect(find.text('Готовим звук'), findsOneWidget);
    },
  );
}
