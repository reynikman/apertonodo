import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/crash_notice.dart';
import 'package:shared_preferences/shared_preferences.dart';

// FT-698 (H6-1): "previous launch ended in crash — send report?".
// Check written by lead before work.

Future<SharedPreferences> prefs([Map<String, Object> values = const {}]) {
  SharedPreferences.setMockInitialValues(values);
  return SharedPreferences.getInstance();
}

StackTrace stackOf(String text) => StackTrace.fromString(text);

const _appFrame =
    '#0      Player.play (package:music_stream/player.dart:120:5)';

void main() {
  group('crash and normal exit', () {
    test('first launch does not prompt', () async {
      final notice = CrashNotice(await prefs());
      await notice.start();
      expect(notice.shouldAsk, isFalse);
    });

    test('launch marks running flag', () async {
      final p = await prefs();
      await CrashNotice(p).start();
      expect(p.getBool(CrashNotice.runningKey), isTrue);
    });

    test('launch with flag present means crash and prompts', () async {
      final p = await prefs();
      await CrashNotice(p).start();
      final next = CrashNotice(p);
      await next.start();
      expect(next.shouldAsk, isTrue);
    });

    test('backgrounding clears flag: OS kill is not crash', () async {
      final p = await prefs();
      final first = CrashNotice(p);
      await first.start();
      await first.paused();
      expect(p.containsKey(CrashNotice.runningKey), isFalse);
      final next = CrashNotice(p);
      await next.start();
      expect(next.shouldAsk, isFalse);
    });

    test('returning from background sets flag again', () async {
      final p = await prefs();
      final first = CrashNotice(p);
      await first.start();
      await first.paused();
      await first.resumed();
      expect(p.getBool(CrashNotice.runningKey), isTrue);
      final next = CrashNotice(p);
      await next.start();
      expect(next.shouldAsk, isTrue);
    });

    test('launch after crash sets flag again', () async {
      final p = await prefs({CrashNotice.runningKey: true});
      final notice = CrashNotice(p);
      await notice.start();
      expect(p.getBool(CrashNotice.runningKey), isTrue);
    });
  });

  group('response', () {
    Future<CrashNotice> crashed([Map<String, Object> more = const {}]) async {
      final notice = CrashNotice(
        await prefs({CrashNotice.runningKey: true, ...more}),
      );
      await notice.start();
      return notice;
    }

    test('prompts once: does not prompt after answer', () async {
      final notice = await crashed();
      await notice.answer(send: false, neverAgain: false);
      expect(notice.shouldAsk, isFalse);
    });

    test('send returns crash report', () async {
      final notice = await crashed();
      final report = await notice.answer(send: true, neverAgain: false);
      expect(report, isNotNull);
    });

    test('do not send produces no report', () async {
      final notice = await crashed();
      final report = await notice.answer(send: false, neverAgain: false);
      expect(report, isNull);
    });

    test('do not ask again is remembered across launches', () async {
      final p = await prefs({CrashNotice.runningKey: true});
      final notice = CrashNotice(p);
      await notice.start();
      await notice.answer(send: false, neverAgain: true);
      expect(p.getBool(CrashNotice.neverKey), isTrue);
      final next = CrashNotice(p);
      await next.start();
      expect(next.shouldAsk, isFalse);
    });

    test('without do not ask again next crash prompts again', () async {
      final p = await prefs({CrashNotice.runningKey: true});
      final notice = CrashNotice(p);
      await notice.start();
      await notice.answer(send: true, neverAgain: false);
      expect(p.containsKey(CrashNotice.neverKey), isFalse);
      final next = CrashNotice(p);
      await next.start();
      expect(next.shouldAsk, isTrue);
    });

    test('response clears saved report', () async {
      final notice = await crashed();
      await notice.remember(StateError('x'), stackOf(_appFrame));
      await notice.answer(send: true, neverAgain: false);
      final p = await SharedPreferences.getInstance();
      expect(p.containsKey(CrashNotice.pendingKey), isFalse);
    });

    test('do not send response also clears report', () async {
      final notice = await crashed();
      await notice.remember(StateError('x'), stackOf(_appFrame));
      await notice.answer(send: false, neverAgain: false);
      final p = await SharedPreferences.getInstance();
      expect(p.containsKey(CrashNotice.pendingKey), isFalse);
    });

    test('never ask does not prompt even after crash', () async {
      final notice = await crashed({CrashNotice.neverKey: true});
      expect(notice.shouldAsk, isFalse);
    });
  });

  group('report', () {
    test('without saved error: crash without stack', () async {
      final notice = CrashNotice(await prefs());
      final json = notice.report.toJson();
      expect(json['kind'], 'crash.native');
      expect(json['screen'], 'app');
      expect(json['frames'], isEmpty);
    });

    test('saved error survives app restart', () async {
      final p = await prefs();
      final first = CrashNotice(p);
      await first.start();
      await first.remember(StateError('boom'), stackOf(_appFrame));
      final next = CrashNotice(p);
      await next.start();
      final json = next.report.toJson();
      expect(json['kind'], 'crash.state_error');
      expect(json['screen'], 'app');
      expect(json['frames'], [
        {
          'function': 'Player.play',
          'file': 'package:music_stream/player.dart',
          'line': 120,
        },
      ]);
    });

    test('error message is omitted from report', () async {
      final p = await prefs();
      final notice = CrashNotice(p);
      await notice.remember(
        StateError('Кино — Группа крови, поиск: секрет'),
        stackOf(_appFrame),
      );
      final stored = p.getString(CrashNotice.pendingKey)!;
      expect(stored, isNot(contains('Кино')));
      expect(stored, isNot(contains('секрет')));
      expect(jsonEncode(notice.report.toJson()), isNot(contains('Кино')));
    });

    test('local paths and addresses stripped from stack', () async {
      final p = await prefs();
      final notice = CrashNotice(p);
      await notice.remember(
        StateError('x'),
        stackOf(
          '#0      a (file:///data/user/0/app/song.mp3:1:1)\n'
          '#1      b (https://apertono.example/v1/stream:2:2)\n'
          '$_appFrame',
        ),
      );
      final stored = p.getString(CrashNotice.pendingKey)!;
      expect(stored, isNot(contains('song.mp3')));
      expect(stored, isNot(contains('apertono.example')));
      expect((notice.report.toJson()['frames'] as List), hasLength(1));
    });

    test('corrupt record: crash without stack, no abort', () async {
      final notice = CrashNotice(
        await prefs({CrashNotice.pendingKey: '{not json'}),
      );
      expect(notice.report.toJson()['kind'], 'crash.native');
    });

    test('malformed record: crash without stack', () async {
      final notice = CrashNotice(
        await prefs({CrashNotice.pendingKey: '[1,2]'}),
      );
      expect(notice.report.toJson()['kind'], 'crash.native');
    });

    test('latest error replaces previous one', () async {
      final notice = CrashNotice(await prefs());
      await notice.remember(StateError('a'), stackOf(_appFrame));
      await notice.remember(ArgumentError('b'), stackOf(_appFrame));
      expect(notice.report.toJson()['kind'], 'crash.argument_error');
    });

    test('send returns saved error', () async {
      final notice = CrashNotice(await prefs({CrashNotice.runningKey: true}));
      await notice.start();
      await notice.remember(StateError('x'), stackOf(_appFrame));
      final report = await notice.answer(send: true, neverAgain: false);
      expect(report!.toJson()['kind'], 'crash.state_error');
    });
  });
}
