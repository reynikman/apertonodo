import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_stream/app.dart';
import 'package:music_stream/auth/session_store.dart';
import 'package:music_stream/main.dart';
import 'package:music_stream/offline/cover_store.dart';
import 'package:music_stream/offline/track_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

// FT-534. App root changed from `MusicApp` to `CoverFiles(MusicApp)`
// when account database was opened. Flutter recreated entire app:
// active search with entered query reset, and phone test could not
// find test tone (MR !258, job 17257). Wrapper must wrap from first frame —
// even before database exists.
void main() {
  testWidgets('covers wrapper at root from first frame', (tester) async {
    String? stored;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            if (call.method == 'write') {
              stored = (call.arguments as Map)['value'] as String;
            }
            if (call.method == 'read') return stored;
            return null;
          },
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.bbflight.background_downloader'),
          (call) async => null,
        );
    const server = 'https://music.example';
    SharedPreferences.setMockInitialValues({
      'active-server': server,
      'active-user': 'user-1',
      'music-space-chosen': true,
    });
    final sessions = SessionStore();
    await sessions.saveToken(List.filled(32, '7').join());
    // Database never opens: screen must exist in wrapper with or without it.
    Future<TrackStore> never(String _) => Completer<TrackStore>().future;
    await tester.pumpWidget(
      buildProductionApp(
        sessions: sessions,
        client: MockClient((_) async => http.Response('{}', 404)),
        initialServer: Uri.parse(server),
        openStore: never,
      ),
    );
    await tester.pump();
    expect(find.byType(MusicApp), findsOneWidget, reason: 'login not saved');
    expect(
      find.ancestor(
        of: find.byType(MusicApp),
        matching: find.byType(CoverFiles),
      ),
      findsOneWidget,
      reason:
          'without cover wrapper from frame 1 appearance of covers recreates app',
    );
    // App timers (network, auth) are waited on here, not after test.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(minutes: 1));
  });
}
