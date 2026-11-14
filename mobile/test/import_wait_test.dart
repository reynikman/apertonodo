import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_stream/server_api.dart';

import 'fakes.dart';

/// Import waits for server longer than normal page (FT-513). On live server 2000 lines
/// match in ~22 s, while file up to 10,000 lines (our limit) — longer than 35 s
/// normal timeout. Upper bound is proxy: NPM waits 90 s
/// (`proxy_read_timeout`), Cloudflare — 100 s. App waits 85 s: longer than
/// 35, but gives up before proxy, so user sees "server did not respond" rather
/// than proxy HTML page.
const base = 'http://192.0.2.1:8088';

ServerApi api(Duration delay) {
  final body = File(
    '../contracts/import-create.response.json',
  ).readAsStringSync();
  final client = MockClient((_) async {
    await Future<void>.delayed(delay);
    return http.Response(
      body,
      200,
      headers: {'content-type': 'application/json'},
    );
  });
  return ServerApi(base, tokens: tokensFor(base), client: client);
}

/// Starts import and records outcome: report or error.
({ImportReport? report, Object? error}) Function() start(Duration delay) {
  ImportReport? report;
  Object? error;
  () async {
    try {
      report = await api(
        delay,
      ).createImport('Список', Uint8List.fromList('Metallica - One'.codeUnits));
    } catch (e) {
      error = e;
    }
  }();
  return () => (report: report, error: error);
}

void main() {
  testWidgets('import waits for response at 60 s', (tester) async {
    {
      final outcome = start(const Duration(seconds: 60));
      await tester.pump(const Duration(seconds: 61));
      final (:report, :error) = outcome();
      expect(
        error,
        isNull,
        reason: 'import gave up before 60 s - waits like normal page',
      );
      expect(report, isNotNull);
    }
  });

  testWidgets('import gives up before proxy (90 s)', (tester) async {
    {
      final outcome = start(const Duration(seconds: 120));
      await tester.pump(const Duration(seconds: 89));
      final (:report, :error) = outcome();
      expect(report, isNull);
      expect(
        error,
        isA<ServerFailed>(),
        reason: 'waits longer than proxy - user would see proxy error',
      );
      // 120 s response timer must not outlive test.
      await tester.pump(const Duration(seconds: 40));
    }
  });

  test('regular requests still wait 35 s', () {
    expect(ServerApi.pageTimeout, const Duration(seconds: 35));
  });
}
