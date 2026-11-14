import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/l10n/app_localizations.dart';
import 'package:music_stream/listening_languages.dart';
import 'package:music_stream/screens/languages_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// FT-808 (P9): on English phone podcast and book languages labeled
/// in English, not "Deutsch · German". No Russian words in app code:
/// they live in strings (`lib/l10n`).
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final ru = lookupAppLocalizations(const Locale('ru'));
  final en = lookupAppLocalizations(const Locale('en'));
  final cyrillic = RegExp('[А-Яа-яЁёІіЇїЄєЎў]');

  test('every language in list has name in both app languages', () {
    for (final lang in knownLanguages) {
      expect(ru.languageName(lang.code), isNotEmpty, reason: lang.code);
      expect(en.languageName(lang.code), isNotEmpty, reason: lang.code);
      expect(
        cyrillic.hasMatch(en.languageName(lang.code)),
        isFalse,
        reason: 'English name ${lang.code}',
      );
    }
    expect(ru.languageName('de'), 'Немецкий');
    expect(en.languageName('de'), 'German');
    expect(en.languageName('be'), 'Belarusian');
    expect(en.languageName('zh'), 'Chinese');
  });

  test('unknown code does not crash: empty string', () {
    expect(en.languageName('xx'), isEmpty);
    expect(ru.languageName('xx'), isEmpty);
  });

  Future<void> pumpSheet(WidgetTester tester, AppLocalizations text) async {
    tester.view.physicalSize = const Size(360, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final langs = ListeningLanguages(phoneLanguage: () => 'en');
    addTearDown(langs.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: LanguagesSheet(
              languages: langs,
              scope: LanguageScope.podcasts,
              texts: LanguagesTexts(
                title: 'Podcast languages',
                all: 'All languages',
                name: text.languageName,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('English phone: «Deutsch · German», own in one word', (
    tester,
  ) async {
    await pumpSheet(tester, en);

    expect(find.text('Deutsch · German'), findsOneWidget);
    expect(find.text('English'), findsOneWidget);
    expect(find.text('Русский · Russian'), findsOneWidget);
    expect(find.text('Українська · Ukrainian'), findsOneWidget);
    expect(find.textContaining('Немецкий'), findsNothing);
    expect(find.textContaining('Английский'), findsNothing);
  });

  testWidgets('Russian phone — as before', (tester) async {
    await pumpSheet(tester, ru);

    expect(find.text('Deutsch · Немецкий'), findsOneWidget);
    expect(find.text('Русский'), findsOneWidget);
    expect(find.text('English · Английский'), findsOneWidget);
  });

  testWidgets('without translation sheet shows endonym, no crash', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final langs = ListeningLanguages(phoneLanguage: () => 'en');
    addTearDown(langs.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: LanguagesSheet(
              languages: langs,
              scope: LanguageScope.books,
              texts: const LanguagesTexts(title: 'T', all: 'A'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Deutsch'), findsOneWidget);
  });

  test('no Russian words in app code — they are in strings', () {
    // Language native names — data, not translation; "yo" — sorting key.
    const allowed = {
      'lib/listening_languages.dart': ['Русский', 'Українська', 'Беларуская'],
      'lib/device_library.dart': ['ё', 'е'],
    };
    final literal = RegExp(
      '''(['"])((?:(?!\\1).)*[А-Яа-яЁё](?:(?!\\1).)*)\\1''',
    );
    final found = <String>[];
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      final path = file.path.replaceAll('\\', '/');
      if (path.startsWith('lib/l10n/')) continue;
      final lines = file.readAsLinesSync();
      for (final (i, line) in lines.indexed) {
        final code = line.trimLeft();
        if (code.startsWith('//')) continue;
        for (final match in literal.allMatches(line)) {
          final text = match.group(2)!;
          if (allowed[path]?.contains(text) ?? false) continue;
          found.add('$path:${i + 1}: $text');
        }
      }
    }
    expect(found, isEmpty, reason: found.join('\n'));
  });
}
