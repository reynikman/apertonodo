import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:music_stream/app.dart';
import 'package:music_stream/auth/session_store.dart';
import 'package:music_stream/main.dart';
import 'package:music_stream/screens/login_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';
import 'fakes.dart';

void main() {
  testWidgets('first frame chooses the wizard or home without requests', (
    tester,
  ) async {
    String? stored;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            if (call.method == 'write') {
              stored = (call.arguments as Map)['value'] as String;
            }
            if (call.method == 'delete') stored = null;
            if (call.method == 'read') return stored;
            return null;
          },
        );
    SharedPreferences.setMockInitialValues({});
    final sessions = SessionStore();
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      throw StateError('No request is expected before the first frame');
    });

    await tester.pumpWidget(
      buildProductionApp(sessions: sessions, client: client),
    );
    expect(find.byKey(const Key('wizard-address')), findsOneWidget);
    expect(requests, 0);

    await tester.pumpWidget(const SizedBox.shrink());
    final random = Random.secure();
    await sessions.saveToken(
      List.generate(32, (_) => random.nextInt(10)).join(),
    );
    requests = 0;
    await tester.pumpWidget(
      buildProductionApp(sessions: sessions, client: client),
    );
    expect(find.byKey(const Key('tab-search')), findsOneWidget);
    expect(find.byKey(const Key('search-field')), findsNothing);
    expect(requests, 0);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the wizard shows its fields on a Russian phone', (tester) async {
    // Release builds draw a failed build as a grey box: on a Russian phone the
    // wizard's TextField found no Material strings for 'ru' and the screen was empty.
    final dispatcher = tester.binding.platformDispatcher;
    addTearDown(dispatcher.clearLocaleTestValue);
    addTearDown(dispatcher.clearLocalesTestValue);
    dispatcher.localeTestValue = const Locale('ru');
    dispatcher.localesTestValue = const [Locale('ru')];
    await tester.pumpWidget(LoginWizard(onLogin: (_, _, _) async {}));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('server-address-field')), findsOneWidget);
    expect(find.text('Адрес сервера'), findsOneWidget);
  });

  // Account and downloads — in "My Music" header. Placed above app they
  // overlapped status bar, directly on device clock.
  testWidgets('account controls live in My music with both languages', (
    tester,
  ) async {
    final dispatcher = tester.binding.platformDispatcher;
    addTearDown(dispatcher.clearLocaleTestValue);
    addTearDown(() => dispatcher.localesTestValue = const [Locale('ru')]);
    Future<void> openLibrary() async {
      final server = FakeServer();
      await tester.pumpWidget(
        MusicApp(
          key: UniqueKey(),
          catalogSource: server.catalog(),
          server: server.api(),
          onAccountAction: (_) async {},
        ),
      );
      expect(find.byKey(const Key('account-button')), findsNothing);
      await tester.tap(find.byKey(const Key('tab-library')));
      await tester.pumpAndSettle();
    }

    String tooltip(String key) =>
        tester.widget<IconButton>(find.byKey(Key(key))).tooltip!;

    dispatcher.localeTestValue = const Locale('en');
    dispatcher.localesTestValue = const [Locale('en')];
    await openLibrary();
    expect(tooltip('account-button'), 'Account');
    await tester.tap(find.byKey(const Key('account-button')));
    await tester.pumpAndSettle();
    expect(find.text('Log out'), findsOneWidget);
    expect(find.text('Switch server'), findsOneWidget);
    expect(find.text('Switch user'), findsNothing, reason: 'FT-846');

    dispatcher.localeTestValue = const Locale('ru');
    dispatcher.localesTestValue = const [Locale('ru')];
    await openLibrary();
    expect(tooltip('account-button'), 'Аккаунт');
    await tester.tap(find.byKey(const Key('account-button')));
    await tester.pumpAndSettle();
    expect(find.text('Выйти'), findsOneWidget);
    expect(find.text('Сменить сервер'), findsOneWidget);
    expect(find.text('Сменить пользователя'), findsNothing, reason: 'FT-846');
  });

  testWidgets('signed-in player does not show the mini player', (tester) async {
    await tester.pumpWidget(
      MusicApp(catalog: const [sandman], onAccountAction: (_) async {}),
    );
    await tester.enterText(find.byKey(const Key('search-field')), 'sandman');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.tap(find.text('Enter Sandman').first);
    await tester.pump();
    await tester.tap(find.byKey(const Key('mini-player')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('player-screen')), findsOneWidget);
    expect(find.byKey(const Key('mini-player')).hitTestable(), findsNothing);
  });
}
