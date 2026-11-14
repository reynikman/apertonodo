// FT-843: three owner findings about lyrics (13.10, No. 3, 5, 13).
//
// Lead check.
//  - the lyrics screen thanks its source: "Текст: LRCLIB" under found lyrics;
//  - the quick-row button is dimmed once the server has answered "no lyrics";
//  - the screen stays on while the lyrics are open and the song is playing.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/l10n/app_localizations.dart';
import 'package:music_stream/lyrics.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/player.dart';
import 'package:music_stream/screen_awake.dart';
import 'package:music_stream/screens/lyrics_sheet.dart';
import 'package:music_stream/screens/lyrics_view.dart';
import 'package:music_stream/screens/player_quick_row.dart';

Widget _app(Widget child) => MaterialApp(
  locale: const Locale('ru'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

const _found = Lyrics(
  found: true,
  instrumental: false,
  plain: 'first line\nsecond line',
  lines: [],
);
const _none = Lyrics(found: false, instrumental: false, plain: null, lines: []);

Widget _view(Lyrics? lyrics) => LyricsView(
  lyrics: lyrics,
  loading: false,
  positions: const Stream<Duration>.empty(),
  onSeek: (_) {},
);

Widget _row({required bool missing}) => PlayerQuickRow(
  downloadTooltip: 'd',
  lyricsTooltip: 'l',
  sleepTooltip: 's',
  onLyrics: () {},
  lyricsMissing: missing,
);

final _dim = find.byKey(const Key('player-quick-lyrics-dim'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <bool>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('apertono/screen'), (
          call,
        ) async {
          if (call.method == 'keepOn') calls.add(call.arguments as bool);
          return null;
        });
  });

  group('credit', () {
    testWidgets('found lyrics end with the source line', (tester) async {
      await tester.pumpWidget(_app(_view(_found)));
      expect(find.byKey(const Key('lyrics-credit')), findsOneWidget);
      expect(find.text('Текст: LRCLIB'), findsOneWidget);
    });

    testWidgets('no lyrics — no credit', (tester) async {
      await tester.pumpWidget(_app(_view(_none)));
      expect(find.byKey(const Key('lyrics-credit')), findsNothing);
    });
  });

  group('quick-row button', () {
    testWidgets('dimmed after the answer "no lyrics", still tappable', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        _app(
          PlayerQuickRow(
            downloadTooltip: 'd',
            lyricsTooltip: 'l',
            sleepTooltip: 's',
            onLyrics: () => taps++,
            lyricsMissing: true,
          ),
        ),
      );
      expect(tester.widget<Opacity>(_dim).opacity, lessThan(0.5));
      await tester.tap(find.byKey(const Key('player-quick-lyrics')));
      expect(taps, 1);
    });

    testWidgets('ordinary before the answer', (tester) async {
      await tester.pumpWidget(_app(_row(missing: false)));
      expect(_dim, findsNothing);
    });

    test('only the answer "not found" counts as missing', () {
      expect(lyricsMissing(_none), isTrue);
      expect(lyricsMissing(_found), isFalse);
      expect(lyricsMissing(null), isFalse, reason: 'no answer is not "no"');
    });
  });

  group('screen', () {
    testWidgets('stays on while asked, released on change and on close', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(const KeepScreenOn(on: true, child: SizedBox())),
      );
      expect(calls, [true]);
      await tester.pumpWidget(
        _app(const KeepScreenOn(on: false, child: SizedBox())),
      );
      expect(calls, [true, false]);
      await tester.pumpWidget(
        _app(const KeepScreenOn(on: true, child: SizedBox())),
      );
      await tester.pumpWidget(_app(const SizedBox()));
      expect(calls, [true, false, true, false]);
    });

    testWidgets('the lyrics sheet asks for it by the player state', (
      tester,
    ) async {
      final player = Player();
      await tester.pumpWidget(
        _app(LyricsSheet(words: Future.value(_found), player: player)),
      );
      await tester.pump();
      final keep = tester.widget<KeepScreenOn>(find.byType(KeepScreenOn));
      expect(keep.on, player.phase == AudioPhase.playing);
      expect(keep.on, isFalse, reason: 'nothing is playing in this test');
      expect(calls, isNot(contains(true)));
      player.dispose();
    });
  });
}
