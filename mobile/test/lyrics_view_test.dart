import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/l10n/l10n.dart';
import 'package:music_stream/lyrics.dart';
import 'package:music_stream/screens/lyrics_view.dart';

/// FT-623 (P-A77): song lyrics on screen, line is highlighted in sync with music.
///
/// Lyrics come from LRCLIB extension (FT-620, `contracts/lyrics-api.md`):
/// `synced` — LRC text with timestamps, `plain` — without timestamps, or
/// "instrumental", or "not found". Here — LRC parsing and screen; fetching
/// lyrics (server query) and player button — lead after wave A.
///
/// What tests do not prove: that highlighting does not lag on device —
/// owner inspects visually after wiring.
void main() {
  group('LRC parsing', () {
    test('timestamps, sorting, metadata tags', () {
      final lines = parseLrc(
        '[ar:Glass Harbor]\n'
        '[ti:Northern Lights]\n'
        '[00:18.90] гаснут огни\n'
        '[00:12.30] Под северным небом\n'
        '[01:02] припев\n'
        '[00:05.5]\n',
      );
      expect(lines.map((l) => l.text), [
        '',
        'Под северным небом',
        'гаснут огни',
        'припев',
      ]);
      expect(lines.map((l) => l.at), [
        const Duration(milliseconds: 5500),
        const Duration(milliseconds: 12300),
        const Duration(milliseconds: 18900),
        const Duration(minutes: 1, seconds: 2),
      ]);
    });

    test('single line with multiple timestamps repeats', () {
      final lines = parseLrc('[00:10.00][00:40.00]Припев\n[00:20.00]Куплет');
      expect(lines.map((l) => (l.at.inSeconds, l.text)), [
        (10, 'Припев'),
        (20, 'Куплет'),
        (40, 'Припев'),
      ]);
    });

    test('three-digit hundredths and [offset] shift', () {
      final lines = parseLrc('[offset:+500]\n[00:10.250] раз\n[00:11.05] два');
      // offset > 0 — lyrics earlier than music: timestamps shift back.
      expect(lines.map((l) => l.at), [
        const Duration(milliseconds: 9750),
        const Duration(milliseconds: 10550),
      ]);
    });

    test('malformed text does not crash parsing', () {
      expect(parseLrc(''), isEmpty);
      expect(parseLrc('просто текст без меток\n[xx:yy] нет'), isEmpty);
    });

    test('current line lookup', () {
      final lines = parseLrc('[00:10.00]a\n[00:20.00]b\n[00:30.00]c');
      expect(currentLine(lines, Duration.zero), -1);
      expect(currentLine(lines, const Duration(seconds: 10)), 0);
      expect(currentLine(lines, const Duration(seconds: 25)), 1);
      expect(currentLine(lines, const Duration(minutes: 5)), 2);
      expect(currentLine(const [], const Duration(seconds: 5)), -1);
    });
  });

  test('server response matches contract', () {
    final synced = Lyrics.fromJson({
      'found': true,
      'instrumental': false,
      'plain': 'a\nb',
      'synced': '[00:01.00]a',
    });
    expect(synced.found, isTrue);
    expect(synced.lines, hasLength(1));
    expect(synced.plain, 'a\nb');
    expect(Lyrics.fromJson({'found': false}).found, isFalse);
    final instrumental = Lyrics.fromJson({
      'found': true,
      'instrumental': true,
      'plain': null,
      'synced': null,
    });
    expect(instrumental.instrumental, isTrue);
    expect(instrumental.lines, isEmpty);
  });

  for (final (locale, none, instrumental) in [
    (const Locale('ru'), 'Текста этой песни пока нет', 'Без слов'),
    (const Locale('en'), 'No lyrics for this song yet', 'Instrumental'),
  ]) {
    Widget host(Widget child) => MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );

    testWidgets('no lyrics, instrumental, loading — $locale', (tester) async {
      final positions = StreamController<Duration>.broadcast();
      addTearDown(positions.close);
      Widget view(Lyrics? l, {bool loading = false}) => host(
        LyricsView(
          lyrics: l,
          loading: loading,
          positions: positions.stream,
          onSeek: (_) {},
        ),
      );

      await tester.pumpWidget(view(null, loading: true));
      expect(find.byKey(const Key('lyrics-loading')), findsOneWidget);

      await tester.pumpWidget(view(Lyrics.fromJson({'found': false})));
      expect(find.text(none), findsOneWidget);

      await tester.pumpWidget(
        view(
          Lyrics.fromJson({
            'found': true,
            'instrumental': true,
            'plain': null,
            'synced': null,
          }),
        ),
      );
      expect(find.text(instrumental), findsOneWidget);

      await tester.pumpWidget(
        view(
          Lyrics.fromJson({
            'found': true,
            'instrumental': false,
            'plain': 'первая строка\nвторая строка',
            'synced': null,
          }),
        ),
      );
      expect(find.byKey(const Key('lyrics-plain')), findsOneWidget);
      expect(find.textContaining('вторая строка'), findsOneWidget);
    });
  }

  testWidgets('line highlighted, lyrics list scrolls, tap seeks song', (
    tester,
  ) async {
    final lrc = [
      for (var i = 0; i < 60; i++)
        '[${(i * 4 ~/ 60).toString().padLeft(2, '0')}:'
            '${(i * 4 % 60).toString().padLeft(2, '0')}.00] строка $i',
    ].join('\n');
    final lyrics = Lyrics.fromJson({
      'found': true,
      'instrumental': false,
      'plain': null,
      'synced': lrc,
    });
    final positions = StreamController<Duration>.broadcast();
    addTearDown(positions.close);
    final seeks = <Duration>[];

    await tester.binding.setSurfaceSize(const Size(400, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: LyricsView(
            lyrics: lyrics,
            positions: positions.stream,
            onSeek: seeks.add,
          ),
        ),
      ),
    );

    FontWeight? weight(int i) => tester
        .widget<Text>(
          find.descendant(
            of: find.byKey(Key('lyric-$i')),
            matching: find.byType(Text),
          ),
        )
        .style
        ?.fontWeight;

    positions.add(const Duration(seconds: 8, milliseconds: 500));
    await tester.pumpAndSettle();
    expect(weight(2), FontWeight.w700, reason: 'line 2 — from 8s');
    expect(weight(1), isNot(FontWeight.w700));
    expect(weight(3), isNot(FontWeight.w700));

    positions.add(const Duration(seconds: 160, milliseconds: 100));
    await tester.pumpAndSettle();
    final line = find.byKey(const Key('lyric-40'));
    expect(line, findsOneWidget);
    expect(weight(40), FontWeight.w700);
    final rect = tester.getRect(line);
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(
      rect.bottom,
      lessThanOrEqualTo(700),
      reason: 'current line on screen',
    );

    await tester.tap(line);
    await tester.pump();
    expect(seeks, [const Duration(seconds: 160)]);
    expect(
      tester.getSize(line).height,
      greaterThanOrEqualTo(48),
      reason: 'touch target at least 48 dp',
    );
  });
}
