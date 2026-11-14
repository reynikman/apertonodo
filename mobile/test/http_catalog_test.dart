import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_stream/catalog.dart';
import 'package:music_stream/server_api.dart';

import 'fakes.dart';

void main() {
  test('http catalog parses search payload', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/v1/search');
      expect(request.url.queryParameters['q'], 'duality');
      return http.Response(
        jsonEncode({
          'tracks': [
            {
              'id': '33333333-3333-3333-3333-333333333333',
              'title': 'Duality',
              'artist': 'Slipknot',
              'duration_ms': 252000,
              'artwork_url': 'https://example.test/cover',
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final catalog = HttpCatalog(
      'http://192.0.2.1:8088',
      tokens: tokensFor('http://192.0.2.1:8088'),
      client: client,
    );
    final tracks = (await catalog.search('duality')).tracks;
    expect(tracks, hasLength(1));
    expect(tracks.first.title, 'Duality');
    expect(tracks.first.toJson().keys, isNot(contains('info_hash')));
  });

  test('artist catalog reads optional photo', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/v1/artists');
      return http.Response(
        jsonEncode({
          'artists': [
            {'name': 'Кино', 'photo': '/v1/images/kino.jpg'},
            {'name': 'АукцЫон'},
          ],
          'total': 2,
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final api = ServerApi(
      'http://192.0.2.1:8088',
      tokens: tokensFor('http://192.0.2.1:8088'),
      client: client,
    );
    final chunk = await api.artistCatalog();
    expect(chunk.items, hasLength(2));
    expect(chunk.items.first.photo, '/v1/images/kino.jpg');
    expect(chunk.items.last.photo, isNull);
    expect((await api.artists()).items, ['Кино', 'АукцЫон']);
  });

  http.Response genresOk() {
    return http.Response(
      jsonEncode({
        'genres': [
          {'id': 'rock', 'name': 'Рок', 'artists': 3},
        ],
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  }

  test('genres() does not make network request a second time', () async {
    var calls = 0;
    final client = MockClient((request) async {
      expect(request.url.path, '/v1/genres');
      calls++;
      return genresOk();
    });
    final api = ServerApi(
      'http://192.0.2.1:8088',
      tokens: tokensFor('http://192.0.2.1:8088'),
      client: client,
    );

    final first = await api.genres();
    final second = await api.genres();

    expect(calls, 1);
    expect(second, first);
    expect(first.single.name, 'Рок');
  });

  test('genres() hits network again after error', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      if (calls == 1) {
        return http.Response(
          '{}',
          503,
          headers: {'content-type': 'application/json'},
        );
      }
      return genresOk();
    });
    final api = ServerApi(
      'http://192.0.2.1:8088',
      tokens: tokensFor('http://192.0.2.1:8088'),
      client: client,
    );

    await expectLater(api.genres(), throwsA(isA<ServerFailed>()));
    expect(calls, 1);

    final genres = await api.genres();
    expect(genres.single.name, 'Рок');
    await api.genres();
    expect(calls, 2);
  });
}
