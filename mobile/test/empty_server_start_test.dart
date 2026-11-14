import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:music_stream/auth/session_store.dart';
import 'package:music_stream/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

// FT-835. A fresh install has no saved server, so the app starts with the
// address baked into the build. The public build bakes in an empty one
// (config/prod.json keeps no author address), and the first frame threw
// 'Cannot use origin without a scheme': a release build drew a blank screen.
// Other tests start with the dev default address and never saw it.
void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => null,
        );
    SharedPreferences.setMockInitialValues({});
  });

  for (final flavor in ['prod', 'staging', 'dev']) {
    testWidgets('fresh install of the $flavor build opens the wizard', (
      tester,
    ) async {
      final config =
          jsonDecode(File('config/$flavor.json').readAsStringSync())
              as Map<String, dynamic>;
      final baked = Uri.parse(config['MUSIC_API_BASE_URL'] as String);
      final client = MockClient((_) async {
        throw StateError('No request is expected before the first frame');
      });

      await tester.pumpWidget(
        buildProductionApp(
          sessions: SessionStore(),
          client: client,
          initialServer: baked,
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('wizard-address')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  test('the public build bakes in no server address', () {
    final config =
        jsonDecode(File('config/prod.json').readAsStringSync())
            as Map<String, dynamic>;
    // The case above is only meaningful while this holds.
    expect(config['MUSIC_API_BASE_URL'], '');
  });
}
