import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'models/track.dart';
import 'offline/track_store.dart';
import 'player.dart';
import 'playback.dart';
import 'podcast_client.dart';
import 'podcast_downloads.dart';
import 'podcast_progress.dart';

/// Progress of episodes on device (FT-717).
class PrefsPodcastProgressBox implements PodcastProgressBox {
  /// Positions of own account belong to itself (FT-735): otherwise sync would
  /// push former account positions to the new account's server.
  PrefsPodcastProgressBox([this.namespace]);

  /// Shared key prior to FT-735 — and device key without account.
  static const key = 'podcast_progress';

  final String? namespace;

  String get _own => namespace == null ? key : '${key}_$namespace';

  @override
  Future<String?> read() async {
    final prefs = await SharedPreferences.getInstance();
    final own = prefs.getString(_own);
    if (own != null || namespace == null) return own;
    // Pre-FT-735 positions are claimed by first account; second account gets none.
    final old = prefs.getString(key);
    if (old == null) return null;
    await prefs.setString(_own, old);
    await prefs.remove(key);
    return old;
  }

  @override
  Future<void> write(String data) async =>
      (await SharedPreferences.getInstance()).setString(_own, data);
}

/// Sync mark for episode positions with server (FT-735) — distinct for each
/// account: foreign server mark would skip its changes.
class PrefsPodcastMarkBox implements PodcastProgressBox {
  PrefsPodcastMarkBox(String? namespace)
    : key = namespace == null
          ? 'podcast_sync_mark'
          : 'podcast_sync_mark_$namespace';

  final String key;

  @override
  Future<String?> read() async =>
      (await SharedPreferences.getInstance()).getString(key);

  @override
  Future<void> write(String data) async =>
      (await SharedPreferences.getInstance()).setString(key, data);
}

/// Episodes are stored in track store (FT-710): same space accounting and eviction.
class TrackEpisodeStore implements EpisodeStore {
  TrackEpisodeStore(this.tracks);

  final TrackStore tracks;

  @override
  File partFile(String id, {required String format}) =>
      tracks.partFile(id, format: format);

  @override
  Future<File> commit(
    String id, {
    required String format,
    required Hold hold,
  }) => tracks.commit(id, format: format, hold: hold);

  @override
  Future<File?> fileFor(String id) => tracks.fileFor(id);

  @override
  Future<void> remove(String id) => tracks.remove(id);

  @override
  Future<bool> roomForDownload() => tracks.roomForDownload();
}

/// Podcast episode in music player.
///
/// Player retrieves audio URL from [PlaybackPort] by track ID. Episode is hosted
/// not on our server, but by podcast author, so its ID starts with
/// `podcast:`: such an ID is not sent to server, URL is taken from [play].
/// Auth token is not attached to foreign URL — guarded by `headersFor`.
class PodcastPlayback implements PlaybackPort {
  PodcastPlayback(this.inner);

  final PlaybackPort inner;
  final _urls = <String, String>{};
  final _keys = <String, String>{};
  final _feeds = <String, String>{};

  static bool isPodcast(String trackId) => trackId.startsWith('podcast:');

  /// Track for player and caching its URL.
  Track play(FoundPodcast podcast, PodcastEpisode episode) {
    final id = PodcastDownloads.idFor(podcast.feedUrl, episode.guid);
    _urls[id] = episode.audioUrl;
    _keys[id] = podcastEpisodeKey(podcast.feedUrl, episode.guid);
    _feeds[id] = podcast.feedUrl;
    return Track(
      id: id,
      title: episode.title,
      artist: podcast.title,
      durationMs: episode.durationMs ?? 0,
      artworkUrl: episode.image ?? podcast.image ?? '',
    );
  }

  /// Episode progress key: under which [PodcastProgressStore] remembers position.
  String? progressKey(String trackId) => _keys[trackId];

  /// Episode feed: against which [PodcastProgressStore] remembers speed (FT-730).
  String? feedOf(String trackId) => _feeds[trackId];

  Future<void>? _restored;

  /// Episode positions restored from device. Read only once.
  Future<void> ready(PodcastProgressStore progress) =>
      _restored ??= progress.restore();

  /// "Listen": resumes from saved position, finished plays from start.
  /// Second tap while episode is starting or playing is not a restart.
  Future<void> listen(
    Player player,
    PodcastProgressStore progress,
    FoundPodcast podcast,
    PodcastEpisode episode,
  ) async {
    final track = play(podcast, episode);
    // Position from device storage: before read finishes episode would start from zero,
    // and very first second would overwrite saved position.
    await ready(progress);
    final from = podcastResumeMs(
      progress.of(_keys[track.id]!),
      durationMs: episode.durationMs,
    );
    // Second tap while episode is playing is not restarted by player.
    await player.select(track, from: Duration(milliseconds: from));
  }

  /// Remember position of playing episode. `false` if not playing an episode.
  bool remember(
    Player player,
    PodcastProgressStore progress,
    Duration position, {
    bool force = false,
  }) {
    final current = player.current;
    final key = current == null ? null : _keys[current.id];
    if (key == null) return false;
    progress
        .report(
          key,
          position.inMilliseconds,
          durationMs: player.duration?.inMilliseconds,
          force: force,
        )
        .ignore();
    return true;
  }

  @override
  Future<String> start(String trackId, {bool prepare = false}) async {
    // Downloaded episode is played from file: offline and without in-memory URL (FT-733).
    if (!isPodcast(trackId) || await inner.isLocal(trackId)) {
      return inner.start(trackId, prepare: prepare);
    }
    final url = _urls[trackId];
    if (url == null) {
      // Episode from previous launch: URL is no longer in memory.
      throw const PlaybackFailed(PlayFailure.unknownTrack);
    }
    return url;
  }

  @override
  Future<bool> isLocal(String trackId) => inner.isLocal(trackId);

  @override
  Future<void> failed(String url) async {
    if (_urls.containsValue(url)) {
      // Foreign URL failure tells our server nothing.
      return;
    }
    await inner.failed(url);
  }
}
