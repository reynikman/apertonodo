import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'auth/token_provider.dart';
import 'lossless_once.dart';
import 'track_formats.dart';

/// Why Play did not produce audio.
///
/// Previously any failure was a single "Failed — retry" string: impossible
/// to tell whether retry would help and what broke — network, server, or source.
enum PlayFailure {
  /// Server did not find a source for the track (409). Retry sometimes helps:
  /// indexer might be empty, and silent release goes last on retry.
  noSource,

  /// Server does not know track (404): results are stale, new search needed.
  unknownTrack,

  /// Build key does not match server (401). Retry won't help.
  noAccess,

  /// Server didn't respond in time or failed: network, 5xx, timeout.
  noAnswer,

  /// Stream opened, but dropped in the middle of track.
  dropped,

  /// Player failed to open stream.
  player,
}

class PlaybackFailed implements Exception {
  const PlaybackFailed(this.reason);

  final PlayFailure reason;

  @override
  String toString() => 'PlaybackFailed(${reason.name})';
}

abstract class PlaybackPort {
  /// Stream URL for track. On failure — [PlaybackFailed] with reason.
  ///
  /// [prepare] — next track in queue while current is playing: server searches
  /// only its own list and doesn't query the source.
  Future<String> start(String trackId, {bool prepare = false});

  /// Track is already on device. Then prepared stream URL
  /// is not needed: it would be taken without network anyway (FT-530).
  Future<bool> isLocal(String trackId);

  /// Notify server that stream failed to play (FT-546).
  Future<void> failed(String url);
}

enum AudioPhase { idle, buffering, playing, paused, error }

class AudioStatus {
  const AudioStatus({
    required this.phase,
    this.position = Duration.zero,
    this.duration,
    this.completed = false,
    this.advanced = false,
  });

  final AudioPhase phase;
  final Duration position;
  final Duration? duration;

  /// Track finished playing to the end. Phase is [AudioPhase.idle], and without
  /// this flag track end is indistinguishable from "haven't started yet".
  final bool completed;

  /// Player automatically transitioned to queued next track.
  final bool advanced;
}

class AudioMetadata {
  const AudioMetadata({
    required this.id,
    required this.title,
    required this.artist,
    required this.artworkUrl,
  });

  final String id;
  final String title;
  final String artist;
  final String artworkUrl;
}

abstract class AudioPort {
  Stream<AudioStatus> get states;

  /// Current player position. From this second "retry" resumes after interruption.
  Duration get position;

  /// Position while playing: seek bar moves along it.
  Stream<Duration> get positions;

  /// "Forward" and "backward" buttons in shade, on lock screen and on
  /// headset. `null` — nowhere to go: button stays in place and does nothing (FT-744).
  /// [pause] — what the system pause does (FT-858): through the queue player,
  /// so a pause while the song is still loading stops the loading.
  void setSkips({
    Future<void> Function()? next,
    Future<void> Function()? previous,
    Future<void> Function()? pause,
  });

  Future<void> playUrl(
    String url,
    AudioMetadata metadata, {
    Duration from = Duration.zero,
  });

  /// Queue track immediately after current; repeated call replaces queued one.
  Future<void> queueNext(String url, AudioMetadata metadata);

  /// Remove queued track.
  Future<void> clearNext();

  Future<void> pause();

  /// Stop playback and release the current stream on account change.
  Future<void> stop();

  Future<void> resume();

  Future<void> seek(Duration position);

  /// Audio speed: 1.0 is normal. Persists until changed (FT-730).
  Future<void> setSpeed(double speed);

  /// Audio volume: 1.0 is normal. Persists until changed (FT-765).
  Future<void> setVolume(double volume);
}

class HttpPlayback implements PlaybackPort {
  HttpPlayback(
    this.baseUrl, {
    required this.tokens,
    http.Client? client,
    this.timeout = playbackTimeout,
    this.preferOpus,
    this.preferLossless,
    this.formats,
    this.losslessOnce,
  }) : _client = client ?? http.Client();

  /// Server bounds Play click to 50 seconds, proxies in front drop response
  /// at 60s. Own limit is last resort: without it network hanging
  /// in the middle left "Buffering" forever.
  static const playbackTimeout = Duration(seconds: 70);

  final String baseUrl;
  final TokenProvider tokens;
  final Duration timeout;
  final Future<bool> Function()? preferOpus;

  /// "Prefer lossless" (FT-633): server ranks FLAC releases first.
  final bool Function()? preferLossless;

  /// Where to store file format from Play response — for badge in player.
  final TrackFormats? formats;

  /// One-time request "this track lossless" (FT-809).
  final LosslessOnce? losslessOnce;
  final http.Client _client;

  @override
  Future<bool> isLocal(String trackId) async => false;

  @override
  Future<String> start(String trackId, {bool prepare = false}) async {
    final http.Response response;
    final uri = Uri.parse('$baseUrl/v1/playback');
    try {
      final opus = preferOpus != null && await preferOpus!();
      // User request overrides saving; prepare doesn't read or consume it.
      final once = !prepare && (losslessOnce?.take(trackId) ?? false);
      final lossless = once || (!opus && (preferLossless?.call() ?? false));
      response = await _client
          .post(
            uri,
            headers: {
              'content-type': 'application/json',
              ...tokens.headersFor(uri),
            },
            body: jsonEncode({
              'track_id': trackId,
              if (prepare) 'prepare': true,
              if (opus && !lossless) 'prefer': 'opus',
              if (lossless) 'prefer': 'lossless',
            }),
          )
          .timeout(timeout);
    } on Exception {
      // Timeout, network drop, proxy connection reset.
      throw const PlaybackFailed(PlayFailure.noAnswer);
    }
    if (response.statusCode == 401) {
      await tokens.onUnauthorized();
    }
    switch (response.statusCode) {
      case 200:
        break;
      case 409:
        throw const PlaybackFailed(PlayFailure.noSource);
      case 404:
        throw const PlaybackFailed(PlayFailure.unknownTrack);
      case 401:
        throw const PlaybackFailed(PlayFailure.noAccess);
      default:
        throw const PlaybackFailed(PlayFailure.noAnswer);
    }
    final token = _token(response.body);
    if (token == null || token.isEmpty) {
      throw const PlaybackFailed(PlayFailure.noAnswer);
    }
    if (formats case final formats?) {
      formats.note(trackId, _audio(response.body));
    }
    return '$baseUrl/v1/stream/$token';
  }

  Object? _audio(String body) {
    try {
      return (jsonDecode(body) as Map<String, dynamic>)['audio'];
    } catch (_) {
      return null;
    }
  }

  String? _token(String body) {
    try {
      final payload = jsonDecode(body) as Map<String, dynamic>;
      return payload['token'] as String?;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> failed(String url) async {
    final prefix = '$baseUrl/v1/stream/';
    if (!url.startsWith(prefix)) {
      return;
    }
    final token = url.substring(prefix.length);
    final uri = Uri.parse('$baseUrl/v1/playback/failed');
    try {
      await _client
          .post(
            uri,
            headers: {
              'content-type': 'application/json',
              ...tokens.headersFor(uri),
            },
            body: jsonEncode({'token': token}),
          )
          .timeout(timeout);
    } catch (_) {
      // Any error (network, non-204) is swallowed — this is a hint to server,
      // not a playback step.
    }
  }
}
