// FT-861: "About the app" in the account menu thanks the sources
// (owner 13.10 on LRCLIB: "обязательно, в знак благодарности").
// Lead check — do not edit (P-A7).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/l10n/app_localizations.dart';
import 'package:music_stream/screens/account_bar.dart';
import 'package:music_stream/theme.dart';

Future<List<String>> openAbout(WidgetTester tester, Locale locale) async {
  final actions = <String>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: apertonoTheme(),
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        appBar: AppBar(actions: [AccountBar(onAction: actions.add)]),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('account-button')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('about')));
  await tester.pumpAndSettle();
  return actions;
}

String shown(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
    .join('\n');

void main() {
  for (final locale in const [Locale('ru'), Locale('en')]) {
    testWidgets('About names every source we use ($locale)', (tester) async {
      final actions = await openAbout(tester, locale);

      final text = shown(tester);
      expect(text, contains('Apertono'));
      for (final source in const [
        'LRCLIB',
        'MusicBrainz',
        'Cover Art Archive',
        'Wikimedia Commons',
      ]) {
        expect(text, contains(source));
      }
      // The dialog is the menu's own business: nothing leaves the app bar.
      expect(actions, isEmpty);
    });
  }

  testWidgets('About leads to the open-source licences', (tester) async {
    await openAbout(tester, const Locale('ru'));

    await tester.tap(find.byKey(const Key('about-licenses')));
    await tester.pumpAndSettle();

    expect(find.byType(LicensePage), findsOneWidget);
  });
}
