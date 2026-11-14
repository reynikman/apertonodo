import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_stream/catalog.dart';
import 'package:music_stream/foreign/foreign_library.dart';
import 'package:music_stream/jellyfin_client.dart';
import 'package:music_stream/subsonic_client.dart';

/// FT-777: catalog and search on foreign server — via common [ForeignLibrary].
///
/// Responses recorded from real Navidrome 0.64.2 and Jellyfin 12.2 (FT-648, FT-649),
/// without credentials. Track mapped to app model [Track]: duration in ms,
/// cover URL is full foreign server address.
http.Response _reply(String dir, String name) {
  final record =
      jsonDecode(File('test/fixtures/$dir/$name.json').readAsStringSync())
          as Map<String, dynamic>;
  final body = record.containsKey('json')
      ? jsonEncode(record['json'])
      : (record['text'] as String? ?? '');
  final type = (record['content_type'] as String? ?? '').split(';').first;
  return http.Response.bytes(
    utf8.encode(body),
    record['status'] as int,
    headers: {if (type.isNotEmpty) 'content-type': type},
  );
}

ForeignLibrary _navidrome(String fixture) => SubsonicLibrary(
  SubsonicClient(
    base: Uri.parse('http://music.test:4533'),
    auth: const SubsonicAuth.password('tester', 'correct horse'),
    client: MockClient((_) async => _reply('navidrome_0_64_2', fixture)),
  ),
);

/// Jellyfin routes: `/Items/{id}` — album itself, `/Items?ParentId=` — album tracks.
http.Response _jellyfinRoute(http.Request request, String fixture) {
  final path = request.url.path;
  if (path.startsWith('/Items/')) return _reply('jellyfin_12_2', 'album');
  if (request.url.queryParameters.containsKey('ParentId')) {
    return _reply('jellyfin_12_2', 'album_songs');
  }
  return _reply('jellyfin_12_2', fixture);
}

ForeignLibrary _jellyfin(String fixture) => JellyfinLibrary(
  JellyfinClient(
    base: Uri.parse('http://music.test'),
    device: const JellyfinDevice(id: 'dev-1', name: 'Pixel', version: '1'),
    session: const JellyfinSession(
      token: 'tok',
      userId: 'user-1',
      serverId: 'srv-1',
    ),
    client: MockClient((request) async => _jellyfinRoute(request, fixture)),
  ),
);

void main() {
  test('Navidrome: search returns app tracks', () async {
    final found = await ForeignCatalog(
      _navidrome('search_tone'),
    ).search('tone');
    final long = found.tracks.firstWhere((t) => t.title == 'Test Tone Long');
    expect(long.id, '2llbCRtEv5j7BosspiA3xR');
    expect(long.artist, 'Apertono');
    expect(long.durationMs, 6000);
  });

  test('Jellyfin: search returns app tracks', () async {
    final found = await ForeignCatalog(_jellyfin('search_tone')).search('tone');
    final long = found.tracks.firstWhere((t) => t.title == 'Test Tone Long');
    expect(long.id, 'd26085522241ca48affd21a482b7d39e');
    expect(long.artist, 'Apertono');
    expect(long.durationMs, 6000, reason: 'RunTimeTicks / 10 000');
  });

  test('suggestions on foreign server: empty and no network', () async {
    var asked = 0;
    final library = SubsonicLibrary(
      SubsonicClient(
        base: Uri.parse('http://music.test:4533'),
        auth: const SubsonicAuth.password('tester', 'x'),
        client: MockClient((_) async {
          asked++;
          return http.Response('', 500);
        }),
      ),
    );
    expect(await ForeignCatalog(library).suggest('met'), isEmpty);
    expect(asked, 0);
  });

  test('Navidrome: album tracks ordered with full cover url', () async {
    final album = await _navidrome('album').album('5w43XUdYrcWMCGWoPzXK7t');
    expect(album.title, 'Test Tones');
    expect(album.tracks, hasLength(2));
    if (album.coverUrl.isNotEmpty) {
      expect(Uri.parse(album.coverUrl).host, 'music.test');
    }
  });

  test('Jellyfin: album tracks', () async {
    final album = await _jellyfin(
      'search_tone',
    ).album('9f7ba097b00e0aed7d08b35077047b7d');
    expect(album.tracks, hasLength(2));
    expect(album.tracks.first.title, 'Test Tone Long');
  });

  test('foreign server error returns SearchFailed, no crash', () async {
    final library = SubsonicLibrary(
      SubsonicClient(
        base: Uri.parse('http://music.test:4533'),
        auth: const SubsonicAuth.password('tester', 'x'),
        client: MockClient((_) async => http.Response('nope', 503)),
      ),
    );
    await expectLater(
      ForeignCatalog(library).search('tone'),
      throwsA(isA<SearchFailed>()),
    );
  });
}
