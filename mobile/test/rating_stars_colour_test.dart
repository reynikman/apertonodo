// FT-842: every star up to the rating is lit, not only the last one.
//
// Lead check. Owner's finding 13.10: with a rating of 4 only the fourth star looked lit —
// stars 1–3 were filled but drawn in the secondary grey.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/l10n/app_localizations.dart';
import 'package:music_stream/ratings.dart';
import 'package:music_stream/screens/rating_controls.dart';
import 'package:music_stream/theme.dart';

const _song = '33333333-3333-3333-3333-333333333333';

class _Port implements RatingsPort {
  @override
  Future<Map<String, Rating>> of(List<String> trackIds) async => {};

  @override
  Future<Rating> set(String trackId, {int? stars, bool? disliked}) async =>
      Rating(stars: stars ?? 0, disliked: disliked ?? false);
}

Icon _icon(WidgetTester tester, int n) => tester.widget<Icon>(
  find.descendant(
    of: find.byKey(Key('rating-star-$n')),
    matching: find.byType(Icon),
  ),
);

void main() {
  testWidgets('a rating of four lights four stars in the accent colour', (
    tester,
  ) async {
    final store = RatingsStore(_Port());
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ru'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: RatingStars(store: store, trackId: _song),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('rating-star-4')));
    await tester.pump();

    for (var n = 1; n <= 4; n++) {
      expect(_icon(tester, n).icon, Icons.star, reason: 'star $n is filled');
      expect(
        _icon(tester, n).color,
        ApertonoColors.accent,
        reason: 'star $n is lit',
      );
    }
    expect(_icon(tester, 5).icon, Icons.star_border);
    expect(_icon(tester, 5).color, ApertonoColors.textSecondary);
    store.dispose();
  });
}
