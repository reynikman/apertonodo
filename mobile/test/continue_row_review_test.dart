import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/continue_shelf.dart';
import 'package:music_stream/screens/continue_row.dart';

// Lead check FT-731, return 1 (Sonnet blind review). Executor does not
// modify this file.

/// Cover art that failed to load: 404, network drop, corrupt file.
class _Broken extends ImageProvider<_Broken> {
  @override
  Future<_Broken> obtainKey(ImageConfiguration configuration) async => this;

  @override
  ImageStreamCompleter loadImage(_Broken key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(Future.error(Exception('404')));
}

const texts = ContinueTexts(
  title: 'Продолжить',
  left: _left,
  part: _part,
  play: _play,
);

String _left(String time) => 'Осталось $time';
String _part(int part, int count) => 'Часть $part из $count';
String _play(String title) => 'Продолжить: $title';

ContinueItem episode(String key, {String? image}) => ContinueItem(
  meta: ContinueMeta(
    kind: ContinueKind.podcast,
    key: key,
    title: 'Выпуск 4',
    subtitle: 'Подкаст',
    imageUrl: image,
    durationMs: 3600000,
  ),
  positionMs: 60000,
  updatedAt: DateTime.utc(2026),
  remainingMs: 18 * 60000,
);

Future<void> pump(
  WidgetTester tester,
  List<ContinueItem> items, {
  ImageProvider? Function(String url)? image,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ContinueRow(
          items: items,
          texts: texts,
          duration: (ms) => '${ms ~/ 60000} мин',
          onTap: (_) {},
          image: image,
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('broken cover shows placeholder, not error', (tester) async {
    await pump(tester, [episode('a', image: 'x')], image: (_) => _Broken());
    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.podcasts), findsOneWidget);
  });

  testWidgets('TalkBack reads title and remainder', (tester) async {
    await pump(tester, [episode('a')]);
    final node = tester.getSemantics(find.byKey(const ValueKey('continue-a')));
    expect(node.label, contains('Продолжить: Выпуск 4'));
    expect(node.label, contains('Осталось 18 мин'));
  });

  testWidgets('row heading is heading for TalkBack', (tester) async {
    await pump(tester, [episode('a')]);
    final node = tester.getSemantics(find.text('Продолжить'));
    expect(node.flagsCollection.isHeader, isTrue);
  });
}
