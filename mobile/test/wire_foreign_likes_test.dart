import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_stream/foreign/foreign_library.dart';
import 'package:music_stream/jellyfin_client.dart';
import 'package:music_stream/subsonic_client.dart';

/// FT-780: favorites on foreign server — native remote favorites.
/// (Subsonic star/unstar/getStarred2, Jellyfin UserFavoriteItems).
///
/// Responses recorded from real Navidrome 0.64.2 and Jellyfin 12.2 (FT-648, FT-649).
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

const navidromeSong = '2llbCRtEv5j7BosspiA3xR';
const jellyfinSong = 'd26085522241ca48affd21a482b7d39e';

void main() {
  late List<http.Request> seen;
  setUp(() => seen = []);

  ForeignLibrary navidrome(String fixture) => SubsonicLibrary(
    SubsonicClient(
      base: Uri.parse('http://music.test:4533'),
      auth: const SubsonicAuth.password('tester', 'correct horse'),
      client: MockClient((request) async {
        seen.add(request);
        return _reply('navidrome_0_64_2', fixture);
      }),
    ),
  );

  ForeignLibrary jellyfin(String fixture) => JellyfinLibrary(
    JellyfinClient(
      base: Uri.parse('http://music.test'),
      device: const JellyfinDevice(id: 'dev-1', name: 'Pixel', version: '1'),
      session: const JellyfinSession(
        token: 'tok',
        userId: 'user-1',
        serverId: 'srv-1',
      ),
      client: MockClient((request) async {
        seen.add(request);
        return _reply('jellyfin_12_2', fixture);
      }),
    ),
  );

  test('Navidrome: favorites returns tracks with full cover', () async {
    final liked = await navidrome('starred_one').favorites();
    expect(liked.map((t) => t.id), [navidromeSong]);
    expect(liked.single.title, 'Test Tone Long');
    // In Navidrome fixture this track lacks `coverArt` — cover missing rather than foreign URL.
    expect(
      liked.single.artworkUrl,
      anyOf('', startsWith('http://music.test:4533/')),
    );
    expect(await navidrome('starred_empty').favorites(), isEmpty);
  });

  test('Navidrome: like calls star, unlike calls unstar', () async {
    await navidrome('star').setFavorite(navidromeSong, favorite: true);
    await navidrome('unstar').setFavorite(navidromeSong, favorite: false);
    expect(seen.map((r) => r.url.path), [
      '/rest/star.view',
      '/rest/unstar.view',
    ]);
    expect(
      seen.every((r) => r.url.queryParameters['id'] == navidromeSong),
      isTrue,
    );
  });

  test('Jellyfin: favorites returns app tracks', () async {
    final liked = await jellyfin('favorites_one').favorites();
    expect(liked.map((t) => t.id), [jellyfinSong]);
    expect(liked.single.durationMs, 6000);
    expect(await jellyfin('favorites_empty').favorites(), isEmpty);
  });

  test('Jellyfin: like calls POST, unlike calls DELETE', () async {
    await jellyfin('favorite_add').setFavorite(jellyfinSong, favorite: true);
    await jellyfin(
      'favorite_remove',
    ).setFavorite(jellyfinSong, favorite: false);
    expect(seen.map((r) => '${r.method} ${r.url.path}'), [
      'POST /UserFavoriteItems/$jellyfinSong',
      'DELETE /UserFavoriteItems/$jellyfinSong',
    ]);
  });
}
