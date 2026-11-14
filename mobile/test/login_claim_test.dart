import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_stream/auth/login.dart';
import 'package:music_stream/auth/login_errors.dart';
import 'package:music_stream/auth/session_store.dart';
import 'package:music_stream/auth/token_provider.dart';
import 'package:music_stream/screens/account_bar.dart';
import 'package:music_stream/screens/change_password.dart';
import 'package:music_stream/screens/login_screen.dart';
import 'package:music_stream/server_api.dart';

/// FT-856, owner 14.10: "I create the user and let them in; the password they
/// make up themselves, in the app. I must not touch it."
///
/// Not proven here: the server side (server/tests/test_invites.py) and the phone.
final _server = Uri.parse('https://music.example.org');

class _MemorySessionStore extends SessionStore {
  @override
  Future<void> saveToken(String token) async {}

  @override
  Future<String?> readToken() async => null;

  @override
  Future<void> clear() async {}
}

Future<void> _openLoginStep(WidgetTester tester, LoginWizard wizard) async {
  await tester.pumpWidget(wizard);
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('wizard-login')), findsOneWidget);
}

void main() {
  test(
    'claim goes to /v1/auth/claim with the code and the new password',
    () async {
      late http.Request sent;
      final client = MockClient((request) async {
        sent = request;
        return http.Response(
          jsonEncode({'token': 't' * 43, 'user_id': 'u1'}),
          200,
        );
      });
      final reply = await claimAt(
        _server,
        'anna',
        'ABCD-EFGH',
        'my own pass',
        client,
      );
      expect(reply.token, 't' * 43);
      expect(sent.url.path, '/v1/auth/claim');
      final body = jsonDecode(sent.body) as Map<String, dynamic>;
      expect(body['username'], 'anna');
      expect(body['code'], 'ABCD-EFGH');
      expect(body['password'], 'my own pass');
      expect(body['device_name'], isA<String>());
    },
  );

  test('a refused code and a weak password get their own words', () async {
    Future<LoginError?> reason(int status, {bool claim = true}) async {
      final client = MockClient((_) async => http.Response('{}', status));
      try {
        claim
            ? await claimAt(_server, 'anna', 'X', 'my own pass', client)
            : await loginAt(_server, 'anna', 'my own pass', client);
      } on LoginFailed catch (failure) {
        return failure.reason;
      }
      return null;
    }

    expect(await reason(401), LoginError.badCode);
    expect(await reason(422), LoginError.weakPassword);
    // A plain sign-in keeps its old meaning.
    expect(await reason(401, claim: false), LoginError.unauthorized);
    expect(await reason(422, claim: false), LoginError.network);
  });

  testWidgets('code link opens code and repeat fields and sends them', (
    tester,
  ) async {
    final calls = <List<String>>[];
    await _openLoginStep(
      tester,
      LoginWizard(
        initialServer: _server,
        onLogin: (_, _, _) async {},
        onClaim: (server, user, code, password) async =>
            calls.add([server.origin, user, code, password]),
      ),
    );
    expect(find.byKey(const Key('login-code')), findsNothing);
    await tester.tap(find.byKey(const Key('wizard-code-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('login-code')), findsOneWidget);
    expect(find.byKey(const Key('login-repeat')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('login-username')), ' anna ');
    await tester.enterText(find.byKey(const Key('login-code')), 'abcd-efgh');
    await tester.enterText(
      find.byKey(const Key('login-password')),
      'my own pass',
    );
    await tester.enterText(
      find.byKey(const Key('login-repeat')),
      'my own pass',
    );
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pumpAndSettle();
    expect(calls, [
      [_server.origin, 'anna', 'abcd-efgh', 'my own pass'],
    ]);
  });

  testWidgets('different or short passwords are stopped before the server', (
    tester,
  ) async {
    var calls = 0;
    await _openLoginStep(
      tester,
      LoginWizard(
        initialServer: _server,
        onLogin: (_, _, _) async {},
        onClaim: (_, _, _, _) async => calls++,
      ),
    );
    await tester.tap(find.byKey(const Key('wizard-code-toggle')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('login-password')),
      'my own pass',
    );
    await tester.enterText(
      find.byKey(const Key('login-repeat')),
      'my own pasz',
    );
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wizard-error')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('login-password')), 'short');
    await tester.enterText(find.byKey(const Key('login-repeat')), 'short');
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wizard-error')), findsOneWidget);
    expect(calls, 0);
  });

  testWidgets('without a claim handler there is no code link', (tester) async {
    await _openLoginStep(
      tester,
      LoginWizard(initialServer: _server, onLogin: (_, _, _) async {}),
    );
    expect(find.byKey(const Key('wizard-code-toggle')), findsNothing);
  });

  test('change password reads the four server answers', () async {
    Future<PasswordChange> answer(int status) async {
      final tokens = TokenProvider(_MemorySessionStore(), server: _server);
      await tokens.signIn('t' * 43);
      late http.Request sent;
      final api = ServerApi(
        _server.origin,
        tokens: tokens,
        client: MockClient((request) async {
          sent = request;
          return http.Response('{}', status);
        }),
      );
      final result = await api.changePassword('old pass 1', 'new pass 1');
      expect(sent.url.path, '/v1/auth/password');
      expect(sent.headers['authorization'], 'Bearer ${'t' * 43}');
      expect(jsonDecode(sent.body), {
        'old_password': 'old pass 1',
        'new_password': 'new pass 1',
      });
      return result;
    }

    expect(await answer(200), PasswordChange.changed);
    expect(await answer(403), PasswordChange.wrongOld);
    expect(await answer(422), PasswordChange.weak);
    expect(await answer(503), PasswordChange.failed);
  });

  testWidgets(
    'change password dialog: wrong old password stays open, success closes',
    (tester) async {
      var answer = PasswordChange.wrongOld;
      bool? closed;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => closed = await showDialog<bool>(
                context: context,
                builder: (_) =>
                    ChangePasswordDialog(change: (_, _) async => answer),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('password-old')),
        'old pass 1',
      );
      await tester.enterText(
        find.byKey(const Key('password-new')),
        'new pass 1',
      );
      await tester.enterText(
        find.byKey(const Key('password-repeat')),
        'new pass 1',
      );
      await tester.tap(find.byKey(const Key('password-save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('password-error')), findsOneWidget);
      expect(closed, isNull);

      answer = PasswordChange.changed;
      await tester.tap(find.byKey(const Key('password-save')));
      await tester.pumpAndSettle();
      expect(closed, isTrue);
    },
  );

  testWidgets('account menu offers "change password" only when asked', (
    tester,
  ) async {
    final actions = <String>[];
    Future<void> open(bool changePassword) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AccountBar(
              changePassword: changePassword,
              onAction: actions.add,
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('account-button')));
      await tester.pumpAndSettle();
    }

    await open(false);
    expect(find.byKey(const Key('change-password')), findsNothing);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();

    await open(true);
    await tester.tap(find.byKey(const Key('change-password')));
    await tester.pumpAndSettle();
    expect(actions, ['change-password']);
  });
}
