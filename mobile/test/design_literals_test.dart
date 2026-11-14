import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/theme.dart';

/// Colors and corner radii — only via tokens from `theme.dart` (DESIGN.md, FT-491).
///
/// Numeric literal drifts across screens silently: mini-player and "My music"
/// rows were rounded by 20, but token 20 was missing, and next screen would pick
/// 18. Linter inspects source code: color or radius literal allowed only in theme.
void main() {
  final forbidden = <String, RegExp>{
    'цвет числом': RegExp(r'Color\(\s*0x'),
    'Colors.white/black': RegExp(r'Colors\.(white|black)'),
    'радиус числом': RegExp(r'Radius\.circular\(\s*[0-9]'),
  };

  List<String> offenders() {
    final found = <String>[];
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart') && f.path != 'lib/theme.dart');
    for (final file in files) {
      final text = file.readAsStringSync();
      for (final entry in forbidden.entries) {
        for (final match in entry.value.allMatches(text)) {
          final line = '\n'.allMatches(text.substring(0, match.start)).length;
          found.add('${file.path}:${line + 1} — ${entry.key}');
        }
      }
    }
    return found..sort();
  }

  test('in app code color and radius only via theme token', () {
    expect(offenders(), isEmpty);
  });

  test(
    'new tokens are the same numbers as in screens (goldens do not change)',
    () {
      expect(ApertonoRadii.row, 20.0);
      expect(ApertonoRadii.pill, 26.0);
      expect(ApertonoRadii.hairline, 2.0);
      expect(ApertonoColors.shadow, const Color(0x99000000));
      expect(ApertonoColors.progressTrack, const Color(0xFF1B1F26));
      expect(ApertonoColors.scrim, const Color(0xFF000000));
      expect(ApertonoColors.inkOnLight, const Color(0xDD000000));
    },
  );
}
