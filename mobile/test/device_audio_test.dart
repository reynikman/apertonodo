import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/auth/token_provider.dart';
import 'package:music_stream/device_audio.dart';
import 'package:music_stream/playback.dart';

import 'fakes.dart';

String streamUrl() =>
    'https://music.example.org/v1/stream/${DateTime.now().microsecondsSinceEpoch}';

void main() {
  test('audio source carries notification metadata', () {
    const metadata = AudioMetadata(
      id: 'track-1',
      title: 'Duality',
      artist: 'Slipknot',
      artworkUrl: 'https://example.test/cover.jpg',
    );

    final source = buildAudioSource(
      streamUrl(),
      metadata,
      tokens: tokensFor('https://music.example.org'),
    );
    final item = source.tag as MediaItem;

    expect(item.id, metadata.id);
    expect(item.title, metadata.title);
    expect(item.artist, metadata.artist);
    expect(item.artUri, Uri.parse(metadata.artworkUrl));
    expect(item.artHeaders, isNull);
  });

  // Release build does not know server URL (MUSIC_API_BASE_URL is empty, URL
  // entered at login). Cover was previously built against this empty URL:
  // schemeless path crashed Play before reaching player on every song with cover art.
  test('server cover path resolves against the stream server', () {
    const metadata = AudioMetadata(
      id: 'track-1',
      title: 'Группа крови',
      artist: 'Кино',
      artworkUrl: '/v1/covers/7ff1eff0-a8c8-37dc-807e-eea5a9e173b5',
    );

    final source = buildAudioSource(
      'https://music.example.test/v1/stream/abc',
      metadata,
      tokens: tokensFor('https://music.example.test'),
    );
    final item = source.tag as MediaItem;

    expect(
      item.artUri,
      Uri.parse(
        'https://music.example.test/v1/covers/7ff1eff0-a8c8-37dc-807e-eea5a9e173b5',
      ),
    );
  });

  // FT-535: cached song plays from phone file, while cover art was built
  // against song URL — file:///v1/covers/…, and key check crashed Play
  // ("Экспонат", 03.10). Cover is always from login server, with API key.
  test('a song from the phone takes its cover from the server', () {
    const metadata = AudioMetadata(
      id: 'track-1',
      title: 'Экспонат',
      artist: 'Ленинград',
      artworkUrl: '/v1/covers/f3856e7f-cda3-493a-85b4-d80637c0cc5c',
    );

    final source = buildAudioSource(
      'file:///data/user/0/app/files/music/abc/track.flac',
      metadata,
      tokens: TokenProvider(
        EmptySessionStore()..cachedToken = 'secret-session-token-0123456789',
        server: Uri.parse('https://music.example.test'),
      ),
    );
    final item = source.tag as MediaItem;

    expect(
      item.artUri,
      Uri.parse(
        'https://music.example.test/v1/covers/f3856e7f-cda3-493a-85b4-d80637c0cc5c',
      ),
    );
    expect(item.artHeaders, isNotNull);
  });

  test('empty artwork leaves artUri null', () {
    const metadata = AudioMetadata(
      id: 'track-1',
      title: 'Duality',
      artist: 'Slipknot',
      artworkUrl: '',
    );

    final source = buildAudioSource(
      streamUrl(),
      metadata,
      tokens: tokensFor('https://music.example.org'),
    );
    final item = source.tag as MediaItem;

    expect(item.artUri, isNull);
    expect(item.artHeaders, isNull);
  });
}
