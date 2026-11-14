import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_stream/jellyfin_client.dart';

/// Lead check FT-649. Responses are recordings from real Jellyfin 12.2.0
/// (`test/fixtures/jellyfin_12_2`), captured 07.10.2026; no tokens or passwords in them.
const _dir = 'test/fixtures/jellyfin_12_2';
const _password = 'correct horse';
const _token = 'tok-9f3a7c1e55';
const _user = '89dcd7c0113246fbbb5c27f8c5f80cf7';
const _long = 'd26085522241ca48affd21a482b7d39e';
const _albumId = '9f7ba097b00e0aed7d08b35077047b7d';
const _artistId = 'd02698b82c3d2a13a46ba7ba6ffcc96b';
const _tag = '2b4c23de32cc6f382e5cf5f66851bad8';
const _zero = '00000000000000000000000000000000';
const _session = JellyfinSession(
  token: _token,
  userId: _user,
  serverId: '67abb6f04b91439e9031de53039a3baf',
);
const _device = JellyfinDevice(id: 'dev-1', name: 'Pixel', version: '1.2.3');

Map<String, dynamic> _record(String name) =>
    jsonDecode(File('$_dir/$name.json').readAsStringSync())
        as Map<String, dynamic>;

/// Recorded response: UTF-8 bytes, status and response shape — as from real server.
http.Response _reply(String name) {
  final record = _record(name);
  final body = record.containsKey('json')
      ? jsonEncode(record['json'])
      : (record['text'] as String? ?? '');
  final type = record['content_type'] as String;
  return http.Response.bytes(
    utf8.encode(body),
    record['status'] as int,
    headers: {if (type.isNotEmpty) 'content-type': type.split(';').first},
  );
}

http.Response _json(Object? body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: {'content-type': 'application/json'},
);

class _Server {
  _Server(this.answer);
  final FutureOr<http.Response> Function(http.Request) answer;
  final requests = <http.Request>[];

  JellyfinClient client({
    String base = 'http://music.test:8096',
    JellyfinSession? session = _session,
    JellyfinDevice device = _device,
    Duration timeout = const Duration(seconds: 15),
  }) => JellyfinClient(
    base: Uri.parse(base),
    device: device,
    session: session,
    timeout: timeout,
    client: MockClient((request) async {
      requests.add(request);
      return answer(request);
    }),
  );

  http.Request get one => requests.single;
  Map<String, String> get query => one.url.queryParameters;
}

_Server _serve(String name) => _Server((_) => _reply(name));

Future<JellyfinError> _error(Future<Object?> Function() call) async {
  try {
    await call();
  } on JellyfinError catch (error) {
    return error;
  }
  fail('no error occurred');
}

void main() {
  test('the records hold no token, password or Mac paths', () {
    final index = jsonDecode(File('$_dir/INDEX.json').readAsStringSync());
    final names = (index['records'] as List).cast<String>();
    expect(names, hasLength(48));
    for (final name in names) {
      final text = File('$_dir/$name.json').readAsStringSync();
      expect(text, isNot(contains('/private/')), reason: name);
      expect(text, isNot(contains('claude-')), reason: name);
      expect(text, isNot(contains('nikolay')), reason: name);
      expect(
        RegExp(r'Token=\\"(?!<token>|0{32})').hasMatch(text),
        isFalse,
        reason: name,
      );
    }
    expect(_record('login_ok')['json']['AccessToken'], '<token>');
    expect(_record('login_ok')['request_body']['Pw'], '<password>');
  });

  group('request', () {
    test('auth header: client, device, version, and token', () async {
      final server = _serve('me');
      await server.client().song(_long).catchError((_) => _dummySong);
      expect(
        server.one.headers['Authorization'],
        'MediaBrowser Client="Apertono", Device="Pixel", DeviceId="dev-1", '
        'Version="1.2.3", Token="$_token"',
      );
      expect(server.one.headers.keys.map((k) => k.toLowerCase()), [
        'authorization',
        'accept',
      ]);
      expect(server.one.headers['Accept'], 'application/json');
      expect(server.one.url.toString(), isNot(contains(_token)));
    });

    test('header omits token prior to authentication', () async {
      final server = _serve('public_info');
      await server.client(session: null).info();
      expect(
        server.one.headers['Authorization'],
        'MediaBrowser Client="Apertono", Device="Pixel", DeviceId="dev-1", '
        'Version="1.2.3"',
      );
      expect(server.one.method, 'GET');
      expect(server.one.url.path, '/System/Info/Public');
      expect(server.one.url.hasQuery, isFalse);
    });

    test('device name with Cyrillic and quote is URL-encoded', () async {
      final server = _serve('public_info');
      await server
          .client(
            session: null,
            device: const JellyfinDevice(
              id: 'a b,"c"',
              name: 'Телефон "x", y=1',
              version: '1.0+7',
            ),
          )
          .info();
      final header = server.one.headers['Authorization']!;
      expect(
        header,
        'MediaBrowser Client="Apertono", '
        'Device="${Uri.encodeComponent('Телефон "x", y=1')}", '
        'DeviceId="${Uri.encodeComponent('a b,"c"')}", '
        'Version="${Uri.encodeComponent('1.0+7')}"',
      );
      expect(header.codeUnits.every((c) => c >= 0x20 && c < 0x7f), isTrue);
      expect('"'.allMatches(header), hasLength(8));
    });

    test('URL with base path preserves path without double slashes', () async {
      for (final base in [
        'https://home.test/jf',
        'https://home.test/jf/',
        'https://home.test/jf//',
      ]) {
        final server = _serve('public_info');
        await server.client(base: base, session: null).info();
        expect(server.one.url.scheme, 'https');
        expect(server.one.url.path, '/jf/System/Info/Public', reason: base);
      }
      final plain = _serve('public_info');
      await plain.client(base: 'http://music.test:8096/', session: null).info();
      expect(plain.one.url.path, '/System/Info/Public');
      expect(plain.one.url.port, 8096);
      expect(plain.one.url.host, 'music.test');
    });

    test('login: POST with user and pass in JSON body, not in URL', () async {
      final server = _serve('login_ok');
      await server.client(session: null).login('tester', 'пароль "1"');
      expect(server.one.method, 'POST');
      expect(server.one.url.path, '/Users/AuthenticateByName');
      expect(server.one.url.hasQuery, isFalse);
      expect(
        server.one.headers['Content-Type'],
        startsWith('application/json'),
      );
      expect(jsonDecode(utf8.decode(server.one.bodyBytes)), {
        'Username': 'tester',
        'Pw': 'пароль "1"',
      });
      expect(server.one.headers['Authorization'], isNot(contains('Token')));
    });

    test('search: term, three item types, recursive, limit, user id', () async {
      final server = _serve('search_tone');
      await server.client().search('песня & знак?=#', limit: 7);
      expect(server.one.method, 'GET');
      expect(server.one.url.path, '/Items');
      expect(server.query, {
        'userId': _user,
        'SearchTerm': 'песня & знак?=#',
        'IncludeItemTypes': 'Audio,MusicAlbum,MusicArtist',
        'Recursive': 'true',
        'Limit': '7',
      });
      final byDefault = _serve('search_tone');
      await byDefault.client().search('tone');
      expect(byDefault.query['Limit'], '20');
    });

    test('artists: endpoint, sorted by name, paginated', () async {
      final server = _serve('album_artists');
      await server.client().artists(limit: 30, startIndex: 60);
      expect(server.one.url.path, '/Artists/AlbumArtists');
      expect(server.query, {
        'userId': _user,
        'SortBy': 'SortName',
        'Limit': '30',
        'StartIndex': '60',
      });
      final byDefault = _serve('album_artists');
      await byDefault.client().artists();
      expect(byDefault.query['Limit'], '100');
      expect(byDefault.query['StartIndex'], '0');
    });

    test('artist albums and album songs', () async {
      final albums = _serve('artist_albums');
      await albums.client().albums(_artistId);
      expect(albums.one.url.path, '/Items');
      expect(albums.query, {
        'userId': _user,
        'IncludeItemTypes': 'MusicAlbum',
        'Recursive': 'true',
        'AlbumArtistIds': _artistId,
        'SortBy': 'ProductionYear,SortName',
      });
      final songs = _serve('album_songs');
      await songs.client().songs(_albumId);
      expect(songs.one.url.path, '/Items');
      expect(songs.query, {
        'userId': _user,
        'ParentId': _albumId,
        'IncludeItemTypes': 'Audio',
        'SortBy': 'ParentIndexNumber,IndexNumber,SortName',
      });
    });

    test('single item: id in path as single path segment', () async {
      final song = _serve('song');
      await song.client().song(_long);
      expect(song.one.url.path, '/Items/$_long');
      expect(song.query, {'userId': _user});
      final odd = _Server((_) => _json({'Type': 'Audio', 'Id': 'a/../b?x#y'}));
      await odd.client().song('a/../b?x#y');
      expect(odd.one.url.pathSegments, ['Items', 'a/../b?x#y']);
      expect(odd.query, {'userId': _user});
    });

    test('favorites: list, mark, and unmark', () async {
      final list = _serve('favorites_one');
      await list.client().favorites(limit: 5, startIndex: 10);
      expect(list.one.url.path, '/Items');
      expect(list.query, {
        'userId': _user,
        'IncludeItemTypes': 'Audio',
        'Recursive': 'true',
        'Filters': 'IsFavorite',
        'Limit': '5',
        'StartIndex': '10',
      });
      final add = _serve('favorite_add');
      await add.client().setFavorite(_long, favorite: true);
      expect(add.one.method, 'POST');
      expect(add.one.url.path, '/UserFavoriteItems/$_long');
      expect(add.query, {'userId': _user});
      final remove = _serve('favorite_remove');
      await remove.client().setFavorite(_long, favorite: false);
      expect(remove.one.method, 'DELETE');
      expect(remove.one.url.path, '/UserFavoriteItems/$_long');
    });

    test(
      'logout: POST to /Sessions/Logout, empty 204 response is valid',
      () async {
        final server = _serve('logout');
        await server.client().logout();
        expect(server.one.method, 'POST');
        expect(server.one.url.path, '/Sessions/Logout');
        expect(
          server.one.headers['Authorization'],
          contains('Token="$_token"'),
        );
      },
    );
  });

  group('real Jellyfin responses', () {
    test('server info without authentication', () async {
      final info = await _serve('public_info').client(session: null).info();
      expect(info.id, '67abb6f04b91439e9031de53039a3baf');
      expect(info.name, 'test-server');
      expect(info.version, '12.2.0');
      expect(info.product, 'Jellyfin Server');
    });

    test('login returns token, user, and server', () async {
      final session = await _serve(
        'login_ok',
      ).client(session: null).login('tester', _password);
      expect(session.token, '<token>');
      expect(session.userId, _user);
      expect(session.serverId, '67abb6f04b91439e9031de53039a3baf');
    });

    test('search organizes results by item type', () async {
      final found = await _serve('search_tone').client().search('tone');
      expect(found.songs.map((s) => s.title), [
        'Test Tone Long',
        'Test Tone Short',
      ]);
      expect(found.albums.single.name, 'Test Tones');
      expect(found.artists, isEmpty);
      final song = found.songs.first;
      expect(song.id, _long);
      expect(song.artist, 'Apertono');
      expect(song.artistId, _artistId);
      expect(song.album, 'Test Tones');
      expect(song.albumId, _albumId);
      expect(song.durationMs, 6000);
      expect(song.track, 1);
      expect(song.favorite, isFalse);
      expect(song.imageItemId, _albumId);
      expect(song.imageTag, _tag);
      final album = found.albums.single;
      expect(album.id, _albumId);
      expect(album.artist, 'Apertono');
      expect(album.artistId, _artistId);
      expect(album.year, 2026);
      expect(album.imageTag, _tag);
    });

    test('Cyrillic in response and empty result set', () async {
      final found = await _serve('search_cyrillic').client().search('песня');
      expect(found.songs.single.title, 'Песня & знак');
      expect(found.songs.single.artist, 'Второй Исполнитель');
      expect(found.songs.single.album, 'Альбом с кириллицей');
      expect(found.songs.single.durationMs, 3000);
      expect(found.songs.single.imageTag, '');
      final none = await _serve('search_nothing').client().search('zzzz');
      expect(none.songs, isEmpty);
      expect(none.albums, isEmpty);
      expect(none.artists, isEmpty);
    });

    test('Cyrillic parsed even without Content-Type header', () async {
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

    test('artists page includes total record count', () async {
      final page = await _serve('album_artists').client().artists();
      expect(page.total, 2);
      expect(page.items.map((a) => a.name), ['Apertono', 'Второй Исполнитель']);
      expect(page.items.first.id, _artistId);
      expect(page.items.first.imageTag, '');
    });

    test('total count taken from server, not page length', () async {
      final paged = _record('songs_paged')['json'] as Map<String, dynamic>;
      expect(paged['TotalRecordCount'], 3);
      final page = await _Server((_) => _json(paged)).client().favorites();
      expect(page.items, hasLength(1));
      expect(page.total, 3);
    });

    test('artist albums and album lookup by id', () async {
      final albums = await _serve('artist_albums').client().albums(_artistId);
      expect(albums.single.name, 'Test Tones');
      expect(albums.single.year, 2026);
      final album = await _serve('album').client().album(_albumId);
      expect(album.id, _albumId);
      expect(album.name, 'Test Tones');
      expect(album.songCount, 2);
      expect(album.artistId, _artistId);
    });

    test('album songs in server order and song lookup by id', () async {
      final songs = await _serve('album_songs').client().songs(_albumId);
      expect(songs.map((s) => s.title), ['Test Tone Long', 'Test Tone Short']);
      expect(songs.map((s) => s.track), [1, 2]);
      expect(songs.last.durationMs, 2000);
      final song = await _serve('song').client().song(_long);
      expect(song.title, 'Test Tone Long');
      expect(song.container, 'mp3');
      expect(song.durationMs, 6000);
    });

    test('favorites: empty, marked song, empty again', () async {
      final empty = await _serve('favorites_empty').client().favorites();
      expect(empty.items, isEmpty);
      expect(empty.total, 0);
      final one = await _serve('favorites_one').client().favorites();
      expect(one.items.single.title, 'Test Tone Long');
      expect(one.items.single.favorite, isTrue);
      expect(one.total, 1);
      final after = await _serve('favorites_after_remove').client().favorites();
      expect(after.items, isEmpty);
    });

    test('marking favorite repeatedly succeeds without error', () async {
      await _serve('favorite_add').client().setFavorite(_long, favorite: true);
      await _serve(
        'favorite_add_twice',
      ).client().setFavorite(_long, favorite: true);
      await _serve(
        'favorite_remove',
      ).client().setFavorite(_long, favorite: false);
    });
  });

  group('edge cases of real server responses', () {
    test(
      'nonexistent id: server returns root folder mapped to not found',
      () async {
        expect(_record('item_missing')['status'], 200);
        for (final call in <Future<Object?> Function(JellyfinClient)>[
          (c) => c.song(_zero),
          (c) => c.album(_zero),
        ]) {
          final error = await _error(
            () => call(_serve('item_missing').client()),
          );
          expect(error.kind, JellyfinFailure.notFound);
        }
      },
    );

    test(
      'album in place of song and song as album are mapped to not found',
      () async {
        final asSong = await _error(
          () => _serve('album').client().song(_albumId),
        );
        expect(asSong.kind, JellyfinFailure.notFound);
        final asAlbum = await _error(
          () => _serve('song').client().album(_long),
        );
        expect(asAlbum.kind, JellyfinFailure.notFound);
      },
    );

    test(
      'server returned different item than requested: mapped to not found',
      () async {
        final error = await _error(() => _serve('song').client().song(_zero));
        expect(error.kind, JellyfinFailure.notFound);
      },
    );

    test('response without id for empty id mapped to not found', () async {
      final error = await _error(
        () => _Server((_) => _json({'Type': 'Audio'})).client().song(''),
      );
      expect(error.kind, JellyfinFailure.notFound);
    });

    test('id with hyphens and uppercase maps to same item', () async {
      const dashed = 'D2608552-2241-CA48-AFFD-21A482B7D39E';
      final song = await _serve('song').client().song(dashed);
      expect(song.id, _long);
      await _serve('favorite_add').client().setFavorite(dashed, favorite: true);
    });

    test(
      'favorite nonexistent song: server returns 200 for another item',
      () async {
        expect(_record('favorite_add_missing')['status'], 200);
        final error = await _error(
          () => _serve(
            'favorite_add_missing',
          ).client().setFavorite(_zero, favorite: true),
        );
        expect(error.kind, JellyfinFailure.notFound);
      },
    );

    test('foreign item types are skipped in lists', () async {
      final mixed = _Server((_) => _reply('search_tone'));
      expect(await mixed.client().songs(_albumId), hasLength(2));
      expect(await mixed.client().albums(_artistId), hasLength(1));
      final favorites = await mixed.client().favorites();
      expect(favorites.items, hasLength(2));
      expect(favorites.total, 3);
    });
  });

  group('failures', () {
    test('wrong password or unknown user returns 401 auth failure', () async {
      for (final name in ['login_wrong_password', 'login_wrong_user']) {
        final error = await _error(
          () => _serve(name).client(session: null).login('tester', 'x'),
        );
        expect(error.kind, JellyfinFailure.auth, reason: name);
        expect(error.status, 401);
      }
    });

    test('invalid, missing or revoked token returns auth failure', () async {
      for (final name in ['me_wrong_token', 'me_no_token', 'me_after_logout']) {
        final error = await _error(() => _serve(name).client().song(_long));
        expect(error.kind, JellyfinFailure.auth, reason: name);
        expect(error.status, 401);
      }
    });

    test('unauthenticated catalog requests are not dispatched', () async {
      final calls = <Future<Object?> Function(JellyfinClient)>[
        (c) => c.search('x'),
        (c) => c.artists(),
        (c) => c.albums('a'),
        (c) => c.album('a'),
        (c) => c.songs('a'),
        (c) => c.song('a'),
        (c) => c.favorites(),
        (c) => c.setFavorite('a', favorite: true),
        (c) => c.logout(),
        (c) async => c.streamUri('a'),
      ];
      for (final call in calls) {
        final server = _serve('me');
        final error = await _error(() => call(server.client(session: null)));
        expect(error.kind, JellyfinFailure.auth);
        expect(error.status, isNull);
        expect(server.requests, isEmpty);
      }
    });

    test('HTTP status codes mapped to error categories', () async {
      const kinds = {
        400: JellyfinFailure.refused,
        401: JellyfinFailure.auth,
        403: JellyfinFailure.forbidden,
        404: JellyfinFailure.notFound,
        409: JellyfinFailure.refused,
        429: JellyfinFailure.refused,
        302: JellyfinFailure.refused,
        500: JellyfinFailure.unavailable,
        502: JellyfinFailure.unavailable,
        503: JellyfinFailure.unavailable,
      };
      for (final entry in kinds.entries) {
        for (final body in ['', '<html>x</html>', '{"Items": []}']) {
          final error = await _error(
            () => _Server(
              (_) => http.Response(body, entry.key),
            ).client().search('x'),
          );
          expect(error.kind, entry.value, reason: '${entry.key}');
          expect(error.status, entry.key);
        }
      }
    });

    test(
      'recorded failures: bad id 400, missing path 404, missing header 400',
      () async {
        final bad = await _error(
          () => _serve('item_bad_id').client().song('x'),
        );
        expect(bad.kind, JellyfinFailure.refused);
        expect(bad.status, 400);
        final path = await _error(
          () => _serve('unknown_path').client().song('x'),
        );
        expect(path.kind, JellyfinFailure.notFound);
        final header = await _error(
          () => _serve(
            'login_no_client_header',
          ).client(session: null).login('tester', 'x'),
        );
        expect(header.kind, JellyfinFailure.refused);
      },
    );

    test('not Jellyfin: HTML page, empty, list, wrong object', () async {
      final answers = <String, http.Response Function()>{
        'html': () => http.Response('<html>login</html>', 200),
        'empty': () => http.Response('', 200),
        'list': () => _json([1, 2]),
        'string': () => _json('ok'),
        'null': () => http.Response('null', 200),
      };
      for (final entry in answers.entries) {
        for (final call in <Future<Object?> Function(JellyfinClient)>[
          (c) => c.info(),
          (c) => c.search('x'),
          (c) => c.song('x'),
          (c) => c.setFavorite('x', favorite: true),
          (c) => c.login('a', 'b'),
        ]) {
          final error = await _error(
            () => call(_Server((_) => entry.value()).client()),
          );
          expect(error.kind, JellyfinFailure.notJellyfin, reason: entry.key);
        }
      }
    });

    test(
      'info without id or version and login without token is not Jellyfin',
      () async {
        for (final body in [
          {'Version': '12.2.0'},
          {'Id': 'abc'},
          {'Id': '', 'Version': '12.2.0'},
          {'Id': 7, 'Version': 12},
          {'status': 'ok'},
        ]) {
          final error = await _error(
            () => _Server((_) => _json(body)).client(session: null).info(),
          );
          expect(error.kind, JellyfinFailure.notJellyfin, reason: '$body');
        }
        for (final body in [
          {
            'User': {'Id': _user},
          },
          {'AccessToken': 't'},
          {
            'AccessToken': '',
            'User': {'Id': _user},
          },
          {'AccessToken': 't', 'User': 'x'},
        ]) {
          final error = await _error(
            () => _Server(
              (_) => _json(body),
            ).client(session: null).login('a', 'b'),
          );
          expect(error.kind, JellyfinFailure.notJellyfin, reason: '$body');
        }
      },
    );

    test('Emby: server info without product name is accepted', () async {
      final info = await _Server(
        (_) => _json({'Id': 'e1', 'Version': '4.8.0', 'ServerName': 'emby'}),
      ).client(session: null).info();
      expect(info.product, '');
      expect(info.name, 'emby');
    });

    test('offline or timeout mapped to unavailable failure', () async {
      for (final Object thrown in [
        http.ClientException('refused'),
        const SocketException('no route'),
        const HandshakeException('bad cert'),
        ArgumentError('bad header'),
      ]) {
        final error = await _error(
          () => _Server((_) => throw thrown).client().search('x'),
        );
        expect(error.kind, JellyfinFailure.unavailable, reason: '$thrown');
        expect(error.status, isNull);
      }
      final never = Completer<http.Response>();
      final late = await _error(
        () => _Server(
          (_) => never.future,
        ).client(timeout: const Duration(milliseconds: 30)).search('x'),
      ).timeout(const Duration(seconds: 5));
      expect(late.kind, JellyfinFailure.unavailable);
      expect(
        JellyfinClient(
          base: Uri.parse('http://music.test'),
          device: _device,
          client: MockClient((_) async => _reply('me')),
        ).timeout,
        const Duration(seconds: 15),
      );
    });

    test('error and session strings omit host, user, password, token', () async {
      final texts = <String>[
        '${await _error(() => _serve('me_wrong_token').client().song(_long))}',
        '${await _error(() => _serve('login_wrong_password').client(session: null).login('tester', _password))}',
        '${await _error(() => _Server((_) => throw http.ClientException('http://music.test:8096/Items?ApiKey=$_token')).client().search('x'))}',
        '${await _error(() => _serve('item_bad_id').client().song('x'))}',
        '$_session',
      ];
      for (final text in texts) {
        for (final secret in [
          'music.test',
          'tester',
          _password,
          _token,
          _user,
          'Error processing',
          'validation',
          '?',
        ]) {
          expect(text, isNot(contains(secret)), reason: text);
        }
      }
      expect(texts.first, 'JellyfinError(auth, 401)');
      expect(
        '${const JellyfinError(JellyfinFailure.notJellyfin)}',
        'JellyfinError(notJellyfin)',
      );
    });
  });

  group('stream and image URLs', () {
    test('stream: raw file, token as ApiKey query parameter', () {
      // Recordings: `api_key` and X-Emby-Token header rejected by Jellyfin 12 (401),
      // `ApiKey` accepted.
      expect(_record('me_query_api_key')['status'], 401);
      expect(_record('me_query_ApiKey')['status'], 200);
      final server = _serve('me');
      final url = server.client(base: 'https://home.test/jf/').streamUri(_long);
      expect(server.requests, isEmpty);
      expect(url.scheme, 'https');
      expect(url.path, '/jf/Audio/$_long/stream');
      expect(url.queryParameters, {'static': 'true', 'ApiKey': _token});
    });

    test('song id in stream URL formatted as single path chunk', () {
      final url = _serve('me').client().streamUri('a/../b?x');
      expect(url.pathSegments, ['Audio', 'a/../b?x', 'stream']);
      expect(url.queryParameters['ApiKey'], _token);
    });

    test('image: without auth, includes tag and maxWidth', () {
      final client = _serve('me').client(base: 'https://home.test/jf');
      final url = client.imageUri(_albumId, _tag, maxWidth: 300)!;
      expect(url.path, '/jf/Items/$_albumId/Images/Primary');
      expect(url.queryParameters, {'maxWidth': '300', 'tag': _tag});
      expect(
        client.imageUri(_albumId, _tag)!.queryParameters['maxWidth'],
        '600',
      );
      expect(url.toString(), isNot(contains(_token)));
    });

    test('image built before login; missing tag or id produces null', () {
      final client = _serve('me').client(session: null);
      expect(client.imageUri(_albumId, _tag), isNotNull);
      expect(client.imageUri(_albumId, ''), isNull);
      expect(client.imageUri('', _tag), isNull);
    });
  });

  group('malformed responses', () {
    Future<JellyfinFound> search(Object? items) =>
        _Server((_) => _json({'Items': items})).client().search('x');

    test('song primary image takes precedence over album image', () async {
      final found = await search([
        {
          'Type': 'Audio',
          'Id': 's1',
          'AlbumId': 'a1',
          'AlbumPrimaryImageTag': 'album-tag',
          'ImageTags': {'Primary': 'own-tag'},
        },
        {'Type': 'Audio', 'Id': 's2', 'AlbumId': 'a1', 'ImageTags': 'x'},
      ]);
      expect(found.songs.first.imageItemId, 's1');
      expect(found.songs.first.imageTag, 'own-tag');
      expect(found.songs.last.imageItemId, 'a1');
      expect(found.songs.last.imageTag, '');
    });

    test(
      'comma-separated artists; missing list falls back to album artist',
      () async {
        final found = await search([
          {
            'Type': 'Audio',
            'Artists': ['A', '', 7, 'B'],
            'ArtistItems': [
              {'Name': 'A', 'Id': 'ida'},
              {'Name': 'B', 'Id': 'idb'},
            ],
            'AlbumArtist': 'Z',
          },
          {'Type': 'Audio', 'Artists': <String>[], 'AlbumArtist': 'Z'},
          {'Type': 'Audio', 'Artists': 'A', 'AlbumArtist': 'Z'},
        ]);
        expect(found.songs[0].artist, 'A, B');
        expect(found.songs[0].artistId, 'ida');
        expect(found.songs[1].artist, 'Z');
        expect(found.songs[1].artistId, '');
        expect(found.songs[2].artist, 'Z');
      },
    );

    test('duration: ticks to ms, invalid or negative is zero', () async {
      final found = await search([
        {'Type': 'Audio', 'RunTimeTicks': 2345678901},
        {'Type': 'Audio', 'RunTimeTicks': 69999.0},
        {'Type': 'Audio', 'RunTimeTicks': -50000},
        {'Type': 'Audio', 'RunTimeTicks': '60000000'},
        {'Type': 'Audio'},
      ]);
      expect(found.songs.map((s) => s.durationMs), [234567, 6, 0, 0, 0]);
    });

    test(
      'Jellyfin lists and search omit song count: unknown, not zero',
      () async {
        final found = await _serve('search_tone').client().search('tone');
        expect(found.albums, isNotEmpty);
        expect(found.albums.map((a) => a.songCount), everyElement(isNull));
        final albums = await _serve('artist_albums').client().albums(_artistId);
        expect(albums, isNotEmpty);
        expect(albums.map((a) => a.songCount), everyElement(isNull));
      },
    );

    test(
      'credentials from server URL omitted from requests and stream URL',
      () async {
        final server = _serve('public_info');
        final client = server.client(
          base: 'http://alice:secret@music.test:8096',
        );
        await client.info();
        expect(server.one.url.userInfo, '');
        expect(client.streamUri(_long).userInfo, '');
        expect(client.imageUri(_albumId, _tag)!.userInfo, '');
      },
    );

    test('out of range numbers (1e400) do not crash parsing', () async {
      const body =
          '{"Items":[{"Type":"Audio","Id":"s1","RunTimeTicks":1e400,"IndexNumber":1e400,'
          '"ParentIndexNumber":-1e400},{"Type":"MusicAlbum","Id":"a1","ProductionYear":1e400,'
          '"ChildCount":1e400}],"TotalRecordCount":1e400}';
      final server = _Server((_) => http.Response(body, 200));
      final found = await server.client().search('x');
      expect(found.songs.single.durationMs, 0);
      expect(found.songs.single.track, isNull);
      expect(found.songs.single.disc, isNull);
      expect(found.albums.single.year, isNull);
      expect(found.albums.single.songCount, isNull);
      final page = await _Server(
        (_) => http.Response(body, 200),
      ).client().favorites();
      expect(page.total, 1);
    });

    test('login: non-string server id clears to empty without error', () async {
      for (final Object? id in [
        7,
        true,
        ['x'],
        {'a': 1},
        null,
      ]) {
        final server = _Server(
          (_) => _json({
            'AccessToken': _token,
            'ServerId': id,
            'User': {'Id': _user, 'ServerId': id},
          }),
        );
        final session = await server
            .client(session: null)
            .login('u', _password);
        expect(session.serverId, '', reason: '$id');
        expect(session.userId, _user);
      }
    });

    test('empty item receives empty fields without crashing parser', () async {
      final found = await search([
        {'Type': 'Audio'},
        {'Type': 'MusicAlbum', 'AlbumArtists': 'x', 'ChildCount': '2'},
        {'Type': 'MusicArtist', 'Id': 7, 'Name': null},
        {'Type': 'Audio', 'ParentIndexNumber': 2, 'IndexNumber': 3.0},
      ]);
      final song = found.songs.first;
      expect(song.id, '');
      expect(song.title, '');
      expect(song.artist, '');
      expect(song.album, '');
      expect(song.albumId, '');
      expect(song.track, isNull);
      expect(song.disc, isNull);
      expect(song.container, '');
      expect(song.imageItemId, '');
      expect(song.imageTag, '');
      expect(song.favorite, isFalse);
      expect(found.songs.last.disc, 2);
      expect(found.songs.last.track, 3);
      expect(found.albums.single.artistId, '');
      expect(found.albums.single.songCount, isNull);
      expect(found.albums.single.year, isNull);
      expect(found.artists.single.id, '');
      expect(found.artists.single.name, '');
    });

    test(
      'corrupted list entries skipped; non-list or absent returns empty',
      () async {
        final mixed = await search([
          'x',
          7,
          null,
          {'Type': 'Audio', 'Id': 'ok'},
          {'Type': 'Video', 'Id': 'film'},
          {'Id': 'no-type'},
          [1],
        ]);
        expect(mixed.songs.single.id, 'ok');
        expect(mixed.albums, isEmpty);
        expect((await search('none')).songs, isEmpty);
        expect((await search(null)).songs, isEmpty);
        final page = await _Server(
          (_) => _json({'TotalRecordCount': 'many'}),
        ).client().artists();
        expect(page.items, isEmpty);
        expect(page.total, 0);
      },
    );

    test('total count smaller than page or invalid uses page count', () async {
      for (final total in [0, -1, 'x', null, 1.5]) {
        final page = await _Server(
          (_) => _json({
            'TotalRecordCount': total,
            'Items': [
              {'Type': 'Audio', 'Id': 'a'},
              {'Type': 'Audio', 'Id': 'b'},
            ],
          }),
        ).client().favorites();
        expect(page.total, 2, reason: '$total');
      }
    });

    test('favorite flag requires literal boolean true', () async {
      final found = await search([
        {
          'Type': 'Audio',
          'UserData': {'IsFavorite': true},
        },
        {
          'Type': 'Audio',
          'UserData': {'IsFavorite': 'true'},
        },
        {'Type': 'Audio', 'UserData': 'x'},
      ]);
      expect(found.songs.map((s) => s.favorite), [true, false, false]);
    });
  });
}

const _dummySong = JellyfinSong(
  id: '',
  title: '',
  artist: '',
  artistId: '',
  album: '',
  albumId: '',
  durationMs: 0,
  track: null,
  disc: null,
  container: '',
  imageItemId: '',
  imageTag: '',
  favorite: false,
);
