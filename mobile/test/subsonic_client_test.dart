import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_stream/subsonic_client.dart';

/// Lead check FT-648. Responses recorded from real Navidrome 0.64.2
/// (`test/fixtures/navidrome_0_64_2`) captured on 07.10.2026; credentials excluded.
const _dir = 'test/fixtures/navidrome_0_64_2';
const _password = 'correct horse';
const _apiKey = 'key-3f9a7c1e';

Map<String, dynamic> _record(String name) =>
    jsonDecode(File('$_dir/$name.json').readAsStringSync())
        as Map<String, dynamic>;

/// UTF-8 response bytes without charset in header — matching Navidrome behavior.
http.Response _reply(String name) {
  final record = _record(name);
  final body = record.containsKey('json')
      ? jsonEncode(record['json'])
      : record['text'] as String;
  return http.Response.bytes(
    utf8.encode(body),
    record['status'] as int,
    headers: {
      'content-type': (record['content_type'] as String).split(';').first,
    },
  );
}

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: {'content-type': 'application/json'},
);

http.Response _failed(int? code) => _json({
  'subsonic-response': {
    'status': 'failed',
    'version': '1.16.1',
    if (code != null) 'error': {'code': code, 'message': 'x'},
  },
});

class _Server {
  _Server(this.answer);
  final FutureOr<http.Response> Function(http.Request) answer;
  final requests = <Uri>[];

  SubsonicClient client({
    String base = 'http://music.test:4533',
    SubsonicAuth auth = const SubsonicAuth.password('tester', _password),
    String Function()? salt,
    Duration timeout = const Duration(seconds: 15),
  }) => SubsonicClient(
    base: Uri.parse(base),
    auth: auth,
    salt: salt,
    timeout: timeout,
    client: MockClient((request) async {
      requests.add(request.url);
      return answer(request);
    }),
  );

  Map<String, String> get query => requests.single.queryParameters;
}

_Server _serve(String name) => _Server((_) => _reply(name));

Future<SubsonicError> _error(Future<Object?> call) async {
  try {
    await call;
  } on SubsonicError catch (error) {
    return error;
  }
  fail('no error occurred');
}

void main() {
  group('records', () {
    test('records do not contain password, token, or salt', () {
      final index = jsonDecode(File('$_dir/INDEX.json').readAsStringSync());
      final names = (index['records'] as List).cast<String>();
      expect(names, hasLength(40));
      for (final name in names) {
        final query = _record(name)['query'] as Map<String, dynamic>;
        for (final key in ['t', 's', 'p']) {
          if (query.containsKey(key)) {
            expect(query[key], startsWith('<'), reason: '$name: $key');
          }
        }
      }
    });
  });

  group('request', () {
    test(
      'ping request calls /rest/ping.view with version, user, and json',
      () async {
        final server = _serve('ping_ok');
        await server.client().ping();
        final url = server.requests.single;
        expect(url.path, '/rest/ping.view');
        expect(url.host, 'music.test');
        expect(url.port, 4533);
        expect(server.query['v'], '1.16.1');
        expect(server.query['c'], 'apertono');
        expect(server.query['f'], 'json');
      },
    );

    test(
      'password sent as md5(pass + salt), raw password never sent',
      () async {
        final server = _serve('ping_ok');
        await server.client(salt: () => 'c19b2d').ping();
        expect(server.query['u'], 'tester');
        expect(server.query['s'], 'c19b2d');
        expect(
          server.query['t'],
          md5.convert(utf8.encode('${_password}c19b2d')).toString(),
        );
        expect(server.query.containsKey('p'), isFalse);
        expect(server.query.containsKey('apiKey'), isFalse);
        final whole = Uri.decodeFull(server.requests.single.toString());
        expect(whole, isNot(contains(_password)));
        expect(whole, isNot(contains('correct')));
      },
    );

    test('non-Latin password hashed as UTF-8', () async {
      final server = _serve('ping_ok');
      await server
          .client(
            auth: const SubsonicAuth.password('tester', 'пароль'),
            salt: () => 'abcdef',
          )
          .ping();
      expect(
        server.query['t'],
        md5.convert(utf8.encode('парольabcdef')).toString(),
      );
    });

    test('salt unique per request and at least 6 characters', () async {
      final server = _Server((_) => _reply('ping_ok'));
      final client = server.client();
      await client.ping();
      await client.ping();
      await client.ping();
      final salts = server.requests.map((u) => u.queryParameters['s']!).toSet();
      expect(salts, hasLength(3));
      for (final salt in salts) {
        expect(salt.length, greaterThanOrEqualTo(6));
        expect(salt, matches(RegExp(r'^[0-9a-zA-Z]+$')));
      }
      final tokens = server.requests.map((u) => u.queryParameters['t']).toSet();
      expect(tokens, hasLength(3));
    });

    test('apiKey login: apiKey only, no user, token, or salt', () async {
      final server = _serve('ping_ok');
      await server.client(auth: const SubsonicAuth.apiKey(_apiKey)).ping();
      expect(server.query['apiKey'], _apiKey);
      for (final key in ['u', 't', 's', 'p']) {
        expect(server.query.containsKey(key), isFalse, reason: key);
      }
      expect(server.query['f'], 'json');
    });

    test('URL with subpath and no trailing slash preserves path', () async {
      for (final base in [
        'https://home.test/music',
        'https://home.test/music/',
      ]) {
        final server = _serve('ping_ok');
        await server.client(base: base).ping();
        final url = server.requests.single;
        expect(url.scheme, 'https');
        expect(url.path, '/music/rest/ping.view', reason: base);
        expect(url.hasPort ? url.port : 443, 443);
      }
    });

    test('URL with trailing slash produces no double slashes', () async {
      final server = _serve('ping_ok');
      await server.client(base: 'http://music.test:4533/').ping();
      expect(server.requests.single.path, '/rest/ping.view');
    });

    test('search sends query, limit, and offset', () async {
      final server = _serve('search_tone');
      await server.client().search('tone', limit: 7, songOffset: 14);
      expect(server.requests.single.path, '/rest/search3.view');
      expect(server.query['query'], 'tone');
      expect(server.query['songCount'], '7');
      expect(server.query['albumCount'], '7');
      expect(server.query['artistCount'], '7');
      expect(server.query['songOffset'], '14');
    });

    test('default search: 20 rows from beginning', () async {
      final server = _serve('search_tone');
      await server.client().search('tone');
      expect(server.query['songCount'], '20');
      expect(server.query['songOffset'], '0');
    });

    test('Cyrillic and symbols in query sent without distortion', () async {
      final server = _serve('search_cyrillic');
      await server.client().search('песня & знак?=#');
      expect(server.query['query'], 'песня & знак?=#');
      expect(server.query['f'], 'json');
    });

    test('artist, album, track queried by ID', () async {
      final cases = <String, Future<Object?> Function(SubsonicClient)>{
        'getArtists': (c) => c.artists(),
        'getArtist': (c) => c.artist('a/1 &x'),
        'getAlbum': (c) => c.album('a/1 &x'),
        'getSong': (c) => c.song('a/1 &x'),
        'getStarred2': (c) => c.starred(),
        'star': (c) => c.star('a/1 &x'),
        'unstar': (c) => c.unstar('a/1 &x'),
      };
      for (final entry in cases.entries) {
        final server = _serve('ping_ok');
        await entry.value(server.client());
        expect(
          server.requests.single.path,
          '/rest/${entry.key}.view',
          reason: entry.key,
        );
        if (!{'getArtists', 'getStarred2'}.contains(entry.key)) {
          expect(server.query['id'], 'a/1 &x', reason: entry.key);
        }
      }
    });
  });

  group('real Navidrome response', () {
    test('ping returns server type and version', () async {
      final server = await _serve('ping_ok').client().ping();
      expect(server.type, 'navidrome');
      expect(server.version, '0.64.2 (10114574)');
      expect(server.openSubsonic, isTrue);
    });

    test(
      'legacy Subsonic without fields has empty type and not OpenSubsonic',
      () async {
        final server = _Server(
          (_) => _json({
            'subsonic-response': {'status': 'ok', 'version': '1.16.1'},
          }),
        );
        final info = await server.client().ping();
        expect(info.type, '');
        expect(info.version, '');
        expect(info.openSubsonic, isFalse);
      },
    );

    test('search: songs, albums, and artists', () async {
      final found = await _serve('search_tone').client().search('tone');
      expect(found.songs.map((s) => s.title), [
        'Test Tone Long',
        'Test Tone Short',
      ]);
      final song = found.songs.first;
      expect(song.id, '2llbCRtEv5j7BosspiA3xR');
      expect(song.artist, 'Apertono');
      expect(song.artistId, '65gKQEzZjvqlrA7DDldiAd');
      expect(song.album, 'Test Tones');
      expect(song.albumId, '5w43XUdYrcWMCGWoPzXK7t');
      expect(song.durationMs, 6000);
      expect(song.track, 1);
      expect(song.suffix, 'mp3');
      expect(song.starred, isFalse);
      expect(found.songs.last.durationMs, 2000);
      expect(found.songs.last.track, 2);
      expect(found.albums.single.name, 'Test Tones');
      expect(found.albums.single.id, '5w43XUdYrcWMCGWoPzXK7t');
      expect(found.albums.single.artist, 'Apertono');
      expect(found.albums.single.year, 2026);
      expect(found.albums.single.songCount, 2);
      expect(found.albums.single.songs, isEmpty);
      expect(found.artists, isEmpty);
    });

    test('empty search results in 3 empty lists, not error', () async {
      final found = await _serve('search_nothing').client().search('zzzz');
      expect(found.songs, isEmpty);
      expect(found.albums, isEmpty);
      expect(found.artists, isEmpty);
    });

    test('Cyrillic in response parsed as UTF-8 even without charset', () async {
      final found = await _serve('search_cyrillic').client().search('песня');
      expect(found.songs.single.title, 'Песня & знак');
      expect(found.songs.single.artist, 'Второй Исполнитель');
      expect(found.songs.single.album, 'Альбом с кириллицей');
      expect(found.songs.single.suffix, 'flac');
      expect(found.songs.single.durationMs, 3000);
    });

    test('Cyrillic parsed even when content type missing', () async {
      final body = utf8.encode(jsonEncode(_record('search_cyrillic')['json']));
      for (final headers in [
        <String, String>{},
        {'content-type': 'text/plain'},
      ]) {
        final found = await _Server(
          (_) => http.Response.bytes(body, 200, headers: headers),
        ).client().search('песня');
        expect(found.songs.single.title, 'Песня & знак', reason: '$headers');
      }
    });

    test('artist list aggregated across all letters in order', () async {
      final artists = await _serve('artists').client().artists();
      expect(artists.map((a) => a.name), ['Второй Исполнитель', 'Apertono']);
      expect(artists.last.id, '65gKQEzZjvqlrA7DDldiAd');
      expect(artists.last.albumCount, 1);
      expect(artists.last.albums, isEmpty);
    });

    test('artist comes with albums', () async {
      final artist = await _serve('artist').client().artist('x');
      expect(artist.name, 'Apertono');
      expect(artist.albumCount, 1);
      expect(artist.albums.single.name, 'Test Tones');
      expect(artist.albums.single.year, 2026);
      expect(artist.albums.single.artistId, '65gKQEzZjvqlrA7DDldiAd');
    });

    test('album comes with tracks in server order', () async {
      final album = await _serve('album').client().album('x');
      expect(album.name, 'Test Tones');
      expect(album.songCount, 2);
      expect(album.songs.map((s) => s.title), [
        'Test Tone Long',
        'Test Tone Short',
      ]);
      expect(album.songs.map((s) => s.track), [1, 2]);
      expect(album.coverArt, '');
    });

    test('track by id', () async {
      final song = await _serve('song').client().song('x');
      expect(song.title, 'Test Tone Long');
      expect(song.durationMs, 6000);
      expect(song.coverArt, '');
    });

    test('starred: empty, one starred track, empty again', () async {
      expect(await _serve('starred_empty').client().starred(), isEmpty);
      final one = await _serve('starred_one').client().starred();
      expect(one.single.title, 'Test Tone Long');
      expect(one.single.starred, isTrue);
      expect(await _serve('starred_after_unstar').client().starred(), isEmpty);
    });

    test('star, star again, and unstar without error', () async {
      await _serve('star').client().star('x');
      await _serve('star_twice').client().star('x');
      await _serve('star_missing').client().star('no-such-id');
      await _serve('unstar').client().unstar('x');
    });
  });

  group('failures', () {
    test('wrong password and unknown user: login error code 40', () async {
      for (final name in ['ping_wrong_token', 'ping_wrong_user']) {
        final error = await _error(_serve(name).client().ping());
        expect(error.kind, SubsonicFailure.auth, reason: name);
        expect(error.code, 40);
      }
    });

    test('login error seen on any request, not just ping', () async {
      final error = await _error(
        _serve('ping_wrong_token').client().search('tone'),
      );
      expect(error.kind, SubsonicFailure.auth);
    });

    test('Navidrome token auth returns code 10: token not supported', () async {
      final error = await _error(
        _serve(
          'ping_api_key_wrong',
        ).client(auth: const SubsonicAuth.apiKey(_apiKey)).ping(),
      );
      expect(error.kind, SubsonicFailure.authUnsupported);
      expect(error.code, 10);
    });

    test('same code 10 on password login is generic failure', () async {
      final error = await _error(_serve('ping_no_auth').client().ping());
      expect(error.kind, SubsonicFailure.refused);
      expect(error.code, 10);
    });

    test('Subsonic and OpenSubsonic codes map to reasons', () async {
      const kinds = {
        0: SubsonicFailure.refused,
        10: SubsonicFailure.refused,
        20: SubsonicFailure.refused,
        30: SubsonicFailure.refused,
        40: SubsonicFailure.auth,
        41: SubsonicFailure.authUnsupported,
        42: SubsonicFailure.authUnsupported,
        43: SubsonicFailure.authUnsupported,
        44: SubsonicFailure.auth,
        50: SubsonicFailure.forbidden,
        60: SubsonicFailure.refused,
        70: SubsonicFailure.notFound,
        999: SubsonicFailure.refused,
      };
      for (final entry in kinds.entries) {
        final error = await _error(
          _Server((_) => _failed(entry.key)).client().ping(),
        );
        expect(error.kind, entry.value, reason: '${entry.key}');
        expect(error.code, entry.key);
      }
    });

    test('failure without code and non-ok status is failure', () async {
      final none = await _error(_Server((_) => _failed(null)).client().ping());
      expect(none.kind, SubsonicFailure.refused);
      expect(none.code, isNull);
      final odd = await _error(
        _Server(
          (_) => _json({
            'subsonic-response': {
              'status': 'weird',
              'error': {'code': '40'},
            },
          }),
        ).client().ping(),
      );
      expect(odd.kind, SubsonicFailure.refused);
      expect(odd.code, isNull);
    });

    test('no such album, artist, or track maps to not found', () async {
      final album = await _error(_serve('album_missing').client().album('x'));
      final artist = await _error(
        _serve('artist_missing').client().artist('x'),
      );
      final song = await _error(_serve('song_missing').client().song('x'));
      for (final error in [album, artist, song]) {
        expect(error.kind, SubsonicFailure.notFound);
        expect(error.code, 70);
      }
    });

    test('error with code is parsed even on HTTP 401 status', () async {
      final error = await _error(
        _Server(
          (_) => _json({
            'subsonic-response': {
              'status': 'failed',
              'error': {'code': 40},
            },
          }, 401),
        ).client().ping(),
      );
      expect(error.kind, SubsonicFailure.auth);
    });

    test('not Subsonic: plain 404, XML, web page, alien JSON', () async {
      final answers = <String, http.Response Function()>{
        '404': () => _reply('unknown_method'),
        'xml': () => _reply('ping_xml_by_default'),
        'html': () => http.Response('<html>login</html>', 200),
        'empty': () => http.Response('', 200),
        'other json': () => _json({'status': 'ok'}),
        'list': () => _json([1, 2]),
        'string body': () => _json({'subsonic-response': 'ok'}),
        'null': () => http.Response('null', 200),
      };
      for (final entry in answers.entries) {
        final error = await _error(
          _Server((_) => entry.value()).client().ping(),
        );
        expect(error.kind, SubsonicFailure.notSubsonic, reason: entry.key);
      }
    });

    test(
      'server down: 500, 502, 503 is unavailable regardless of body',
      () async {
        for (final status in [500, 502, 503, 504]) {
          for (final body in ['<html>bad gateway</html>', '']) {
            final error = await _error(
              _Server((_) => http.Response(body, status)).client().ping(),
            );
            expect(error.kind, SubsonicFailure.unavailable, reason: '$status');
          }
        }
        final ok = await _error(
          _Server(
            (_) => _json(_record('ping_ok')['json'] as Object, 503),
          ).client().ping(),
        );
        expect(ok.kind, SubsonicFailure.unavailable);
      },
    );

    test('no network maps to unavailable', () async {
      for (final Object thrown in [
        http.ClientException('connection refused'),
        const SocketException('no route'),
        const HandshakeException('bad cert'),
      ]) {
        final error = await _error(
          _Server((_) => throw thrown).client().ping(),
        );
        expect(error.kind, SubsonicFailure.unavailable, reason: '$thrown');
      }
    });

    test('timeout maps to unavailable instead of hanging forever', () async {
      final never = Completer<http.Response>();
      final error = await _error(
        _Server(
          (_) => never.future,
        ).client(timeout: const Duration(milliseconds: 30)).ping(),
      ).timeout(const Duration(seconds: 5));
      expect(error.kind, SubsonicFailure.unavailable);
    });

    test('default timeout is fifteen seconds', () {
      expect(
        SubsonicClient(
          base: Uri.parse('http://music.test'),
          auth: const SubsonicAuth.apiKey(_apiKey),
          client: MockClient((_) async => _reply('ping_ok')),
        ).timeout,
        const Duration(seconds: 15),
      );
    });

    test(
      'error text excludes URL, username, password, token, and message',
      () async {
        final texts = <String>[
          '${await _error(_serve('ping_wrong_token').client().ping())}',
          '${await _error(_serve('unknown_method').client().ping())}',
          '${await _error(_Server((_) => throw http.ClientException('http://music.test:4533/rest?u=tester&t=abc', Uri.parse('http://music.test:4533/rest?u=tester'))).client().ping())}',
          '${await _error(_serve('ping_api_key_wrong').client(auth: const SubsonicAuth.apiKey(_apiKey)).ping())}',
          '${const SubsonicAuth.password('tester', _password)}',
          '${const SubsonicAuth.apiKey(_apiKey)}',
        ];
        for (final text in texts) {
          for (final secret in [
            'music.test',
            'tester',
            _password,
            _apiKey,
            'Wrong username',
            'missing parameter',
            '?',
          ]) {
            expect(text, isNot(contains(secret)), reason: text);
          }
        }
        expect(texts.first, contains('auth'));
        expect(texts.first, contains('40'));
      },
    );
  });

  group('stream and cover URLs', () {
    test('stream URL: stream.view, track id, and auth', () {
      final client = _serve('ping_ok').client(salt: () => 'c19b2d');
      final url = client.streamUri('2llb/x &y');
      expect(url.path, '/rest/stream.view');
      expect(url.queryParameters['id'], '2llb/x &y');
      expect(url.queryParameters['u'], 'tester');
      expect(url.queryParameters['s'], 'c19b2d');
      expect(
        url.queryParameters['t'],
        md5.convert(utf8.encode('${_password}c19b2d')).toString(),
      );
      expect(url.queryParameters['v'], '1.16.1');
      expect(url.queryParameters['c'], 'apertono');
      expect(url.queryParameters.containsKey('p'), isFalse);
      expect(url.queryParameters.containsKey('format'), isFalse);
      expect(url.queryParameters.containsKey('maxBitRate'), isFalse);
    });

    test('stream URL built without server request and with server path', () {
      final server = _serve('ping_ok');
      final url = server
          .client(
            base: 'https://home.test/music/',
            auth: const SubsonicAuth.apiKey(_apiKey),
          )
          .streamUri('7');
      expect(server.requests, isEmpty);
      expect(url.scheme, 'https');
      expect(url.path, '/music/rest/stream.view');
      expect(url.queryParameters['apiKey'], _apiKey);
      expect(url.queryParameters.containsKey('u'), isFalse);
    });

    test('cover URL: getCoverArt.view, id, and size', () {
      final client = _serve('ping_ok').client();
      final url = client.coverUri('al-5w43', size: 300)!;
      expect(url.path, '/rest/getCoverArt.view');
      expect(url.queryParameters['id'], 'al-5w43');
      expect(url.queryParameters['size'], '300');
      expect(url.queryParameters['u'], 'tester');
      expect(client.coverUri('al-5w43')!.queryParameters['size'], '600');
    });

    test('no cover id means no cover URL', () {
      expect(_serve('ping_ok').client().coverUri(''), isNull);
    });
  });

  group('malformed and unexpected responses', () {
    Future<SubsonicFound> search(Object result) => _Server(
      (_) => _json({
        'subsonic-response': {'status': 'ok', 'searchResult3': result},
      }),
    ).client().search('x');

    test('numeric ids become string, float duration becomes int', () async {
      final found = await search({
        'song': [
          {
            'id': 4521,
            'title': 'A',
            'artistId': 12,
            'albumId': 77,
            'duration': 6.4,
            'coverArt': 77,
            'track': 3.0,
            'starred': '2026-10-07T03:16:55Z',
          },
        ],
        'album': [
          {'id': 77, 'name': 'B', 'year': 1999.0, 'coverArt': 'al-77'},
        ],
        'artist': [
          {'id': 12, 'name': 'C', 'albumCount': 5},
          {'id': 13, 'name': 'D'},
        ],
      });
      final song = found.songs.single;
      expect(song.id, '4521');
      expect(song.artistId, '12');
      expect(song.albumId, '77');
      expect(song.coverArt, '77');
      expect(song.durationMs, 6000);
      expect(song.track, 3);
      expect(song.starred, isTrue);
      expect(found.albums.single.id, '77');
      expect(found.albums.single.year, 1999);
      expect(found.albums.single.coverArt, 'al-77');
      expect(found.artists.first.id, '12');
      expect(found.artists.first.name, 'C');
      expect(found.artists.first.albumCount, 5);
      expect(found.artists.last.albumCount, 0);
    });

    test('empty track gets empty fields without crashing list', () async {
      final found = await search({
        'song': [
          <String, dynamic>{},
          {'id': 'b', 'title': null, 'duration': 'long', 'track': '7'},
        ],
      });
      expect(found.songs, hasLength(2));
      final song = found.songs.first;
      expect(song.id, '');
      expect(song.title, '');
      expect(song.artist, '');
      expect(song.album, '');
      expect(song.durationMs, 0);
      expect(song.track, isNull);
      expect(song.suffix, '');
      expect(song.coverArt, '');
      expect(song.starred, isFalse);
      expect(found.songs.last.title, '');
      expect(found.songs.last.durationMs, 0);
      expect(found.songs.last.track, isNull);
    });

    test('garbage list entry skipped, invalid list becomes empty', () async {
      final mixed = await search({
        'song': [
          'x',
          7,
          null,
          {'id': 'ok', 'title': 'T'},
          [1],
        ],
        'album': 'none',
        'artist': 7,
      });
      expect(mixed.songs.single.id, 'ok');
      expect(mixed.albums, isEmpty);
      expect(mixed.artists, isEmpty);
      final none = await search('nothing');
      expect(none.songs, isEmpty);
    });

    test('single object instead of list becomes single-item list', () async {
      // Legacy Subsonic servers collapse single-element list into object.
      final found = await search({
        'song': {'id': 's1', 'title': 'Одна'},
        'album': {
          'id': 'a1',
          'name': 'Один',
          'song': {'id': 's1', 'title': 'Одна'},
        },
        'artist': {
          'id': 'r1',
          'name': 'Один',
          'album': {'id': 'a1', 'name': 'Один'},
        },
      });
      expect(found.songs.single.title, 'Одна');
      expect(found.albums.single.songs.single.id, 's1');
      expect(found.artists.single.albums.single.id, 'a1');
      final artists = await _Server(
        (_) => _json({
          'subsonic-response': {
            'status': 'ok',
            'artists': {
              'index': {
                'name': 'A',
                'artist': {'id': 'r1', 'name': 'Один'},
              },
            },
          },
        }),
      ).client().artists();
      expect(artists.single.id, 'r1');
    });

    test('missing section in response gives empty list, no crash', () async {
      Future<T> on<T>(Future<T> Function(SubsonicClient) call) => call(
        _Server(
          (_) => _json({
            'subsonic-response': {'status': 'ok'},
          }),
        ).client(),
      );
      expect((await on((c) => c.search('x'))).songs, isEmpty);
      expect(await on((c) => c.artists()), isEmpty);
      expect(await on((c) => c.starred()), isEmpty);
      expect((await on((c) => c.album('x'))).songs, isEmpty);
      expect((await on((c) => c.artist('x'))).albums, isEmpty);
      expect((await on((c) => c.song('x'))).id, '');
    });
  });
}
