import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/theme.dart';

/// "Dark Obsidian 2.0" design tokens (P4, step 1; P-A27, P-A28, P-A32).
///
/// Values from owner's `flowtune-flutter-handoff.md`, sections 2–4. Font is
/// Onest instead of Plus Jakarta Sans: that font had zero Cyrillic glyphs, and
/// Russian text rendered with system fallback mixed with Latin.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('colors match design export', () {
    const expected = <String, (Color, int)>{
      'background': (ApertonoColors.background, 0xFF07090C),
      'surface': (ApertonoColors.surface, 0xFF0E1217),
      'surfaceRaised': (ApertonoColors.surfaceRaised, 0xFF151920),
      'navItemActive': (ApertonoColors.navItemActive, 0xFF181D24),
      'border': (ApertonoColors.border, 0x12FFFFFF),
      'borderStrong': (ApertonoColors.borderStrong, 0x1FFFFFFF),
      'divider': (ApertonoColors.divider, 0x0FFFFFFF),
      'accent': (ApertonoColors.accent, 0xFFE5A93B),
      'accentHighlight': (ApertonoColors.accentHighlight, 0xFFF5B842),
      'accentSoft': (ApertonoColors.accentSoft, 0x24E5A93B),
      'textPrimary': (ApertonoColors.textPrimary, 0xFFFFFFFF),
      'textSecondary': (ApertonoColors.textSecondary, 0xFF8C93A4),
      'textMuted': (ApertonoColors.textMuted, 0xFF5D6574),
      'error': (ApertonoColors.error, 0xFFFFB4AB),
    };
    for (final MapEntry(key: name, value: (color, argb)) in expected.entries) {
      expect(color.toARGB32(), argb, reason: name);
    }
  });

  test('tile and panel gradients run top to bottom', () {
    for (final (name, gradient, top, bottom) in [
      ('card', ApertonoColors.cardGradient, 0xFF12161C, 0xFF0A0D12),
      ('nav', ApertonoColors.navGradient, 0xFF13171D, 0xFF0B0E13),
    ]) {
      expect(gradient.begin, Alignment.topCenter, reason: name);
      expect(gradient.end, Alignment.bottomCenter, reason: name);
      expect(gradient.colors.map((c) => c.toARGB32()), [
        top,
        bottom,
      ], reason: name);
    }
  });

  test('radii: single scale across the entire app', () {
    expect(ApertonoRadii.xLarge, 24);
    expect(ApertonoRadii.large, 22);
    expect(ApertonoRadii.medium, 16);
    expect(ApertonoRadii.genre, 14);
    expect(ApertonoRadii.album, 12);
    expect(ApertonoRadii.cover, 10);
    expect(ApertonoRadii.capsule, 22);
  });

  test('typography: sizes, weights and leading of export', () {
    void sans(
      String name,
      TextStyle style,
      double size,
      double line,
      FontWeight weight, {
      double? spacing,
      Color? color,
    }) {
      expect(style.fontFamily, 'Onest', reason: name);
      expect(style.fontSize, size, reason: name);
      expect(style.height! * size, closeTo(line, 0.01), reason: name);
      expect(style.fontWeight, weight, reason: name);
      if (spacing != null) {
        expect(style.letterSpacing, closeTo(spacing, 0.001), reason: name);
      }
      if (color != null) expect(style.color, color, reason: name);
    }

    sans(
      'screenTitle',
      ApertonoText.screenTitle,
      26,
      32,
      FontWeight.w700,
      spacing: -0.52,
      color: ApertonoColors.textPrimary,
    );
    sans(
      'sectionTitle',
      ApertonoText.sectionTitle,
      18,
      22,
      FontWeight.w700,
      spacing: -0.18,
    );
    sans('trackTitle', ApertonoText.trackTitle, 15, 19, FontWeight.w600);
    sans(
      'trackArtist',
      ApertonoText.trackArtist,
      12.5,
      16,
      FontWeight.w400,
      color: ApertonoColors.textSecondary,
    );
    sans('promoTitle', ApertonoText.promoTitle, 16.5, 20, FontWeight.w700);
    sans('artistName', ApertonoText.artistName, 12, 15, FontWeight.w500);

    const time = ApertonoText.time;
    expect(time.fontFamily, 'JetBrains Mono');
    expect(time.fontSize, 12);
    expect(time.height! * 12, closeTo(16, 0.01));
    expect(time.fontWeight, FontWeight.w500);
    expect(time.fontFeatures, contains(const FontFeature.tabularFigures()));
  });

  test('theme uses Onest and export error color', () {
    final theme = apertonoTheme();
    expect(theme.textTheme.bodyMedium?.fontFamily, 'Onest');
    expect(theme.textTheme.titleLarge?.fontFamily, 'Onest');
    expect(theme.colorScheme.error, ApertonoColors.error);
    expect(theme.colorScheme.surface, ApertonoColors.background);
    expect(theme.colorScheme.onSurfaceVariant, ApertonoColors.textSecondary);
    expect(theme.dividerTheme.color, ApertonoColors.divider);
  });

  group('fonts in bundle', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    const weights = {
      'Regular': 400,
      'Medium': 500,
      'SemiBold': 600,
      'Bold': 700,
    };

    test('Onest declared with four weights, Plus Jakarta Sans removed', () {
      expect(pubspec, contains('family: Onest'));
      for (final MapEntry(key: name, value: weight) in weights.entries) {
        expect(
          RegExp(
            'asset: fonts/Onest-$name\\.ttf\\s+weight: $weight',
          ).hasMatch(pubspec),
          isTrue,
          reason: 'Onest-$name should be configured with weight: $weight',
        );
      }
      expect(pubspec, isNot(contains('Jakarta')));
      final leftovers = [
        ...Directory('fonts').listSync().map((f) => f.path),
        ...Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .where((f) => f.readAsStringSync().contains('Jakarta'))
            .map((f) => f.path),
      ].where((path) => path.contains('Jakarta'));
      expect(leftovers, isEmpty, reason: 'leftovers of Plus Jakarta Sans');
    });

    for (final name in weights.keys) {
      test('Onest-$name covers all Cyrillic and Latin glyphs', () {
        final covered = _codePoints(
          File('fonts/Onest-$name.ttf').readAsBytesSync(),
        );
        const russian =
            'АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ'
            'абвгдеёжзийклмнопрстуфхцчшщъыьэюя';
        const latin = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
        const marks = '0123456789«»—…№·éüñß';
        final missing = '$russian$latin$marks'.runes
            .where((rune) => !covered.contains(rune))
            .map(String.fromCharCode)
            .join();
        expect(missing, isEmpty, reason: 'missing in Onest-$name: $missing');
      });
    }

    test('JetBrains Mono supports Cyrillic letters', () {
      final covered = _codePoints(
        File('fonts/JetBrainsMono-Medium.ttf').readAsBytesSync(),
      );
      expect('Ёжик'.runes.every(covered.contains), isTrue);
    });
  });

  test('licenses for both fonts visible in app Licenses', () async {
    registerFontLicenses();
    final fonts = <String, String>{};
    await for (final entry in LicenseRegistry.licenses) {
      for (final package in entry.packages) {
        if (package == 'Onest' || package == 'JetBrains Mono') {
          fonts[package] = entry.paragraphs.map((p) => p.text).join('\n');
        }
      }
    }
    expect(fonts.keys.toSet(), {'Onest', 'JetBrains Mono'});
    for (final MapEntry(key: font, value: text) in fonts.entries) {
      expect(text, contains('SIL Open Font License'), reason: font);
      expect(text, contains('Copyright'), reason: font);
    }
  });
}

/// Characters supported by font: `cmap` table, formats 4 and 12.
Set<int> _codePoints(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final tables = data.getUint16(4);
  int? cmap;
  for (var i = 0; i < tables; i++) {
    final record = 12 + i * 16;
    final tag = String.fromCharCodes(bytes.sublist(record, record + 4));
    if (tag == 'cmap') cmap = data.getUint32(record + 8);
  }
  if (cmap == null) fail('font has no cmap table');

  final found = <int>{};
  final subtables = data.getUint16(cmap + 2);
  for (var i = 0; i < subtables; i++) {
    final at = cmap + data.getUint32(cmap + 4 + i * 8 + 4);
    final format = data.getUint16(at);
    if (format == 4) {
      final segments = data.getUint16(at + 6) ~/ 2;
      final ends = at + 14;
      final starts = ends + segments * 2 + 2;
      final deltas = starts + segments * 2;
      final offsets = deltas + segments * 2;
      for (var s = 0; s < segments; s++) {
        final end = data.getUint16(ends + s * 2);
        final start = data.getUint16(starts + s * 2);
        final delta = data.getUint16(deltas + s * 2);
        final offset = data.getUint16(offsets + s * 2);
        for (var code = start; code <= end && code != 0xFFFF; code++) {
          final glyph = offset == 0
              ? (code + delta) & 0xFFFF
              : data.getUint16(offsets + s * 2 + offset + (code - start) * 2);
          if (glyph != 0) found.add(code);
        }
      }
    } else if (format == 12) {
      final groups = data.getUint32(at + 12);
      for (var g = 0; g < groups; g++) {
        final group = at + 16 + g * 12;
        final start = data.getUint32(group);
        final end = data.getUint32(group + 4);
        for (var code = start; code <= end; code++) {
          found.add(code);
        }
      }
    }
  }
  return found;
}
