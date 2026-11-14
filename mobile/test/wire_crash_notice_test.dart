import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/app.dart';
import 'package:music_stream/crash_notice.dart';
import 'package:music_stream/error_reports.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';

/// Wire FT-698: previous launch crashed — prompt once
/// "send report?". Clearing flag on backgrounding —
/// `wire5_review_test.dart` (via app root from login screen).
void main() {
  late Rig rig;
  late SharedPreferences prefs;

  Future<void> launch(WidgetTester tester, {required bool crashed}) async {
    SharedPreferences.setMockInitialValues({
      if (crashed) CrashNotice.runningKey: true,
      CrashNotice.pendingKey: jsonEncode({
        'kind': 'crash.state_error',
        'screen': 'app',
        'frames': [],
      }),
    });
    prefs = await SharedPreferences.getInstance();
    final crash = CrashNotice(prefs);
    await crash.start();
    rig = Rig();
    rig.server.on('POST /v1/reports', (_) => answer(202, {}));
    addTearDown(rig.audio.close);
    await tester.pumpWidget(
      MusicApp(
        catalogSource: rig.server.catalog(),
        playback: rig.playback,
        audio: rig.audio,
        server: rig.server.api(),
        reports: ErrorReports(rig.server.api()),
        crash: crash,
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('after crash: prompt appears, Send Report sends report', (
    tester,
  ) async {
    await launch(tester, crashed: true);

    expect(
      find.text('В прошлый раз приложение закрылось с ошибкой'),
      findsOneWidget,
    );
    await tapAndSettle(tester, find.text('Отправить отчёт'));

    expect(
      rig.server.bodies('POST /v1/reports').single['kind'],
      'crash.state_error',
    );
    expect(find.text('Отчёт отправлен'), findsOneWidget);
    expect(prefs.getString(CrashNotice.pendingKey), isNull);
  });

  testWidgets('Do Not Ask Again sends nothing and remembers choice', (
    tester,
  ) async {
    await launch(tester, crashed: true);

    await tapAndSettle(tester, find.text('Больше не спрашивать'));

    expect(rig.server.calls('POST /v1/reports'), isEmpty);
    expect(prefs.getBool(CrashNotice.neverKey), isTrue);
  });

  testWidgets('no prompt when no crash occurred', (tester) async {
    await launch(tester, crashed: false);

    expect(find.byKey(const Key('crash-sheet')), findsNothing);
  });
}
