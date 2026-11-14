import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'auth/token_provider.dart';
import 'error_reports.dart';
import 'book_client.dart' show BookReply;
import 'listen_outbox.dart' show ListenReport, ListenSent;
import 'lyrics.dart';
import 'models/track.dart';
import 'podcast_client.dart' show PodcastReply;
import 'screens/known_as.dart' show ArtistAlias;
import 'screens/problem_sheet.dart' show ProblemReport, ProblemResult;
import 'scrobble_settings.dart';

/// Why server did not provide a catalog or "My Music" page.
///
/// "Server unavailable" and "nothing found" are different: empty genre is empty
/// list, while 503 is "retry" (owner decision 19.09).
enum ServerFailure {
  /// Build key does not match server (401).
  noAccess,

  /// Server is up, but lacks database or catalog: 503 `catalog_unavailable`,
  /// `library_unavailable`.
  unavailable,

  /// No such artist, album, or playlist (404).
  notFound,

  /// Playlist changed while screen was open (409 on reorder).
  conflict,

  /// Server rate-limited requests (429).
  tooMany,

  /// Server did not respond: network, timeout, crash.
  noAnswer,
}

class ServerFailed implements Exception {
  const ServerFailed(this.reason);

  final ServerFailure reason;

  @override
  String toString() => 'ServerFailed(${reason.name})';
}

/// Import failure phrase — screen only, not for error logs.
class ImportFailed implements Exception {
  const ImportFailed(this.message);

  final String message;

  @override
  String toString() => 'ImportFailed';
}

class ImportRow {
  ImportRow.fromJson(Map<String, dynamic> json)
    : n = json['n'] as int,
      artist = json['artist'] as String,
      title = json['title'] as String,
      status = json['status'] as String,
      track = json['track'] == null
          ? null
          : Track.fromJson(json['track'] as Map<String, dynamic>),
      candidates = [
        for (final candidate in json['candidates'] as List<dynamic>)
          Track.fromJson(candidate as Map<String, dynamic>),
      ];

  final int n;
  final String artist;
  final String title;
  final String status;
  final Track? track;
  final List<Track> candidates;
}

class ImportList {
  ImportList.fromJson(Map<String, dynamic> json)
    : index = json['index'] as int,
      name = json['name'] as String,
      favoritesHint = json['favorites_hint'] as bool,
      total = json['total'] as int,
      found = json['found'] as int,
      doubtful = json['doubtful'] as int,
      missing = json['missing'] as int,
      rows = [
        for (final row in json['rows'] as List<dynamic>)
          ImportRow.fromJson(row as Map<String, dynamic>),
      ];

  final int index;
  final String name;
  final bool favoritesHint;
  final int total;
  final int found;
  final int doubtful;
  final int missing;
  final List<ImportRow> rows;
}

class ImportReport {
  ImportReport.fromJson(Map<String, dynamic> json)
    : id = json['id'] as String,
      lists = [
        for (final list in json['lists'] as List<dynamic>)
          ImportList.fromJson(list as Map<String, dynamic>),
      ];

  final String id;
  final List<ImportList> lists;
}

class ImportSaved {
  ImportSaved.fromJson(Map<String, dynamic> json)
    : target = json['target'] as String,
      added = json['added'] as int,
      missing = json['missing'] as int,
      playlistId = json['target'] == 'playlist'
          ? json['playlist_id'] as String
          : null,
      name = json['target'] == 'playlist' ? json['name'] as String : null;

  final String target;
  final int added;
  final int missing;
  final String? playlistId;
  final String? name;
}

typedef Genre = ({String id, String name, int artists});
typedef Letter = ({String letter, int artists});
typedef GenreLetter = ({String letter, int artists, int offset});
typedef TopTrack = ({String title, bool playable, Track? track});
typedef PlaylistInfo = ({String id, String name, int tracks});
typedef Listen = ({
  Track track,
  DateTime at,
  String? artistPhoto,
  bool testTone,
});

/// Artist list item. [photo] appears once server starts returning
/// it: screens already read the field and draw initial circle without it.
class CatalogArtist {
  const CatalogArtist({required this.name, this.photo});

  final String name;
  final String? photo;
}

/// Slice of a long list — genre artists, history — and total count.
typedef Chunk<T> = ({List<T> items, int total});

/// Release inside album tile (FT-552): namesake of same year — live,
/// compilation, other single. Opens via regular `GET /v1/albums/{id}`.
class AlbumEdition {
  const AlbumEdition({
    required this.id,
    required this.title,
    this.year,
    this.kind = 'album',
  });

  factory AlbumEdition.fromJson(Map<String, dynamic> json) {
    return AlbumEdition(
      id: json['id'] as String,
      title: json['title'] as String,
      year: json['year'] as int?,
      kind: json['kind'] as String? ?? 'album',
    );
  }

  final String id;
  final String title;
  final int? year;
  final String kind;
}

class Album {
  const Album({
    required this.id,
    required this.title,
    required this.year,
    this.kind = 'album',
    this.editions = const [],
    required this.playable,
    required this.cover,
  });

  factory Album.fromJson(Map<String, dynamic> json) {
    return Album(
      id: json['id'] as String,
      title: json['title'] as String,
      year: json['year'] as int?,
      kind: json['kind'] as String? ?? 'album',
      editions: [
        for (final row in json['editions'] as List<dynamic>? ?? const [])
          AlbumEdition.fromJson(row as Map<String, dynamic>),
      ],
      playable: json['playable'] as bool,
      cover: json['cover'] as String?,
    );
  }

  final String id;
  final String title;
  final int? year;
  final String kind;
  bool get ep => kind == 'ep';

  /// Other releases with same title and year (FT-552). Empty — no namesakes.
  final List<AlbumEdition> editions;
  final bool playable;

  /// Cover path on own server; `null` means no cover.
  final String? cover;
}

class ArtistPage {
  const ArtistPage({
    this.id,
    required this.name,
    required this.photo,
    required this.photoCredit,
    required this.albums,
    required this.topTracks,
    required this.similar,
    required this.bio,
    this.aliases = const [],
  });

  /// Artist MBID. `null` means server did not provide it: nothing to follow.
  final String? id;

  final String name;

  /// Photo path on own server; `null` means no photo, initial square shown.
  final String? photo;

  /// "author, license" — photo attribution. Server never sends photo without it:
  /// Wikimedia Commons images cannot be displayed without author attribution.
  final String? photoCredit;

  final List<Album> albums;

  /// Last.fm blocks (Phase F2). Missing data — server omits key entirely.
  final List<TopTrack> topTracks;
  final List<CatalogArtist> similar;
  final String? bio;

  /// Alternate name spellings from catalog (FT-746, Им-2).
  final List<ArtistAlias> aliases;
}

class AlbumPage {
  const AlbumPage({
    required this.album,
    required this.artist,
    required this.tracks,
  });

  final Album album;
  final String artist;
  final List<Track> tracks;
}

class Playlist {
  const Playlist({required this.id, required this.name, required this.tracks});

  final String id;
  final String name;
  final List<Track> tracks;
}

/// News feed card (FT-579): channel article or catalog release.
///
/// Article only links outside via "Source" (`link`); release plays album
/// `album_id` from first track. Sample — `contracts/news.response.json`.
class NewsItem {
  const NewsItem({
    required this.id,
    required this.type,
    required this.channel,
    required this.title,
    required this.text,
    required this.published,
    this.link,
    this.image,
    this.artist,
    this.albumId,
  });

  factory NewsItem.fromJson(Map<String, dynamic> json) {
    return NewsItem(
      id: json['id'] as String,
      type: json['type'] as String? ?? 'article',
      channel: json['channel'] as String? ?? '',
      title: json['title'] as String? ?? '',
      text: json['text'] as String? ?? '',
      published: json['published'] as String? ?? '',
      link: json['link'] as String?,
      image: json['image'] as String?,
      artist: json['artist'] as String?,
      albumId: json['album_id'] as String?,
    );
  }

  final String id;
  final String type;
  final String channel;
  final String title;
  final String text;

  /// Publication time, ISO-8601.
  final String published;

  /// Link to source; `null` — nowhere to navigate outside.
  final String? link;

  /// Image path on own server; `null` — without image.
  final String? image;
  final String? artist;
  final String? albumId;

  bool get isRelease => type == 'release';
}

/// News feed response: the cards themselves and whether enabled on server (FT-581).
/// `enabled` absent in sample — treated as enabled; `{"enabled": false}` —
/// admin disabled news for all, this is neither error nor empty feed.
class NewsPage {
  const NewsPage({required this.enabled, required this.items});

  final bool enabled;
  final List<NewsItem> items;
}

/// Empty feed suggestions (FT-580): where they came from and who to follow.
class NewsSuggestions {
  const NewsSuggestions({required this.source, required this.artists});

  /// `history` — from user listening history, `popular` — from catalog.
  final String source;

  final List<({String id, String name})> artists;
}

/// Curated list channel (FT-582): toggle state is per-user.
class CuratedChannel {
  const CuratedChannel({
    required this.id,
    required this.name,
    required this.lang,
    required this.enabled,
  });

  factory CuratedChannel.fromJson(Map<String, dynamic> json) {
    return CuratedChannel(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      lang: json['lang'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? true,
    );
  }

  /// Stable channel ID — URL of its feed.
  final String id;
  final String name;
  final String lang;
  final bool enabled;
}

/// User custom channel (FT-577).
class OwnChannel {
  const OwnChannel({
    required this.name,
    required this.feedUrl,
    required this.kind,
  });

  factory OwnChannel.fromJson(Map<String, dynamic> json) {
    return OwnChannel(
      name: json['name'] as String? ?? '',
      feedUrl: json['feed_url'] as String? ?? '',
      kind: json['kind'] as String? ?? '',
    );
  }

  final String name;
  final String feedUrl;
  final String kind;
}

/// Popular server channel (FT-582): name and subscriber count.
class PopularChannel {
  const PopularChannel({required this.name, required this.people});

  factory PopularChannel.fromJson(Map<String, dynamic> json) {
    return PopularChannel(
      name: json['name'] as String? ?? '',
      people: (json['people'] as num?)?.toInt() ?? 0,
    );
  }

  final String name;
  final int people;
}

/// Outcome of adding channel via URL (FT-577, FT-582).
enum ChannelAddResult {
  /// Channel accepted and added to user list.
  added,

  /// `not_public`: address points to internal network.
  notPublic,

  /// `too_many`: user already reached maximum channels.
  tooMany,

  /// `not_feed`: no news feed found at URL.
  notFeed,

  /// Server did not respond or returned unexpected response.
  failed,
}

/// Server for menu screens: catalog (phases F, F2), "My Music" (H), and news.
enum PasswordChange { changed, wrongOld, weak, failed }

class ServerApi implements ScrobblePort {
  ServerApi(
    this.baseUrl, {
    required this.tokens,
    http.Client? client,
    this.timeout = pageTimeout,
    this.language,
  }) : _client = client ?? http.Client();

  /// Artist page awaits MusicBrainz up to 25 seconds (`PAGE_BUDGET_S`
  /// in catalog_api.py); remainder is mobile network headroom.
  static const pageTimeout = Duration(seconds: 35);

  /// Large import has longer timeout than page, but under NPM proxy 90s.
  static const importTimeout = Duration(seconds: 85);

  /// Genre artists and history records per request.
  static const pageSize = 100;

  /// Maximum IDs per batch when querying server for favorites.
  static const likedChunk = 500;

  final String baseUrl;
  final TokenProvider tokens;
  final Duration timeout;
  final http.Client _client;
  final String Function()? language;

  /// Successful library modifications; screens reread it on return.
  final libraryRevision = ValueNotifier(0);

  /// Genres cached until restart: device unaware of nightly catalog rebuild.
  List<Genre>? _genres;
  ({bool books, bool podcasts})? _features;

  /// Image request headers: covers protected by the same key.
  Map<String, String> get headers => tokens.headersFor(Uri.parse(baseUrl));

  String url(String path) => '$baseUrl$path';

  /// FT-856: the person changes their own password; other devices sign out.
  Future<PasswordChange> changePassword(String old, String fresh) async {
    final uri = Uri.parse(url('/v1/auth/password'));
    final request = http.Request('POST', uri)
      ..followRedirects = false
      ..headers.addAll({
        ...tokens.headersFor(uri),
        'content-type': 'application/json',
      })
      ..body = jsonEncode({'old_password': old, 'new_password': fresh});
    try {
      final response = await _client.send(request).timeout(timeout);
      await response.stream.drain<void>();
      return switch (response.statusCode) {
        200 => PasswordChange.changed,
        403 => PasswordChange.wrongOld,
        422 => PasswordChange.weak,
        _ => PasswordChange.failed,
      };
    } on Exception {
      return PasswordChange.failed;
    }
  }

  /// Reports have their own statuses; no response body or error text is needed.
  Future<ReportResult> sendReport(ErrorReport report) async {
    try {
      final uri = Uri.parse(url('/v1/reports'));
      final response = await _client
          .post(
            uri,
            headers: {
              ...tokens.headersFor(uri),
              'content-type': 'application/json',
            },
            body: jsonEncode(report.toJson()),
          )
          .timeout(timeout);
      if (response.statusCode == 401) await tokens.onUnauthorized();
      return switch (response.statusCode) {
        202 => ReportResult.sent,
        503 => ReportResult.off,
        _ => ReportResult.failed,
      };
    } catch (_) {
      return ReportResult.failed;
    }
  }

  /// Delete single history entry: track and timestamp matching the row.
  Future<int> historyRemove(String trackId, DateTime playedAt) async {
    final reply = await _changeLibrary(
      '/v1/history/remove',
      body: {
        'track_id': trackId,
        'played_at': playedAt.toUtc().toIso8601String(),
      },
    );
    return _removed(reply);
  }

  /// Clear entire listening history.
  Future<int> historyClear() async =>
      _removed(await _changeLibrary('/v1/history/clear', body: const {}));

  int _removed(Object? reply) => switch (reply) {
    {'removed': final int removed} => removed,
    _ => 0,
  };

  /// Server listening history pause (FT-630): enable or disable. [until] is
  /// the deadline the person chose (FT-853); without it — three hours.
  Future<Object?> historyPause(bool paused, {DateTime? until}) => _call(
    'POST',
    '/v1/history/pause',
    body: {
      'paused': paused,
      if (until != null) 'until': until.toUtc().toIso8601String(),
    },
  );

  /// Whether listening history recording is currently paused.
  Future<Object?> historyPauseState() => _call('GET', '/v1/history/pause');

  /// Status of both scrobble services (FT-631, FT-645) — two queries.
  /// Last.fm down — marked "unavailable", while ListenBrainz still visible.
  @override
  Future<ScrobbleStatus> status() async {
    final listenbrainz = await _call('GET', '/v1/scrobble');
    Object? lastfm;
    try {
      lastfm = await _call('GET', '/v1/scrobble/lastfm');
    } on ServerFailed {
      lastfm = null;
    }
    return ScrobbleStatus.fromJson({
      if (listenbrainz is Map) 'listenbrainz': listenbrainz['listenbrainz'],
      if (lastfm is Map) 'lastfm': lastfm['lastfm'],
    });
  }

  @override
  Future<void> connectListenBrainz(String token) =>
      _call('POST', '/v1/scrobble/listenbrainz', body: {'token': token});

  @override
  Future<void> removeListenBrainz() =>
      _call('POST', '/v1/scrobble/listenbrainz/remove', body: const {});

  @override
  Future<Uri> startLastfm() async {
    final reply = await _call(
      'POST',
      '/v1/scrobble/lastfm/start',
      body: const {},
    );
    if (reply case {'url': final String url}) return Uri.parse(url);
    throw const ServerFailed(ServerFailure.noAnswer);
  }

  @override
  Future<ScrobbleState> finishLastfm() async {
    final reply = await _call(
      'POST',
      '/v1/scrobble/lastfm/finish',
      body: const {},
    );
    return switch (reply) {
      {'lastfm': 'on'} => ScrobbleState.on,
      {'lastfm': 'pending'} => ScrobbleState.pending,
      _ => ScrobbleState.off,
    };
  }

  @override
  Future<void> removeLastfm() =>
      _call('POST', '/v1/scrobble/lastfm/remove', body: const {});

  /// Ratings for these tracks; unrated omitted from response (FT-629).
  Future<Object?> ratingsOf(List<String> trackIds) =>
      _call('POST', '/v1/ratings/of', body: {'track_ids': trackIds});

  /// Rate with stars or "dislike"; response is recorded rating.
  Future<Object?> rate(String trackId, {int? stars, bool? disliked}) =>
      _changeLibrary(
        '/v1/ratings',
        body: {'track_id': trackId, 'stars': ?stars, 'disliked': ?disliked},
      );

  /// Rated tracks paginated: at least [minStars] stars or "dislike".
  Future<Object?> rated({
    required int minStars,
    required bool disliked,
    required int limit,
    required int offset,
  }) => _call(
    'GET',
    '/v1/ratings',
    query: {
      if (disliked) 'disliked': 'true' else 'min_stars': '$minStars',
      'limit': '$limit',
      'offset': '$offset',
    },
  );

  /// "Report a problem" (FT-622): 202 accepted, 429 rate-limited.
  /// Track lyrics (FT-623/624). `null` means no lyrics: service disabled,
  /// LRCLIB down, track missing, or network error. Screen informs user.
  Future<Lyrics?> lyrics(String trackId) async {
    try {
      final uri = Uri.parse(url('/v1/lyrics/$trackId'));
      final response = await _client
          .get(uri, headers: tokens.headersFor(uri))
          .timeout(timeout);
      if (response.statusCode == 401) await tokens.onUnauthorized();
      if (response.statusCode != 200) return null;
      final json = jsonDecode(response.body);
      return json is Map<String, dynamic> ? Lyrics.fromJson(json) : null;
    } catch (_) {
      return null;
    }
  }

  Future<ProblemResult> sendProblem(ProblemReport report) async {
    try {
      final uri = Uri.parse(url('/v1/problems'));
      final response = await _client
          .post(
            uri,
            headers: {
              ...tokens.headersFor(uri),
              'content-type': 'application/json',
            },
            body: jsonEncode(report.toJson()),
          )
          .timeout(timeout);
      if (response.statusCode == 401) await tokens.onUnauthorized();
      return switch (response.statusCode) {
        202 => ProblemResult.sent,
        429 => ProblemResult.tooMany,
        _ => ProblemResult.failed,
      };
    } catch (_) {
      return ProblemResult.failed;
    }
  }

  /// Podcast client channel (`PodcastSend`): status and parsed JSON,
  /// client handles error parsing. No response throws, like `_call`.
  Future<PodcastReply> podcastSend(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
  }) async {
    final uri = Uri.parse(url(path)).replace(queryParameters: query);
    final request = http.Request(method, uri);
    request.headers.addAll({
      ...tokens.headersFor(uri),
      if (body != null) 'content-type': 'application/json',
    });
    if (body != null) {
      request.body = jsonEncode(body);
    }
    final http.Response response;
    try {
      response = await _client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(timeout);
    } on Exception {
      throw const ServerFailed(ServerFailure.noAnswer);
    }
    if (response.statusCode == 401) {
      await tokens.onUnauthorized();
    }
    Object? json;
    try {
      json = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      json = null;
    }
    return PodcastReply(response.statusCode, json);
  }

  /// Audiobook client channel (`BookSend`): status and parsed JSON,
  /// client handles error parsing. No response throws, like `_call`.
  Future<BookReply> bookSend(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
  }) async {
    final uri = Uri.parse(url(path)).replace(queryParameters: query);
    final request = http.Request(method, uri);
    request.headers.addAll({
      ...tokens.headersFor(uri),
      if (body != null) 'content-type': 'application/json',
    });
    if (body != null) {
      request.body = jsonEncode(body);
    }
    final http.Response response;
    try {
      response = await _client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(timeout);
    } on Exception {
      throw const ServerFailed(ServerFailure.noAnswer);
    }
    if (response.statusCode == 401) {
      await tokens.onUnauthorized();
    }
    Object? json;
    try {
      json = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      json = null;
    }
    return BookReply(response.statusCode, json);
  }

  Future<Object?> _call(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    bool importErrors = false,
    Duration? wait,
  }) async {
    final uri = Uri.parse(url(path)).replace(queryParameters: query);
    final request = http.Request(method, uri);
    final lang = importErrors && language != null ? language!() : null;
    request.headers.addAll({
      ...tokens.headersFor(uri),
      if (body != null) 'content-type': 'application/json',
      'accept-language': ?lang,
    });
    if (body != null) {
      request.body = jsonEncode(body);
    }
    final http.Response response;
    try {
      response = await _client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(wait ?? timeout);
    } on Exception {
      throw const ServerFailed(ServerFailure.noAnswer);
    }
    if (response.statusCode == 401) {
      await tokens.onUnauthorized();
    }
    if (importErrors &&
        (response.statusCode == 413 || response.statusCode == 422)) {
      try {
        final json = jsonDecode(utf8.decode(response.bodyBytes));
        if (json is Map<String, dynamic> && json['message'] is String) {
          throw ImportFailed(json['message'] as String);
        }
      } on FormatException {
        throw const ServerFailed(ServerFailure.noAnswer);
      }
      throw const ServerFailed(ServerFailure.noAnswer);
    }
    final failure = switch (response.statusCode) {
      200 || 201 || 202 || 204 => null,
      401 => ServerFailure.noAccess,
      429 => ServerFailure.tooMany,
      404 => ServerFailure.notFound,
      409 => ServerFailure.conflict,
      503 => ServerFailure.unavailable,
      _ => ServerFailure.noAnswer,
    };
    if (failure != null) {
      throw ServerFailed(failure);
    }
    if (response.statusCode == 204 || response.bodyBytes.isEmpty) {
      return null;
    }
    try {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw const ServerFailed(ServerFailure.noAnswer);
    }
  }

  Future<Map<String, dynamic>> _get(
    String path, [
    Map<String, String>? query,
  ]) async {
    return await _call('GET', path, query: query) as Map<String, dynamic>;
  }

  List<Map<String, dynamic>> _rows(Map<String, dynamic> json, String key) {
    return [
      for (final row in json[key] as List<dynamic>? ?? const [])
        row as Map<String, dynamic>,
    ];
  }

  List<Track> _tracks(Map<String, dynamic> json) {
    return [for (final row in _rows(json, 'tracks')) Track.fromJson(row)];
  }

  // --- catalog ------------------------------------------------------------

  Future<List<Genre>> genres() async {
    final cached = _genres;
    if (cached != null) {
      return cached;
    }
    // Only successful response cached: assignment follows call,
    // so network failure does not lock genres until restart.
    return _genres = [
      for (final row in _rows(await _get('/v1/genres'), 'genres'))
        (
          id: row['id'] as String,
          name: row['name'] as String,
          artists: row['artists'] as int,
        ),
    ];
  }

  /// FT-800: server configured features. Only successful response cached;
  /// any failure (legacy server without endpoint, network, malformed response)
  /// defaults to "all configured" to avoid breaking working features.
  Future<({bool books, bool podcasts})> features() async {
    final cached = _features;
    if (cached != null) {
      return cached;
    }
    try {
      final json = await _get('/v1/features');
      final books = json['books'];
      final podcasts = json['podcasts'];
      if (books is! bool || podcasts is! bool) {
        return (books: true, podcasts: true);
      }
      return _features = (books: books, podcasts: podcasts);
    } catch (_) {
      return (books: true, podcasts: true);
    }
  }

  Future<List<Letter>> letters() async {
    return [
      for (final row in _rows(await _get('/v1/letters'), 'letters'))
        (letter: row['letter'] as String, artists: row['artists'] as int),
    ];
  }

  Future<List<GenreLetter>> genreLetters(String genre) async {
    final letters = [
      for (final row in _rows(
        await _get('/v1/letters', {'genre': genre}),
        'letters',
      ))
        (
          letter: row['letter'] as String,
          artists: row['artists'] as int,
          offset: row['offset'] as int,
        ),
    ];
    if (letters.any((letter) => letter.offset < 0)) {
      throw const ServerFailed(ServerFailure.noAnswer);
    }
    return letters;
  }

  /// Genre artists (top popular first) or by letter (alphabetical).
  Future<Chunk<String>> artists({
    String? genre,
    String? letter,
    int offset = 0,
  }) async {
    final chunk = await artistCatalog(
      genre: genre,
      letter: letter,
      offset: offset,
    );
    return (
      items: [for (final row in chunk.items) row.name],
      total: chunk.total,
    );
  }

  /// Same list with optional photo. Missing field renders initial circle.
  Future<Chunk<CatalogArtist>> artistCatalog({
    String? genre,
    String? letter,
    int offset = 0,
  }) async {
    final json = await _get('/v1/artists', {
      'genre': ?genre,
      'letter': ?letter,
      'offset': '$offset',
      'limit': '$pageSize',
    });
    return (
      items: [
        for (final row in _rows(json, 'artists'))
          CatalogArtist(
            name: row['name'] as String,
            photo: row['photo'] as String?,
          ),
      ],
      total: json['total'] as int,
    );
  }

  TopTrack _topTrack(Map<String, dynamic> row, {String? defaultArtist}) {
    return (
      title: row['title'] as String,
      playable: row['playable'] as bool,
      track: row['id'] is String
          ? Track.fromJson({
              'id': row['id'],
              'title': row['title'],
              'artist': row['artist'] as String? ?? defaultArtist ?? '',
              'duration_ms': row['duration_ms'] as int? ?? 0,
              'artwork_url': row['artwork_url'] as String? ?? '',
              'playable': row['playable'] as bool,
            })
          : null,
    );
  }

  /// Name passed in query string: stripped by server access log, path logged.
  Future<ArtistPage> artist(String name) async {
    final json = await _get('/v1/artist', {'name': name});
    final artist = json['artist'] as Map<String, dynamic>;
    return ArtistPage(
      id: artist['id'] as String?,
      name: artist['name'] as String,
      photo: artist['photo'] as String?,
      photoCredit: artist['photo_credit'] as String?,
      albums: [for (final row in _rows(json, 'albums')) Album.fromJson(row)],
      topTracks: [
        for (final row in _rows(json, 'top_tracks'))
          _topTrack(row, defaultArtist: artist['name'] as String?),
      ],
      similar: [
        for (final row in _rows(json, 'similar'))
          CatalogArtist(
            name: row['name'] as String,
            photo: row['photo'] as String?,
          ),
      ],
      bio: json['bio'] as String?,
      aliases: ArtistAlias.listFrom(artist['aliases']),
    );
  }

  /// All popular tracks of artist in Last.fm order (FT-553).
  Future<List<TopTrack>> artistSongs(String name) async {
    final json = await _get('/v1/artist/songs', {'name': name});
    return [
      for (final row in _rows(json, 'tracks'))
        _topTrack(row, defaultArtist: name),
    ];
  }

  Future<AlbumPage> album(String id) async {
    final json = await _get('/v1/albums/$id');
    final album = json['album'] as Map<String, dynamic>;
    return AlbumPage(
      album: Album.fromJson(album),
      artist: album['artist'] as String,
      tracks: _tracks(json),
    );
  }

  Future<({String id, String title})?> trackAlbum(String id) async {
    try {
      final json = await _get('/v1/tracks/$id/album');
      final album = json['album'] as Map<String, dynamic>;
      return (id: album['id'] as String, title: album['title'] as String);
    } on ServerFailed catch (e) {
      if (e.reason == ServerFailure.notFound) {
        return null;
      }
      rethrow;
    }
  }

  // --- News (FT-579) ------------------------------------------------------

  /// News feed: up to 50 cards per page (sample
  /// `contracts/news.response.json`). `enabled` is admin toggle.
  Future<NewsPage> news() async {
    final json = await _get('/v1/news');
    return NewsPage(
      enabled: json['enabled'] as bool? ?? true,
      items: [for (final row in _rows(json, 'items')) NewsItem.fromJson(row)],
    );
  }

  /// Who the user already follows (`GET /v1/news/follows`, FT-580).
  Future<Set<String>> newsFollows() async {
    final json = await _get('/v1/news/follows');
    return {for (final row in _rows(json, 'artists')) row['id'] as String};
  }

  Future<void> followArtist(String id) =>
      _call('POST', '/v1/news/follows', body: {'artist_id': id});

  Future<void> unfollowArtist(String id) =>
      _call('POST', '/v1/news/follows/remove', body: {'artist_id': id});

  /// Suggestions for empty feed (`GET /v1/news/suggestions`, FT-580).
  Future<NewsSuggestions> newsSuggestions() async {
    final json = await _get('/v1/news/suggestions');
    return NewsSuggestions(
      source: json['source'] as String? ?? 'popular',
      artists: [
        for (final row in _rows(json, 'artists'))
          (id: row['id'] as String, name: row['name'] as String),
      ],
    );
  }

  // --- Channels (FT-582) ---------------------------------------------------

  /// Curated channels list (`GET /v1/news/curated`).
  Future<List<CuratedChannel>> newsCurated() async {
    final json = await _get('/v1/news/curated');
    return [
      for (final row in _rows(json, 'channels')) CuratedChannel.fromJson(row),
    ];
  }

  /// Curated channel toggle is per-user.
  Future<void> setNewsCurated(String id, bool enabled) =>
      _call('POST', '/v1/news/curated', body: {'id': id, 'enabled': enabled});

  /// User custom channels (`GET /v1/news/channels`, FT-577).
  Future<List<OwnChannel>> newsChannels() async {
    final json = await _get('/v1/news/channels');
    return [
      for (final row in _rows(json, 'channels')) OwnChannel.fromJson(row),
    ];
  }

  /// Custom channels added by at least three users.
  Future<List<PopularChannel>> newsPopularChannels() async {
    final json = await _get('/v1/news/channels/popular');
    return [
      for (final row in _rows(json, 'channels')) PopularChannel.fromJson(row),
    ];
  }

  /// Add custom channel by URL (FT-577). Server rejection mapped to clear enum
  /// (`ChannelAddResult`), without URL text: `not_public` internal IP,
  /// `too_many` channel limit, `not_feed` URL contains no feed.
  Future<ChannelAddResult> addNewsChannel(String link) async {
    final http.Response response;
    try {
      final uri = Uri.parse(url('/v1/news/channels'));
      final request = http.Request('POST', uri)
        ..headers.addAll({
          ...tokens.headersFor(uri),
          'content-type': 'application/json',
        })
        ..body = jsonEncode({'link': link});
      response = await _client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(timeout);
    } on Exception {
      return ChannelAddResult.failed;
    }
    if (response.statusCode == 401) {
      await tokens.onUnauthorized();
    }
    if (response.statusCode == 200) {
      return ChannelAddResult.added;
    }
    var error = '';
    try {
      final json = jsonDecode(utf8.decode(response.bodyBytes));
      if (json is Map<String, dynamic>) {
        error = json['error'] as String? ?? '';
      }
    } on FormatException {
      return ChannelAddResult.failed;
    }
    return switch ((response.statusCode, error)) {
      (400, 'not_public') => ChannelAddResult.notPublic,
      (400, _) => ChannelAddResult.notFeed,
      (409, _) => ChannelAddResult.tooMany,
      _ => ChannelAddResult.failed,
    };
  }

  // --- My Music -----------------------------------------------------------

  Future<Object?> _changeLibrary(String path, {Object? body}) async {
    final result = await _call('POST', path, body: body);
    libraryRevision.value++;
    return result;
  }

  Future<ImportReport> createImport(String? name, Uint8List bytes) async {
    final json = await _call(
      'POST',
      '/v1/imports',
      body: {'name': name, 'data': base64Encode(bytes)},
      importErrors: true,
      wait: importTimeout,
    );
    try {
      return ImportReport.fromJson(json as Map<String, dynamic>);
    } on TypeError {
      throw const ServerFailed(ServerFailure.noAnswer);
    }
  }

  Future<ImportSaved> saveImport(
    String id, {
    required int list,
    required String target,
    required Map<int, int?> choices,
  }) async {
    final json = await _call(
      'POST',
      '/v1/imports/$id/save',
      body: {
        'list': list,
        'target': target,
        'choices': {
          for (final entry in choices.entries) '${entry.key}': entry.value,
        },
      },
      importErrors: true,
    );
    // New playlist or Favorites — Home and My Music are refreshed.
    libraryRevision.value++;
    try {
      return ImportSaved.fromJson(json as Map<String, dynamic>);
    } on TypeError {
      throw const ServerFailed(ServerFailure.noAnswer);
    }
  }

  Future<List<Track>> favorites() async => _tracks(await _get('/v1/favorites'));

  Future<void> like(String trackId, {String artworkUrl = ''}) => _changeLibrary(
    '/v1/favorites',
    body: {
      'track_id': trackId,
      if (artworkUrl.isNotEmpty) 'artwork_url': artworkUrl,
    },
  );

  Future<void> unlike(String trackId) =>
      _changeLibrary('/v1/favorites/remove', body: {'track_id': trackId});

  /// Which tracks are favorited. Queries server: same track has different
  /// IDs in search vs album page, impossible to match on device.
  Future<Set<String>> liked(List<String> trackIds) async {
    final liked = <String>{};
    for (var start = 0; start < trackIds.length; start += likedChunk) {
      final end = min(start + likedChunk, trackIds.length);
      final json =
          await _call(
                'POST',
                '/v1/favorites/contains',
                body: {'track_ids': trackIds.sublist(start, end)},
              )
              as Map<String, dynamic>;
      liked.addAll([
        for (final id in json['track_ids'] as List<dynamic>) id as String,
      ]);
    }
    return liked;
  }

  Future<Chunk<Listen>> history({int offset = 0}) async {
    final json = await _get('/v1/history', {
      'offset': '$offset',
      'limit': '$pageSize',
    });
    return (
      items: [
        for (final row in _rows(json, 'tracks'))
          (
            track: Track.fromJson(row),
            at: DateTime.parse(row['played_at'] as String),
            artistPhoto: row['artist_photo'] as String?,
            testTone: row['test_tone'] as bool? ?? false,
          ),
      ],
      total: json['total'] as int,
    );
  }

  /// Playback report with session ID (Д1): same `POST /v1/history`.
  /// Accepted (including "not recorded") — 2xx; 404 and 422 never accepted;
  /// others and no network — retry later.
  Future<ListenSent> sendListen(
    ListenReport report, {
    String artworkUrl = '',
  }) async {
    try {
      final uri = Uri.parse(url('/v1/history'));
      final response = await _client
          .post(
            uri,
            headers: {
              ...tokens.headersFor(uri),
              'content-type': 'application/json',
            },
            body: jsonEncode({
              ...report.toJson(),
              if (artworkUrl.isNotEmpty) 'artwork_url': artworkUrl,
            }),
          )
          .timeout(timeout);
      final code = response.statusCode;
      if (code == 401) await tokens.onUnauthorized();
      if (code >= 200 && code < 300) return ListenSent.accepted;
      if (code == 404 || code == 422) return ListenSent.rejected;
      return ListenSent.retry;
    } catch (_) {
      return ListenSent.retry;
    }
  }

  /// Actual track playback duration. Server decides whether to count.
  Future<void> listened(
    String trackId,
    int listenedMs, {
    String artworkUrl = '',
  }) => _call(
    'POST',
    '/v1/history',
    body: {
      'track_id': trackId,
      'listened_ms': listenedMs,
      if (artworkUrl.isNotEmpty) 'artwork_url': artworkUrl,
    },
  );

  Future<List<PlaylistInfo>> playlists() async {
    return [
      for (final row in _rows(await _get('/v1/playlists'), 'playlists'))
        (
          id: row['id'] as String,
          name: row['name'] as String,
          tracks: row['tracks'] as int,
        ),
    ];
  }

  Future<Playlist> playlist(String id) async {
    final json = await _get('/v1/playlists/$id');
    return Playlist(
      id: json['id'] as String,
      name: json['name'] as String,
      tracks: _tracks(json),
    );
  }

  Future<PlaylistInfo> createPlaylist(String name) async {
    final json =
        await _changeLibrary('/v1/playlists', body: {'name': name})
            as Map<String, dynamic>;
    return (
      id: json['id'] as String,
      name: json['name'] as String,
      tracks: json['tracks'] as int? ?? 0,
    );
  }

  Future<void> renamePlaylist(String id, String name) =>
      _changeLibrary('/v1/playlists/$id/rename', body: {'name': name});

  Future<void> deletePlaylist(String id) =>
      _changeLibrary('/v1/playlists/$id/delete');

  Future<void> addToPlaylist(
    String id,
    String trackId, {
    String artworkUrl = '',
  }) => _changeLibrary(
    '/v1/playlists/$id/tracks',
    body: {
      'track_id': trackId,
      if (artworkUrl.isNotEmpty) 'artwork_url': artworkUrl,
    },
  );

  Future<void> removeFromPlaylist(String id, String trackId) => _changeLibrary(
    '/v1/playlists/$id/tracks/remove',
    body: {'track_id': trackId},
  );

  /// Entire new order. 409 — playlist changed since displayed:
  /// server reordered nothing.
  Future<void> orderPlaylist(String id, List<String> trackIds) =>
      _changeLibrary('/v1/playlists/$id/order', body: {'track_ids': trackIds});

  // --- device downloads (FT-526) ------------------------------------------

  Future<void> requestDownloads(List<String> trackIds) async {
    await _call('POST', '/v1/downloads', body: {'track_ids': trackIds});
  }

  Future<List<Map<String, dynamic>>> downloads() async {
    final json = await _get('/v1/downloads');
    return _rows(json, 'items');
  }

  Future<void> removeDownloads(List<String> trackIds) async {
    await _call('POST', '/v1/downloads/remove', body: {'track_ids': trackIds});
  }
}
