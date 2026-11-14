import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/app.dart';

import 'fake_server.dart';

/// Logout and server change — only after "yes" (FT-466).
///
/// FT-846 (owner 13.10): "Switch user" did exactly what "Log out" does — back to the name and
/// password of the same server — so the menu keeps only two ways to leave.
///
/// Owner finding 01.10: tapped "Switch user" — and login screen immediately,
/// requiring password re-entry. Cancel must touch neither login nor music.
void main() {
  final dialog = find.byType(AlertDialog);

  testWidgets('the account menu has no duplicate of "Log out"', (tester) async {
    final server = FakeServer();
    await tester.pumpWidget(
      MusicApp(
        key: UniqueKey(),
        catalogSource: server.catalog(),
        server: server.api(),
        onAccountAction: (_) async {},
      ),
    );
    await tester.tap(find.byKey(const Key('tab-library')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('account-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('logout')), findsOneWidget);
    expect(find.byKey(const Key('switch-server')), findsOneWidget);
    expect(find.byKey(const Key('switch-user')), findsNothing);
  });

  for (final (action, item, en) in [
    ('logout', 'Выйти', 'Log out'),
    ('switch-server', 'Сменить сервер', 'Switch server'),
  ]) {
    Future<List<String>> open(WidgetTester tester, Locale locale) async {
      final dispatcher = tester.binding.platformDispatcher;
      dispatcher.localeTestValue = locale;
      dispatcher.localesTestValue = [locale];
      addTearDown(dispatcher.clearLocaleTestValue);
      addTearDown(() => dispatcher.localesTestValue = const [Locale('ru')]);
      final calls = <String>[];
      final server = FakeServer();
      await tester.pumpWidget(
        MusicApp(
          key: UniqueKey(),
          catalogSource: server.catalog(),
          server: server.api(),
          onAccountAction: (action) async => calls.add(action),
        ),
      );
      await tester.tap(find.byKey(const Key('tab-library')));
      await tester.pumpAndSettle();
      return calls;
    }

    Future<void> choose(WidgetTester tester, String title) async {
      await tester.tap(find.byKey(const Key('account-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(title).last);
      await tester.pumpAndSettle();
    }

    testWidgets('$action asks first, cancel keeps the session', (tester) async {
      final calls = await open(tester, const Locale('ru'));

      await choose(tester, item);
      expect(dialog, findsOneWidget);
      expect(calls, isEmpty, reason: 'called without asking');
      expect(
        find.descendant(of: dialog, matching: find.textContaining('пароль')),
        findsWidgets,
        reason: 'user must know that password will be needed again',
      );

      // Button requiring password afterwards — error color, not accent.
      final confirm = tester.widget<FilledButton>(
        find.byKey(const Key('leave-confirm')),
      );
      final scheme = Theme.of(tester.element(dialog)).colorScheme;
      expect(confirm.style?.backgroundColor?.resolve({}), scheme.error);
      expect(confirm.style?.foregroundColor?.resolve({}), scheme.onError);

      await tester.tap(find.byKey(const Key('leave-cancel')));
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      expect(calls, isEmpty, reason: 'cancel still logged out');
      expect(find.byKey(const Key('account-button')), findsOneWidget);

      await choose(tester, item);
      await tester.tap(find.byKey(const Key('leave-confirm')));
      await tester.pumpAndSettle();
      expect(calls, [action]);
    });

    testWidgets('$action asks in English too', (tester) async {
      final calls = await open(tester, const Locale('en'));

      await choose(tester, en);
      expect(dialog, findsOneWidget);
      expect(
        find.descendant(of: dialog, matching: find.textContaining('password')),
        findsWidgets,
      );
      await tester.tap(find.byKey(const Key('leave-confirm')));
      await tester.pumpAndSettle();
      expect(calls, [action]);
    });
  }
}
