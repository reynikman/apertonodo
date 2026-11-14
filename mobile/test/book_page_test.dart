import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/book_position.dart';
import 'package:music_stream/screens/book_page.dart';

final texts = BookPageTexts(
  addToShelf: 'Добавить на полку',
  addFailed: 'Не удалось добавить',
  listen: 'Слушать',
  continueListening: 'Продолжить',
  restart: 'Начать заново',
  removeFromShelf: 'Убрать с полки',
  removeConfirm: 'Убрать книгу с полки?',
  removeYes: 'Убрать',
  cancel: 'Отмена',
  narrator: 'Чтец',
  language: 'Язык',
  duration: 'Длительность',
  parts: 'Части',
  year: 'Год записи',
  partsAfterAdding: 'после добавления',
  partsCount: (n) => '$n части',
  gone: 'Книгу убрали с полки на другом телефоне',
  toMyShelf: 'К моей полке',
);

const info = BookPageInfo(
  title: 'Мастер и Маргарита',
  author: 'Михаил Булгаков',
  narrator: 'Александр Клюквин',
  language: 'Русский',
  durationLabel: '16 ч 40 мин',
  parts: 24,
  year: 2011,
);

BookPosition pos({int part = 1, int ms = 0, bool finished = false}) =>
    BookPosition(
      part: part,
      positionMs: ms,
      finished: finished,
      updatedAt: DateTime.utc(2026, 10, 1),
    );

class Calls {
  int add = 0;
  int listen = 0;
  int restart = 0;
  int remove = 0;
  int toShelf = 0;
  Future<bool> Function() addResult = () async => true;
  Completer<void>? restartGate;
}

Widget app(
  Calls calls, {
  BookPageMode mode = BookPageMode.onShelf,
  BookPosition? position,
  BookPageInfo bookInfo = info,
}) => MaterialApp(
  home: Scaffold(
    body: BookPage(
      info: bookInfo,
      mode: mode,
      position: position,
      texts: texts,
      onAdd: () {
        calls.add++;
        return calls.addResult();
      },
      onListen: () => calls.listen++,
      onRestart: () async {
        calls.restart++;
        await calls.restartGate?.future;
      },
      onRemove: () async => calls.remove++,
      onToShelf: () => calls.toShelf++,
    ),
  ),
);

void main() {
  testWidgets('header: title, author, language duration parts line', (
    tester,
  ) async {
    await tester.pumpWidget(app(Calls()));
    expect(find.text('Мастер и Маргарита'), findsOneWidget);
    expect(find.text('Михаил Булгаков'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('book-summary'))).data,
      'Русский · 16 ч 40 мин · 24 части',
    );
  });

  testWidgets('grid: reader, language, duration, parts, year', (tester) async {
    await tester.pumpWidget(app(Calls()));
    for (final (key, label, value) in [
      ('book-row-narrator', 'Чтец', 'Александр Клюквин'),
      ('book-row-language', 'Язык', 'Русский'),
      ('book-row-duration', 'Длительность', '16 ч 40 мин'),
      ('book-row-parts', 'Части', '24'),
      ('book-row-year', 'Год записи', '2011'),
    ]) {
      final row = find.byKey(ValueKey(key));
      expect(row, findsOneWidget, reason: key);
      expect(
        find.descendant(of: row, matching: find.text(label)),
        findsOneWidget,
        reason: key,
      );
      expect(
        find.descendant(of: row, matching: find.text(value)),
        findsOneWidget,
        reason: key,
      );
    }
  });

  testWidgets('without description or genres (R-A108 item 4)', (tester) async {
    await tester.pumpWidget(app(Calls()));
    expect(find.textContaining('Описание'), findsNothing);
    expect(find.textContaining('Жанр'), findsNothing);
  });

  testWidgets(
    'no reader, duration, or year: no rows, header shows only language',
    (tester) async {
      await tester.pumpWidget(
        app(
          Calls(),
          bookInfo: const BookPageInfo(
            title: 'Т',
            author: '',
            language: 'Русский',
            parts: 3,
          ),
        ),
      );
      expect(find.byKey(const ValueKey('book-row-narrator')), findsNothing);
      expect(find.byKey(const ValueKey('book-row-duration')), findsNothing);
      expect(find.byKey(const ValueKey('book-row-year')), findsNothing);
      expect(find.byKey(const ValueKey('book-row-language')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('book-summary'))).data,
        'Русский · 3 части',
      );
    },
  );

  testWidgets('empty duration leaves no extra bullet', (tester) async {
    await tester.pumpWidget(
      app(
        Calls(),
        bookInfo: const BookPageInfo(
          title: 'Т',
          author: 'А',
          language: 'Русский',
          durationLabel: '',
          parts: 2,
        ),
      ),
    );
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('book-summary'))).data,
      'Русский · 2 части',
    );
  });

  group('before shelf', () {
    testWidgets('parts after adding, add button present, no listen', (
      tester,
    ) async {
      await tester.pumpWidget(app(Calls(), mode: BookPageMode.notOnShelf));
      final parts = find.byKey(const ValueKey('book-row-parts'));
      expect(
        find.descendant(of: parts, matching: find.text('после добавления')),
        findsOneWidget,
      );
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('book-summary'))).data,
        'Русский · 16 ч 40 мин',
      );
      expect(find.byKey(const ValueKey('book-add')), findsOneWidget);
      expect(find.text('Добавить на полку'), findsOneWidget);
      expect(find.byKey(const ValueKey('book-listen')), findsNothing);
      expect(find.byKey(const ValueKey('book-remove')), findsNothing);
      expect(find.byKey(const ValueKey('book-restart')), findsNothing);
    });

    testWidgets(
      'tapping Add invokes onAdd; while waiting the button is disabled',
      (tester) async {
        final calls = Calls();
        final done = Completer<bool>();
        calls.addResult = () => done.future;
        await tester.pumpWidget(app(calls, mode: BookPageMode.notOnShelf));
        await tester.tap(find.byKey(const ValueKey('book-add')));
        await tester.pump();
        expect(calls.add, 1);
        final button = tester.widget<FilledButton>(
          find.byKey(const ValueKey('book-add')),
        );
        expect(button.onPressed, isNull);
        await tester.tap(find.byKey(const ValueKey('book-add')));
        await tester.pump();
        expect(calls.add, 1);
        done.complete(true);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<FilledButton>(find.byKey(const ValueKey('book-add')))
              .onPressed,
          isNotNull,
        );
        expect(find.byKey(const ValueKey('book-add-failed')), findsNothing);
      },
    );

    testWidgets('failure: error text shown, retry clears it', (tester) async {
      final calls = Calls();
      calls.addResult = () async => false;
      await tester.pumpWidget(app(calls, mode: BookPageMode.notOnShelf));
      await tester.tap(find.byKey(const ValueKey('book-add')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('book-add-failed')), findsOneWidget);
      expect(find.text('Не удалось добавить'), findsOneWidget);
      calls.addResult = () async => true;
      await tester.tap(find.byKey(const ValueKey('book-add')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('book-add-failed')), findsNothing);
      expect(calls.add, 2);
    });

    testWidgets('exception in onAdd: same error text, does not crash', (
      tester,
    ) async {
      final calls = Calls();
      calls.addResult = () async => throw StateError('net');
      await tester.pumpWidget(app(calls, mode: BookPageMode.notOnShelf));
      await tester.tap(find.byKey(const ValueKey('book-add')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('book-add-failed')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('on shelf', () {
    testWidgets('no position: listen shown, no restart button', (tester) async {
      final calls = Calls();
      await tester.pumpWidget(app(calls));
      expect(find.text('Слушать'), findsOneWidget);
      expect(find.text('Продолжить'), findsNothing);
      expect(find.byKey(const ValueKey('book-restart')), findsNothing);
      expect(find.byKey(const ValueKey('book-add')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('book-listen')));
      expect(calls.listen, 1);
    });

    testWidgets('started book displays resume and start over buttons', (
      tester,
    ) async {
      final calls = Calls();
      await tester.pumpWidget(app(calls, position: pos(part: 3, ms: 61000)));
      expect(find.text('Продолжить'), findsOneWidget);
      expect(find.text('Слушать'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('book-restart')));
      await tester.pump();
      expect(calls.restart, 1);
    });

    testWidgets('beginning of part two also shows resume', (tester) async {
      await tester.pumpWidget(app(Calls(), position: pos(part: 2)));
      expect(find.text('Продолжить'), findsOneWidget);
    });

    testWidgets('position at very start displays listen', (tester) async {
      await tester.pumpWidget(app(Calls(), position: pos()));
      expect(find.text('Слушать'), findsOneWidget);
      expect(find.byKey(const ValueKey('book-restart')), findsOneWidget);
    });

    testWidgets('finished: shows listen and start over', (tester) async {
      await tester.pumpWidget(
        app(Calls(), position: pos(part: 24, ms: 9000, finished: true)),
      );
      expect(find.text('Слушать'), findsOneWidget);
      expect(find.text('Продолжить'), findsNothing);
      expect(find.byKey(const ValueKey('book-restart')), findsOneWidget);
    });

    testWidgets('remove from shelf prompts; cancel does nothing at all', (
      tester,
    ) async {
      final calls = Calls();
      await tester.pumpWidget(app(calls));
      await tester.ensureVisible(find.byKey(const ValueKey('book-remove')));
      await tester.tap(find.byKey(const ValueKey('book-remove')));
      await tester.pumpAndSettle();
      expect(find.text('Убрать книгу с полки?'), findsOneWidget);
      expect(calls.remove, 0);
      await tester.tap(find.byKey(const ValueKey('book-remove-cancel')));
      await tester.pumpAndSettle();
      expect(calls.remove, 0);
      expect(find.text('Убрать книгу с полки?'), findsNothing);
    });

    testWidgets('confirmation invokes onRemove once', (tester) async {
      final calls = Calls();
      await tester.pumpWidget(app(calls));
      await tester.ensureVisible(find.byKey(const ValueKey('book-remove')));
      await tester.tap(find.byKey(const ValueKey('book-remove')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('book-remove-confirm')));
      await tester.pumpAndSettle();
      expect(calls.remove, 1);
      expect(find.text('Убрать книгу с полки?'), findsNothing);
    });

    testWidgets('dismissing prompt does not call onRemove', (tester) async {
      final calls = Calls();
      await tester.pumpWidget(app(calls));
      await tester.ensureVisible(find.byKey(const ValueKey('book-remove')));
      await tester.tap(find.byKey(const ValueKey('book-remove')));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(calls.remove, 0);
    });
  });

  group('second pass: retries and book switching', () {
    testWidgets('double tap remove: single prompt and single removal', (
      tester,
    ) async {
      final calls = Calls();
      await tester.pumpWidget(app(calls));
      await tester.ensureVisible(find.byKey(const ValueKey('book-remove')));
      await tester.tap(find.byKey(const ValueKey('book-remove')));
      await tester.tap(
        find.byKey(const ValueKey('book-remove')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(find.text('Убрать книгу с полки?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('book-remove-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('Убрать книгу с полки?'), findsNothing);
      expect(calls.remove, 1);
    });

    testWidgets(
      'book removed on another device while prompt open: yes is noop',
      (tester) async {
        final calls = Calls();
        await tester.pumpWidget(app(calls));
        await tester.ensureVisible(find.byKey(const ValueKey('book-remove')));
        await tester.tap(find.byKey(const ValueKey('book-remove')));
        await tester.pumpAndSettle();
        await tester.pumpWidget(app(calls, mode: BookPageMode.gone));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('book-remove-confirm')));
        await tester.pumpAndSettle();
        expect(calls.remove, 0);
        expect(find.byKey(const ValueKey('book-gone')), findsOneWidget);
      },
    );

    testWidgets(
      'restart pressed while previous running is not called a second time',
      (tester) async {
        final calls = Calls();
        final gate = Completer<void>();
        calls.restartGate = gate;
        await tester.pumpWidget(app(calls, position: pos(part: 2)));
        await tester.tap(find.byKey(const ValueKey('book-restart')));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('book-restart')));
        await tester.pump();
        expect(calls.restart, 1);
        gate.complete();
        await tester.pumpAndSettle();
        calls.restartGate = null;
        await tester.tap(find.byKey(const ValueKey('book-restart')));
        await tester.pumpAndSettle();
        expect(calls.restart, 2);
      },
    );

    testWidgets('add error is announced via TalkBack liveRegion', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final calls = Calls();
      calls.addResult = () async => false;
      await tester.pumpWidget(app(calls, mode: BookPageMode.notOnShelf));
      await tester.tap(find.byKey(const ValueKey('book-add')));
      await tester.pumpAndSettle();
      expect(
        tester.getSemantics(find.byKey(const ValueKey('book-add-failed'))),
        isSemantics(label: 'Не удалось добавить', isLiveRegion: true),
      );
      handle.dispose();
    });
  });

  group('removed on another phone', () {
    testWidgets('text and to my shelf, no other actions', (tester) async {
      final calls = Calls();
      await tester.pumpWidget(
        app(calls, mode: BookPageMode.gone, position: pos(part: 2, ms: 5)),
      );
      expect(find.byKey(const ValueKey('book-gone')), findsOneWidget);
      expect(
        find.text('Книгу убрали с полки на другом телефоне'),
        findsOneWidget,
      );
      for (final key in [
        'book-add',
        'book-listen',
        'book-restart',
        'book-remove',
      ]) {
        expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
      }
      await tester.tap(find.byKey(const ValueKey('book-to-shelf')));
      expect(calls.toShelf, 1);
    });
  });

  testWidgets('buttons are at least 48 dp high', (tester) async {
    await tester.pumpWidget(app(Calls(), position: pos(part: 2)));
    for (final key in ['book-listen', 'book-restart', 'book-remove']) {
      final size = tester.getSize(find.byKey(ValueKey(key)));
      expect(size.height, greaterThanOrEqualTo(48), reason: key);
    }
    await tester.pumpWidget(app(Calls(), mode: BookPageMode.notOnShelf));
    expect(
      tester.getSize(find.byKey(const ValueKey('book-add'))).height,
      greaterThanOrEqualTo(48),
    );
    await tester.pumpWidget(app(Calls(), mode: BookPageMode.gone));
    expect(
      tester.getSize(find.byKey(const ValueKey('book-to-shelf'))).height,
      greaterThanOrEqualTo(48),
    );
  });

  for (final width in [360.0, 412.0]) {
    testWidgets('$width dp, font x2: no overflow, all accessible', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      for (final mode in BookPageMode.values) {
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: app(Calls(), mode: mode, position: pos(part: 2)),
          ),
        );
        expect(tester.takeException(), isNull, reason: mode.name);
        final last = switch (mode) {
          BookPageMode.notOnShelf => 'book-add',
          BookPageMode.onShelf => 'book-remove',
          BookPageMode.gone => 'book-to-shelf',
        };
        await tester.scrollUntilVisible(
          find.byKey(ValueKey(last)),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.byKey(ValueKey(last)), findsOneWidget, reason: mode.name);
      }
    });
  }

  testWidgets('buttons have accessibility labels for TalkBack', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(app(Calls(), position: pos(part: 2)));
    expect(
      tester.getSemantics(find.byKey(const ValueKey('book-listen'))),
      isSemantics(label: 'Продолжить', isButton: true),
    );
    expect(
      tester.getSemantics(find.byKey(const ValueKey('book-remove'))),
      isSemantics(label: 'Убрать с полки', isButton: true),
    );
    handle.dispose();
  });
}
