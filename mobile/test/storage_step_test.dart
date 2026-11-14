import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_stream/auth/session_store.dart';
import 'package:music_stream/device_info.dart';
import 'package:music_stream/main.dart';
import 'package:music_stream/screens/storage_step.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// "Storage for music" onboarding step after initial login (FT-529, P-A60, rule 7).
///
/// User selects storage quota allocated for cached playback: 10, 3
/// or 0 GB. Slider ranges from 0 to "free space minus 1 GB", capped at 50,
/// 1 GB step, default 10. Free space queried via Android; on error —
/// capped at 10 to avoid promising unavailable storage.
const gib = 1024 * 1024 * 1024;
const device = MethodChannel('apertono/device');

Slider slider(WidgetTester tester) =>
    tester.widget<Slider>(find.byKey(const Key('storage-slider')));

Future<void> showStep(
  WidgetTester tester,
  int? free, {
  Future<void> Function(int bytes)? onDone,
}) async {
  await tester.pumpWidget(
    StorageStep(freeBytes: free, onDone: onDone ?? (_) async {}),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('slider', () {
    testWidgets('plenty of space - up to 50 GB, set at 10', (tester) async {
      await showStep(tester, 200 * gib);
      expect(slider(tester).min, 0);
      expect(slider(tester).max, 50);
      expect(slider(tester).value, 10);
      expect(slider(tester).divisions, 50, reason: '1 GB step');
      expect(find.byKey(const Key('storage-value')), findsOneWidget);
      final value = tester.widget<Text>(find.byKey(const Key('storage-value')));
      expect(value.data, contains('10'));
    });

    testWidgets('21 GB free - max 20: one GB left for system', (tester) async {
      await showStep(tester, 21 * gib + 512 * 1024 * 1024);
      expect(slider(tester).max, 20);
      expect(slider(tester).value, 10);
    });

    testWidgets('4.5 GB free - max 3, set at 3', (tester) async {
      await showStep(tester, 4 * gib + gib ~/ 2);
      expect(slider(tester).max, 3);
      expect(slider(tester).value, 3);
    });

    testWidgets('<1 GB free - no reserve, clearly stated', (tester) async {
      var saved = -1;
      await showStep(tester, gib ~/ 2, onDone: (bytes) async => saved = bytes);
      expect(find.byKey(const Key('storage-slider')), findsNothing);
      expect(find.byKey(const Key('storage-no-room')), findsOneWidget);
      await tester.tap(find.byKey(const Key('storage-done')));
      await tester.pumpAndSettle();
      expect(saved, 0);
    });

    testWidgets('Android gave no free space - cap at 10 GB', (tester) async {
      await showStep(tester, null);
      expect(slider(tester).max, 10);
      expect(slider(tester).value, 10);
    });

    testWidgets('selection stored in whole gigabytes', (tester) async {
      var saved = -1;
      await showStep(tester, 200 * gib, onDone: (bytes) async => saved = bytes);
      slider(tester).onChanged!(3.4);
      await tester.pump();
      expect(slider(tester).value, 3);
      await tester.tap(find.byKey(const Key('storage-done')));
      await tester.pumpAndSettle();
      expect(saved, 3 * gib);
    });

    testWidgets('zero allowed: listened not kept', (tester) async {
      var saved = -1;
      await showStep(tester, 200 * gib, onDone: (bytes) async => saved = bytes);
      slider(tester).onChanged!(0);
      await tester.pump();
      await tester.tap(find.byKey(const Key('storage-done')));
      await tester.pumpAndSettle();
      expect(saved, 0);
    });

    testWidgets('localized on Russian phone', (tester) async {
      final dispatcher = tester.binding.platformDispatcher;
      addTearDown(dispatcher.clearLocaleTestValue);
      addTearDown(dispatcher.clearLocalesTestValue);
      dispatcher.localeTestValue = const Locale('ru');
      dispatcher.localesTestValue = const [Locale('ru')];
      await showStep(tester, 200 * gib);
      expect(tester.takeException(), isNull);
      expect(find.text('Место для музыки'), findsOneWidget);
      final value = tester.widget<Text>(find.byKey(const Key('storage-value')));
      expect(value.data, '10 ГБ');
    });
  });

  group('Android free space', () {
    tearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(device, null),
    );

    void answer(Object? Function(MethodCall call) handler) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(device, (call) async => handler(call));
    }

    test('bridge response is bytes', () async {
      answer((call) => call.method == 'freeBytes' ? 7 * gib : null);
      expect(await DeviceInfo.freeBytes(), 7 * gib);
    });

    test('bridge crashes or silent - unknown', () async {
      expect(await DeviceInfo.freeBytes(), isNull, reason: 'no bridge');
      answer((call) => throw PlatformException(code: 'boom'));
      expect(await DeviceInfo.freeBytes(), isNull);
      answer((call) => null);
      expect(await DeviceInfo.freeBytes(), isNull);
    });

    test('bridge queries space in app folder', () {
      final code = File(
        'android/app/src/main/kotlin/app/apertono/player/MainActivity.kt',
      ).readAsStringSync();
      expect(code, contains('"freeBytes"'));
      expect(code, contains('StatFs'));
      expect(code, contains('filesDir'));
    });
  });

  group('after first login', () {
    String? stored;
    late SessionStore sessions;
    late http.Client client;

    setUp(() {
      stored = null;
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
      sessions = SessionStore();
      final random = Random.secure();
      final token = List.generate(32, (_) => random.nextInt(10)).join();
      client = MockClient((request) async {
        if (request.url.path == '/v1/auth/login') {
          return http.Response(
            jsonEncode({'token': token, 'user_id': 'u1'}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        // Since FT-776 login wizard probes server type at URL first.
        if (request.url.path == '/v1/health') {
          return http.Response(
            '{"status":"ok"}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('{}', 503);
      });
    });

    Future<void> signIn(WidgetTester tester) async {
      await tester.enterText(
        find.byKey(const Key('server-address-field')),
        'music.example',
      );
      await tester.tap(find.byKey(const Key('server-address-next')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('login-username')), 'anna');
      await tester.enterText(find.byKey(const Key('login-password')), 'secret');
      await tester.tap(find.byKey(const Key('login-submit')));
      await tester.pumpAndSettle();
    }

    testWidgets('login -> storage -> app; will not ask again', (tester) async {
      SharedPreferences.setMockInitialValues({});
      var saved = -1;
      await tester.pumpWidget(
        buildProductionApp(
          sessions: sessions,
          client: client,
          freeBytes: () async => 21 * gib,
          saveReserveLimit: (bytes) async => saved = bytes,
        ),
      );
      await signIn(tester);

      expect(find.byKey(const Key('storage-step')), findsOneWidget);
      expect(find.byKey(const Key('tab-search')), findsNothing);
      expect(slider(tester).max, 20);
      slider(tester).onChanged!(3);
      await tester.pump();
      await tester.tap(find.byKey(const Key('storage-done')));
      await tester.pumpAndSettle();

      expect(saved, 3 * gib);
      expect(find.byKey(const Key('tab-search')), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('music-space-chosen'), isTrue);

      // Restart with saved login: opens app directly, skipping wizard step.
      await tester.pumpWidget(const SizedBox.shrink());
      saved = -1;
      await tester.pumpWidget(
        buildProductionApp(
          sessions: sessions,
          client: client,
          freeBytes: () async => 21 * gib,
          saveReserveLimit: (bytes) async => saved = bytes,
        ),
      );
      expect(find.byKey(const Key('tab-search')), findsOneWidget);
      expect(find.byKey(const Key('storage-step')), findsNothing);
      expect(saved, -1);
      await tester.pump(const Duration(milliseconds: 1));
      // After reading account, app rebuilds screens for its database (FT-535);
      // deferred frame tasks need an additional frame.
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('choice already made on phone - won\'t prompt after login', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({'music-space-chosen': true});
      await tester.pumpWidget(
        buildProductionApp(
          sessions: sessions,
          client: client,
          freeBytes: () async => 21 * gib,
          saveReserveLimit: (_) async => fail('already chosen'),
        ),
      );
      await signIn(tester);
      expect(find.byKey(const Key('storage-step')), findsNothing);
      expect(find.byKey(const Key('tab-search')), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
