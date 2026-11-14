// FT-627 (P-A87, beta requirement): "Report problem" sheet in app.
//
// Server receives reports since FT-622 (`POST /v1/problems`). Here — sheet shown on track,
// album, artist, playlist, and player: pick reason, optionally enter comment, send.
//
// Guarded:
// - each location has its own reason list, report includes id of that specific location;
// - report payload strictly matches accepted fields (unexpected field rejects entire request);
// - "Other" without text cannot be submitted; comment limited to 500 chars;
// - second report cannot be submitted while previous request is pending;
// - "too many requests" (429) and failures explained clearly, user selection preserved;
// - Russian and English supported, touch target >= 48 dp.
//
// What test does not prove: buttons opening sheet and real network request — sheet receives
// submission function externally; wired by lead after merging wave A P9.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/l10n/l10n.dart';
import 'package:music_stream/screens/problem_sheet.dart';

const _track = '33333333-3333-3333-3333-333333333333';
const _album = '44444444-4444-4444-4444-444444444444';
const _playlist = '55555555-5555-5555-5555-555555555555';
const _version = '0.9.0+42';

Future<void> _open(
  WidgetTester tester, {
  required ProblemSend send,
  ProblemPlace place = ProblemPlace.song,
  String? trackId = _track,
  String? albumId,
  String? artist,
  String? playlistId,
  Locale locale = const Locale('ru'),
}) => tester.pumpWidget(
  MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: SingleChildScrollView(
        child: ProblemSheet(
          place: place,
          trackId: trackId,
          albumId: albumId,
          artist: artist,
          playlistId: playlistId,
          appVersion: _version,
          send: send,
        ),
      ),
    ),
  ),
);

Finder _reason(String id) => find.byKey(Key('problem-reason-$id'));
final _text = find.byKey(const Key('problem-text'));
final _send = find.byKey(const Key('problem-send'));

void main() {
  test('each target has its own reasons', () {
    expect(problemReasons(ProblemPlace.song), [
      'wrong_track',
      'no_play',
      'bad_sound',
      'cover',
      'wrong_name',
      'other',
    ]);
    expect(
      problemReasons(ProblemPlace.player),
      problemReasons(ProblemPlace.song),
    );
    expect(problemReasons(ProblemPlace.album), [
      'cover',
      'wrong_name',
      'no_play',
      'other',
    ]);
    expect(problemReasons(ProblemPlace.artist), [
      'cover',
      'wrong_name',
      'other',
    ]);
    expect(problemReasons(ProblemPlace.playlist), ['no_play', 'other']);
  });

  test('report body - only server fields, empty omitted', () {
    expect(
      const ProblemReport(
        reason: 'wrong_track',
        place: ProblemPlace.song,
        trackId: _track,
        appVersion: _version,
      ).toJson(),
      {
        'reason': 'wrong_track',
        'place': 'song',
        'track_id': _track,
        'app_version': _version,
      },
    );
    expect(
      const ProblemReport(
        reason: 'other',
        place: ProblemPlace.artist,
        artist: 'Glass Harbor',
        appVersion: _version,
        text: 'фото не того человека',
      ).toJson(),
      {
        'reason': 'other',
        'place': 'artist',
        'artist': 'Glass Harbor',
        'app_version': _version,
        'text': 'фото не того человека',
      },
    );
  });

  for (final (locale, title, wrongTrack, sendLabel, thanks) in [
    (
      const Locale('ru'),
      'Сообщить о проблеме',
      'Играет не та песня',
      'Отправить',
      'Спасибо, отчёт отправлен',
    ),
    (
      const Locale('en'),
      'Report a problem',
      'Wrong song plays',
      'Send',
      'Thanks, report sent',
    ),
  ]) {
    testWidgets('song: select reason and send - $locale', (tester) async {
      final sent = <ProblemReport>[];
      await _open(
        tester,
        locale: locale,
        send: (report) async {
          sent.add(report);
          return ProblemResult.sent;
        },
      );
      expect(find.text(title), findsOneWidget);
      expect(find.text(wrongTrack), findsOneWidget);
      expect(find.text(sendLabel), findsOneWidget);
      for (final id in problemReasons(ProblemPlace.song)) {
        expect(_reason(id), findsOneWidget, reason: id);
        expect(
          tester.getSize(_reason(id)).height,
          greaterThanOrEqualTo(48),
          reason: 'touch target at least 48 dp: $id',
        );
      }
      expect(tester.getSize(_send).height, greaterThanOrEqualTo(48));

      await tester.tap(_send);
      await tester.pump();
      expect(sent, isEmpty, reason: 'report not sent without reason');

      await tester.tap(_reason('wrong_track'));
      await tester.pump();
      await tester.tap(_send);
      await tester.pumpAndSettle();

      expect(sent, hasLength(1));
      expect(sent.single.toJson(), {
        'reason': 'wrong_track',
        'place': 'song',
        'track_id': _track,
        'app_version': _version,
      });
      expect(find.text(thanks), findsOneWidget);
      expect(_send, findsNothing, reason: 'form gone after send');
    });
  }

  testWidgets('album: custom reasons and its id', (tester) async {
    final sent = <ProblemReport>[];
    await _open(
      tester,
      place: ProblemPlace.album,
      trackId: null,
      albumId: _album,
      send: (report) async {
        sent.add(report);
        return ProblemResult.sent;
      },
    );
    expect(_reason('wrong_track'), findsNothing);
    expect(_reason('bad_sound'), findsNothing);
    await tester.tap(_reason('cover'));
    await tester.pump();
    await tester.tap(_send);
    await tester.pumpAndSettle();
    expect(sent.single.toJson(), {
      'reason': 'cover',
      'place': 'album',
      'album_id': _album,
      'app_version': _version,
    });
  });

  testWidgets('artist and playlist carry their own', (tester) async {
    final sent = <ProblemReport>[];
    Future<ProblemResult> send(ProblemReport report) async {
      sent.add(report);
      return ProblemResult.sent;
    }

    await _open(
      tester,
      place: ProblemPlace.artist,
      trackId: null,
      artist: 'Glass Harbor',
      send: send,
    );
    await tester.tap(_reason('wrong_name'));
    await tester.pump();
    await tester.tap(_send);
    await tester.pumpAndSettle();
    expect(sent.last.toJson()['artist'], 'Glass Harbor');
    expect(sent.last.toJson()['place'], 'artist');

    await tester.pumpWidget(const SizedBox());
    await _open(
      tester,
      place: ProblemPlace.playlist,
      trackId: null,
      playlistId: _playlist,
      send: send,
    );
    await tester.tap(_reason('no_play'));
    await tester.pump();
    await tester.tap(_send);
    await tester.pumpAndSettle();
    expect(sent.last.toJson()['playlist_id'], _playlist);
    expect(sent.last.toJson().containsKey('track_id'), isFalse);
  });

  testWidgets('\'Other\' requires text, text trimmed', (tester) async {
    final sent = <ProblemReport>[];
    await _open(
      tester,
      send: (report) async {
        sent.add(report);
        return ProblemResult.sent;
      },
    );
    await tester.tap(_reason('other'));
    await tester.pump();
    await tester.tap(_send);
    await tester.pump();
    expect(sent, isEmpty, reason: '\'Other\' without text rejected');

    await tester.enterText(_text, '   ');
    await tester.pump();
    await tester.tap(_send);
    await tester.pump();
    expect(sent, isEmpty, reason: 'whitespace is not text');

    await tester.enterText(_text, '  играет вторая половина дважды \n');
    await tester.pump();
    await tester.tap(_send);
    await tester.pumpAndSettle();
    expect(sent.single.text, 'играет вторая половина дважды');
    expect(sent.single.toJson()['text'], 'играет вторая половина дважды');
  });

  testWidgets('text for standard reason optional, max 500 chars', (
    tester,
  ) async {
    final sent = <ProblemReport>[];
    await _open(
      tester,
      send: (report) async {
        sent.add(report);
        return ProblemResult.sent;
      },
    );
    await tester.tap(_reason('bad_sound'));
    await tester.pump();
    await tester.enterText(_text, 'я' * 700);
    await tester.pump();
    await tester.tap(_send);
    await tester.pumpAndSettle();
    expect(sent.single.reason, 'bad_sound');
    expect(sent.single.text, isNotNull);
    expect(sent.single.text!.length, lessThanOrEqualTo(500));
  });

  testWidgets('no second report sent while awaiting response', (tester) async {
    var calls = 0;
    final answer = Completer<ProblemResult>();
    await _open(
      tester,
      send: (_) {
        calls++;
        return answer.future;
      },
    );
    await tester.tap(_reason('no_play'));
    await tester.pump();
    await tester.tap(_send);
    await tester.pump();
    await tester.tap(_send, warnIfMissed: false);
    await tester.pump();
    expect(calls, 1);
    answer.complete(ProblemResult.sent);
    await tester.pumpAndSettle();
    expect(calls, 1);
  });

  for (final (locale, result, message) in [
    (
      const Locale('ru'),
      ProblemResult.tooMany,
      'Слишком много отчётов. Попробуйте через час.',
    ),
    (
      const Locale('en'),
      ProblemResult.tooMany,
      'Too many reports. Try again in an hour.',
    ),
    (
      const Locale('ru'),
      ProblemResult.failed,
      'Не получилось отправить. Попробуйте ещё раз.',
    ),
    (const Locale('en'), ProblemResult.failed, 'Could not send. Try again.'),
  ]) {
    testWidgets('failure explained, selection kept - $result $locale', (
      tester,
    ) async {
      final answers = [result, ProblemResult.sent];
      final sent = <ProblemReport>[];
      await _open(
        tester,
        locale: locale,
        send: (report) async {
          sent.add(report);
          return answers.removeAt(0);
        },
      );
      await tester.tap(_reason('other'));
      await tester.pump();
      await tester.enterText(_text, 'треск в начале');
      await tester.pump();
      await tester.tap(_send);
      await tester.pumpAndSettle();

      expect(find.text(message), findsOneWidget);
      expect(_send, findsOneWidget, reason: 'form remained');
      expect(find.text('треск в начале'), findsOneWidget);

      await tester.tap(_send);
      await tester.pumpAndSettle();
      expect(sent, hasLength(2), reason: 'retry without new selection');
      expect(sent.last.reason, 'other');
      expect(sent.last.text, 'треск в начале');
      expect(find.text(message), findsNothing);
    });
  }

  testWidgets('send failure does not crash sheet', (tester) async {
    await _open(tester, send: (_) => Future.error(StateError('no network')));
    await tester.tap(_reason('no_play'));
    await tester.pump();
    await tester.tap(_send);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      find.text('Не получилось отправить. Попробуйте ещё раз.'),
      findsOneWidget,
    );
  });
}
