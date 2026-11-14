import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/l10n/app_localizations.dart';
import 'package:music_stream/screens/login_screen.dart';
import 'package:music_stream/theme.dart';

import 'golden_support.dart';

/// Login screen (P4, P-A43): custom MaterialApp used default Material theme —
/// purple. Now app colors are used.
void main() {
  final address = find.byKey(const Key('server-address-field'));
  final next = find.byKey(const Key('server-address-next'));

  late List<Uri> logins;

  Future<void> open(WidgetTester tester) async {
    logins = [];
    await tester.pumpWidget(
      LoginWizard(onLogin: (server, _, _) async => logins.add(server)),
    );
    await tester.pumpAndSettle();
  }

  InputDecoration decorationOf(WidgetTester tester, Finder field) =>
      tester.widget<TextField>(field).decoration!;

  Future<void> typeAddress(WidgetTester tester, String value) async {
    await tester.enterText(address, value);
    await tester.pump();
    await tester.tap(next);
    await tester.pumpAndSettle();
  }

  Future<void> signIn(WidgetTester tester) async {
    await tester.enterText(find.byKey(const Key('login-username')), 'anna');
    await tester.enterText(find.byKey(const Key('login-password')), 'secret');
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pumpAndSettle();
  }

  testWidgets('app colors, not purple Material', (tester) async {
    await open(tester);
    final theme = Theme.of(tester.element(address));
    expect(theme.colorScheme.primary, ApertonoColors.accent);
    expect(theme.scaffoldBackgroundColor, ApertonoColors.background);
    expect(theme.colorScheme.brightness, Brightness.dark);
    final button = tester.widget<Material>(
      find.descendant(of: next, matching: find.byType(Material)).first,
    );
    expect(button.color, ApertonoColors.accent);
    // Button has the same corner radius as input fields, not a Material "pill".
    expect(
      button.shape,
      RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ApertonoRadii.medium),
      ),
    );
  });

  testWidgets('login title matches regular app screens, without AppBar', (
    tester,
  ) async {
    await open(tester);
    expect(find.byType(AppBar), findsNothing);
    final title = tester.widget<Text>(find.byKey(const Key('wizard-title')));
    expect(title.style?.fontSize, ApertonoText.screenTitle.fontSize);
    expect(title.style?.fontWeight, FontWeight.w700);
  });

  testWidgets('address field: no prefix, an example, and where Next will go', (
    tester,
  ) async {
    // Owner 13.10: a fixed "https://" in front read as "https only".
    await open(tester);
    final decoration = decorationOf(tester, address);
    final ru = lookupAppLocalizations(const Locale('ru'));
    expect(decoration.prefixText, isNull);
    expect(decoration.hintText, ru.loginAddressExample);
    expect(find.text('https://'), findsNothing);
    final note = find.byKey(const Key('wizard-scheme-note'));
    expect(note, findsNothing);
    Future<String?> noteFor(String typed) async {
      await tester.enterText(address, typed);
      await tester.pump();
      return note.evaluate().isEmpty ? null : tester.widget<Text>(note).data;
    }

    expect(
      await noteFor('192.168.1.10:8088'),
      ru.loginConnectVia('http://192.168.1.10:8088'),
    );
    expect(tester.widget<Text>(note).style?.color, ApertonoColors.textMuted);
    expect(
      await noteFor('music.example.org'),
      ru.loginConnectVia('https://music.example.org'),
    );
    expect(await noteFor('nas:8088'), ru.loginConnectVia('http://nas:8088'));
    // Half-typed input names no address.
    for (final half in ['h', 'http', 'https:/', 'mus', 'music.', '192.168.']) {
      expect(await noteFor(half), isNull, reason: half);
    }
    // Plain http to a public host is refused: no promise to connect there.
    expect(await noteFor('http://music.example.org'), isNull);
  });

  testWidgets('typing again clears the old address error', (tester) async {
    await open(tester);
    await tester.enterText(address, 'http://music.example.org');
    await tester.tap(find.byKey(const Key('server-address-next')));
    await tester.pump();
    expect(find.byKey(const Key('wizard-address-error')), findsOneWidget);
    await tester.enterText(address, 'music.example.org');
    await tester.pump();
    expect(find.byKey(const Key('wizard-address-error')), findsNothing);
    expect(find.byKey(const Key('wizard-scheme-note')), findsOneWidget);
  });

  testWidgets('login step: «Another server» returns to the address', (
    tester,
  ) async {
    // Owner 13.10: «Log out» lands on the login step of the same server, and there
    // was no way from it to another server.
    await open(tester);
    await typeAddress(tester, '192.168.1.10:8088');
    expect(find.byKey(const Key('wizard-login')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('login-password')), 'secret');
    await tester.tap(find.byKey(const Key('wizard-change-server')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wizard-address')), findsOneWidget);
    expect(
      tester.widget<TextField>(address).controller!.text,
      'http://192.168.1.10:8088',
    );
    await typeAddress(tester, 'music.example.org');
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('login-password')))
          .controller!
          .text,
      isEmpty,
    );
    await signIn(tester);
    expect(logins, [Uri.parse('https://music.example.org')]);
  });

  testWidgets('fields like search: height 50, radius 16, border', (
    tester,
  ) async {
    await open(tester);
    final decoration = decorationOf(tester, address);
    expect(decoration.filled, isTrue);
    expect(decoration.fillColor, ApertonoColors.surface);
    final border = decoration.enabledBorder as OutlineInputBorder;
    expect(border.borderRadius, BorderRadius.circular(ApertonoRadii.medium));
    expect(border.borderSide.color, ApertonoColors.border);
    final focused = decoration.focusedBorder as OutlineInputBorder;
    expect(focused.borderSide.color, ApertonoColors.accent);
    expect(tester.getSize(address).height, moreOrLessEquals(50, epsilon: 1));
    expect(tester.getSize(next).height, greaterThanOrEqualTo(52));

    await typeAddress(tester, 'apertono.example');
    for (final key in ['login-username', 'login-password']) {
      final field = find.byKey(Key(key));
      final login = decorationOf(tester, field);
      expect(login.fillColor, ApertonoColors.surface, reason: key);
      expect(
        (login.enabledBorder as OutlineInputBorder).borderRadius,
        BorderRadius.circular(ApertonoRadii.medium),
        reason: key,
      );
      expect(tester.getSize(field).height, moreOrLessEquals(50, epsilon: 1));
    }
  });

  testWidgets('address without scheme — server over https', (tester) async {
    await open(tester);
    await typeAddress(tester, 'apertono.example');
    expect(find.byKey(const Key('wizard-login')), findsOneWidget);
    await signIn(tester);
    expect(logins, [Uri.parse('https://apertono.example')]);
  });

  testWidgets('full address with scheme does not duplicate «https://»', (
    tester,
  ) async {
    await open(tester);
    await tester.enterText(address, 'https://');
    await tester.pump();
    await typeAddress(tester, 'https://apertono.example');
    await signIn(tester);
    expect(logins, [Uri.parse('https://apertono.example')]);
  });

  testWidgets('http only to localhost, as before', (tester) async {
    await open(tester);
    await typeAddress(tester, 'http://apertono.example');
    expect(find.byKey(const Key('wizard-address')), findsOneWidget);
    expect(find.byKey(const Key('wizard-address-error')), findsOneWidget);

    await typeAddress(tester, 'http://localhost:8080');
    await signIn(tester);
    expect(logins, [Uri.parse('http://localhost:8080')]);
  });

  testWidgets('port without scheme also uses https', (tester) async {
    await open(tester);
    await typeAddress(tester, 'apertono.example:8443');
    await signIn(tester);
    expect(logins, [Uri.parse('https://apertono.example:8443')]);
  });

  group('снимок-эталон', () {
    setUpAll(() async {
      await loadAppFonts();
      compareOnMacOnly();
    });

    for (final MapEntry(key: name, value: size) in phones.entries) {
      testWidgets('login screen at $name dp', (tester) async {
        usePhone(tester, size);
        // Owner phone is in Russian.
        final dispatcher = tester.binding.platformDispatcher;
        addTearDown(dispatcher.clearLocaleTestValue);
        dispatcher.localeTestValue = const Locale('ru');
        await tester.pumpWidget(LoginWizard(onLogin: (_, _, _) async {}));
        await tester.pumpAndSettle();
        await expectLater(
          find.byType(LoginWizard),
          matchesGoldenFile('goldens/login_$name.png'),
        );
      });
    }
  });
}
