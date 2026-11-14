import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_stream/catalog.dart';
import 'package:music_stream/models/track.dart';

import 'fakes.dart';

void main() {
  test('client parses search contract fixture', () {
    final file = File('../contracts/search.response.json');
    final payload = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final tracks = (payload['tracks'] as List<dynamic>)
        .map((row) => Track.fromJson(row as Map<String, dynamic>))
        .toList();
    expect(tracks, hasLength(1));
    expect(tracks.first.title, 'Nothing Else Matters');
    expect(tracks.first.toJson().keys, isNot(contains('info_hash')));
  });

  /// Response shape changed in Phase J: artists in separate list. Test
  /// parses full contract via real deserialization, otherwise new field is easy
  /// to lose along the way unnoticed: results would remain non-empty.
  test(
    'client reads both the artists and unplayable mark from contract',
    () async {
      final body = File('../contracts/search.response.json').readAsStringSync();
      final client = MockClient(
        (_) async => http.Response(
          body,
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      final result = await HttpCatalog(
        'http://192.0.2.1:8088',
        tokens: tokensFor('http://192.0.2.1:8088'),
        client: client,
      ).search('metallica');
      expect(result.artists, ['Metallica']);
      expect(result.tracks.single.playable, isTrue);
      expect(result.isEmpty, isFalse);
    },
  );

  test('client reads suggestions contract', () async {
    final body = File('../contracts/suggest.response.json').readAsStringSync();
    final client = MockClient(
      (_) async => http.Response(
        body,
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    final hints = await HttpCatalog(
      'http://192.0.2.1:8088',
      tokens: tokensFor('http://192.0.2.1:8088'),
      client: client,
    ).suggest('lin');
    expect(hints, ['Linkin Park', 'Numb']);
  });

  /// Suggestion is convenience, not answer: its failure is silent rather than breaking search.
  test('suggestion is silent on any failure', () async {
    final broken = MockClient((_) async => throw http.ClientException('reset'));
    expect(
      await HttpCatalog(
        'http://192.0.2.1:8088',
        tokens: tokensFor('http://192.0.2.1:8088'),
        client: broken,
      ).suggest('lin'),
      isEmpty,
    );
    final refused = MockClient((_) async => http.Response('{}', 401));
    expect(
      await HttpCatalog(
        'http://192.0.2.1:8088',
        tokens: tokensFor('http://192.0.2.1:8088'),
        client: refused,
      ).suggest('l'),
      isEmpty,
    );
  });
}
