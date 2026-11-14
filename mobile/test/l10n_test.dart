// FT-600 (P-A84, P-A91): foundation of app translation.
//
// Strings live in `lib/l10n/app_en.arb` (primary) and `app_ru.arb` (secondary), screen gets them via
// `l10n(context)`. Language matches phone: Russian phone — Russian, any other — English.
// Until FT-606 all tests run in Russian locale (`flutter_test_config.dart`): wave A executors translate
// screens without touching test strings or golden snapshots.
import 'dart:convert';
import 'dart:io';

import 'package:music_stream/l10n/l10n.dart';
import 'package:music_stream/screens/login_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _arb(String name) =>
    jsonDecode(File('lib/l10n/$name').readAsStringSync())
        as Map<String, dynamic>;

/// In `select`/`plural` word in brackets after branch name (`ru{Russian}`) —
/// human-readable text, not interpolation: skip such bracket (FT-808).
Set<String> _placeholders(String text) {
  final icu = RegExp(r',\s*(select|plural)\s*,').hasMatch(text);
  final pattern = icu ? RegExp(r'(?<![\w=])\{(\w+)') : RegExp(r'\{(\w+)');
  return pattern.allMatches(text).map((m) => m.group(1)!).toSet();
}

Future<void> _pumpLogin(
  WidgetTester tester, {
  bool delegates = false,
  Locale? locale,
}) async {
  final wizard = LoginWizard(onLogin: (_, _, _) async {});
  await tester.pumpWidget(
    delegates
        ? MaterialApp(
            locale: locale,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: wizard,
          )
        : MaterialApp(home: wizard),
  );
  await tester.pump();
}

void main() {
  test('every English key has a Russian twin with the same placeholders', () {
    final en = _arb('app_en.arb');
    final ru = _arb('app_ru.arb');
    final keys = {
      for (final k in en.keys)
        if (!k.startsWith('@')) k,
    };
    final ruKeys = {
      for (final k in ru.keys)
        if (!k.startsWith('@')) k,
    };
    expect(keys, isNotEmpty);
    expect(ruKeys.difference(keys), isEmpty, reason: 'extra keys in ru');
    expect(keys.difference(ruKeys), isEmpty, reason: 'no translation in ru');
    for (final key in keys) {
      expect(
        _placeholders(ru[key] as String),
        _placeholders(en[key] as String),
        reason: 'placeholders in «$key» differ',
      );
    }
  });

  test('tests run in Russian until FT-606', () {
    expect(
      TestWidgetsFlutterBinding.instance.platformDispatcher.locale.languageCode,
      'ru',
    );
  });

  testWidgets('a Russian phone sees Russian', (tester) async {
    await _pumpLogin(tester, delegates: true, locale: const Locale('ru'));
    expect(find.text('Далее'), findsOneWidget);
    expect(find.text('Next'), findsNothing);
  });

  testWidgets('an English phone sees English', (tester) async {
    await _pumpLogin(tester, delegates: true, locale: const Locale('en'));
    expect(find.text('Next'), findsOneWidget);
  });

  testWidgets('any other language falls back to English', (tester) async {
    tester.platformDispatcher.localeTestValue = const Locale('de');
    tester.platformDispatcher.localesTestValue = const [Locale('de')];
    addTearDown(() {
      tester.platformDispatcher.localeTestValue = const Locale('ru');
      tester.platformDispatcher.localesTestValue = const [Locale('ru')];
    });
    await _pumpLogin(tester, delegates: true);
    expect(find.text('Next'), findsOneWidget);
  });

  testWidgets('a screen without delegates (bare test app) follows the phone', (
    tester,
  ) async {
    await _pumpLogin(tester);
    expect(find.text('Далее'), findsOneWidget);
    tester.platformDispatcher.localeTestValue = const Locale('en', 'US');
    addTearDown(
      () => tester.platformDispatcher.localeTestValue = const Locale('ru'),
    );
    await tester.pumpWidget(const SizedBox());
    await _pumpLogin(tester);
    expect(find.text('Next'), findsOneWidget);
  });

  testWidgets('l10n(context) is the same object the delegates give', (
    tester,
  ) async {
    late AppLocalizations seen;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ru'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            seen = l10n(context);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(seen.localeName, 'ru');
  });

  test('Android lets the user pick the app language (Android 13+)', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    expect(manifest, contains('android:localeConfig="@xml/locales_config"'));
    final config = File(
      'android/app/src/main/res/xml/locales_config.xml',
    ).readAsStringSync();
    expect(config, contains('android:name="en"'));
    expect(config, contains('android:name="ru"'));
  });

  test('login has no Russian left in code', () {
    for (final path in [
      'lib/screens/login_screen.dart',
      'lib/auth/login_errors.dart',
    ]) {
      final code = File(path)
          .readAsLinesSync()
          .where((line) => !line.trimLeft().startsWith('//'))
          .join('\n');
      expect(
        RegExp(r'''['"][^'"\n]*[А-Яа-яЁё][^'"\n]*['"]''').hasMatch(code),
        isFalse,
        reason: '$path: Russian string in code',
      );
    }
  });
}
