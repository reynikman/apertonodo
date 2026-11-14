import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'browse_overview_test.dart' show genresAnswer, photoGenres;
import 'fake_server.dart';
import 'golden_support.dart';

/// "Browse" fits on one screen (FT-794, owner finding 12.10 item 6):
/// "our rule is no downward swiping ... must fit on one screen,
/// without gaps". Tiles "Podcasts" and "Audiobooks" at top, below
/// them ten genres, "All genres" — below genre tiles.
const sizes = {
  'небольшой 360×640': Size(360, 640),
  'обычный 360×780': Size(360, 780),
  'высокий 412×915': Size(412, 915),
  // Mini-player above tab bar subtracts about 80 in height from screen.
  'небольшой с мини-плеером 360×560': Size(360, 560),
  'обычный с мини-плеером 360×700': Size(360, 700),
};

void main() {
  final podcasts = find.byKey(const Key('browse-podcasts'));
  final books = find.byKey(const Key('browse-books'));
  final allGenres = find.byKey(const Key('browse-all-genres'));
  final title = find.byKey(const Key('browse-title'));
  Finder tile(String slug) => find.byKey(ValueKey('genre-card-$slug'));

  Future<void> openBrowse(WidgetTester tester, Size phone) async {
    usePhone(tester, phone);
    final rig = Rig();
    rig.server.on('GET /v1/genres', (_) => answer(200, genresAnswer()));
    await rig.start(tester);
    await openTab(tester, 'browse');
    await tester.pumpAndSettle();
  }

  // Real fonts: with test "Аудиокниги" always fits.
  setUpAll(loadAppFonts);

  for (final MapEntry(key: name, value: phone) in sizes.entries) {
    testWidgets('$name: all on one screen, without scrolling or gaps', (
      tester,
    ) async {
      await openBrowse(tester, phone);
      expect(tester.takeException(), isNull, reason: 'nothing overflowed');

      // Screen bottom is the top of tab bar.
      final floor = tester.getRect(find.byKey(const Key('tab-browse'))).top;
      final all = tester.getRect(allGenres);
      final rock = tester.getRect(tile('rock'));
      // As many genre rows as fit (FT-797): bottom one is last
      // of visible.
      final shown = [
        for (final slug in photoGenres)
          if (tile(slug).evaluate().isNotEmpty) tester.getRect(tile(slug)),
      ];
      expect(shown.length, greaterThanOrEqualTo(4));
      expect(shown.length.isEven, isTrue);
      final reggae = shown.last;
      final spoken = tester.getRect(podcasts);

      // Order top to bottom: header, podcasts and books, genres, "All genres".
      expect(tester.getRect(title).bottom, lessThanOrEqualTo(spoken.top));
      expect(tester.getRect(books).top, spoken.top);
      expect(spoken.bottom, lessThan(rock.top));
      expect(reggae.bottom, lessThanOrEqualTo(all.top));

      // Everything visible without scrolling.
      expect(all.bottom, lessThanOrEqualTo(floor + 0.5));
      for (final element in find.byType(Scrollable).evaluate()) {
        final position = (element as StatefulElement).state as ScrollableState;
        if (position.position.axis != Axis.vertical) continue;
        expect(
          position.position.maxScrollExtent,
          0,
          reason: 'screen should not scroll down',
        );
      }

      // No gaps: neither under "All genres", nor between genres and it.
      expect(floor - all.bottom, lessThanOrEqualTo(24));
      expect(all.top - reggae.bottom, lessThanOrEqualTo(16));

      // Tiles equal height and touch-friendly.
      expect(rock.height, moreOrLessEquals(reggae.height, epsilon: 0.5));
      // Podcasts and books — larger than genre and with photo (owner 12.10).
      expect(spoken.height, greaterThanOrEqualTo(rock.height * 1.3));
      expect(tester.getRect(books).height, spoken.height);
      for (final card in [podcasts, books]) {
        expect(
          find.descendant(of: card, matching: find.byType(Image)),
          findsOneWidget,
        );
      }
      expect(rock.height, greaterThanOrEqualTo(56));
      expect(all.height, greaterThanOrEqualTo(48));
    });
  }

  testWidgets('audiobooks in single line, word does not break', (tester) async {
    await openBrowse(tester, const Size(360, 640));
    final label = find.descendant(of: books, matching: find.text('Аудиокниги'));
    final one = find.descendant(of: podcasts, matching: find.text('Подкасты'));
    expect(
      tester.getSize(label).height,
      moreOrLessEquals(tester.getSize(one).height, epsilon: 0.5),
      reason: 'Audiobooks in two lines like now',
    );
    // And not clipped: "Аудиокни…" is also not a word.
    final paragraph = tester.renderObject<RenderParagraph>(label);
    expect(paragraph.didExceedMaxLines, isFalse);
    expect(
      paragraph.getMaxIntrinsicWidth(double.infinity),
      lessThanOrEqualTo(paragraph.size.width + 0.5),
      reason: 'entire word fits in allotted width',
    );
    // Font size not below 13, even if label is shrunk.
    final scale = tester.getRect(label).height / paragraph.size.height;
    expect(scale * paragraph.text.style!.fontSize!, greaterThanOrEqualTo(13));
  });
}
