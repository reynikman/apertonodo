// Check for P9 wave A translation cards (FT-601...FT-605): common part.
//
// Each card translates its own files in `lib/`. Accepted when:
// 1. no string literals with Russian letters remain in its files (comments do not count);
// 2. every Russian string present in those files on `main` (snapshot `test/l10n/ft60N_ru.json`),
//    exists in `app_ru.arb` — verbatim, substitutions `$x` / `${...}` / `{x}` treated as equal, string
//    may be concatenated with adjacent. Russian interface does not change;
// 3. `app_en.arb` has no Russian letters, and every key has a Russian counterpart (`l10n_test.dart`).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final _cyrillic = RegExp('[А-Яа-яЁё]');

/// String literals of code line; everything after `//` outside quotes is a comment.
List<String> _literals(String line) {
  final found = <String>[];
  var quote = '';
  var start = 0;
  for (var i = 0; i < line.length; i++) {
    final char = line[i];
    if (quote.isNotEmpty) {
      if (char == r'\') {
        i++;
      } else if (char == quote) {
        found.add(line.substring(start, i));
        quote = '';
      }
    } else if (char == "'" || char == '"') {
      quote = char;
      start = i + 1;
    } else if (line.startsWith('//', i)) {
      break;
    }
  }
  return found;
}

// Product name on screens — Apertono already in P9 (P-A91).
String _norm(String text) => text
    .replaceAll('Flowtune', 'Apertono')
    .replaceAll(RegExp(r'\$\{[^}]*\}'), '{}')
    .replaceAll(RegExp(r'\$[A-Za-z_]\w*'), '{}')
    .replaceAll(RegExp(r'\{\w+(,[^{}]*)?\}'), '{}')
    .replaceAll(r"\'", "'");

Map<String, String> _arb(String name) {
  final json =
      jsonDecode(File('lib/l10n/$name').readAsStringSync())
          as Map<String, dynamic>;
  return {
    for (final entry in json.entries)
      if (!entry.key.startsWith('@')) entry.key: entry.value as String,
  };
}

void expectCardTranslated(String card) {
  final snapshot =
      jsonDecode(File('test/l10n/${card}_ru.json').readAsStringSync())
          as Map<String, dynamic>;

  for (final file in snapshot.keys) {
    test('$file: no Russian left in code', () {
      final left = [
        for (final line in File('lib/$file').readAsLinesSync())
          for (final literal in _literals(line))
            if (_cyrillic.hasMatch(literal)) literal,
      ];
      expect(left, isEmpty, reason: '$file: Russian strings in code');
    });
  }

  test('$card: every Russian string survives in app_ru.arb', () {
    final ru = _arb('app_ru.arb').values.map(_norm).toList();
    final lost = [
      for (final strings in snapshot.values)
        for (final text in (strings as List<dynamic>).cast<String>())
          if (!ru.any((value) => value.contains(_norm(text)))) text,
    ];
    expect(lost, isEmpty, reason: 'Russian string missing or changed');
  });

  test('$card: English strings have no Russian letters', () {
    final bad = [
      for (final entry in _arb('app_en.arb').entries)
        if (_cyrillic.hasMatch(entry.value)) entry.key,
    ];
    expect(bad, isEmpty);
  });
}
