import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_stream/auth/session_store.dart';
import 'package:music_stream/crash_notice.dart';
import 'package:music_stream/main.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            if (call.method == 'write') return true;
            if (call.method == 'delete') return true;
            if (call.method == 'read') return 'token-123';
            return null;
          },
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.bbflight.background_downloader'),
          (call) async => null,
        );
  });

  testWidgets('backgrounded on login is not crash: running flag cleared', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final crash = CrashNotice(prefs);
    await crash.start();
    expect(prefs.getBool(CrashNotice.runningKey), isTrue);

    final sessions = SessionStore();
    final client = MockClient((_) async => http.Response('{}', 200));
    await tester.pumpWidget(
      buildProductionApp(sessions: sessions, crash: crash, client: client),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('wizard-address')), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();

    // Minimized app clears flag so next launch does not treat it as crash
    expect(prefs.getBool(CrashNotice.runningKey), isNull);

    // From "minimized" to "open" — through intermediate states like on device.
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();
    expect(prefs.getBool(CrashNotice.runningKey), isTrue);
  });

  testWidgets(
    'closing on login screen does not prompt for error report on next launch',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final crash = CrashNotice(prefs);
      await crash.start();

      final sessions = SessionStore();
      final client = MockClient((_) async => http.Response('{}', 200));
      await tester.pumpWidget(
        buildProductionApp(sessions: sessions, crash: crash, client: client),
      );
      await tester.pumpAndSettle();

      // Normal exit / backgrounding
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();

      // Subsequent launch
      final nextCrash = CrashNotice(prefs);
      await nextCrash.start();
      expect(nextCrash.shouldAsk, isFalse);
    },
  );
}
