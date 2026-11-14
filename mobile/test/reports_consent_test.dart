import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/app.dart';
import 'package:music_stream/error_reports.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';

/// "Send reports automatically" requires explicit user consent (P-A46).
///
/// Owner finding 01.10: switch toggled silently as if nothing changed.
/// Enabling means agreeing that device automatically sends crash reports;
/// user must read what data is transmitted. Disabling requires no confirmation:
/// opting out carries no risk.
void main() {
  final dialog = find.byType(AlertDialog);
  const preference = 'automatic-error-reports';

  Future<ErrorReports> tapSwitch(
    WidgetTester tester, {
    bool on = false,
    Locale locale = const Locale('ru'),
  }) async {
    SharedPreferences.setMockInitialValues({preference: on});
    final dispatcher = tester.binding.platformDispatcher;
    dispatcher.localeTestValue = locale;
    dispatcher.localesTestValue = [locale];
    addTearDown(dispatcher.clearLocaleTestValue);
    addTearDown(() => dispatcher.localesTestValue = const [Locale('ru')]);
    final server = FakeServer();
    final reports = ErrorReports(server.api());
    await reports.load();
    expect(reports.automatic, on);
    await tester.pumpWidget(
      MusicApp(
        catalogSource: server.catalog(),
        server: server.api(),
        reports: reports,
        onAccountAction: (_) async {},
      ),
    );
    await tester.tap(find.byKey(const Key('tab-library')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('account-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('auto-reports')));
    await tester.pumpAndSettle();
    return reports;
  }

  Future<bool?> saved() async =>
      (await SharedPreferences.getInstance()).getBool(preference);

  testWidgets('enable: confirmation and what is sent first', (tester) async {
    final reports = await tapSwitch(tester);

    expect(dialog, findsOneWidget);
    expect(reports.automatic, isFalse, reason: 'enabled before consent');
    expect(
      find.descendant(
        of: dialog,
        matching: find.text('Присылать отчёты автоматически?'),
      ),
      findsOneWidget,
    );
    // What is sent and what is excluded — human language, not "telemetry".
    for (final words in ['сбо', 'экран', 'названий песен', 'поиск']) {
      expect(
        find.descendant(of: dialog, matching: find.textContaining(words)),
        findsWidgets,
        reason: words,
      );
    }
    // Consent is safe action: button uses theme accent, not error
    // color like "Log out".
    final confirm = tester.widget<FilledButton>(
      find.byKey(const Key('reports-confirm')),
    );
    final scheme = Theme.of(tester.element(dialog)).colorScheme;
    expect(confirm.style?.backgroundColor?.resolve({}), isNot(scheme.error));

    await tester.tap(find.byKey(const Key('reports-confirm')));
    await tester.pumpAndSettle();
    expect(dialog, findsNothing);
    expect(reports.automatic, isTrue);
    expect(await saved(), isTrue);
  });

  testWidgets('cancel - reports remain disabled', (tester) async {
    final reports = await tapSwitch(tester);

    await tester.tap(find.byKey(const Key('reports-cancel')));
    await tester.pumpAndSettle();
    expect(dialog, findsNothing);
    expect(reports.automatic, isFalse);
    expect(await saved(), isFalse);
  });

  testWidgets('disable - no confirmation', (tester) async {
    final reports = await tapSwitch(tester, on: true);

    expect(dialog, findsNothing);
    expect(reports.automatic, isFalse);
    expect(await saved(), isFalse);
  });

  testWidgets('confirms in English too', (tester) async {
    final reports = await tapSwitch(tester, locale: const Locale('en'));

    expect(
      find.descendant(
        of: dialog,
        matching: find.text('Send reports automatically?'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.textContaining('song')),
      findsWidgets,
    );
    await tester.tap(find.byKey(const Key('reports-confirm')));
    await tester.pumpAndSettle();
    expect(reports.automatic, isTrue);
  });
}
