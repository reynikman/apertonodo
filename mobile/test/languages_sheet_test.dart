import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/l10n/app_localizations.dart';
import 'package:music_stream/listening_languages.dart';
import 'package:music_stream/screens/languages_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Lead check FT-706 (Pd-3). Executor does not modify this file.

// FT-808: language name comes from app strings, not from code.
final ruName = lookupAppLocalizations(const Locale('ru')).languageName;
final texts = LanguagesTexts(
  title: 'Языки подкастов',
  all: 'Все языки',
  name: ruName,
);

Finder row(String code) => find.byKey(ValueKey('lang-$code'));
final allRow = find.byKey(const ValueKey('lang-all'));

bool checkedOf(WidgetTester tester, Finder f) {
  return tester.widget<CheckboxListTile>(f).value == true;
}

Future<ListeningLanguages> pump(
  WidgetTester tester, {
  LanguageScope scope = LanguageScope.podcasts,
  String phone = 'ru',
  ListeningLanguages? store,
  Size size = const Size(360, 780),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final langs = store ?? ListeningLanguages(phoneLanguage: () => phone);
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(
        size: size,
        textScaler: TextScaler.linear(textScale),
      ),
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: LanguagesSheet(languages: langs, scope: scope, texts: texts),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return langs;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('header and «All languages» row', (tester) async {
    await pump(tester);
    expect(find.text('Языки подкастов'), findsOneWidget);
    expect(find.text('Все языки'), findsOneWidget);
  });

  testWidgets('all known languages — as rows, in list order, words', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 3000);
    await pump(tester, size: const Size(360, 3000));
    double? prev;
    for (final lang in knownLanguages) {
      expect(row(lang.code), findsOneWidget, reason: lang.code);
      expect(
        find.descendant(
          of: row(lang.code),
          matching: find.text(lang.labelWith(ruName(lang.code))),
        ),
        findsOneWidget,
      );
      final y = tester.getTopLeft(row(lang.code)).dy;
      if (prev != null) expect(y, greaterThan(prev));
      prev = y;
    }
    expect(
      tester.getTopLeft(allRow).dy,
      lessThan(tester.getTopLeft(row('ru')).dy),
    );
  });

  testWidgets('initially phone language checked, «All» unchecked', (
    tester,
  ) async {
    await pump(tester, phone: 'de');
    expect(checkedOf(tester, row('de')), isTrue);
    expect(checkedOf(tester, row('ru')), isFalse);
    expect(checkedOf(tester, allRow), isFalse);
  });

  testWidgets('tapping a language adds it to selection, keeping previous', (
    tester,
  ) async {
    final langs = await pump(tester);
    await tester.tap(row('en'));
    await tester.pumpAndSettle();
    expect(langs.chosen(LanguageScope.podcasts), ['ru', 'en']);
    expect(checkedOf(tester, row('en')), isTrue);
    expect(checkedOf(tester, row('ru')), isTrue);
  });

  testWidgets('tapping again unchecks it', (tester) async {
    final langs = await pump(tester);
    await tester.tap(row('en'));
    await tester.pumpAndSettle();
    await tester.tap(row('en'));
    await tester.pumpAndSettle();
    expect(langs.chosen(LanguageScope.podcasts), ['ru']);
    expect(checkedOf(tester, row('en')), isFalse);
  });

  testWidgets(
    'unchecking the last language cannot stay empty — fallback becomes «All»',
    (tester) async {
      final langs = await pump(tester);
      await tester.tap(row('ru'));
      await tester.pumpAndSettle();
      expect(langs.isAll(LanguageScope.podcasts), isTrue);
      expect(checkedOf(tester, allRow), isTrue);
      expect(checkedOf(tester, row('ru')), isFalse);
    },
  );

  testWidgets('«All» unchecks other checkboxes', (tester) async {
    final langs = await pump(tester);
    await tester.tap(row('en'));
    await tester.pumpAndSettle();
    await tester.tap(allRow);
    await tester.pumpAndSettle();
    expect(langs.isAll(LanguageScope.podcasts), isTrue);
    expect(checkedOf(tester, allRow), isTrue);
    for (final lang in knownLanguages) {
      expect(checkedOf(tester, row(lang.code)), isFalse, reason: lang.code);
    }
  });

  testWidgets('under «All» tapping language leaves only it', (tester) async {
    final langs = await pump(tester);
    await tester.tap(allRow);
    await tester.pumpAndSettle();
    await tester.tap(row('fr'));
    await tester.pumpAndSettle();
    expect(langs.chosen(LanguageScope.podcasts), ['fr']);
    expect(checkedOf(tester, allRow), isFalse);
  });

  testWidgets('books sheet changes only books', (tester) async {
    final langs = await pump(tester, scope: LanguageScope.books);
    await tester.tap(row('en'));
    await tester.pumpAndSettle();
    expect(langs.chosen(LanguageScope.books), ['ru', 'en']);
    expect(langs.chosen(LanguageScope.podcasts), ['ru']);
  });

  testWidgets('podcasts sheet changes only podcasts', (tester) async {
    final langs = await pump(tester);
    await tester.tap(allRow);
    await tester.pumpAndSettle();
    expect(langs.isAll(LanguageScope.podcasts), isTrue);
    expect(langs.isAll(LanguageScope.books), isFalse);
  });

  testWidgets('external change immediately visible on sheet', (tester) async {
    final langs = await pump(tester);
    await langs.toggle(LanguageScope.podcasts, 'es');
    await tester.pumpAndSettle();
    expect(checkedOf(tester, row('es')), isTrue);
  });

  testWidgets('selection persists across restart', (tester) async {
    await pump(tester);
    await tester.tap(row('it'));
    await tester.pumpAndSettle();
    final again = ListeningLanguages(phoneLanguage: () => 'ru');
    await again.load();
    expect(again.chosen(LanguageScope.podcasts), ['ru', 'it']);
  });

  testWidgets('row height at least 48 dp', (tester) async {
    await pump(tester);
    expect(tester.getSize(allRow).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(row('ru')).height, greaterThanOrEqualTo(48));
  });

  testWidgets('TalkBack: row has checked state and accessibility label', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pump(tester, phone: 'de');
    expect(
      tester.getSemantics(row('de')),
      isSemantics(isChecked: true, label: 'Deutsch · Немецкий'),
    );
    handle.dispose();
  });

  testWidgets(
    'large font ×2 on 360 — screen layout has no overflow or truncation',
    (tester) async {
      await pump(tester, textScale: 2, size: const Size(360, 4000));
      expect(tester.takeException(), isNull);
      final text = tester.widget<Text>(
        find.descendant(
          of: row('uk'),
          matching: find.text('Українська · Украинский'),
        ),
      );
      expect(text.maxLines, isNull);
      expect(text.overflow, isNot(TextOverflow.ellipsis));
    },
  );

  testWidgets('sheet does not alter selection on open', (tester) async {
    final langs = await pump(tester);
    expect(langs.chosen(LanguageScope.podcasts), ['ru']);
    expect(langs.chosen(LanguageScope.books), ['ru']);
  });
}
