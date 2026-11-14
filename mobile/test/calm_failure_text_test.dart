// FT-848: a failure message on the book and podcast screens is calm text, not red.
//
// Lead check. Owner's finding 13.10 (for the second time): "service unavailable — and the text
// is red again". Red stays only on a button that destroys something (remove a book).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _screens = [
  'lib/screens/books_page.dart',
  'lib/screens/book_page.dart',
  'lib/screens/podcast_page.dart',
  'lib/screens/podcasts_page.dart',
];

void main() {
  test('red is only on destructive confirmations', () {
    final wrong = <String>[];
    for (final path in _screens) {
      final lines = File(path).readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (!lines[i].contains('ApertonoColors.error')) continue;
        final before = lines.sublist((i - 8).clamp(0, i), i).join('\n');
        if (!before.contains('confirm')) wrong.add('$path:${i + 1}');
      }
    }
    expect(wrong, isEmpty, reason: 'failure text painted red');
  });
}
