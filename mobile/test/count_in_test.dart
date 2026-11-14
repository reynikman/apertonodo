// FT-601, lead check fix: number with noun — per screen language rules.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/l10n/l10n.dart';
import 'package:music_stream/screens/parts.dart';

void main() {
  test('Russian keeps three forms, English has two', () {
    final ru = lookupAppLocalizations(const Locale('ru'));
    final en = lookupAppLocalizations(const Locale('en'));
    String r(int n) => countIn(ru, n, 'трек', 'трека', 'треков');
    String e(int n) => countIn(en, n, 'track', 'tracks', 'tracks');
    expect(
      [r(1), r(2), r(5), r(21)],
      ['1 трек', '2 трека', '5 треков', '21 трек'],
    );
    expect(
      [e(1), e(2), e(5), e(21)],
      ['1 track', '2 tracks', '5 tracks', '21 tracks'],
    );
    expect(e(352844), '352 844 tracks');
  });
}
