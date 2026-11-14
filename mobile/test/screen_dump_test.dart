import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../integration_test/screen_dump.dart';

/// Screen contents dump when device scenario timed out (FT-490).
///
/// 01.10 `device-smoke` on main twice missed "Test Tone Long" in 25 s, while
/// retry succeeded. Log only showed "found 0" — no network error,
/// rate limit, or empty results explanation. Now scenario prints screen
/// as single line `FLOWTUNE_SCREEN=…`.
void main() {
  Future<void> show(WidgetTester tester, Widget body) =>
      tester.pumpWidget(MaterialApp(home: Scaffold(body: body)));

  testWidgets('visible texts in order, no duplicates, via \' | \'', (
    tester,
  ) async {
    await show(
      tester,
      const Column(
        children: [
          Text('Поиск'),
          Text('Сервер не ответил'),
          Text('Поиск'),
          Text('Повторить'),
        ],
      ),
    );

    expect(screenTexts(), 'Поиск | Сервер не ответил | Повторить');
  });

  testWidgets('icons and hidden items not printed', (tester) async {
    await show(
      tester,
      const Column(
        children: [
          Icon(Icons.search),
          Text('видно'),
          Offstage(child: Text('за кадром')),
          Visibility(visible: false, child: Text('спрятано')),
        ],
      ),
    );

    expect(screenTexts(), 'видно');
  });

  testWidgets('field input also shown on screen', (tester) async {
    await show(
      tester,
      TextField(controller: TextEditingController(text: 'flowtune test tone')),
    );

    expect(screenTexts(), 'flowtune test tone');
  });

  testWidgets('newline in text becomes space: single log line', (tester) async {
    await show(tester, const Text('Не удалось\nнайти'));

    expect(screenTexts(), 'Не удалось найти');
  });

  testWidgets('over limit - first in order and \'...\'', (tester) async {
    await show(
      tester,
      ListView(children: [for (var i = 0; i < 60; i++) Text('строка $i')]),
    );
    // Viewport contains fewer than 60, but more than 5: ListView pre-renders overflow buffer.
    final shown = screenTexts(limit: 5);

    expect(shown, 'строка 0 | строка 1 | строка 2 | строка 3 | строка 4 | …');
  });

  testWidgets('empty screen - stated clearly', (tester) async {
    await show(tester, const SizedBox());

    expect(screenTexts(), '(на экране нет текста)');
  });
}
