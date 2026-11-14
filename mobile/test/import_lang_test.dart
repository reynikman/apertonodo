import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_stream/server_api.dart';

import 'fakes.dart';

/// FT-826 (P9): the server words an import refusal in the phone language, so the
/// app has to say which language that is. Only import calls carry it — search,
/// Play and the rest stay as they were.
const base = 'http://192.0.2.1:8088';

final _report = File(
  '../contracts/import-create.response.json',
).readAsStringSync();

({ServerApi api, List<http.BaseRequest> seen}) _api({
  String Function()? language,
  int status = 200,
  String? body,
}) {
  final seen = <http.BaseRequest>[];
  final client = MockClient((request) async {
    seen.add(request);
    return http.Response(
      body ?? _report,
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  });
  final api = language == null
      ? ServerApi(base, tokens: tokensFor(base), client: client)
      : ServerApi(
          base,
          tokens: tokensFor(base),
          client: client,
          language: language,
        );
  return (api: api, seen: seen);
}

final _file = Uint8List.fromList('Metallica - One'.codeUnits);

void main() {
  test('import says the phone language to the server', () async {
    final server = _api(language: () => 'en');
    await server.api.createImport('List', _file);
    expect(server.seen.single.url.path, '/v1/imports');
    expect(server.seen.single.headers['accept-language'], 'en');
  });

  test('the language is read at the moment of the call', () async {
    var language = 'ru';
    final server = _api(language: () => language);
    await server.api.createImport('List', _file);
    language = 'en';
    await server.api.createImport('List', _file);
    expect(server.seen.map((r) => r.headers['accept-language']), ['ru', 'en']);
  });

  test('without a language the header is not sent at all', () async {
    final server = _api();
    await server.api.createImport('List', _file);
    expect(server.seen.single.headers.containsKey('accept-language'), isFalse);
  });

  test(
    'the English refusal reaches the screen as the server said it',
    () async {
      final server = _api(
        language: () => 'en',
        status: 422,
        body: '{"status": "empty", "message": "The file has no songs."}',
      );
      await expectLater(
        server.api.createImport('List', _file),
        throwsA(
          isA<ImportFailed>().having(
            (e) => e.message,
            'message',
            'The file has no songs.',
          ),
        ),
      );
    },
  );

  test('every ServerApi the app builds is told the language', () {
    final source = File('lib/main.dart').readAsStringSync();
    final built = RegExp(r'ServerApi\(').allMatches(source).length;
    final told = RegExp(
      r'ServerApi\([^)]*language:',
      dotAll: true,
    ).allMatches(source).length;
    expect(built, greaterThanOrEqualTo(3));
    expect(told, built);
  });
}
