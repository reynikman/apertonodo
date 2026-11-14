import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_stream/auth/session_store.dart';
import 'package:music_stream/auth/token_provider.dart';
import 'package:music_stream/error_reports.dart';
import 'package:music_stream/screens/parts.dart';
import 'package:music_stream/screens/problem_sheet.dart';
import 'package:music_stream/server_api.dart';

/// FT-857, owner 14.10: he pressed "Send report" 5-10 times on songs that did
/// not play, and the lead could not say which songs: the error report carries
/// no song by design. Now the same tap also files a "does not play" complaint
/// with the song number, where complaints are read.
///
/// Not proven here: the player screen wiring on a phone.
class _Store extends SessionStore {
  @override
  Future<void> saveToken(String token) async {}

  @override
  Future<String?> readToken() async => null;

  @override
  Future<void> clear() async {}
}

void main() {
  testWidgets('one tap sends the error report and the song complaint', (
    tester,
  ) async {
    final server = Uri.parse('https://music.example.org');
    final tokens = TokenProvider(_Store(), server: server);
    await tokens.signIn('t' * 43);
    final sent = <String, Map<String, dynamic>>{};
    final api = ServerApi(
      server.origin,
      tokens: tokens,
      client: MockClient((request) async {
        sent[request.url.path] =
            jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response('{"status":"accepted"}', 202);
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReportButton(
            server: api,
            report: const ErrorReport(kind: 'play.no_source', screen: 'player'),
            problem: const ProblemReport(
              reason: 'no_play',
              place: ProblemPlace.player,
              trackId: 'track-42',
              appVersion: 'test',
              text: 'play.noSource',
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('send-report')));
    await tester.pumpAndSettle();

    expect(sent['/v1/reports']?['kind'], 'play.no_source');
    expect(sent['/v1/problems']?['track_id'], 'track-42');
    expect(sent['/v1/problems']?['reason'], 'no_play');
    expect(sent['/v1/problems']?['place'], 'player');
  });
}
