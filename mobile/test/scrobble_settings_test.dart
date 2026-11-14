// FT-644 (P-A94, P-A96, contract D1; feature B6, step P6): "Listening" screen.
//
// Server stores user connection to ListenBrainz (FT-631) and supports Last.fm (FT-643). Here — client
// half: `ScrobbleSettings` (state and actions) and `ScrobbleView` (settings screen body).
//
// Guarded:
// - nothing sent until enabled: screen explains in text while disconnected;
// - ListenBrainz token validated before request and cleared from field after connect;
// - Last.fm hidden completely when server owner did not configure app key;
// - Last.fm authorization page opens strictly via https on www.last.fm — URL provided by server;
// - "not authorized yet" and "timed out" have distinct error messages; errors do not alter state;
// - one action at a time: second tap during pending request is ignored;
// - late response after closing screen does not crash;
// - Russian and English, 320 dp width, buttons >= 48 dp height.
//
// What test does not prove: real requests (provided by `ScrobblePort` written by lead over
// `server_api.dart`), opening browser (`onOpen` wired by lead), and opening screen from settings — B6.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/l10n/l10n.dart';
import 'package:music_stream/screens/scrobble_view.dart';
import 'package:music_stream/scrobble_settings.dart';

const _good = 'abcdefgh-1234';
final _page = Uri.parse('https://www.last.fm/api/auth/?api_key=k&token=t');

class _Port implements ScrobblePort {
  final calls = <String>[];
  final _waiting = <Completer<Object?>>[];

  /// Number of requests awaiting response.
  int get open => _waiting.where((c) => !c.isCompleted).length;

  Future<T> _ask<T>(String name) {
    calls.add(name);
    final completer = Completer<Object?>();
    _waiting.add(completer);
    return completer.future.then((value) => value as T);
  }

  /// Respond to oldest pending request.
  void answer([Object? value]) =>
      _waiting.firstWhere((c) => !c.isCompleted).complete(value);

  void fail() =>
      _waiting.firstWhere((c) => !c.isCompleted).completeError(StateError('x'));

  @override
  Future<ScrobbleStatus> status() => _ask('status');
  @override
  Future<void> connectListenBrainz(String token) => _ask('connect:$token');
  @override
  Future<void> removeListenBrainz() => _ask('remove-lb');
  @override
  Future<Uri> startLastfm() => _ask('start');
  @override
  Future<ScrobbleState> finishLastfm() => _ask('finish');
  @override
  Future<void> removeLastfm() => _ask('remove-lastfm');
}

ScrobbleStatus _status({
  ScrobbleState lb = ScrobbleState.off,
  ScrobbleState lastfm = ScrobbleState.off,
}) => ScrobbleStatus(listenbrainz: lb, lastfm: lastfm);

/// Settings preloaded with given state.
Future<(ScrobbleSettings, _Port)> _loaded({
  ScrobbleState lb = ScrobbleState.off,
  ScrobbleState lastfm = ScrobbleState.off,
}) async {
  final port = _Port();
  final settings = ScrobbleSettings(port);
  final loading = settings.load();
  port.answer(_status(lb: lb, lastfm: lastfm));
  await loading;
  port.calls.clear();
  return (settings, port);
}

Widget _app(Widget child, {Locale locale = const Locale('ru')}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

AppLocalizations _text([String code = 'ru']) =>
    lookupAppLocalizations(Locale(code));

Finder _key(String name) => find.byKey(Key(name));

void main() {
  group('server response', () {
    test('words become states', () {
      final status = ScrobbleStatus.fromJson({
        'listenbrainz': 'bad_token',
        'lastfm': 'pending',
      });
      expect(status.listenbrainz, ScrobbleState.badToken);
      expect(status.lastfm, ScrobbleState.pending);
      for (final (word, state) in [
        ('off', ScrobbleState.off),
        ('on', ScrobbleState.on),
        ('bad_token', ScrobbleState.badToken),
        ('pending', ScrobbleState.pending),
        ('unavailable', ScrobbleState.unavailable),
      ]) {
        expect(
          ScrobbleStatus.fromJson({
            'listenbrainz': 'on',
            'lastfm': word,
          }).lastfm,
          state,
          reason: word,
        );
      }
    });

    test('server without Last.fm: section hidden, ListenBrainz shown', () {
      final status = ScrobbleStatus.fromJson({'listenbrainz': 'on'});
      expect(status.listenbrainz, ScrobbleState.on);
      expect(status.lastfm, ScrobbleState.unavailable);
    });

    test('bad response handled: ListenBrainz off, Last.fm hidden', () {
      for (final Object? json in [
        null,
        'text',
        7,
        <Object?>[],
        <String, Object?>{},
        {'listenbrainz': 5, 'lastfm': true},
        {'listenbrainz': 'ON', 'lastfm': 'On'},
        {'listenbrainz': 'pending', 'lastfm': 'later'},
        {'listenbrainz': 'unavailable', 'lastfm': null},
      ]) {
        final status = ScrobbleStatus.fromJson(json);
        expect(status.listenbrainz, ScrobbleState.off, reason: '$json');
        expect(status.lastfm, ScrobbleState.unavailable, reason: '$json');
      }
    });
  });

  group('loading', () {
    test('before response nothing connected and Last.fm hidden', () {
      final settings = ScrobbleSettings(_Port());
      expect(settings.loaded, isFalse);
      expect(settings.busy, isFalse);
      expect(settings.error, isNull);
      expect(settings.listenbrainz, ScrobbleState.off);
      expect(settings.lastfm, ScrobbleState.unavailable);
    });

    test('response becomes state, listeners notified', () async {
      final port = _Port();
      final settings = ScrobbleSettings(port);
      var told = 0;
      settings.addListener(() => told++);
      final loading = settings.load();
      expect(settings.busy, isTrue);
      expect(told, greaterThan(0));
      port.answer(
        _status(lb: ScrobbleState.on, lastfm: ScrobbleState.badToken),
      );
      await loading;
      expect(settings.loaded, isTrue);
      expect(settings.busy, isFalse);
      expect(settings.listenbrainz, ScrobbleState.on);
      expect(settings.lastfm, ScrobbleState.badToken);
      expect(port.calls, ['status']);
    });

    test('error named, retry reloads', () async {
      final port = _Port();
      final settings = ScrobbleSettings(port);
      final first = settings.load();
      port.fail();
      await first;
      expect(settings.loaded, isFalse);
      expect(settings.busy, isFalse);
      expect(settings.error, ScrobbleError.load);
      final second = settings.load();
      expect(settings.error, isNull, reason: 'new request clears error');
      port.answer(_status(lb: ScrobbleState.on));
      await second;
      expect(settings.loaded, isTrue);
      expect(settings.error, isNull);
    });

    test('refresh failure does not clear known state', () async {
      final (settings, port) = await _loaded(lb: ScrobbleState.on);
      final again = settings.load();
      port.fail();
      await again;
      expect(settings.loaded, isTrue);
      expect(settings.listenbrainz, ScrobbleState.on);
      expect(settings.error, ScrobbleError.load);
    });

    test('actions before load make no requests', () async {
      final port = _Port();
      final settings = ScrobbleSettings(port);
      expect(await settings.connectListenBrainz(_good), isFalse);
      await settings.removeListenBrainz();
      expect(await settings.startLastfm(), isNull);
      await settings.finishLastfm();
      await settings.removeLastfm();
      expect(port.calls, isEmpty);
    });
  });

  group('ListenBrainz', () {
    test('token sent trimmed of whitespace, state becomes connected', () async {
      final (settings, port) = await _loaded();
      final connecting = settings.connectListenBrainz('  $_good \n');
      expect(settings.busy, isTrue);
      expect(port.calls, ['connect:$_good']);
      port.answer();
      expect(await connecting, isTrue);
      expect(settings.listenbrainz, ScrobbleState.on);
      expect(settings.busy, isFalse);
      expect(settings.error, isNull);
    });

    test('invalid token rejected before request', () async {
      final (settings, port) = await _loaded();
      for (final raw in [
        '',
        '   ',
        'short77',
        'has space inside',
        'кириллица-1234',
        'tab\tinside-123',
        'x' * 201,
      ]) {
        expect(await settings.connectListenBrainz(raw), isFalse, reason: raw);
        expect(settings.error, ScrobbleError.tokenShape, reason: raw);
      }
      expect(port.calls, isEmpty);
      expect(settings.listenbrainz, ScrobbleState.off);
    });

    test('length limits: 8 and 200 chars are valid', () async {
      for (final raw in ['x' * 8, 'x' * 200, '!~{}[]"#']) {
        final (settings, port) = await _loaded();
        final connecting = settings.connectListenBrainz(raw);
        expect(port.calls, ['connect:$raw']);
        port.answer();
        expect(await connecting, isTrue);
      }
    });

    test('save error: state unchanged, error named', () async {
      final (settings, port) = await _loaded(lb: ScrobbleState.badToken);
      final connecting = settings.connectListenBrainz(_good);
      port.fail();
      expect(await connecting, isFalse);
      expect(settings.listenbrainz, ScrobbleState.badToken);
      expect(settings.error, ScrobbleError.save);
      expect(settings.busy, isFalse);
    });

    test('new token clears \'bad key\'', () async {
      final (settings, port) = await _loaded(lb: ScrobbleState.badToken);
      final connecting = settings.connectListenBrainz(_good);
      port.answer();
      await connecting;
      expect(settings.listenbrainz, ScrobbleState.on);
    });

    test('disconnect', () async {
      final (settings, port) = await _loaded(lb: ScrobbleState.on);
      final removing = settings.removeListenBrainz();
      expect(port.calls, ['remove-lb']);
      port.answer();
      await removing;
      expect(settings.listenbrainz, ScrobbleState.off);
    });

    test('disconnect failure leaves connected', () async {
      final (settings, port) = await _loaded(lb: ScrobbleState.on);
      final removing = settings.removeListenBrainz();
      port.fail();
      await removing;
      expect(settings.listenbrainz, ScrobbleState.on);
      expect(settings.error, ScrobbleError.save);
    });

    test('nothing to disconnect - no request', () async {
      final (settings, port) = await _loaded();
      await settings.removeListenBrainz();
      expect(port.calls, isEmpty);
    });

    test('form error dismissed on next action', () async {
      final (settings, port) = await _loaded();
      await settings.connectListenBrainz('bad');
      expect(settings.error, ScrobbleError.tokenShape);
      final connecting = settings.connectListenBrainz(_good);
      expect(settings.error, isNull);
      port.answer();
      await connecting;
    });
  });

  group('Last.fm', () {
    test('start: auth page URL, state is waiting', () async {
      final (settings, port) = await _loaded();
      final starting = settings.startLastfm();
      expect(port.calls, ['start']);
      port.answer(_page);
      expect(await starting, _page);
      expect(settings.lastfm, ScrobbleState.pending);
      expect(settings.error, isNull);
    });

    test('untrusted URL is not opened', () async {
      for (final address in [
        'http://www.last.fm/api/auth/?token=t',
        'https://last.fm.evil.example/api/auth/',
        'https://evil.example/www.last.fm',
        'https://www.last.fm.evil.example/',
        'https://evil-last.fm/api/auth/',
        'https://last.fm/api/auth/',
        'intent://www.last.fm/#Intent;end',
        'javascript:alert(1)',
        'https://user@evil.example/?www.last.fm',
      ]) {
        final (settings, port) = await _loaded();
        final starting = settings.startLastfm();
        port.answer(Uri.parse(address));
        expect(await starting, isNull, reason: address);
        expect(settings.lastfm, ScrobbleState.off, reason: address);
        expect(settings.error, ScrobbleError.lastfmStart, reason: address);
      }
    });

    test('start error: state unchanged', () async {
      final (settings, port) = await _loaded(lastfm: ScrobbleState.badToken);
      final starting = settings.startLastfm();
      port.fail();
      expect(await starting, isNull);
      expect(settings.lastfm, ScrobbleState.badToken);
      expect(settings.error, ScrobbleError.lastfmStart);
    });

    test('can start from \'off\', \'bad key\', and \'waiting\'', () async {
      for (final from in [
        ScrobbleState.off,
        ScrobbleState.badToken,
        ScrobbleState.pending,
      ]) {
        final (settings, port) = await _loaded(lastfm: from);
        final starting = settings.startLastfm();
        expect(port.calls, ['start'], reason: '$from');
        port.answer(_page);
        expect(await starting, _page);
      }
    });

    test('hidden or connected Last.fm cannot be started', () async {
      for (final from in [ScrobbleState.unavailable, ScrobbleState.on]) {
        final (settings, port) = await _loaded(lastfm: from);
        expect(await settings.startLastfm(), isNull);
        expect(port.calls, isEmpty, reason: '$from');
        expect(settings.error, isNull);
      }
    });

    test('check: authorized - connected', () async {
      final (settings, port) = await _loaded(lastfm: ScrobbleState.pending);
      final finishing = settings.finishLastfm();
      expect(port.calls, ['finish']);
      port.answer(ScrobbleState.on);
      await finishing;
      expect(settings.lastfm, ScrobbleState.on);
      expect(settings.error, isNull);
    });

    test(
      'check: not yet authorized - remains waiting, explained in text',
      () async {
        final (settings, port) = await _loaded(lastfm: ScrobbleState.pending);
        final finishing = settings.finishLastfm();
        port.answer(ScrobbleState.pending);
        await finishing;
        expect(settings.lastfm, ScrobbleState.pending);
        expect(settings.error, ScrobbleError.lastfmNotYet);
      },
    );

    test('check: timed out - off, start over', () async {
      for (final answer in [
        ScrobbleState.off,
        ScrobbleState.badToken,
        ScrobbleState.unavailable,
      ]) {
        final (settings, port) = await _loaded(lastfm: ScrobbleState.pending);
        final finishing = settings.finishLastfm();
        port.answer(answer);
        await finishing;
        expect(settings.lastfm, ScrobbleState.off, reason: '$answer');
        expect(settings.error, ScrobbleError.lastfmExpired, reason: '$answer');
      }
    });

    test('check failure: stays waiting, can check again', () async {
      final (settings, port) = await _loaded(lastfm: ScrobbleState.pending);
      final finishing = settings.finishLastfm();
      port.fail();
      await finishing;
      expect(settings.lastfm, ScrobbleState.pending);
      expect(settings.error, ScrobbleError.lastfmStart);
      final again = settings.finishLastfm();
      port.answer(ScrobbleState.on);
      await again;
      expect(settings.lastfm, ScrobbleState.on);
    });

    test('nothing to check - no request', () async {
      for (final from in [
        ScrobbleState.unavailable,
        ScrobbleState.off,
        ScrobbleState.on,
        ScrobbleState.badToken,
      ]) {
        final (settings, port) = await _loaded(lastfm: from);
        await settings.finishLastfm();
        expect(port.calls, isEmpty, reason: '$from');
      }
    });

    test('disconnect and cancel wait', () async {
      for (final from in [
        ScrobbleState.on,
        ScrobbleState.pending,
        ScrobbleState.badToken,
      ]) {
        final (settings, port) = await _loaded(lastfm: from);
        final removing = settings.removeLastfm();
        expect(port.calls, ['remove-lastfm'], reason: '$from');
        port.answer();
        await removing;
        expect(settings.lastfm, ScrobbleState.off);
      }
    });

    test('disconnect failure leaves as is', () async {
      final (settings, port) = await _loaded(lastfm: ScrobbleState.on);
      final removing = settings.removeLastfm();
      port.fail();
      await removing;
      expect(settings.lastfm, ScrobbleState.on);
      expect(settings.error, ScrobbleError.save);
    });

    test('nothing to disconnect - no request', () async {
      for (final from in [ScrobbleState.unavailable, ScrobbleState.off]) {
        final (settings, port) = await _loaded(lastfm: from);
        await settings.removeLastfm();
        expect(port.calls, isEmpty, reason: '$from');
      }
    });

    test('ListenBrainz disconnect does not affect Last.fm', () async {
      for (final lastfm in [ScrobbleState.on, ScrobbleState.pending]) {
        final (settings, port) = await _loaded(
          lb: ScrobbleState.on,
          lastfm: lastfm,
        );
        final removing = settings.removeListenBrainz();
        port.answer();
        await removing;
        expect(settings.listenbrainz, ScrobbleState.off);
        expect(settings.lastfm, lastfm);
      }
    });

    test('action on one service does not affect the other', () async {
      final (settings, port) = await _loaded(
        lb: ScrobbleState.on,
        lastfm: ScrobbleState.on,
      );
      final removing = settings.removeLastfm();
      port.answer();
      await removing;
      expect(settings.listenbrainz, ScrobbleState.on);
      final dropping = settings.removeListenBrainz();
      port.answer();
      await dropping;
      expect(settings.lastfm, ScrobbleState.off);
      expect(settings.listenbrainz, ScrobbleState.off);
    });
  });

  group('one action at a time', () {
    test('in-flight request blocks other action requests', () async {
      final (settings, port) = await _loaded(
        lb: ScrobbleState.on,
        lastfm: ScrobbleState.pending,
      );
      final removing = settings.removeListenBrainz();
      expect(await settings.connectListenBrainz(_good), isFalse);
      await settings.removeListenBrainz();
      expect(await settings.startLastfm(), isNull);
      await settings.finishLastfm();
      await settings.removeLastfm();
      await settings.load();
      expect(port.calls, ['remove-lb']);
      expect(settings.error, isNull, reason: 'dropped tap is not an error');
      port.answer();
      await removing;
      expect(settings.busy, isFalse);
    });

    test('invalid token during request does not cause failure', () async {
      final (settings, port) = await _loaded();
      final starting = settings.startLastfm();
      expect(await settings.connectListenBrainz('bad'), isFalse);
      expect(settings.error, isNull);
      port.answer(_page);
      await starting;
    });

    test('after response next action proceeds', () async {
      final (settings, port) = await _loaded();
      final starting = settings.startLastfm();
      port.answer(_page);
      await starting;
      final finishing = settings.finishLastfm();
      expect(port.calls, ['start', 'finish']);
      port.answer(ScrobbleState.on);
      await finishing;
    });
  });

  group('after close', () {
    test('late response crashes nothing and notifies no one', () async {
      for (final late in ['answer', 'fail']) {
        final (settings, port) = await _loaded();
        var told = 0;
        settings.addListener(() => told++);
        final starting = settings.startLastfm();
        final before = told;
        settings.dispose();
        late == 'answer' ? port.answer(_page) : port.fail();
        expect(await starting, isNull);
        expect(told, before);
      }
    });

    test('actions after close make no requests', () async {
      final (settings, port) = await _loaded(
        lb: ScrobbleState.on,
        lastfm: ScrobbleState.pending,
      );
      settings.dispose();
      await settings.load();
      expect(await settings.connectListenBrainz(_good), isFalse);
      await settings.removeListenBrainz();
      expect(await settings.startLastfm(), isNull);
      await settings.finishLastfm();
      await settings.removeLastfm();
      expect(port.calls, isEmpty);
    });
  });

  group('screen', () {
    Future<(ScrobbleSettings, _Port, List<Uri>)> show(
      WidgetTester tester, {
      ScrobbleState lb = ScrobbleState.off,
      ScrobbleState lastfm = ScrobbleState.off,
      Locale locale = const Locale('ru'),
      double width = 400,
    }) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final (settings, port) = await _loaded(lb: lb, lastfm: lastfm);
      addTearDown(settings.dispose);
      final opened = <Uri>[];
      await tester.pumpWidget(
        _app(
          ScrobbleView(settings: settings, onOpen: opened.add),
          locale: locale,
        ),
      );
      return (settings, port, opened);
    }

    testWidgets('makes no requests on its own', (tester) async {
      final port = _Port();
      final settings = ScrobbleSettings(port);
      addTearDown(settings.dispose);
      await tester.pumpWidget(
        _app(ScrobbleView(settings: settings, onOpen: (_) {})),
      );
      expect(port.calls, isEmpty);
      expect(_key('scrobble-loading'), findsOneWidget);
      expect(_key('scrobble-lb-connect'), findsNothing);
    });

    testWidgets('load failure: message and retry', (tester) async {
      final port = _Port();
      final settings = ScrobbleSettings(port);
      addTearDown(settings.dispose);
      await tester.pumpWidget(
        _app(ScrobbleView(settings: settings, onOpen: (_) {})),
      );
      final loading = settings.load();
      port.fail();
      await loading;
      await tester.pump();
      expect(find.text(_text().scrobbleLoadFailed), findsOneWidget);
      expect(_key('scrobble-loading'), findsNothing);
      await tester.tap(_key('scrobble-retry'));
      await tester.pump();
      expect(port.calls, ['status', 'status']);
      expect(_key('scrobble-loading'), findsOneWidget);
      port.answer(_status());
      await tester.pump();
      expect(_key('scrobble-lb-connect'), findsOneWidget);
    });

    testWidgets('nothing connected: stated clearly, hint in place', (
      tester,
    ) async {
      await show(tester);
      expect(
        tester.widget<Text>(_key('scrobble-lb-state')).data,
        _text().scrobbleStateOff,
      );
      expect(
        tester.widget<Text>(_key('scrobble-lastfm-state')).data,
        _text().scrobbleStateOff,
      );
      expect(
        tester.widget<Text>(_key('scrobble-hint')).data,
        _text().scrobbleHint,
      );
      expect(_key('scrobble-lb-token'), findsOneWidget);
      expect(_key('scrobble-lb-connect'), findsOneWidget);
      expect(_key('scrobble-lb-remove'), findsNothing);
      expect(_key('scrobble-lastfm-start'), findsOneWidget);
      expect(_key('scrobble-lastfm-finish'), findsNothing);
      expect(_key('scrobble-lastfm-remove'), findsNothing);
      expect(_key('scrobble-error'), findsNothing);
    });

    testWidgets('token masked with dots and hidden from keyboard', (
      tester,
    ) async {
      await show(tester);
      final field = tester.widget<TextField>(_key('scrobble-lb-token'));
      expect(field.obscureText, isTrue);
      expect(field.autocorrect, isFalse);
      expect(field.enableSuggestions, isFalse);
      expect(field.decoration?.labelText, _text().scrobbleTokenLabel);
    });

    testWidgets('ListenBrainz connected: field cleared and removed', (
      tester,
    ) async {
      final (settings, port, _) = await show(tester);
      await tester.enterText(_key('scrobble-lb-token'), ' $_good ');
      await tester.tap(_key('scrobble-lb-connect'));
      await tester.pump();
      expect(port.calls, ['connect:$_good']);
      port.answer();
      await tester.pump();
      await tester.pump();
      expect(settings.listenbrainz, ScrobbleState.on);
      expect(_key('scrobble-lb-token'), findsNothing);
      expect(find.text(_good), findsNothing);
      expect(
        tester.widget<Text>(_key('scrobble-lb-state')).data,
        _text().scrobbleStateOn,
      );
      expect(_key('scrobble-lb-remove'), findsOneWidget);
      // Disconnected — field cleared: token not retained in app.
      await tester.tap(_key('scrobble-lb-remove'));
      await tester.pump();
      port.answer();
      await tester.pump();
      await tester.pump();
      final field = tester.widget<TextField>(_key('scrobble-lb-token'));
      expect(field.controller?.text, isEmpty);
    });

    testWidgets('screen closed during connect: response crashes nothing', (
      tester,
    ) async {
      final (settings, port, opened) = await show(tester);
      await tester.enterText(_key('scrobble-lb-token'), _good);
      await tester.tap(_key('scrobble-lb-connect'));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      port.answer();
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(settings.listenbrainz, ScrobbleState.on);

      // Same with Last.fm: page in closed screen does not open.
      await tester.pumpWidget(
        _app(ScrobbleView(settings: settings, onOpen: opened.add)),
      );
      await tester.tap(_key('scrobble-lastfm-start'));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      port.answer(_page);
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(opened, isEmpty);
    });

    testWidgets('connect error: input kept, error message shown', (
      tester,
    ) async {
      final (_, port, _) = await show(tester);
      await tester.enterText(_key('scrobble-lb-token'), _good);
      await tester.tap(_key('scrobble-lb-connect'));
      await tester.pump();
      port.fail();
      await tester.pump();
      await tester.pump();
      expect(
        tester.widget<TextField>(_key('scrobble-lb-token')).controller?.text,
        _good,
      );
      expect(
        tester.widget<Text>(_key('scrobble-error')).data,
        _text().scrobbleErrorSave,
      );
    });

    testWidgets('invalid token: error message, no request', (tester) async {
      final (_, port, _) = await show(tester);
      await tester.enterText(_key('scrobble-lb-token'), 'bad');
      await tester.tap(_key('scrobble-lb-connect'));
      await tester.pump();
      expect(port.calls, isEmpty);
      expect(
        tester.widget<Text>(_key('scrobble-error')).data,
        _text().scrobbleErrorTokenShape,
      );
    });

    testWidgets('bad key stated, new input field shown', (tester) async {
      await show(tester, lb: ScrobbleState.badToken);
      expect(
        tester.widget<Text>(_key('scrobble-lb-state')).data,
        _text().scrobbleStateBadToken,
      );
      expect(_key('scrobble-lb-token'), findsOneWidget);
      expect(_key('scrobble-lb-connect'), findsOneWidget);
    });

    testWidgets('Last.fm without server host key is completely hidden', (
      tester,
    ) async {
      await show(tester, lastfm: ScrobbleState.unavailable);
      expect(_key('scrobble-lastfm'), findsNothing);
      expect(_key('scrobble-lastfm-state'), findsNothing);
      expect(_key('scrobble-lastfm-start'), findsNothing);
      expect(find.textContaining('Last.fm'), findsNothing);
      expect(_key('scrobble-lb-connect'), findsOneWidget);
    });

    testWidgets('Last.fm auth: page opens once', (tester) async {
      final (settings, port, opened) = await show(tester);
      await tester.tap(_key('scrobble-lastfm-start'));
      await tester.pump();
      expect(opened, isEmpty, reason: 'URL not available yet');
      port.answer(_page);
      await tester.pump();
      await tester.pump();
      expect(opened, [_page]);
      expect(settings.lastfm, ScrobbleState.pending);
      expect(
        tester.widget<Text>(_key('scrobble-lastfm-state')).data,
        _text().scrobbleStatePending,
      );
      expect(_key('scrobble-lastfm-start'), findsNothing);
      expect(_key('scrobble-lastfm-finish'), findsOneWidget);
      expect(_key('scrobble-lastfm-remove'), findsOneWidget);
    });

    testWidgets('untrusted URL blocked, error explained', (tester) async {
      final (_, port, opened) = await show(tester);
      await tester.tap(_key('scrobble-lastfm-start'));
      await tester.pump();
      port.answer(Uri.parse('https://evil.example/www.last.fm'));
      await tester.pump();
      await tester.pump();
      expect(opened, isEmpty);
      expect(
        tester.widget<Text>(_key('scrobble-error')).data,
        _text().scrobbleErrorLastfmStart,
      );
      expect(_key('scrobble-lastfm-start'), findsOneWidget);
    });

    testWidgets('auth check: three outcomes in three words', (tester) async {
      final (settings, port, _) = await show(
        tester,
        lastfm: ScrobbleState.pending,
      );
      await tester.tap(_key('scrobble-lastfm-finish'));
      await tester.pump();
      port.answer(ScrobbleState.pending);
      await tester.pump();
      await tester.pump();
      expect(
        tester.widget<Text>(_key('scrobble-error')).data,
        _text().scrobbleErrorLastfmNotYet,
      );
      expect(_key('scrobble-lastfm-finish'), findsOneWidget);

      await tester.tap(_key('scrobble-lastfm-finish'));
      await tester.pump();
      expect(_key('scrobble-error'), findsNothing, reason: 'clears on request');
      port.answer(ScrobbleState.off);
      await tester.pump();
      await tester.pump();
      expect(
        tester.widget<Text>(_key('scrobble-error')).data,
        _text().scrobbleErrorLastfmExpired,
      );
      expect(_key('scrobble-lastfm-start'), findsOneWidget);
      expect(settings.lastfm, ScrobbleState.off);
    });

    testWidgets('connected Last.fm: \'Disconnect\' only', (tester) async {
      final (settings, port, _) = await show(tester, lastfm: ScrobbleState.on);
      expect(
        tester.widget<Text>(_key('scrobble-lastfm-state')).data,
        _text().scrobbleStateOn,
      );
      expect(_key('scrobble-lastfm-start'), findsNothing);
      expect(_key('scrobble-lastfm-finish'), findsNothing);
      expect(
        find.descendant(
          of: _key('scrobble-lastfm-remove'),
          matching: find.text(_text().scrobbleDisconnect),
        ),
        findsOneWidget,
      );
      await tester.tap(_key('scrobble-lastfm-remove'));
      await tester.pump();
      port.answer();
      await tester.pump();
      await tester.pump();
      expect(settings.lastfm, ScrobbleState.off);
      expect(_key('scrobble-lastfm-start'), findsOneWidget);
    });

    testWidgets('buttons and field disabled during request', (tester) async {
      final (_, port, _) = await show(tester, lastfm: ScrobbleState.pending);
      await tester.tap(_key('scrobble-lastfm-finish'));
      await tester.pump();
      for (final name in [
        'scrobble-lb-connect',
        'scrobble-lastfm-finish',
        'scrobble-lastfm-remove',
      ]) {
        expect(
          tester.widget<ButtonStyleButton>(_key(name)).onPressed,
          isNull,
          reason: name,
        );
      }
      expect(
        tester.widget<TextField>(_key('scrobble-lb-token')).enabled,
        isFalse,
      );
      await tester.tap(_key('scrobble-lastfm-remove'), warnIfMissed: false);
      await tester.pump();
      expect(port.calls, ['finish']);
      port.answer(ScrobbleState.pending);
      await tester.pump();
      await tester.pump();
      expect(
        tester.widget<ButtonStyleButton>(_key('scrobble-lb-connect')).onPressed,
        isNotNull,
      );
    });

    testWidgets('error is read aloud by screen reader', (tester) async {
      final handle = tester.ensureSemantics();
      await show(tester);
      await tester.tap(_key('scrobble-lb-connect'));
      await tester.pump();
      expect(
        tester.getSemantics(_key('scrobble-error')),
        matchesSemantics(
          label: _text().scrobbleErrorTokenShape,
          isLiveRegion: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('buttons at least 48 dp', (tester) async {
      await show(tester, lb: ScrobbleState.on, lastfm: ScrobbleState.pending);
      for (final name in [
        'scrobble-lb-remove',
        'scrobble-lastfm-finish',
        'scrobble-lastfm-remove',
      ]) {
        final size = tester.getSize(_key(name));
        expect(size.height, greaterThanOrEqualTo(48), reason: name);
        expect(size.width, greaterThanOrEqualTo(48), reason: name);
      }
    });

    testWidgets('English: same places, English words', (tester) async {
      await show(
        tester,
        lb: ScrobbleState.badToken,
        lastfm: ScrobbleState.pending,
        locale: const Locale('en'),
      );
      final en = _text('en');
      expect(
        tester.widget<Text>(_key('scrobble-lb-state')).data,
        en.scrobbleStateBadToken,
      );
      expect(
        tester.widget<Text>(_key('scrobble-lastfm-state')).data,
        en.scrobbleStatePending,
      );
      expect(find.text(en.scrobbleConnect), findsOneWidget);
      expect(find.text(en.scrobbleLastfmCheck), findsOneWidget);
      expect(find.text(en.scrobbleLastfmCancel), findsOneWidget);
      expect(find.text(en.scrobbleHint), findsOneWidget);
    });

    for (final code in ['ru', 'en']) {
      testWidgets('320 dp, $code: no overflow', (tester) async {
        for (final (lb, lastfm) in [
          (ScrobbleState.off, ScrobbleState.off),
          (ScrobbleState.badToken, ScrobbleState.pending),
          (ScrobbleState.on, ScrobbleState.on),
        ]) {
          await show(
            tester,
            lb: lb,
            lastfm: lastfm,
            locale: Locale(code),
            width: 320,
          );
          expect(tester.takeException(), isNull, reason: '$lb $lastfm');
          await tester.pumpWidget(const SizedBox());
        }
      });
    }
  });

  group('rows', () {
    test('each word has both languages, and they differ', () {
      final ru = _text(), en = _text('en');
      final pairs = <(String, String)>[
        (ru.scrobbleStateOff, en.scrobbleStateOff),
        (ru.scrobbleStateOn, en.scrobbleStateOn),
        (ru.scrobbleStateBadToken, en.scrobbleStateBadToken),
        (ru.scrobbleStatePending, en.scrobbleStatePending),
        (ru.scrobbleTokenLabel, en.scrobbleTokenLabel),
        (ru.scrobbleConnect, en.scrobbleConnect),
        (ru.scrobbleDisconnect, en.scrobbleDisconnect),
        (ru.scrobbleLastfmAllow, en.scrobbleLastfmAllow),
        (ru.scrobbleLastfmCheck, en.scrobbleLastfmCheck),
        (ru.scrobbleLastfmCancel, en.scrobbleLastfmCancel),
        (ru.scrobbleLoadFailed, en.scrobbleLoadFailed),
        (ru.scrobbleRetry, en.scrobbleRetry),
        (ru.scrobbleErrorTokenShape, en.scrobbleErrorTokenShape),
        (ru.scrobbleErrorSave, en.scrobbleErrorSave),
        (ru.scrobbleErrorLastfmStart, en.scrobbleErrorLastfmStart),
        (ru.scrobbleErrorLastfmNotYet, en.scrobbleErrorLastfmNotYet),
        (ru.scrobbleErrorLastfmExpired, en.scrobbleErrorLastfmExpired),
        (ru.scrobbleHint, en.scrobbleHint),
      ];
      final cyrillic = RegExp('[а-яА-ЯёЁ]');
      for (final (r, e) in pairs) {
        expect(r, isNotEmpty);
        expect(e, isNotEmpty);
        expect(r, isNot(e));
        expect(cyrillic.hasMatch(r), isTrue, reason: r);
        expect(cyrillic.hasMatch(e), isFalse, reason: e);
      }
      // Six failures — six distinct phrases: "not authorized yet" and "timed out" are not confused.
      final errors = {
        ru.scrobbleLoadFailed,
        ru.scrobbleErrorTokenShape,
        ru.scrobbleErrorSave,
        ru.scrobbleErrorLastfmStart,
        ru.scrobbleErrorLastfmNotYet,
        ru.scrobbleErrorLastfmExpired,
      };
      expect(errors, hasLength(6));
    });
  });
}
