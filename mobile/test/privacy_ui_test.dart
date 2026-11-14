import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_server.dart';
import 'back.dart';

/// Words absent from UI and client API (AGENTS.md).
///
/// Short "seeds" and "peers" — matched as whole words, otherwise "Sydney" and
/// "pie" would match. Word boundary here uses `\p{L}`, not `\b`: `\b` in Dart only
/// recognizes ASCII and would never trigger on Cyrillic.
final sourceWords = RegExp(
  r'torrent|торрент|magnet|магнет|tracker|трекер|раздач|раздающ|'
  r'(?<!\p{L})(сид(ы|ов|ер\p{L}*)?|пир(ы|ов)?)(?!\p{L})|'
  r'seed|peer|info_?hash|btih|rutracker|prowlarr|rqbit',
  caseSensitive: false,
  unicode: true,
);

List<File> dartFiles(String dir) => [
  for (final entity in Directory(dir).listSync(recursive: true))
    if (entity is File && entity.path.endsWith('.dart')) entity,
];

/// File string literals excluding comments: everything that can appear on screen.
Iterable<String> literals(String source) sync* {
  final code = source
      .split('\n')
      .where((line) => !line.trimLeft().startsWith('//'))
      .join('\n');
  final quoted = RegExp(
    r"'(?:[^'\\\n]|\\.)*'"
    '|'
    r'"(?:[^"\\\n]|\\.)*"',
  );
  for (final match in quoted.allMatches(code)) {
    yield match[0]!;
  }
}

/// All texts on screen currently: labels and button tooltips.
List<String> screenTexts(WidgetTester tester) => [
  for (final text in tester.widgetList<Text>(find.byType(Text)))
    text.data ?? text.textSpan?.toPlainText() ?? '',
  for (final tip in tester.widgetList<Tooltip>(find.byType(Tooltip)))
    tip.message ?? '',
];

void expectClean(WidgetTester tester, String where) {
  final dirty = screenTexts(tester).where(sourceWords.hasMatch).toList();
  expect(dirty, isEmpty, reason: 'on \'$where\' screen');
}

void main() {
  test('word guard catches forbidden words, leaves ordinary', () {
    for (final word in [
      'Torrent',
      'торрент',
      'magnet',
      'Трекер',
      'Раздача молчит',
      'раздающих нет',
      'нет сидов',
      'Сиды: 3',
      'сидеры',
      'пиры',
      'seeders',
      'peers',
      'info_hash',
      'RuTracker',
    ]) {
      expect(sourceWords.hasMatch(word), isTrue, reason: word);
    }
    for (final word in ['Сидней', 'пирог', 'Кино', 'Играть альбом', 'Пустой']) {
      expect(sourceWords.hasMatch(word), isFalse, reason: word);
    }
  });

  test('lib/ has no log output: no titles, artists or ids', () {
    final logging = RegExp(
      r'\b(print|debugPrint|debugPrintStack|log)\s*\(|dart:developer|stdout|stderr',
    );
    final found = [
      for (final file in dartFiles('lib'))
        for (final (n, line) in file.readAsLinesSync().indexed)
          if (!line.trimLeft().startsWith('//') && logging.hasMatch(line))
            '${file.path}:${n + 1}: ${line.trim()}',
    ];
    expect(found, isEmpty);
  });

  test('the app strings have no words about releases', () {
    final found = [
      for (final file in dartFiles('lib'))
        for (final literal in literals(file.readAsStringSync()))
          if (sourceWords.hasMatch(literal)) '${file.path}: $literal',
    ];
    expect(found, isEmpty);
  });

  testWidgets('no source terms in menu screens', (tester) async {
    final rig = Rig();
    await rig.start(tester);
    await typeSearch(tester, 'metallica');
    expectClean(tester, 'Поиск');

    await openTab(tester, 'browse');
    expectClean(tester, 'Жанры');
    await tapAndSettle(tester, find.text('Рок'));
    expectClean(tester, 'Исполнители жанра');
    await tapAndSettle(tester, find.text('Кино'));
    expectClean(tester, 'Исполнитель');
    // Photo name and album title match; album is below.
    await tester.ensureVisible(find.text('Metallica').last);
    await tapAndSettle(tester, find.text('Metallica').last);
    await tapAndSettle(tester, find.byTooltip('Ещё').first);
    expectClean(tester, 'Альбом, меню песни');
    await tapAndSettle(tester, find.text('Добавить в плейлист'));
    expectClean(tester, 'Добавить в плейлист');
    await tapAndSettle(tester, find.text('Отмена'));

    await tapBack(tester);
    await tester.pumpAndSettle();
    await tapBack(tester);
    await tester.pumpAndSettle();
    await tapBack(tester);
    await tester.pumpAndSettle();
    await tapAndSettle(tester, find.byKey(const Key('browse-all-genres')));
    expectClean(tester, 'Все жанры');

    await openTab(tester, 'library');
    expectClean(tester, 'Моя музыка');
    for (final item in ['Любимые песни', 'История', 'Плейлисты']) {
      await tapAndSettle(tester, find.text(item));
      expectClean(tester, item);
      if (item == 'Плейлисты') {
        await tapAndSettle(tester, find.text('В дорогу'));
        expectClean(tester, 'Плейлист');
        await tapBack(tester);
        await tester.pumpAndSettle();
      }
      await tapBack(tester);
      await tester.pumpAndSettle();
    }

    // Check inspects intended location: screen has readable content.
    expect(screenTexts(tester), contains('Любимые песни'));
  });
}
