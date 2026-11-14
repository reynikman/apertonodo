// FT-634 (P-A49, feature B4 per P-A95): history in app — remove item, clear all, "pause history".
//
// Server supports this since FT-630 (`/v1/history/remove`, `/clear`, `/pause`). Here is app half:
// `HistoryControl` (logic) and three widgets wired into history screen by lead.
//
// Guarded:
// - item hidden immediately, request sent to server only after 5 seconds; "Undo" restores it
//   and avoids server call completely;
// - exact track and timestamp from row sent to server;
// - failed deletion restores item with explanatory message;
// - second deleted item does not discard first; leaving screen does not lose pending deletion;
// - pause: toggled via server, failure does not lie about state, auto-expires;
// - "Clear all" prompts for confirmation; cancel clears nothing;
// - Russian and English, tap target at least 48 dp.
//
// What test does not prove: real server requests (provided by `HistoryPort` written by lead
// on top of `server_api.dart`) and placement of widgets on history screen — wired after queue merge.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/history_control.dart';
import 'package:music_stream/l10n/l10n.dart';
import 'package:music_stream/screens/history_controls.dart';

const _song = '33333333-3333-3333-3333-333333333333';
const _other = '44444444-4444-4444-4444-444444444444';
final _at = DateTime.utc(2026, 10, 6, 18, 30, 15, 123, 456);
final _later = DateTime.utc(2026, 10, 6, 18, 35);

class _Port implements HistoryPort {
  final removed = <(String, DateTime)>[];
  int clears = 0;
  final pauses = <bool>[];

  /// Deadlines the app asked for, one per [pause] call (FT-853).
  final untils = <DateTime?>[];

  /// Answer like the server: the pause lasts until the deadline asked for.
  bool echo = false;
  int states = 0;

  bool failRemove = false;
  bool failClear = false;
  bool failPause = false;
  bool failState = false;
  HistoryPause state = const HistoryPause(paused: false);
  Completer<void>? holdRemove;
  Completer<void>? holdState;
  Completer<void>? holdPause;

  @override
  Future<int> remove(String trackId, DateTime playedAt) async {
    removed.add((trackId, playedAt));
    if (holdRemove != null) await holdRemove!.future;
    if (failRemove) throw StateError('нет сети');
    return 1;
  }

  @override
  Future<int> clear() async {
    clears++;
    if (failClear) throw StateError('нет сети');
    return 7;
  }

  @override
  Future<HistoryPause> pause(bool paused, {DateTime? until}) async {
    pauses.add(paused);
    untils.add(until);
    if (echo) {
      state = paused && until != null
          ? HistoryPause(paused: true, until: until)
          : const HistoryPause(paused: false);
    }
    final answer = state;
    if (holdPause != null) await holdPause!.future;
    if (failPause) throw StateError('нет сети');
    return answer;
  }

  @override
  Future<HistoryPause> pauseState() async {
    states++;
    final answer = state;
    if (holdState != null) await holdState!.future;
    if (failState) throw StateError('нет сети');
    return answer;
  }
}

Widget _app(Widget child, {Locale locale = const Locale('ru')}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

final _undo = find.byKey(const Key('history-undo'));
final _pause = find.byKey(const Key('history-pause'));
final _clear = find.byKey(const Key('history-clear'));
final _confirm = find.byKey(const Key('history-clear-confirm'));
final _cancel = find.byKey(const Key('history-clear-cancel'));
final _forHour = find.byKey(const Key('history-pause-hour'));
final _tillTomorrow = find.byKey(const Key('history-pause-tomorrow'));
final _forever = find.byKey(const Key('history-pause-forever'));

void main() {
  group('server pause response', () {
    test('pause with expiration timestamp', () {
      final p = HistoryPause.fromJson({
        'paused': true,
        'until': '2026-10-06T21:30:00+00:00',
      });
      expect(p.paused, isTrue);
      expect(
        p.until!.isAtSameMomentAs(DateTime.utc(2026, 10, 6, 21, 30)),
        isTrue,
      );
    });

    test('no pause active', () {
      final p = HistoryPause.fromJson({'paused': false, 'until': null});
      expect(p.paused, isFalse);
      expect(p.until, isNull);
    });

    test('malformed response: no pause, without exception', () {
      for (final Map<String, Object?> json in [
        {},
        {'paused': 'yes', 'until': '2026-10-06T21:30:00+00:00'},
        {'paused': true},
        {'paused': true, 'until': 'завтра'},
        {'paused': true, 'until': 42},
      ]) {
        final p = HistoryPause.fromJson(json);
        expect(p.paused, isFalse, reason: '$json');
        expect(p.until, isNull, reason: '$json');
      }
    });
  });

  group('remove item row', () {
    testWidgets('row hides immediately, request sent after 5 seconds', (
      tester,
    ) async {
      final port = _Port();
      final control = HistoryControl(port);
      var notified = 0;
      control.addListener(() => notified++);

      control.removeLater(_song, _at);
      expect(control.isHidden(_song, _at), isTrue);
      expect(
        control.isHidden(_song, _later),
        isFalse,
        reason: 'distinct playback event of same track',
      );
      expect(control.isHidden(_other, _at), isFalse);
      expect(control.canUndo, isTrue);
      expect(notified, greaterThan(0));
      expect(port.removed, isEmpty);

      await tester.pump(const Duration(seconds: 4));
      expect(port.removed, isEmpty, reason: 'five seconds have not passed yet');

      await tester.pump(const Duration(seconds: 2));
      expect(port.removed, [(_song, _at)], reason: 'exact song and timestamp');
      expect(control.canUndo, isFalse);
      expect(
        control.isHidden(_song, _at),
        isTrue,
        reason: 'removed item row does not return',
      );
      expect(control.removeFailed, isFalse);
      control.dispose();
    });

    testWidgets('Undo restores item row and avoids contacting server', (
      tester,
    ) async {
      final port = _Port();
      final control = HistoryControl(port);
      control.removeLater(_song, _at);
      await tester.pump(const Duration(seconds: 3));

      control.undo();
      expect(control.isHidden(_song, _at), isFalse);
      expect(control.canUndo, isFalse);

      await tester.pump(const Duration(seconds: 10));
      expect(port.removed, isEmpty);
      control.dispose();
    });

    testWidgets('deletion failed: item row restored and remains visible', (
      tester,
    ) async {
      final port = _Port()..failRemove = true;
      final control = HistoryControl(port);
      control.removeLater(_song, _at);
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();

      expect(port.removed, hasLength(1));
      expect(control.isHidden(_song, _at), isFalse);
      expect(control.removeFailed, isTrue);

      port.failRemove = false;
      control.removeLater(_song, _at);
      expect(
        control.removeFailed,
        isFalse,
        reason: 'new attempt clears previous error',
      );
      control.undo();
      control.dispose();
    });

    testWidgets('second row does not drop first queued row', (tester) async {
      final port = _Port();
      final control = HistoryControl(port);
      control.removeLater(_song, _at);
      await tester.pump(const Duration(seconds: 2));
      control.removeLater(_other, _later);
      await tester.pump();

      expect(port.removed, [
        (_song, _at),
      ], reason: 'first is dispatched immediately without waiting');
      expect(control.isHidden(_song, _at), isTrue);
      expect(control.isHidden(_other, _later), isTrue);

      control.undo();
      expect(
        control.isHidden(_other, _later),
        isFalse,
        reason: 'only the last item is undone',
      );
      expect(control.isHidden(_song, _at), isTrue);

      await tester.pump(const Duration(seconds: 10));
      expect(port.removed, [(_song, _at)]);
      control.dispose();
    });

    testWidgets('flush sends pending items once immediately', (tester) async {
      final port = _Port();
      final control = HistoryControl(port);
      control.removeLater(_song, _at);

      await control.flush();
      expect(port.removed, [(_song, _at)]);
      expect(control.canUndo, isFalse);

      await control.flush();
      await tester.pump(const Duration(seconds: 10));
      expect(port.removed, hasLength(1));
      control.dispose();
    });

    testWidgets('leaving screen preserves pending removal', (tester) async {
      final port = _Port();
      final control = HistoryControl(port);
      control.removeLater(_song, _at);

      control.dispose();
      await tester.pump(const Duration(seconds: 10));
      expect(port.removed, [
        (_song, _at),
      ], reason: 'dispatched once, timer did not fire again');
    });

    testWidgets('response after leaving screen does not crash application', (
      tester,
    ) async {
      final port = _Port()
        ..failRemove = true
        ..holdRemove = Completer<void>();
      final control = HistoryControl(port);
      control.removeLater(_song, _at);
      await tester.pump(const Duration(seconds: 6));
      control.dispose();

      port.holdRemove!.complete();
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('pause history recording', () {
    final now = DateTime(2026, 10, 6, 18, 30);
    final until = DateTime(2026, 10, 6, 21, 30);

    testWidgets('load fetches pause state from server', (tester) async {
      final port = _Port()..state = HistoryPause(paused: true, until: until);
      final control = HistoryControl(port, now: () => now);
      expect(control.paused, isFalse);

      await control.load();
      expect(port.states, 1);
      expect(control.paused, isTrue);
      expect(control.pausedUntil, until);
      control.dispose();
    });

    testWidgets('load error: no pause, without exception', (tester) async {
      final port = _Port()..failState = true;
      final control = HistoryControl(port, now: () => now);
      await control.load();
      expect(control.paused, isFalse);
      expect(control.pausedUntil, isNull);
      control.dispose();
    });

    testWidgets('toggle pause sends state to server', (tester) async {
      final port = _Port()..state = HistoryPause(paused: true, until: until);
      final control = HistoryControl(port, now: () => now);

      expect(await control.setPaused(true), isTrue);
      expect(port.pauses, [true]);
      expect(control.paused, isTrue);
      expect(
        control.pausedUntil,
        until,
        reason: 'duration taken from server response',
      );

      port.state = const HistoryPause(paused: false);
      expect(await control.setPaused(false), isTrue);
      expect(port.pauses, [true, false]);
      expect(control.paused, isFalse);
      expect(control.pausedUntil, isNull);
      control.dispose();
    });

    testWidgets('error does not modify toggle state', (tester) async {
      final port = _Port()..failPause = true;
      final control = HistoryControl(port, now: () => now);
      expect(await control.setPaused(true), isFalse);
      expect(
        control.paused,
        isFalse,
        reason: 'server did not confirm: pause not enabled',
      );

      port
        ..failPause = false
        ..state = HistoryPause(paused: true, until: until);
      await control.setPaused(true);
      port.failPause = true;
      expect(await control.setPaused(false), isFalse);
      expect(
        control.paused,
        isTrue,
        reason: 'server did not confirm: pause not cleared',
      );
      control.dispose();
    });

    testWidgets('delayed response does not overwrite newer server state', (
      tester,
    ) async {
      final port = _Port()..holdState = Completer<void>();
      final control = HistoryControl(port, now: () => now);
      final loading = control.load();

      port.state = HistoryPause(paused: true, until: until);
      expect(await control.setPaused(true), isTrue);
      expect(control.paused, isTrue);

      port.holdState!.complete();
      await loading;
      expect(
        control.paused,
        isTrue,
        reason: 'load response requested earlier and is stale',
      );
      control.dispose();
    });

    testWidgets('pause tile is read as single semantics node', (tester) async {
      final handle = tester.ensureSemantics();
      final port = _Port();
      final control = HistoryControl(port, now: () => now);
      await tester.pumpWidget(_app(HistoryPauseTile(control: control)));

      final node = tester.getSemantics(
        find.bySemanticsLabel(RegExp('Не записывать историю')).first,
      );
      expect(
        node,
        isSemantics(hasToggledState: true),
        reason:
            'title and toggle form single node, not an unnamed toggle switch',
      );
      handle.dispose();
      control.dispose();
    });

    testWidgets('pause expires automatically when timer ends', (tester) async {
      var clock = now;
      final port = _Port()..state = HistoryPause(paused: true, until: until);
      final control = HistoryControl(port, now: () => clock);
      await control.load();
      var notified = 0;
      control.addListener(() => notified++);

      clock = until.subtract(const Duration(minutes: 1));
      expect(control.paused, isTrue);

      clock = until.add(const Duration(seconds: 1));
      expect(
        control.paused,
        isFalse,
        reason: 'timer expired, no need to query server',
      );
      await tester.pump(const Duration(hours: 3, seconds: 5));
      expect(
        notified,
        greaterThan(0),
        reason: 'screen is informed that toggle turned off',
      );
      control.dispose();
    });

    testWidgets('switch displays duration and communicates with server', (
      tester,
    ) async {
      final port = _Port();
      final control = HistoryControl(port, now: () => now);
      await tester.pumpWidget(_app(HistoryPauseTile(control: control)));

      expect(find.text('Не записывать историю'), findsOneWidget);
      expect(find.text('На час, до завтра или бессрочно'), findsOneWidget);
      expect(tester.getSize(_pause).height, greaterThanOrEqualTo(48));
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);

      port.echo = true;
      await tester.tap(_pause);
      await tester.pumpAndSettle();
      expect(port.pauses, isEmpty, reason: 'first the person picks how long');
      expect(tester.getSize(_forHour).height, greaterThanOrEqualTo(48));
      await tester.tap(_forHour);
      await tester.pumpAndSettle();
      expect(port.pauses, [true]);
      expect(port.untils, [DateTime(2026, 10, 6, 19, 30)]);
      expect(_forHour, findsNothing, reason: 'choice closes after a pick');
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      expect(find.text('До 19:30'), findsOneWidget);
      expect(find.text('На час, до завтра или бессрочно'), findsNothing);

      port.echo = false;

      port.state = const HistoryPause(paused: false);
      await tester.tap(_pause);
      await tester.pumpAndSettle();
      expect(port.pauses, [true, false]);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      control.dispose();
    });

    testWidgets('till tomorrow lasts until midnight by the phone clock', (
      tester,
    ) async {
      final port = _Port()..echo = true;
      final control = HistoryControl(port, now: () => now);
      await tester.pumpWidget(_app(HistoryPauseTile(control: control)));

      await tester.tap(_pause);
      await tester.pumpAndSettle();
      await tester.tap(_tillTomorrow);
      await tester.pumpAndSettle();
      expect(port.untils, [DateTime(2026, 10, 7)]);
      expect(find.text('До завтра'), findsOneWidget);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      control.dispose();
    });

    testWidgets('"until I turn it back on" has no clock time', (tester) async {
      final port = _Port()..echo = true;
      final control = HistoryControl(port, now: () => now);
      await tester.pumpWidget(_app(HistoryPauseTile(control: control)));

      await tester.tap(_pause);
      await tester.pumpAndSettle();
      await tester.tap(_forever);
      await tester.pumpAndSettle();
      expect(port.pauses, [true]);
      expect(
        port.untils.single!.difference(now).inDays,
        greaterThan(365 * 50),
        reason: 'a deadline far away, the server knows no special state',
      );
      expect(control.pausedForever, isTrue);
      expect(find.text('Пока не включите снова'), findsOneWidget);
      expect(find.textContaining('До '), findsNothing);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      // Pump far past any plausible timer: no timer is armed for "forever".
      await tester.pump(const Duration(days: 2));
      expect(control.paused, isTrue);
      control.dispose();
    });

    testWidgets('closing the choice turns nothing on', (tester) async {
      final port = _Port()..echo = true;
      final control = HistoryControl(port, now: () => now);
      await tester.pumpWidget(_app(HistoryPauseTile(control: control)));

      await tester.tap(_pause);
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(port.pauses, isEmpty);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      control.dispose();
    });

    testWidgets('switch error displayed with descriptive text', (tester) async {
      final port = _Port()..failPause = true;
      final control = HistoryControl(port, now: () => now);
      await tester.pumpWidget(_app(HistoryPauseTile(control: control)));

      await tester.tap(_pause);
      await tester.pumpAndSettle();
      await tester.tap(_forHour);
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      expect(
        find.text('Не получилось. Проверьте сеть и попробуйте ещё раз'),
        findsOneWidget,
      );
      control.dispose();
    });
  });

  group('clear all', () {
    testWidgets('prompts confirmation; dismissal clears nothing at all', (
      tester,
    ) async {
      final port = _Port();
      final control = HistoryControl(port);
      var cleared = 0;
      await tester.pumpWidget(
        _app(HistoryClearButton(control: control, onCleared: () => cleared++)),
      );
      expect(find.text('Очистить историю'), findsOneWidget);
      expect(tester.getSize(_clear).height, greaterThanOrEqualTo(48));

      await tester.tap(_clear);
      await tester.pumpAndSettle();
      expect(port.clears, 0, reason: 'nothing cleared before confirmation');
      expect(
        find.text('Стереть всю историю прослушиваний? Вернуть её будет нельзя'),
        findsOneWidget,
      );

      await tester.tap(_cancel);
      await tester.pumpAndSettle();
      expect(port.clears, 0);
      expect(cleared, 0);
      expect(_confirm, findsNothing, reason: 'dialog closed');
      control.dispose();
    });

    testWidgets('confirm clears history and updates screen', (tester) async {
      final port = _Port();
      final control = HistoryControl(port);
      var cleared = 0;
      await tester.pumpWidget(
        _app(HistoryClearButton(control: control, onCleared: () => cleared++)),
      );
      await tester.tap(_clear);
      await tester.pumpAndSettle();
      await tester.tap(_confirm);
      await tester.pumpAndSettle();

      expect(port.clears, 1);
      expect(cleared, 1);
      expect(_confirm, findsNothing);
      control.dispose();
    });

    testWidgets('error explained in text, screen not misled', (tester) async {
      final port = _Port()..failClear = true;
      final control = HistoryControl(port);
      var cleared = 0;
      await tester.pumpWidget(
        _app(HistoryClearButton(control: control, onCleared: () => cleared++)),
      );
      await tester.tap(_clear);
      await tester.pumpAndSettle();
      await tester.tap(_confirm);
      await tester.pumpAndSettle();

      expect(port.clears, 1);
      expect(cleared, 0);
      expect(
        find.text('Не получилось. Проверьте сеть и попробуйте ещё раз'),
        findsOneWidget,
      );
      control.dispose();
    });

    testWidgets('clear error does not restore removed rows', (tester) async {
      final port = _Port();
      final control = HistoryControl(port);
      control.removeLater(_song, _at);
      await control.flush();
      await tester.pump();
      control.removeLater(_other, _later);

      port.failClear = true;
      expect(await control.clear(), isFalse);
      await tester.pump();
      expect(
        control.isHidden(_song, _at),
        isTrue,
        reason: 'no longer present on server',
      );
      expect(port.removed, [
        (_song, _at),
        (_other, _later),
      ], reason: 'pending row dispatched in its own request');
      expect(control.isHidden(_other, _later), isTrue);
      control.dispose();
    });

    testWidgets('clear history cancels pending row deletion', (tester) async {
      final port = _Port();
      final control = HistoryControl(port);
      control.removeLater(_song, _at);

      expect(await control.clear(), isTrue);
      expect(control.canUndo, isFalse);
      await tester.pump(const Duration(seconds: 10));
      expect(
        port.removed,
        isEmpty,
        reason: 'history cleared completely: separate request unnecessary',
      );
      control.dispose();
    });
  });

  group('Undo snackbar bar', () {
    testWidgets('prior failure does not remove Undo from subsequent row', (
      tester,
    ) async {
      final port = _Port()
        ..failRemove = true
        ..holdRemove = Completer<void>();
      final control = HistoryControl(port);
      await tester.pumpWidget(_app(HistoryUndoBar(control: control)));
      control.removeLater(_song, _at);
      await tester.pump(const Duration(seconds: 1));
      control.removeLater(_other, _later);
      await tester.pump();
      port.holdRemove!.complete();
      await tester.pump();
      await tester.pump();

      expect(find.text('Не удалось убрать из истории'), findsOneWidget);
      expect(_undo, findsOneWidget, reason: 'second row can still be restored');
      await tester.tap(_undo);
      await tester.pump();
      expect(control.isHidden(_other, _later), isFalse);
      control.dispose();
    });

    testWidgets('visible only while undo action is available', (tester) async {
      final port = _Port();
      final control = HistoryControl(port);
      await tester.pumpWidget(_app(HistoryUndoBar(control: control)));
      expect(_undo, findsNothing);
      expect(
        find.byType(Text),
        findsNothing,
        reason: 'nothing to undo: snackbar is empty',
      );

      control.removeLater(_song, _at);
      await tester.pump();
      expect(find.text('Убрано из истории'), findsOneWidget);
      expect(find.text('Отменить'), findsOneWidget);
      expect(tester.getSize(_undo).height, greaterThanOrEqualTo(48));

      await tester.tap(_undo);
      await tester.pump();
      expect(control.isHidden(_song, _at), isFalse);
      expect(_undo, findsNothing);

      await tester.pump(const Duration(seconds: 10));
      expect(port.removed, isEmpty);
      control.dispose();
    });

    testWidgets('delete failure described in plain words', (tester) async {
      final port = _Port()..failRemove = true;
      final control = HistoryControl(port);
      await tester.pumpWidget(_app(HistoryUndoBar(control: control)));
      control.removeLater(_song, _at);
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();

      expect(_undo, findsNothing);
      expect(find.text('Не удалось убрать из истории'), findsOneWidget);
      control.dispose();
    });
  });

  testWidgets('English localization', (tester) async {
    final port = _Port()
      ..state = HistoryPause(paused: true, until: DateTime(2026, 10, 6, 21, 5));
    final control = HistoryControl(
      port,
      now: () => DateTime(2026, 10, 6, 18, 5),
    );
    await control.load();
    await tester.pumpWidget(
      _app(
        Column(
          children: [
            HistoryPauseTile(control: control),
            HistoryClearButton(control: control, onCleared: () {}),
            HistoryUndoBar(control: control),
          ],
        ),
        locale: const Locale('en'),
      ),
    );
    control.removeLater(_song, _at);
    await tester.pump();

    expect(find.text('Don’t record history'), findsOneWidget);
    expect(find.text('Until 21:05'), findsOneWidget);
    expect(find.text('Clear history'), findsOneWidget);
    expect(find.text('Removed from history'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);

    control.undo();
    await tester.tap(_clear);
    await tester.pumpAndSettle();
    expect(
      find.text('Erase all listening history? This can’t be undone'),
      findsOneWidget,
    );
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Erase'), findsOneWidget);
    await tester.tap(_cancel);
    await tester.pumpAndSettle();
    control.dispose();
  });
}
