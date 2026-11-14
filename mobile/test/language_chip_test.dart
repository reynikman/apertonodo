import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/listening_languages.dart';
import 'package:music_stream/screens/language_chip.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Lead check FT-734 (Yaz-5). Executor does not modify this file.
//
// Contract `mobile/lib/screens/language_chip.dart`:
// - `LanguageChipTexts({required chosen, required all, required nothing,
//   required searchAll, required unknown})`: `chosen(String names)` — "Languages:
//   Russian, English", `all` — "All languages", `nothing` — "Nothing found
//   in selected languages", `searchAll` — "Search all languages", `unknown` —
//   "language not specified".
// - `LanguageChip({required languages, required scope, required texts,
//   required onTap})` — button above results. Label: selected languages
//   by native names (`ListeningLanguage.native`) separated by ", " in order of
//   `knownLanguages`; when "all" — `texts.all`. Repaints itself when
//   selection changes. Key `language-chip`, tap target >= 48.
// - `LanguageEmpty({required texts, required onSearchAll})` — empty results:
//   text `nothing` and button `searchAll` (key `language-search-all`).
// - `languageTag(String? language, {required List<String>? chosen,
//   required bool mixed, required LanguageChipTexts texts}) → String?` —
//   language tag in result row. `null` — no tag. Tag present when
//   results are mixed or language not in selected (`chosen == null` — "all",
//   then only when mixed). Known code — native name, unknown —
//   uppercase code, `null` — `texts.unknown`.

const texts = LanguageChipTexts(
  chosen: _chosen,
  all: 'Все языки',
  nothing: 'На выбранных языках ничего не найдено',
  searchAll: 'Искать на всех языках',
  unknown: 'язык не указан',
);

String _chosen(String names) => 'Языки: $names';

final chip = find.byKey(const ValueKey('language-chip'));

Future<ListeningLanguages> langs() async {
  SharedPreferences.setMockInitialValues({});
  final store = ListeningLanguages(phoneLanguage: () => 'ru');
  addTearDown(store.dispose);
  return store;
}

Future<void> pumpChip(
  WidgetTester tester,
  ListeningLanguages store, {
  VoidCallback? onTap,
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(360, 780),
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: LanguageChip(
              languages: store,
              scope: LanguageScope.podcasts,
              texts: texts,
              onTap: onTap ?? () {},
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('language button', () {
    testWidgets('phone language by default', (tester) async {
      await pumpChip(tester, await langs());
      expect(find.text('Языки: Русский'), findsOneWidget);
    });

    testWidgets('multiple languages — follows list order, endonyms', (
      tester,
    ) async {
      final store = await langs();
      await store.toggle(LanguageScope.podcasts, 'de');
      await store.toggle(LanguageScope.podcasts, 'en');
      await pumpChip(tester, store);
      expect(find.text('Языки: Русский, English, Deutsch'), findsOneWidget);
    });

    testWidgets('«all» — own label', (tester) async {
      final store = await langs();
      await store.setAll(LanguageScope.podcasts);
      await pumpChip(tester, store);
      expect(find.text('Все языки'), findsOneWidget);
    });

    testWidgets('selection changed — label updates without rebuild', (
      tester,
    ) async {
      final store = await langs();
      await pumpChip(tester, store);
      await store.toggle(LanguageScope.podcasts, 'en');
      await tester.pump();
      expect(find.text('Языки: Русский, English'), findsOneWidget);
    });

    testWidgets('books do not affect podcast button', (tester) async {
      final store = await langs();
      await pumpChip(tester, store);
      await store.toggle(LanguageScope.books, 'en');
      await tester.pump();
      expect(find.text('Языки: Русский'), findsOneWidget);
    });

    testWidgets('tap calls onTap, target ≥ 48', (tester) async {
      var taps = 0;
      await pumpChip(tester, await langs(), onTap: () => taps++);
      await tester.tap(chip);
      expect(taps, 1);
      expect(tester.getSize(chip).height >= 48, isTrue);
    });

    testWidgets('TalkBack: button with label, once', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpChip(tester, await langs());
      final label = find.bySemanticsLabel('Языки: Русский');
      expect(label, findsOneWidget);
      expect(
        tester.getSemantics(label),
        isSemantics(isButton: true, hasTapAction: true),
      );
      handle.dispose();
    });

    testWidgets('large font and many languages — layout has no overflow', (
      tester,
    ) async {
      final store = await langs();
      for (final l in knownLanguages.skip(1)) {
        await store.toggle(LanguageScope.podcasts, l.code);
      }
      await pumpChip(tester, store, textScale: 2);
      expect(tester.takeException(), isNull);
    });
  });

  group('empty results', () {
    testWidgets('text and button «in all languages»', (tester) async {
      var asked = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LanguageEmpty(texts: texts, onSearchAll: () => asked++),
          ),
        ),
      );
      expect(
        find.text('На выбранных языках ничего не найдено'),
        findsOneWidget,
      );
      expect(find.text('Искать на всех языках'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('language-search-all')));
      expect(asked, 1);
    });
  });

  group('language tag in row', () {
    String? tag(String? language, {List<String>? chosen, bool mixed = false}) =>
        languageTag(language, chosen: chosen, mixed: mixed, texts: texts);

    test('chosen language, unmixed results — no tag', () {
      expect(tag('ru', chosen: ['ru']), isNull);
    });

    test('mixed results — tag for each', () {
      expect(tag('ru', chosen: ['ru', 'en'], mixed: true), 'Русский');
      expect(tag('en', chosen: ['ru', 'en'], mixed: true), 'English');
    });

    test('unchosen language — tag', () {
      expect(tag('de', chosen: ['ru']), 'Deutsch');
    });

    test('unknown language — «language not specified»', () {
      expect(tag(null, chosen: ['ru']), 'язык не указан');
    });

    test('«all» and unmixed — no tag, even if unknown', () {
      expect(tag('de'), isNull);
      expect(tag(null), isNull);
    });

    test('«all» and mixed — tag', () {
      expect(tag('de', mixed: true), 'Deutsch');
    });

    test('code not in list — uppercase', () {
      expect(tag('nl', chosen: ['ru']), 'NL');
    });
  });
}
