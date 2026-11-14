import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/error_reports.dart';
import 'package:music_stream/screens/account_bar.dart';
import 'package:music_stream/screens/catalog_screens.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';

/// Error report — via own server (P3.5, P-A11, P-A36).
///
/// Screen error has "Send report". Toggle "send automatically"
/// is off by default. Report contains only fields accepted by server
/// (`server/tests/test_app_reports.py`): error kind, screen, app and system
/// versions, location in code. Neither error message, query, nor track title.
const probe = 'zqxwvprobe';

final kindShape = RegExp(r'^[a-z][a-z0-9_.-]{0,63}$');
final versionShape = RegExp(r'^[0-9A-Za-z.+-]{1,32}$');
final osShape = RegExp(r'^[0-9A-Za-z .+-]{1,32}$');
final functionShape = RegExp(r'^[\w.<> $-]{1,200}$');
final fileShape = RegExp(r'^(package|dart):[\w./-]{1,200}$');

/// Report body matches exactly what server accepts — otherwise 422 and report lost.
void expectServerShape(Map<String, dynamic> body) {
  expect(body.keys.toSet(), {'kind', 'screen', 'app_version', 'os', 'frames'});
  expect(body['kind'], matches(kindShape));
  expect(body['screen'], matches(kindShape));
  expect(body['app_version'], matches(versionShape));
  expect(body['os'], matches(osShape));
  final frames = body['frames'] as List<dynamic>;
  expect(frames.length, lessThanOrEqualTo(100));
  for (final frame in frames.cast<Map<String, dynamic>>()) {
    expect(frame.keys.toSet(), {'function', 'file', 'line'});
    expect(frame['function'], matches(functionShape));
    expect(frame['file'], matches(fileShape));
    expect(frame['line'], isA<int>());
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'screen error: send report sends to server and notifies that it was sent',
    (tester) async {
      final rig = Rig();
      rig.server.fail('GET /v1/genres', 500, 'internal');
      rig.server.on(
        'POST /v1/reports',
        (_) => answer(202, const {'status': 'accepted'}),
      );
      await rig.screen(tester, (services) => GenresScreen(services: services));

      expect(find.text('Повторить'), findsOneWidget);
      await tapAndSettle(tester, find.byKey(const Key('send-report')));

      final sent = rig.server.calls('POST /v1/reports');
      expect(sent, hasLength(1));
      final body = bodyOf(sent.single);
      expectServerShape(body);
      expect(body['kind'], 'server.no_answer');
      expect(body['screen'], 'genres');
      expect(find.text('Отчёт отправлен'), findsOneWidget);
      // Same report is not sent twice: button performed its action.
      expect(find.byKey(const Key('send-report')), findsNothing);
    },
  );

  testWidgets('server without reports: say so instead of sent message', (
    tester,
  ) async {
    final rig = Rig();
    rig.server.fail('GET /v1/genres', 500, 'internal');
    rig.server.on(
      'POST /v1/reports',
      (_) => answer(503, const {'status': 'reports_off'}),
    );
    await rig.screen(tester, (services) => GenresScreen(services: services));
    await tapAndSettle(tester, find.byKey(const Key('send-report')));

    expect(find.text('Отчёты выключены на сервере'), findsOneWidget);
    expect(find.text('Отчёт отправлен'), findsNothing);
  });

  test(
    'crash report: not sent without toggle, with toggle without error text',
    () async {
      final server = FakeServer();
      server.on(
        'POST /v1/reports',
        (_) => answer(202, const {'status': 'accepted'}),
      );
      final reports = ErrorReports(server.api());
      await reports.load();
      expect(
        reports.automatic,
        isFalse,
        reason: 'disabled by default in error settings (R-A11)',
      );

      StackTrace stack;
      try {
        throw StateError('query $probe');
      } on StateError catch (_, trace) {
        stack = trace;
      }
      await reports.crash(StateError('query $probe'), stack);
      expect(server.calls('POST /v1/reports'), isEmpty);

      await reports.setAutomatic(true);
      await reports.crash(StateError('query $probe'), stack);
      final sent = server.calls('POST /v1/reports');
      expect(sent, hasLength(1));
      final body = bodyOf(sent.single);
      expectServerShape(body);
      expect(body['kind'], 'crash.state_error');
      expect(body['screen'], matches(kindShape));
      expect((body['frames'] as List<dynamic>), isNotEmpty);
      expect(jsonEncode(body), isNot(contains(probe)));
      // File path on build machine identifies machine — omitted from report.
      expect(jsonEncode(body), isNot(contains('file://')));

      // Toggle state remembered across launches.
      final again = ErrorReports(server.api());
      await again.load();
      expect(again.automatic, isTrue);
    },
  );

  test('report does not crash app if server is silent', () async {
    final server = FakeServer();
    server.on('POST /v1/reports', (_) => throw Exception('reset'));
    final reports = ErrorReports(server.api());
    await reports.load();
    await reports.setAutomatic(true);
    await reports.crash(StateError('x'), StackTrace.current);
    expect(
      await server.api().sendReport(
        const ErrorReport(kind: 'server.no_answer', screen: 'genres'),
      ),
      ReportResult.failed,
    );
  });

  testWidgets('account menu: toggle send reports automatically', (
    tester,
  ) async {
    final actions = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            actions: [AccountBar(text: (en, ru) => ru, onAction: actions.add)],
          ),
        ),
      ),
    );
    await tapAndSettle(tester, find.byKey(const Key('account-button')));
    expect(find.byKey(const Key('auto-reports')), findsOneWidget);
    await tapAndSettle(tester, find.byKey(const Key('auto-reports')));
    // Enabling — after consent (P-A46, reports_consent_test.dart).
    await tapAndSettle(tester, find.byKey(const Key('reports-confirm')));
    expect(actions, ['auto-reports']);
  });
}
