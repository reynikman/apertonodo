import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_stream/auth/foreign_login.dart';
import 'package:music_stream/auth/foreign_session.dart';
import 'package:music_stream/auth/login_errors.dart';
import 'package:music_stream/foreign/foreign_library.dart';
import 'package:music_stream/foreign/foreign_shell.dart';
import 'package:music_stream/l10n/app_localizations.dart';
import 'package:music_stream/player.dart';
import 'package:music_stream/subsonic_client.dart';
import 'package:music_stream/main.dart';
import 'package:music_stream/screens/login_screen.dart';
import 'package:music_stream/server_kind.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

/// FT-779: foreign session stored only in secure storage, Jellyfin — without
/// password; relaunch opens shell without network; logout wipes session.
void main() {
  late Map<String, String> secure;

  setUp(() {
    secure = {};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args = (call.arguments as Map?) ?? {};
            switch (call.method) {
              case 'write':
                secure[args['key'] as String] = args['value'] as String;
              case 'delete':
                secure.remove(args['key']);
              case 'read':
                return secure[args['key']];
            }
            return null;
          },
        );
    SharedPreferences.setMockInitialValues({});
  });

  final subsonic = ForeignLogin(
    kind: ServerKind.subsonic,
    base: Uri.parse('http://192.168.1.10:4533'),
    username: 'anna',
    password: 'hunter2',
  );
  final jellyfin = ForeignLogin(
    kind: ServerKind.jellyfin,
    base: Uri.parse('http://192.168.1.10:8096'),
    username: 'anna',
    password: 'hunter2',
  );

  http.Response json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );

  MockClient server({bool wrongPassword = false}) => MockClient((
    request,
  ) async {
    if (request.url.path.endsWith('/ping.view')) {
      return json({
        'subsonic-response': wrongPassword
            ? {
                'status': 'failed',
                'version': '1.16.1',
                'error': {'code': 40, 'message': 'Wrong username or password'},
              }
            : {'status': 'ok', 'version': '1.16.1'},
      });
    }
    if (request.url.path.endsWith('/Users/AuthenticateByName')) {
      return wrongPassword
          ? json({}, 401)
          : json({
              'AccessToken': 'tok-123',
              'ServerId': 'srv-1',
              'User': {'Id': 'user-9'},
            });
    }
    return json({}, 404);
  });

  test(
    'Subsonic: password in secure storage, not in SharedPreferences',
    () async {
      final account = await signInForeign(subsonic, server());
      await ForeignSession().save(account);

      expect(secure.keys, ['foreign_login']);
      expect(jsonDecode(secure['foreign_login']!)['password'], 'hunter2');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), isEmpty);

      final back = await ForeignSession().read();
      expect(back!.kind, ServerKind.subsonic);
      expect(back.base, subsonic.base);
      expect(back.username, 'anna');
      expect(back.password, 'hunter2');
    },
  );

  test('Jellyfin: only token and userId, password nowhere', () async {
    final account = await signInForeign(jellyfin, server());
    await ForeignSession().save(account);

    expect(secure['foreign_login'], isNot(contains('hunter2')));
    final stored = jsonDecode(secure['foreign_login']!) as Map;
    expect(stored.containsKey('password'), isFalse);
    expect(stored['token'], 'tok-123');
    expect(stored['userId'], 'user-9');
    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);

    final back = await ForeignSession().read();
    expect(back!.kind, ServerKind.jellyfin);
    expect(back.password, isNull);
    expect(back.token, 'tok-123');
    expect(back.userId, 'user-9');
  });

  test('wrong password: LoginFailed, nothing saved', () async {
    for (final login in [subsonic, jellyfin]) {
      await expectLater(
        signInForeign(login, server(wrongPassword: true)),
        throwsA(
          isA<LoginFailed>().having(
            (e) => e.reason,
            'reason',
            LoginError.unauthorized,
          ),
        ),
      );
    }
    expect(secure, isEmpty);
  });

  test(
    'clear removes login; corrupted record is treated as no login entry',
    () async {
      final session = ForeignSession();
      await session.save(await signInForeign(subsonic, server()));
      await session.clear();
      expect(await session.read(), isNull);

      secure['foreign_login'] =
          '{"kind":"jellyfin","base":"http://x","username":"a"}';
      expect(await session.read(), isNull, reason: 'no token - no login');
      secure['foreign_login'] = 'not json';
      expect(await session.read(), isNull);
    },
  );

  testWidgets(
    'restart: saved login is a shell without requests; logout clears out',
    (tester) async {
      final account = await signInForeign(subsonic, server());
      final session = ForeignSession();
      await session.save(account);
      final restored = await ForeignSession().read();

      final client = MockClient((_) async {
        return json({
          'subsonic-response': {'status': 'ok', 'version': '1.16.1'},
        });
      });
      await tester.pumpWidget(
        buildProductionApp(
          audio: FakeAudio(),
          client: client,
          foreignSession: session,
          foreignAccount: restored,
        ),
      );
      expect(find.byType(ForeignShell), findsOneWidget);
      expect(find.byType(LoginWizard), findsNothing);
      // Shell on first frame: login loaded before runApp, network not waited on.

      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('foreign-leave')));
      await tester.pumpAndSettle();
      expect(find.byType(LoginWizard), findsOneWidget);
      expect(secure, isEmpty, reason: 'logout cleared login');
      expect(await ForeignSession().read(), isNull);
    },
  );

  testWidgets('foreign server login rejection (code 40) goes back to login', (
    tester,
  ) async {
    var left = 0;
    final library = SubsonicLibrary(
      SubsonicClient(
        base: Uri.parse('http://music.test:4533'),
        auth: const SubsonicAuth.password('anna', 'old'),
        client: MockClient(
          (_) async => json({
            'subsonic-response': {
              'status': 'failed',
              'version': '1.16.1',
              'error': {'code': 40, 'message': 'Wrong username or password'},
            },
          }),
        ),
      ),
    );
    final player = Player(audio: FakeAudio());
    addTearDown(player.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ForeignShell(
          library: library,
          player: player,
          onLeave: () async => left++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(left, 1);
  });
}
