// FT-844: every bottom sheet opens above the mini-player and the tab bar.
//
// Lead check. Owner's finding 13.10 No. 12: "Report a problem" was cut off by the mini-player
// with a foreign background under it. Screens live in a nested navigator, the mini-player sits
// below it in the outer route — a sheet pushed to the nearest navigator is drawn only in the
// area above the mini-player. Every sheet must go to the root navigator.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every showModalBottomSheet goes to the root navigator', () {
    final wrong = <String>[];
    var seen = 0;
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      final source = file.readAsStringSync();
      for (final call in 'showModalBottomSheet<'.allMatches(source)) {
        seen++;
        // The arguments start right after the call: the flag is among the first of them.
        final end = (call.start + 400).clamp(0, source.length);
        final head = source.substring(call.start, end);
        if (!head.contains('useRootNavigator: true')) {
          final line =
              '\n'.allMatches(source.substring(0, call.start)).length + 1;
          wrong.add('${file.path}:$line');
        }
      }
    }
    expect(seen, greaterThan(10), reason: 'the scan found the sheets');
    expect(wrong, isEmpty, reason: 'sheets under the mini-player');
  });
}
