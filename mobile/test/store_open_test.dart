import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_stream/app.dart';
import 'package:music_stream/auth/session_store.dart';
import 'package:music_stream/main.dart';
import 'package:music_stream/offline/track_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// FT-535. Cold start with saved credentials builds app twice:
// initially with "unknown" account, then with authenticated account next frame.
// Both opened same database on device concurrently while first was still opening.
// Concurrent opens locked each other, breaking Play and Downloads on
// release build (03.10, release 78d1b8ad).
void main() {
  sqfliteFfiInit();

  testWidgets('cold start opens the music store one at a time', (tester) async {
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
    // Background downloader is native component; platform channel has no handler here.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.bbflight.background_downloader'),
          (call) async => null,
        );
    // Network monitor (FT-691) is native component: respond with "Wi-Fi connected".
    for (final name in const [
      'dev.fluttercommunity.plus/connectivity',
      'dev.fluttercommunity.plus/connectivity_status',
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            MethodChannel(name),
            (call) async => call.method == 'check' ? ['wifi'] : null,
          );
    }
    const server = 'https://music.example';
    SharedPreferences.setMockInitialValues({
      'active-server': server,
      'active-user': 'user-1',
      'music-space-chosen': true,
    });
    final sessions = SessionStore();
    final random = Random.secure();
    await sessions.saveToken(
      List.generate(32, (_) => random.nextInt(10)).join(),
    );
    final client = MockClient((_) async => http.Response('{}', 404));

    final root = await tester.runAsync(
      () => Directory.systemTemp.createTemp('store_open_test'),
    );
    addTearDown(() => root!.delete(recursive: true));

    final opened = <String>[];
    final finished = <String>[];
    var opening = 0;
    var most = 0;
    // Block initial open until account load finishes: takes longer than
    // a frame on device, and second open started concurrently.
    final firstMayFinish = Completer<void>();
    Future<TrackStore> open(String namespace) async {
      opened.add(namespace);
      opening++;
      most = max(most, opening);
      try {
        if (opened.length == 1) await firstMayFinish.future;
        final store = await TrackStore.open(
          root: root!,
          namespace: namespace,
          databaseFactory: databaseFactoryFfi,
          now: DateTime.now,
          freeBytes: () async => null,
        );
        finished.add(namespace);
        return store;
      } finally {
        opening--;
      }
    }

    // Screen player holds first-frame database: screen must update alongside
    // it, otherwise Play encounters database_closed.
    State? firstScreen;
    await tester.runAsync(() async {
      await tester.pumpWidget(
        buildProductionApp(
          sessions: sessions,
          client: client,
          initialServer: Uri.parse(server),
          openStore: open,
        ),
      );
      firstScreen = tester.state(find.byType(MusicApp));
      // Under full suite load account takes longer to load: up to 2 s.
      for (var i = 0; i < 100 && opened.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
      firstMayFinish.complete();
      for (
        var i = 0;
        i < 500 && (opened.length < 2 || finished.length < opened.length);
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });

    expect(opened, hasLength(2), reason: 'account loaded next frame');
    expect(most, 1, reason: 'second open started over first');
    expect(finished, opened, reason: 'database opening did not finish');
    expect(
      tester.state(find.byType(MusicApp)),
      isNot(same(firstScreen)),
      reason: 'screen stayed with player on closed database',
    );

    await tester.runAsync(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
  });
}
