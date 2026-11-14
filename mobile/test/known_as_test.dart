import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/l10n/l10n.dart';
import 'package:music_stream/screens/known_as.dart';

/// Im-2 (FT-746): artist name — as in catalog, with "Other
/// spellings" below: "Кино" also found as "Kino". Server provided these names long ago
/// (`aliases: [{name, locale}]`), app did not display them.
Widget page(KnownAs known, {Locale locale = const Locale('ru')}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: SizedBox(width: 360, child: known)),
);

const heading = 'Другие написания';

List<String> shown(WidgetTester tester) => [
  for (final text in tester.widgetList<Text>(
    find.descendant(
      of: find.byKey(const Key('known-as-names')),
      matching: find.byType(Text),
    ),
  ))
    text.data!,
];

void main() {
  group('ArtistAlias.listFrom — parse server response', () {
    test('name and language', () {
      final aliases = ArtistAlias.listFrom([
        {'name': 'Kino', 'locale': 'en'},
        {'name': 'Kino Band'},
      ]);
      expect(aliases.map((a) => (a.name, a.locale)), [
        ('Kino', 'en'),
        ('Kino Band', null),
      ]);
    });

    test('malformed data does not crash page', () {
      expect(ArtistAlias.listFrom(null), isEmpty);
      expect(ArtistAlias.listFrom('Kino'), isEmpty);
      expect(
        ArtistAlias.listFrom([
          42,
          {'locale': 'en'},
          {'name': '   '},
          {'name': 'Kino', 'locale': 7},
        ]).map((a) => (a.name, a.locale)),
        [('Kino', null)],
      );
    });
  });

  testWidgets('no other names — no block', (tester) async {
    await tester.pumpWidget(
      page(const KnownAs(name: 'Кино', aliases: [], language: 'ru')),
    );
    expect(find.text(heading), findsNothing);
    expect(tester.getSize(find.byType(KnownAs)).height, 0);
  });

  testWidgets('matches name (case-insensitive) — not displayed', (
    tester,
  ) async {
    await tester.pumpWidget(
      page(
        const KnownAs(
          name: 'Metallica',
          aliases: [ArtistAlias('METALLICA', 'en'), ArtistAlias('metallica')],
          language: 'ru',
        ),
      ),
    );
    expect(find.text(heading), findsNothing);
  });

  testWidgets('phone language first, then Latin, then rest; '
      'duplicates — only once', (tester) async {
    await tester.pumpWidget(
      page(
        const KnownAs(
          name: 'Кино',
          aliases: [
            ArtistAlias('キノ', 'ja'),
            ArtistAlias('Kino', 'en'),
            ArtistAlias('Группа Кино', 'ru'),
            ArtistAlias('KINO'),
          ],
          language: 'ru',
        ),
      ),
    );
    expect(find.text(heading), findsOneWidget);
    expect(shown(tester), ['Группа Кино', 'Kino', 'キノ']);
  });

  testWidgets('Vietnamese Latin is also Latin', (tester) async {
    await tester.pumpWidget(
      page(
        const KnownAs(
          name: 'Кино',
          aliases: [ArtistAlias('キノ'), ArtistAlias('Đặng Kino')],
          language: 'ru',
        ),
      ),
    );
    expect(shown(tester), ['Đặng Kino', 'キノ']);
  });

  testWidgets('at most five', (tester) async {
    await tester.pumpWidget(
      page(
        KnownAs(
          name: 'Кино',
          aliases: [for (var i = 1; i <= 8; i++) ArtistAlias('Kino $i', 'en')],
          language: 'ru',
        ),
      ),
    );
    expect(shown(tester), ['Kino 1', 'Kino 2', 'Kino 3', 'Kino 4', 'Kino 5']);
  });

  testWidgets('long name — single line with ellipsis', (tester) async {
    await tester.pumpWidget(
      page(
        KnownAs(
          name: 'Кино',
          aliases: [ArtistAlias('Kino ${'very long name ' * 20}', 'en')],
          language: 'ru',
        ),
      ),
    );
    final text = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const Key('known-as-names')),
        matching: find.byType(Text),
      ),
    );
    expect(text.maxLines, 1);
    expect(text.overflow, TextOverflow.ellipsis);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TalkBack reads «Also known as …»', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      page(
        const KnownAs(
          name: 'Кино',
          aliases: [ArtistAlias('Kino', 'en')],
          language: 'ru',
        ),
      ),
    );
    expect(find.bySemanticsLabel('Также известен как Kino'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('in English — own words', (tester) async {
    await tester.pumpWidget(
      page(
        const KnownAs(
          name: 'Кино',
          aliases: [ArtistAlias('Kino', 'en')],
          language: 'en',
        ),
        locale: const Locale('en'),
      ),
    );
    expect(find.text('Also known as'), findsOneWidget);
  });
}
