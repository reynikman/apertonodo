import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_stream/auth/login.dart';

void main() {
  // App and P3 server were written separately, and login from phone returned 400:
  // app did not send device_name. Both sides verify against the same contract.
  test('login sends and reads the shape of the contract', () async {
    final request =
        jsonDecode(
              File('../contracts/auth-login.request.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    final response =
        jsonDecode(
              File('../contracts/auth-login.response.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    Map<String, dynamic>? sent;
    final client = MockClient((call) async {
      sent = jsonDecode(call.body) as Map<String, dynamic>;
      final body = {for (final key in response.keys) key: '$key-value'};
      return http.Response(jsonEncode(body), 200);
    });

    final session = await loginAt(
      Uri.parse('https://music.example'),
      'owner',
      'secret words',
      client,
    );

    expect(sent!.keys.toSet(), request.keys.toSet());
    expect(sent!['username'], 'owner');
    expect(sent!['password'], 'secret words');
    expect((sent!['device_name'] as String).trim(), isNotEmpty);
    expect(session.token, 'token-value');
    expect(session.userId, 'user_id-value');
  });
}
