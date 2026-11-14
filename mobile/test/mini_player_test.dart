import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/screens/mini_player.dart';
import 'package:music_stream/screens/parts.dart';
import 'package:music_stream/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';
import 'golden_support.dart';

/// Mini player per dump (P4, step 2; FT-470): floating 68 dp card with
/// 14 dp margins, 46 dp cover, title and artist, thin bar under text and
/// one gold button. "Back" and "forward" live on the full player.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final card = find.byKey(const Key('mini-player'));
  Finder inCard(Finder what) => find.descendant(of: card, matching: what);

  TextStyle styleOf(WidgetTester tester, String text) =>
      tester.renderObject<RenderParagraph>(inCard(find.text(text))).text.style!;

  /// Entire app, track playing, user returned to home screen.
  Future<Rig> playing(
    WidgetTester tester, {
    Duration at = const Duration(seconds: 134),
  }) async {
    final rig = Rig();
    await rig.start(tester);
    await tester.pumpAndSettle();
    await typeSearch(tester, 'metallica');
    await tester.tap(find.text('Nothing Else Matters'));
    await tester.pump();
    rig.audio.emit(AudioPhase.playing);
    await tester.pump();
    await openTab(tester, 'home');
    rig.audio.tick(at);
    // First frame delivers position, second frame renders it.
    await tester.pump();
    await tester.pump();
    return rig;
  }

  testWidgets('card: padding 14, height 68, cover 46', (tester) async {
    usePhone(tester, phones['360']!);
    await playing(tester);

    final rect = tester.getRect(card);
    expect(rect.left, 14);
    expect(rect.right, 360 - 14);
    expect(rect.height, 68);
    expect(tester.getSize(inCard(find.byType(Cover))), const Size(46, 46));
    expect(tester.takeException(), isNull);
    // Progress bar redraws every second — should only repaint the
    // card, not entire screen. Golden test also captures just the card.
    expect(
      tester.renderObject(find.byType(MiniPlayer)).isRepaintBoundary,
      isTrue,
    );
  });

  testWidgets('single gold button on card; no «back» or «forward»', (
    tester,
  ) async {
    usePhone(tester, phones['360']!);
    await playing(tester);

    expect(inCard(find.byIcon(Icons.skip_next)), findsNothing);
    expect(inCard(find.byIcon(Icons.skip_previous)), findsNothing);
    expect(inCard(find.byType(IconButton)), findsOneWidget);

    final pause = find.byKey(const Key('pause-button'));
    final button = tester.widget<IconButton>(pause);
    expect(button.style?.backgroundColor?.resolve({}), ApertonoColors.accent);
    expect(
      button.style?.foregroundColor?.resolve({}),
      ApertonoColors.background,
    );
    // Circle is 44; Material touch target can expand up to 48, no more.
    final size = tester.getSize(pause);
    expect(size.width, inInclusiveRange(44, 48));
    expect(size.height, inInclusiveRange(44, 48));
    // Right of button is card margin, not screen edge.
    expect(tester.getRect(pause).right, lessThanOrEqualTo(360 - 14 - 8));
  });

  testWidgets('play button still pauses and resumes audio playback', (
    tester,
  ) async {
    final rig = await playing(tester);
    final before = rig.audio.pauses;
    await tester.tap(find.byKey(const Key('pause-button')));
    await tester.pump();
    expect(rig.audio.pauses, before + 1);
    rig.audio.emit(AudioPhase.paused);
    await tester.pump();
    expect(find.byKey(const Key('play-button')), findsOneWidget);
  });

  testWidgets('spec text, 2.5 bar — under text, not full width', (
    tester,
  ) async {
    usePhone(tester, phones['360']!);
    await playing(tester);

    final title = styleOf(tester, 'Nothing Else Matters');
    expect(title.fontSize, 15);
    expect(title.fontWeight, FontWeight.w700);
    expect(title.color, ApertonoColors.textPrimary);
    final artist = styleOf(tester, 'Metallica');
    expect(artist.fontSize, 12.5);
    expect(artist.color, ApertonoColors.textSecondary);

    final bar = tester.getRect(inCard(find.byType(LinearProgressIndicator)));
    final text = tester.getRect(inCard(find.text('Nothing Else Matters')));
    expect(bar.height, 2.5);
    expect(bar.left, text.left);
    expect(
      bar.top,
      greaterThan(tester.getRect(inCard(find.text('Metallica'))).bottom - 0.01),
    );
    expect(
      bar.right,
      lessThanOrEqualTo(
        tester.getRect(find.byKey(const Key('pause-button'))).left,
      ),
    );
    // 134 s of 388: bar shows progress, does not stay at zero.
    final value = tester
        .widget<LinearProgressIndicator>(
          inCard(find.byType(LinearProgressIndicator)),
        )
        .value;
    expect(value, closeTo(134 / 388, 0.02));
  });

  testWidgets('large font: mini player card expands, text not clipped', (
    tester,
  ) async {
    usePhone(tester, phones['360']!);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await playing(tester);

    expect(tester.takeException(), isNull, reason: 'text clipped in card');
    expect(tester.getRect(card).height, greaterThan(68));
  });

  testWidgets('loading: same height, seconds inline with artist', (
    tester,
  ) async {
    // Owner finding 01.10: while track loaded, two lines appeared below title —
    // "Preparing audio" and "0 s" — card grew then shrank
    // back when audio started playback.
    usePhone(tester, phones['360']!);
    final rig = Rig();
    await rig.start(tester);
    await tester.pumpAndSettle();
    await typeSearch(tester, 'metallica');
    await tester.tap(find.text('Nothing Else Matters'));
    await tester.pump();

    final status = inCard(find.text('Готовим звук'));
    final wait = inCard(find.byKey(const Key('play-wait')));
    expect(status, findsOneWidget);
    expect(wait, findsOneWidget);
    expect(inCard(find.text('Metallica')), findsNothing);
    final loading = tester.getRect(card);
    expect(loading.height, 68);
    // Seconds are on the same line, right of words, not on line below.
    expect(
      tester.getRect(wait).center.dy,
      moreOrLessEquals(tester.getRect(status).center.dy, epsilon: 1),
    );
    expect(tester.getRect(wait).left, greaterThan(tester.getRect(status).left));
    final waitStyle = tester.renderObject<RenderParagraph>(wait).text.style!;
    expect(waitStyle.color, ApertonoColors.textSecondary);
    expect(waitStyle.fontSize, 12.5);

    rig.audio.emit(AudioPhase.playing);
    await tester.pump();
    expect(inCard(find.text('Metallica')), findsOneWidget);
    expect(wait, findsNothing);
    expect(tester.getRect(card), loading);
  });

  testWidgets('tapping card opens full player', (tester) async {
    await playing(tester);
    await tester.tap(inCard(find.text('Nothing Else Matters')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('player-screen')), findsOneWidget);
  });

  group('снимок-эталон', () {
    setUpAll(() async {
      await loadAppFonts();
      compareOnMacOnly();
    });

    for (final MapEntry(key: name, value: size) in phones.entries) {
      testWidgets('mini-player at $name dp', (tester) async {
        usePhone(tester, size);
        await playing(tester);
        await expectLater(
          find.byType(MiniPlayer),
          matchesGoldenFile('goldens/mini_player_$name.png'),
        );
      });
    }
  });
}
