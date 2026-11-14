import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_stream/server_kind.dart';

/// Lead check FT-892: the revision is read from the new header; a server
/// deployed before FT-888 sends only the old one, and it still works.

Future<String?> _revision(Map<String, String> headers) async {
  final client = MockClient(
    (_) async => http.Response.bytes(
      utf8.encode('{"status":"ok"}'),
      200,
      headers: {'content-type': 'application/json', ...headers},
    ),
  );
  return (await detectServer('https://example.org', client: client)).version;
}

void main() {
  test('revision from the new header', () async {
    expect(await _revision({'x-apertonodo-revision': 'new1234'}), 'new1234');
  });

  test('old server: revision from the old header', () async {
    expect(await _revision({'x-flowtune-revision': 'old1234'}), 'old1234');
  });

  test('both headers: the new one wins', () async {
    expect(
      await _revision({
        'x-apertonodo-revision': 'new1234',
        'x-flowtune-revision': 'old1234',
      }),
      'new1234',
    );
  });
}
