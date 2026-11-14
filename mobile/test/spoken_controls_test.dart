import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/screens/skip_buttons.dart';
import 'package:music_stream/screens/spoken_controls.dart';

// Lead check FT-708 (Pl-1). Executor does not modify this file.

const texts = SpokenTexts(
  skip: SkipTexts(back: 'Назад 15 с', forward: 'Вперёд 30 с'),
  speed: 'Скорость',
  download: 'Скачать',
  downloaded: 'На телефоне',
  sleep: 'Таймер сна',
  queue: 'Очередь',
  parts: 'Части',
  remaining: 'Осталось',
);

Finder k(String key) => find.byKey(ValueKey(key));

Future<void> pumpBox(
  WidgetTester tester,
  Widget child, {
  double width = 360,
  double textScale = 1,
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(width, 800),
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(body: Center(child: child)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class Calls {
  final List<String> log = [];
  VoidCallback cb(String name) =>
      () => log.add(name);
}

SpokenTiles podcastTiles(
  Calls c, {
  double speed = 1.0,
  bool sleep = false,
  SpokenDownload download = SpokenDownload.none,
  int? percent,
}) => SpokenTiles(
  kind: SpokenKind.podcast,
  speed: speed,
  onSpeed: c.cb('speed'),
  sleepActive: sleep,
  onSleep: c.cb('sleep'),
  download: download,
  downloadPercent: percent,
  onDownload: c.cb('download'),
  onQueue: c.cb('queue'),
  texts: texts,
);

SpokenTiles bookTiles(Calls c, {String? remaining = '≈ 3 ч 10 мин'}) =>
    SpokenTiles(
      kind: SpokenKind.book,
      speed: 1.0,
      onSpeed: c.cb('speed'),
      sleepActive: false,
      onSleep: c.cb('sleep'),
      onParts: c.cb('parts'),
      remaining: remaining,
      texts: texts,
    );

void main() {
  group('speedLabel', () {
    for (final (v, s) in [
      (1.0, '1×'),
      (1.25, '1.25×'),
      (0.5, '0.5×'),
      (0.75, '0.75×'),
      (1.5, '1.5×'),
      (2.0, '2×'),
      (3.0, '3×'),
    ]) {
      test('$v → $s', () => expect(speedLabel(v), s));
    }
  });

  group('button row', () {
    testWidgets('-15 left, +30 right, center between them in order', (
      tester,
    ) async {
      final c = Calls();
      await pumpBox(
        tester,
        SpokenTransport(
          center: [
            IconButton(
              key: const ValueKey('c1'),
              onPressed: c.cb('c1'),
              icon: const Icon(Icons.skip_previous),
            ),
            IconButton(
              key: const ValueKey('c2'),
              onPressed: c.cb('c2'),
              icon: const Icon(Icons.play_arrow),
            ),
          ],
          onBack: c.cb('back'),
          onForward: c.cb('forward'),
          texts: texts,
        ),
      );
      final xs = [
        'spoken-back',
        'c1',
        'c2',
        'spoken-forward',
      ].map((key) => tester.getCenter(k(key)).dx).toList();
      for (var i = 1; i < xs.length; i++) {
        expect(xs[i], greaterThan(xs[i - 1]));
      }
      expect(tester.widget<SkipButton>(k('spoken-back')).kind, SkipKind.back);
      expect(
        tester.widget<SkipButton>(k('spoken-forward')).kind,
        SkipKind.forward,
      );
      await tester.tap(k('spoken-back'));
      await tester.tap(k('spoken-forward'));
      await tester.tap(k('c2'));
      expect(c.log, ['back', 'forward', 'c2']);
    });

    testWidgets('no action: button disabled, tap breaks nothing', (
      tester,
    ) async {
      await pumpBox(
        tester,
        const SpokenTransport(
          center: [],
          onBack: null,
          onForward: null,
          texts: texts,
        ),
      );
      expect(tester.widget<SkipButton>(k('spoken-back')).onPressed, isNull);
      await tester.tap(k('spoken-back'), warnIfMissed: false);
      expect(tester.takeException(), isNull);
    });

    testWidgets('-15/+30 tooltips from localized strings', (tester) async {
      await pumpBox(
        tester,
        SpokenTransport(
          center: const [],
          onBack: () {},
          onForward: () {},
          texts: texts,
        ),
      );
      expect(find.byTooltip('Назад 15 с'), findsOneWidget);
      expect(find.byTooltip('Вперёд 30 с'), findsOneWidget);
    });
  });

  group('podcast tiles', () {
    testWidgets(
      'speed, download, timer, queue - left to right; no parts or remaining',
      (tester) async {
        await pumpBox(tester, podcastTiles(Calls()));
        final xs = [
          'spoken-speed',
          'spoken-download',
          'spoken-sleep',
          'spoken-queue',
        ].map((key) => tester.getCenter(k(key)).dx).toList();
        for (var i = 1; i < xs.length; i++) {
          expect(xs[i], greaterThan(xs[i - 1]));
        }
        expect(k('spoken-parts'), findsNothing);
        expect(k('spoken-remaining'), findsNothing);
      },
    );

    testWidgets('taps invoke their actions', (tester) async {
      final c = Calls();
      await pumpBox(tester, podcastTiles(c));
      for (final key in [
        'spoken-speed',
        'spoken-download',
        'spoken-sleep',
        'spoken-queue',
      ]) {
        await tester.tap(k(key));
      }
      expect(c.log, ['speed', 'download', 'sleep', 'queue']);
    });

    testWidgets('speed shown with label and number', (tester) async {
      await pumpBox(tester, podcastTiles(Calls(), speed: 1.5));
      expect(
        find.descendant(of: k('spoken-speed'), matching: find.text('Скорость')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: k('spoken-speed'), matching: find.text('1.5×')),
        findsOneWidget,
      );
    });

    testWidgets(
      'download: idle -> "Download", progress -> %, done -> "On phone"',
      (tester) async {
        await pumpBox(tester, podcastTiles(Calls()));
        expect(
          find.descendant(
            of: k('spoken-download'),
            matching: find.text('Скачать'),
          ),
          findsOneWidget,
        );
        expect(find.textContaining('%'), findsNothing);

        await pumpBox(
          tester,
          podcastTiles(
            Calls(),
            download: SpokenDownload.downloading,
            percent: 42,
          ),
        );
        expect(
          find.descendant(
            of: k('spoken-download'),
            matching: find.text('42 %'),
          ),
          findsOneWidget,
        );

        await pumpBox(
          tester,
          podcastTiles(Calls(), download: SpokenDownload.done),
        );
        expect(
          find.descendant(
            of: k('spoken-download'),
            matching: find.text('На телефоне'),
          ),
          findsOneWidget,
        );
        expect(find.text('Скачать'), findsNothing);
      },
    );

    testWidgets('percentage stays in 0..100', (tester) async {
      await pumpBox(
        tester,
        podcastTiles(
          Calls(),
          download: SpokenDownload.downloading,
          percent: 150,
        ),
      );
      expect(find.text('100 %'), findsOneWidget);
      await pumpBox(
        tester,
        podcastTiles(
          Calls(),
          download: SpokenDownload.downloading,
          percent: -5,
        ),
      );
      expect(find.text('0 %'), findsOneWidget);
    });

    testWidgets('sleep timer active - tile selected for TalkBack', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpBox(tester, podcastTiles(Calls(), sleep: true));
      expect(
        tester.getSemantics(k('spoken-sleep')),
        isSemantics(isButton: true, isSelected: true, label: 'Таймер сна'),
      );
      await pumpBox(tester, podcastTiles(Calls()));
      expect(
        tester.getSemantics(k('spoken-sleep')),
        isSemantics(isButton: true, isSelected: false),
      );
      handle.dispose();
    });

    testWidgets('TalkBack reads speed with value', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpBox(tester, podcastTiles(Calls(), speed: 2.0));
      final label = tester.getSemantics(k('spoken-speed')).label;
      expect(label, contains('Скорость'));
      expect(label, contains('2×'));
      handle.dispose();
    });

    testWidgets('speed not 1x - tile selected, 1x - not', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpBox(tester, podcastTiles(Calls(), speed: 1.25));
      expect(
        tester.getSemantics(k('spoken-speed')),
        isSemantics(isSelected: true),
      );
      await pumpBox(tester, podcastTiles(Calls()));
      expect(
        tester.getSemantics(k('spoken-speed')),
        isSemantics(isSelected: false),
      );
      handle.dispose();
    });

    testWidgets('labels not truncated to single line', (tester) async {
      await pumpBox(tester, podcastTiles(Calls()), textScale: 2);
      for (final t in tester.widgetList<Text>(
        find.descendant(
          of: find.byType(SpokenTiles),
          matching: find.byType(Text),
        ),
      )) {
        expect(t.maxLines, isNull, reason: t.data);
        expect(t.softWrap, isNot(false), reason: t.data);
        expect(t.overflow, isNot(TextOverflow.ellipsis), reason: t.data);
      }
    });

    testWidgets('downloading: "Download" label stays, percent next to it', (
      tester,
    ) async {
      await pumpBox(
        tester,
        podcastTiles(
          Calls(),
          download: SpokenDownload.downloading,
          percent: 42,
        ),
      );
      expect(
        find.descendant(
          of: k('spoken-download'),
          matching: find.text('Скачать'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: k('spoken-download'), matching: find.text('42 %')),
        findsOneWidget,
      );
    });

    testWidgets('tile without action is disabled button for TalkBack', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpBox(
        tester,
        const SpokenTiles(
          kind: SpokenKind.podcast,
          speed: 1.0,
          onSpeed: null,
          sleepActive: false,
          onSleep: null,
          texts: texts,
        ),
      );
      expect(
        tester.getSemantics(k('spoken-queue')),
        isSemantics(isButton: true, hasEnabledState: true, isEnabled: false),
      );
      await pumpBox(tester, podcastTiles(Calls()));
      expect(
        tester.getSemantics(k('spoken-queue')),
        isSemantics(
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          hasTapAction: true,
        ),
      );
      handle.dispose();
    });

    testWidgets(
      'tappable tiles provide ink response (InkWell) like rest of player',
      (tester) async {
        await pumpBox(tester, podcastTiles(Calls()));
        for (final key in [
          'spoken-speed',
          'spoken-download',
          'spoken-sleep',
          'spoken-queue',
        ]) {
          expect(
            find.descendant(of: k(key), matching: find.byType(InkWell)),
            findsOneWidget,
            reason: key,
          );
        }
        expect(find.byType(GestureDetector), findsWidgets);
      },
    );

    testWidgets('tile without action does not crash on tap', (tester) async {
      await pumpBox(
        tester,
        const SpokenTiles(
          kind: SpokenKind.podcast,
          speed: 1.0,
          onSpeed: null,
          sleepActive: false,
          onSleep: null,
          texts: texts,
        ),
      );
      await tester.tap(k('spoken-queue'));
      await tester.tap(k('spoken-speed'));
      expect(tester.takeException(), isNull);
    });
  });

  group('audiobook tiles', () {
    testWidgets('speed, parts, timer, remaining; no download or queue', (
      tester,
    ) async {
      await pumpBox(tester, bookTiles(Calls()));
      final xs = [
        'spoken-speed',
        'spoken-parts',
        'spoken-sleep',
        'spoken-remaining',
      ].map((key) => tester.getCenter(k(key)).dx).toList();
      for (var i = 1; i < xs.length; i++) {
        expect(xs[i], greaterThan(xs[i - 1]));
      }
      expect(k('spoken-download'), findsNothing);
      expect(k('spoken-queue'), findsNothing);
    });

    testWidgets('"Parts" invokes its action', (tester) async {
      final c = Calls();
      await pumpBox(tester, bookTiles(c));
      await tester.tap(k('spoken-parts'));
      expect(c.log, ['parts']);
    });

    testWidgets('"Remaining" displays external string and is not button', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final c = Calls();
      await pumpBox(tester, bookTiles(c));
      expect(
        find.descendant(
          of: k('spoken-remaining'),
          matching: find.text('≈ 3 ч 10 мин'),
        ),
        findsOneWidget,
      );
      expect(
        tester.getSemantics(k('spoken-remaining')),
        isSemantics(isButton: false),
      );
      await tester.tap(k('spoken-remaining'));
      expect(c.log, isEmpty);
      handle.dispose();
    });

    testWidgets('remaining unknown - word only, no blank line', (tester) async {
      await pumpBox(tester, bookTiles(Calls(), remaining: null));
      final texts = tester
          .widgetList<Text>(
            find.descendant(
              of: k('spoken-remaining'),
              matching: find.byType(Text),
            ),
          )
          .map((t) => t.data)
          .toList();
      expect(texts, ['Осталось']);
    });
  });

  group('dimensions', () {
    for (final kind in SpokenKind.values) {
      testWidgets('$kind: equal width tiles, min height 48', (tester) async {
        await pumpBox(
          tester,
          kind == SpokenKind.podcast
              ? podcastTiles(Calls())
              : bookTiles(Calls()),
        );
        final keys = kind == SpokenKind.podcast
            ? [
                'spoken-speed',
                'spoken-download',
                'spoken-sleep',
                'spoken-queue',
              ]
            : [
                'spoken-speed',
                'spoken-parts',
                'spoken-sleep',
                'spoken-remaining',
              ];
        final w = tester.getSize(k(keys.first)).width;
        for (final key in keys) {
          expect(
            tester.getSize(k(key)).height,
            greaterThanOrEqualTo(48),
            reason: key,
          );
          expect(
            tester.getSize(k(key)).width,
            moreOrLessEquals(w, epsilon: 0.5),
            reason: key,
          );
        }
      });

      testWidgets('$kind: 360 dp, font x2 - no overflow', (tester) async {
        await pumpBox(
          tester,
          kind == SpokenKind.podcast
              ? podcastTiles(
                  Calls(),
                  download: SpokenDownload.downloading,
                  percent: 42,
                  speed: 1.25,
                )
              : bookTiles(Calls()),
          textScale: 2,
        );
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('-15/+30 row with 3 center buttons on 320 - no overflow', (
      tester,
    ) async {
      await pumpBox(
        tester,
        SpokenTransport(
          center: [
            IconButton(onPressed: () {}, icon: const Icon(Icons.skip_previous)),
            IconButton(
              onPressed: () {},
              iconSize: 32,
              icon: const Icon(Icons.play_arrow),
            ),
            IconButton(onPressed: () {}, icon: const Icon(Icons.skip_next)),
          ],
          onBack: () {},
          onForward: () {},
          texts: texts,
        ),
        width: 320,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
