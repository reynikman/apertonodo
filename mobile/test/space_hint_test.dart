// FT-694: capacity hint below storage slider (B-5, P-A60). Lead check written before work.
//
// Contract:
// - average track: FLAC 30 MiB, Opus 4 MiB (`avgFlacBytes`, `avgOpusBytes`, 1 MiB = 1024 * 1024);
// - track count — integer division of bytes by average size, then `roughCount`;
// - `roughCount`: < 100 — exact; otherwise rounded to two significant digits (half rounded up);
// - less than one Opus track (including 0 and negative) — `nothing`;
// - external strings (`SpaceHintTexts.fits(flac, opus)`), `SpaceHint` widget renders complete string.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/screens/space_hint.dart';

const gib = 1024 * 1024 * 1024;
const mib = 1024 * 1024;

final texts = SpaceHintTexts(
  fits: (flac, opus) => '≈ $flac songs FLAC / $opus Opus',
  nothing: 'Nothing fits',
);

void main() {
  test('average sizes', () {
    expect(avgFlacBytes, 30 * mib);
    expect(avgOpusBytes, 4 * mib);
  });

  group('roughCount', () {
    for (final (n, want) in [
      (0, 0),
      (1, 1),
      (34, 34),
      (99, 99),
      (100, 100),
      (104, 100),
      (105, 110),
      (170, 170),
      (256, 260),
      (682, 680),
      (995, 1000),
      (999, 1000),
      (1280, 1300),
      (1249, 1200),
      (1250, 1300),
      (5120, 5100),
      (20480, 20000),
      (25600, 26000),
      (123456, 120000),
    ]) {
      test('$n → $want', () => expect(roughCount(n), want));
    }
  });

  group('spaceHint', () {
    for (final (bytes, want) in [
      (1 * gib, '≈ 34 songs FLAC / 260 Opus'),
      (5 * gib, '≈ 170 songs FLAC / 1300 Opus'),
      (20 * gib, '≈ 680 songs FLAC / 5100 Opus'),
      (100 * gib, '≈ 3400 songs FLAC / 26000 Opus'),
      (512 * mib, '≈ 17 songs FLAC / 130 Opus'),
      (29 * mib, '≈ 0 songs FLAC / 7 Opus'),
      (31 * mib, '≈ 1 songs FLAC / 7 Opus'),
      (4 * mib, '≈ 0 songs FLAC / 1 Opus'),
    ]) {
      test('$bytes bytes', () => expect(spaceHint(bytes, texts), want));
    }

    test('less than one Opus track - nothing', () {
      expect(spaceHint(4 * mib - 1, texts), 'Nothing fits');
      expect(spaceHint(1, texts), 'Nothing fits');
      expect(spaceHint(0, texts), 'Nothing fits');
      expect(spaceHint(-gib, texts), 'Nothing fits');
    });

    test('strings provided externally', () {
      final ru = SpaceHintTexts(
        fits: (f, o) => 'примерно $f FLAC / $o Opus',
        nothing: 'ничего не помещается',
      );
      expect(spaceHint(5 * gib, ru), 'примерно 170 FLAC / 1300 Opus');
      expect(spaceHint(0, ru), 'ничего не помещается');
    });
  });

  group('widget', () {
    Future<void> pump(WidgetTester t, int bytes, {double scale = 1}) =>
        t.pumpWidget(
          MediaQuery(
            data: MediaQueryData(
              size: const Size(360, 780),
              textScaler: TextScaler.linear(scale),
            ),
            child: MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: 320,
                  child: SpaceHint(bytes: bytes, texts: texts),
                ),
              ),
            ),
          ),
        );

    testWidgets('displays string', (t) async {
      await pump(t, 5 * gib);
      expect(find.text('≈ 170 songs FLAC / 1300 Opus'), findsOneWidget);
    });

    testWidgets('new value - new string', (t) async {
      await pump(t, 5 * gib);
      await pump(t, 20 * gib);
      expect(find.text('≈ 680 songs FLAC / 5100 Opus'), findsOneWidget);
      expect(find.text('≈ 170 songs FLAC / 1300 Opus'), findsNothing);
    });

    testWidgets('font x2 - not truncated, wraps', (t) async {
      await pump(t, 100 * gib, scale: 2);
      expect(t.takeException(), isNull);
      final text = t.widget<Text>(find.byType(Text));
      expect(text.maxLines, isNull);
      expect(text.overflow, isNot(TextOverflow.ellipsis));
      expect(text.softWrap, isNot(false));
      expect(t.getSize(find.byType(Text)).height, greaterThan(30));
    });

    testWidgets('TalkBack reads entire string', (t) async {
      final sem = t.ensureSemantics();
      await pump(t, 5 * gib);
      expect(
        t.getSemantics(find.byType(SpaceHint)),
        isSemantics(label: '≈ 170 songs FLAC / 1300 Opus'),
      );
      sem.dispose();
    });
  });
}
