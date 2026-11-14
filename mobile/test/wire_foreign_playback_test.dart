import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:just_audio/just_audio.dart';
import 'package:music_stream/auth/token_provider.dart';
import 'package:music_stream/device_audio.dart';
import 'package:music_stream/foreign/foreign_library.dart';
import 'package:music_stream/foreign/foreign_playback.dart';
import 'package:music_stream/jellyfin_client.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/subsonic_client.dart';

import 'fakes.dart';

/// FT-778: audio stream and artwork from foreign server.
///
/// Foreign server authenticates in query params (Subsonic `u/t/s`, Jellyfin `ApiKey`) —
/// required by their stream protocol. Our auth token never sent to them: neither in
/// stream header nor notification artwork header.
void main() {
  var asked = 0;
  final quiet = MockClient((_) async {
    asked++;
    return http.Response('', 500);
  });

  ForeignLibrary navidrome() => SubsonicLibrary(
    SubsonicClient(
      base: Uri.parse('http://192.168.1.10:4533'),
      auth: const SubsonicAuth.password('anna', 'correct horse'),
      client: quiet,
    ),
  );

  ForeignLibrary jellyfin() => JellyfinLibrary(
    JellyfinClient(
      base: Uri.parse('http://192.168.1.11:8096'),
      device: const JellyfinDevice(id: 'dev-1', name: 'Pixel', version: '1'),
      session: const JellyfinSession(
        token: 'jf-token',
        userId: 'user-1',
        serverId: 'srv-1',
      ),
      client: quiet,
    ),
  );

  setUp(() => asked = 0);

  test('Navidrome: Play gets foreign stream URL with auth query', () async {
    final url = Uri.parse(await ForeignPlayback(navidrome()).start('song-1'));
    expect(url.host, '192.168.1.10');
    expect(url.path, contains('/rest/stream'));
    expect(url.queryParameters['id'], 'song-1');
    expect(url.queryParameters['u'], 'anna');
    expect(url.queryParameters['p'], isNull, reason: 'plaintext password');
    expect(url.queryParameters['t'], isNotEmpty);
    expect(asked, 0, reason: 'stream URL constructed without request');
  });

  test('Jellyfin: Play gets stream URL with ApiKey', () async {
    final url = Uri.parse(await ForeignPlayback(jellyfin()).start('song-2'));
    expect(url.host, '192.168.1.11');
    expect(url.path, contains('song-2'));
    expect(
      url.queryParameters['ApiKey'] ?? url.queryParameters['api_key'],
      'jf-token',
    );
  });

  test(
    'foreign track not on device and failures not reported to own server',
    () async {
      final playback = ForeignPlayback(navidrome());
      expect(await playback.isLocal('song-1'), isFalse);
      await playback.failed('http://192.168.1.10:4533/rest/stream?id=1&t=x');
      expect(asked, 0);
    },
  );

  test('own token never sent to foreign server with stream or cover', () async {
    final playback = ForeignPlayback(navidrome());
    final url = await playback.start('song-1');
    final ours = TokenProvider(
      EmptySessionStore()..cachedToken = 'secret-session-token-0123456789',
      server: Uri.parse('https://music.example.org'),
    );
    final source =
        buildAudioSource(
              url,
              const AudioMetadata(
                id: 'song-1',
                title: 'Test Tone Long',
                artist: 'Apertono',
                artworkUrl:
                    'http://192.168.1.10:4533/rest/getCoverArt?id=al-1&u=anna',
              ),
              tokens: ours,
            )
            as UriAudioSource;
    expect(source.headers, anyOf(isNull, isEmpty));
    final item = source.tag as MediaItem;
    expect(item.artUri?.host, '192.168.1.10');
    expect(item.artHeaders, isNull);
  });
}
