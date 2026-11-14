import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Mutation control on phone (`scripts/unlazy/mutation_control.mjs`)
/// mutates app by exact code snippets. If a snippet shifts by even a single
/// space — control says "not found", but only on phone. Here the same
/// check runs without phone: Phase I menu restructured `app.dart`, where
/// `select-plays` anchor lives.
void main() {
  const control = '../scripts/unlazy/mutation_control.mjs';
  test(
    'all phone negative-control anchors are found, each once',
    () {
      final script = File(control).readAsStringSync();
      final cases = RegExp(
        r"file: '([^']+)',\s*find:\s*(?:'((?:[^'\\]|\\.)*)'|"
        r'"((?:[^"\\]|\\.)*)")',
      ).allMatches(script).toList();
      expect(cases, hasLength(8), reason: 'eight cases in script');

      for (final match in cases) {
        final file = match[1]!;
        final anchor = (match[2] ?? match[3]!).replaceAllMapped(
          RegExp(r'\\(.)'),
          (escape) => escape[1] == 'n' ? '\n' : escape[1]!,
        );
        final source = File('../$file').readAsStringSync();
        expect(
          anchor.allMatches(source),
          hasLength(1),
          reason: '$file: «$anchor»',
        );
      }
    },
    skip: File(control).existsSync() || Directory('../plan').existsSync()
        ? false
        : 'not in public slice: scripts/unlazy/mutation_control.mjs',
  );
}
