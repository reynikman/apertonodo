import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/screens/downloads_screen.dart';

import 'fakes.dart';

/// P-A73 item 5 (FT-560): storage is a separate window. In Downloads single line
/// "Storage · X GB of Y"; window: bar (downloaded / cache / free), cache
/// selector Off / 1 / 2 / 5 / 10 GB, "Clear cache", "Delete all
/// downloads". Slider is removed from Downloads screen.
///
/// X is downloaded and cache combined, Y is X plus free device storage.
const gib = 1024 * 1024 * 1024;

/// Downloading spinner spins continuously — `pumpAndSettle` will not wait.
Future<void> frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  late FakeDownloads downloads;

  setUp(() {
    downloads = FakeDownloads()
      ..downloadBytes = 2 * gib
      ..reserveBytes = gib
      ..freeBytes = 50 * gib
      ..reserveLimitBytes = 2 * gib;
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DownloadsScreen(downloads: downloads, play: (_, _) {}),
      ),
    );
    await frames(tester);
  }

  Future<void> openWindow(WidgetTester tester) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('downloads-memory')));
    await frames(tester);
    expect(find.byKey(const Key('memory-window')), findsOneWidget);
  }

  String textOf(WidgetTester tester, Key key) {
    final texts = tester.widgetList<Text>(
      find.descendant(of: find.byKey(key), matching: find.byType(Text)),
    );
    return [
      for (final text in tester.widgetList<Text>(find.byKey(key)))
        text.data ?? '',
      for (final text in texts) text.data ?? '',
    ].join(' ');
  }

  ChoiceChip chip(WidgetTester tester, int gb) =>
      tester.widget<ChoiceChip>(find.byKey(Key('memory-reserve-$gb')));

  testWidgets('in «Downloads» single «Storage» row without any slider', (
    tester,
  ) async {
    await open(tester);
    expect(
      textOf(tester, const Key('downloads-memory')),
      contains('Память · 3 ГБ из 53 ГБ'),
    );
    expect(find.byType(Slider), findsNothing);
    expect(find.byKey(const Key('downloads-reserve')), findsNothing);
  });

  testWidgets('fractional gigabytes use comma', (tester) async {
    downloads
      ..downloadBytes = gib + gib ~/ 2
      ..reserveBytes = 0
      ..freeBytes = 10 * gib;
    await open(tester);
    expect(
      textOf(tester, const Key('downloads-memory')),
      contains('Память · 1,5 ГБ из 11,5 ГБ'),
    );
  });

  testWidgets('window: downloaded / cache / free bar proportions', (
    tester,
  ) async {
    await openWindow(tester);
    final parts = [
      for (final part in ['downloads', 'reserve', 'free'])
        tester.getSize(find.byKey(Key('memory-bar-$part'))).width,
    ];
    final whole = parts.reduce((a, b) => a + b);
    expect(
      tester.getSize(find.byKey(const Key('memory-bar'))).width,
      closeTo(whole, 1),
    );
    expect(parts[0], closeTo(whole * 2 / 53, 1));
    expect(parts[1], closeTo(whole * 1 / 53, 1));
    expect(parts[2], closeTo(whole * 50 / 53, 1));
    expect(find.textContaining('Скачанное · 2 ГБ'), findsOneWidget);
    expect(find.textContaining('Запас · 1 ГБ'), findsOneWidget);
    expect(find.textContaining('Свободно · 50 ГБ'), findsOneWidget);
  });

  testWidgets('reserve options: Off / 1 / 2 / 5 / 10 GB', (tester) async {
    await openWindow(tester);
    expect(find.text('Выключен'), findsOneWidget);
    for (final gb in [0, 1, 2, 5, 10]) {
      expect(chip(tester, gb).selected, gb == 2, reason: '$gb GB');
    }
    await tester.tap(find.byKey(const Key('memory-reserve-5')));
    await frames(tester);
    expect(downloads.reserveLimitBytes, 5 * gib);
    expect(chip(tester, 5).selected, isTrue);

    await tester.tap(find.byKey(const Key('memory-reserve-0')));
    await frames(tester);
    expect(downloads.reserveLimitBytes, 0);
  });

  testWidgets('cannot select reserve exceeding free space minus 1 GB', (
    tester,
  ) async {
    downloads.freeBytes = 3 * gib + gib ~/ 2;
    await openWindow(tester);
    for (final gb in [0, 1, 2]) {
      expect(chip(tester, gb).onSelected, isNotNull, reason: '$gb GB');
    }
    for (final gb in [5, 10]) {
      expect(chip(tester, gb).onSelected, isNull, reason: '$gb GB');
    }
  });

  testWidgets('«Clear reserve» — immediate', (tester) async {
    await openWindow(tester);
    await tester.tap(find.text('Очистить запас'));
    await frames(tester);
    expect(downloads.clearedReserve, 1);
    expect(find.textContaining('Запас · 0 ГБ'), findsOneWidget);
  });

  testWidgets('«Delete all downloads» — only after confirmation', (
    tester,
  ) async {
    await openWindow(tester);
    await tester.tap(find.text('Удалить все загрузки'));
    await frames(tester);
    await tester.tap(find.text('Отмена'));
    await frames(tester);
    expect(downloads.removedAll, 0);

    await tester.tap(find.text('Удалить все загрузки'));
    await frames(tester);
    await tester.tap(find.text('Удалить'));
    await frames(tester);
    expect(downloads.removedAll, 1);
  });
}
