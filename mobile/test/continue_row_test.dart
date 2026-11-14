import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/continue_shelf.dart';
import 'package:music_stream/screens/continue_row.dart';

/// "Continue" shelf at top of podcasts section (FT-731, draft Pd-1 view).
///
/// Contract `mobile/lib/screens/continue_row.dart`:
/// - `ContinueTexts({required title, required left, required part,
///   required play})`: `title` — shelf header ("Continue"),
///   `left(String time)` — "18 min left", `part(int part, int count)` —
///   "Part 3 of 12", `play(String title)` — TalkBack label of card
///   ("Continue: Episode 4").
/// - `ContinueRow({required items, required texts, required duration,
///   required onTap, this.image})`: `duration(int ms) -> String` — duration
///   in words ("18 min", provided by screen); `image(String url) -> ImageProvider?` —
///   cover art (no function or `null` — offline placeholder).
/// - Empty list — no shelf at all (neither header nor height).
/// - Header, followed by horizontal strip of cards with key
///   `ValueKey('continue-<meta.key>')` in list order. Inside card: cover,
///   title (up to 2 lines), subtitle `meta.subtitle` (1 line), remaining
///   progress label: for episode with `remainingMs` — `left(duration(remainingMs))`;
///   for book with `part` and `meta.partCount` — `part(part, partCount)`; otherwise
///   no label.
/// - Tapping card invokes `onTap(item)`; card is single button for TalkBack
///   with label `play(meta.title)` and joined by ", " remaining label if present
///   (return 1), tap target height at least 48.
/// - No literal strings in shelf code — all via `texts` and `duration`.
/// - Font scale ×2 on 360 dp: nothing overflows (no layout errors).
void main() {
  ContinueItem episode(
    String key, {
    String title = 'Выпуск',
    int? remainingMs,
    String? image,
  }) => ContinueItem(
    meta: ContinueMeta(
      kind: ContinueKind.podcast,
      key: key,
      title: title,
      subtitle: 'Подкаст',
      imageUrl: image,
      durationMs: 3_600_000,
    ),
    positionMs: 60_000,
    updatedAt: DateTime.utc(2026, 10, 10),
    remainingMs: remainingMs,
  );

  ContinueItem book(String key, {int? part, int? count}) => ContinueItem(
    meta: ContinueMeta(
      kind: ContinueKind.book,
      key: key,
      title: 'Книга',
      subtitle: 'Автор',
      partCount: count,
    ),
    positionMs: 60_000,
    updatedAt: DateTime.utc(2026, 10, 10),
    part: part,
  );

  const texts = ContinueTexts(
    title: 'Продолжить',
    left: _left,
    part: _part,
    play: _play,
  );

  Future<List<ContinueItem>> pump(
    WidgetTester tester,
    List<ContinueItem> items, {
    ImageProvider? Function(String url)? image,
    double scale = 1.0,
    double width = 412,
  }) async {
    final tapped = <ContinueItem>[];
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: Size(width, 800),
            textScaler: TextScaler.linear(scale),
          ),
          child: Scaffold(
            body: ListView(
              children: [
                ContinueRow(
                  items: items,
                  texts: texts,
                  duration: (ms) => '${ms ~/ 60000} мин',
                  onTap: tapped.add,
                  image: image,
                ),
                const Text('ниже'),
              ],
            ),
          ),
        ),
      ),
    );
    return tapped;
  }

  testWidgets('empty: row is absent entirely', (tester) async {
    await pump(tester, const []);
    expect(find.text('Продолжить'), findsNothing);
    expect(tester.getTopLeft(find.text('ниже')).dy, 0);
  });

  testWidgets('heading and cards in list order', (tester) async {
    await pump(tester, [
      episode('a', title: 'Первый'),
      episode('b', title: 'Второй'),
      episode('c', title: 'Третий'),
    ]);
    expect(find.text('Продолжить'), findsOneWidget);
    final a = tester.getTopLeft(find.byKey(const ValueKey('continue-a')));
    final b = tester.getTopLeft(find.byKey(const ValueKey('continue-b')));
    final c = tester.getTopLeft(find.byKey(const ValueKey('continue-c')));
    expect(a.dx < b.dx && b.dx < c.dx, isTrue);
    expect(a.dy, b.dy);
    expect(find.text('Первый'), findsOneWidget);
    expect(find.text('Подкаст'), findsNWidgets(3));
  });

  testWidgets('episode shows time remaining', (tester) async {
    await pump(tester, [episode('a', remainingMs: 18 * 60000)]);
    expect(find.text('Осталось 18 мин'), findsOneWidget);
  });

  testWidgets('episode without duration: no remaining line', (tester) async {
    await pump(tester, [episode('a')]);
    expect(find.textContaining('Осталось'), findsNothing);
  });

  testWidgets('book shows part out of total', (tester) async {
    await pump(tester, [book('k', part: 3, count: 12)]);
    expect(find.text('Часть 3 из 12'), findsOneWidget);
    expect(find.textContaining('Осталось'), findsNothing);
  });

  testWidgets('book without part count: no count line', (tester) async {
    await pump(tester, [book('k', part: 3)]);
    expect(find.textContaining('Часть'), findsNothing);
  });

  testWidgets('tap emits its own card', (tester) async {
    final items = [episode('a'), episode('b', title: 'Второй')];
    final tapped = await pump(tester, items);
    await tester.tap(find.byKey(const ValueKey('continue-b')));
    expect(tapped, [items[1]]);
  });

  testWidgets('TalkBack: single labeled button, target ≥ 48', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester, [episode('a', title: 'Выпуск 4', remainingMs: 60000)]);
    final card = find.byKey(const ValueKey('continue-a'));
    expect(
      tester.getSemantics(card),
      isSemantics(isButton: true, hasTapAction: true),
    );
    expect(tester.getSemantics(card).label, startsWith('Продолжить: Выпуск 4'));
    expect(tester.getSize(card).height >= 48, isTrue);
    expect(tester.getSize(card).width >= 48, isTrue);
    handle.dispose();
  });

  testWidgets('cover via function, placeholder without it', (tester) async {
    final asked = <String>[];
    await pump(
      tester,
      [episode('a', image: 'https://cdn.example.org/a.jpg'), episode('b')],
      image: (url) {
        asked.add(url);
        return null;
      },
    );
    expect(asked, ['https://cdn.example.org/a.jpg']);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('screen cover: it is shown rather than network request', (
    tester,
  ) async {
    final cover = MemoryImage(_pixel);
    await pump(tester, [
      episode('a', image: 'https://cdn.example.org/a.jpg'),
    ], image: (_) => cover);
    final shown = tester.widget<Image>(find.byType(Image));
    expect(shown.image, same(cover));
  });

  testWidgets('font x2 on 360 dp: no overflow', (tester) async {
    await pump(
      tester,
      [
        episode(
          'a',
          title: 'Очень длинное название выпуска, которое не влезает в строку',
          remainingMs: 125 * 60000,
        ),
        book('k', part: 10, count: 120),
      ],
      scale: 2.0,
      width: 360,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('ниже'), findsOneWidget);
  });

  testWidgets('row code has no hardcoded strings', (tester) async {
    await pump(tester, [episode('a', remainingMs: 60000)]);
    final shown = tester
        .widgetList<Text>(
          find.descendant(
            of: find.byType(ContinueRow),
            matching: find.byType(Text),
          ),
        )
        .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
        .toSet();
    expect(shown, {'Продолжить', 'Выпуск', 'Подкаст', 'Осталось 1 мин'});
  });
}

final _pixel = Uint8List.fromList(const [
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
]);

String _left(String time) => 'Осталось $time';
String _part(int part, int count) => 'Часть $part из $count';
String _play(String title) => 'Продолжить: $title';
