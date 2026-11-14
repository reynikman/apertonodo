// FT-662: app communication with podcast server (Р-A93, block В-5).

import 'dart:async';

import 'podcast_progress.dart';
import 'podcast_sync.dart';

const int podcastMaxText = 500;
const int podcastMaxDescription = 4000;
const int podcastMaxUrl = 2048;
const int podcastMaxRows = 2000;

enum PodcastFailure {
  offline,
  unavailable,
  searchUnavailable,
  badUrl,
  limit,
  notSubscribed,
  signedOut,
  broken,
}

class PodcastException implements Exception {
  final PodcastFailure reason;

  const PodcastException(this.reason);

  @override
  String toString() => 'PodcastException(${reason.name})';
}

class PodcastReply {
  final int status;
  final Object? json;

  const PodcastReply(this.status, this.json);

  @override
  String toString() => 'PodcastReply';
}

typedef PodcastSend =
    Future<PodcastReply> Function(
      String method,
      String path, {
      Map<String, String>? query,
      Object? body,
    });

bool _isTextControlOrBidi(int code) {
  if (code <= 0x1f) return true;
  if (code >= 0x7f && code <= 0x9f) return true;
  if (code == 0x200e || code == 0x200f) return true;
  if (code >= 0x202a && code <= 0x202e) return true;
  if (code >= 0x2066 && code <= 0x2069) return true;
  return false;
}

bool _isWhitespaceOrControl(int code) {
  if (code <= 0x20) return true;
  if (code >= 0x7f && code <= 0x9f) return true;
  if (code == 0x00a0) return true;
  if (code == 0x1680) return true;
  if (code >= 0x2000 && code <= 0x200f) return true;
  if (code >= 0x2028 && code <= 0x202f) return true;
  if (code == 0x205f) return true;
  if (code >= 0x2066 && code <= 0x2069) return true;
  if (code == 0x3000 || code == 0xfeff) return true;
  return false;
}

String? podcastHttpUrl(Object? raw) {
  if (raw is! String) return null;
  if (raw.isEmpty || raw.length > podcastMaxUrl) return null;
  for (final rune in raw.runes) {
    if (_isWhitespaceOrControl(rune)) {
      return null;
    }
  }
  final uri = Uri.tryParse(raw);
  if (uri == null) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  if (uri.host.isEmpty) return null;
  if (uri.userInfo.isNotEmpty) return null;
  return raw;
}

String? cleanText(Object? raw, {int maxLength = podcastMaxText}) {
  if (raw is! String) return null;
  final buffer = StringBuffer();
  for (final rune in raw.runes) {
    if (_isTextControlOrBidi(rune)) {
      buffer.write(' ');
    } else if (rune >= 0xd800 && rune <= 0xdfff) {
      // Lone surrogate half: Flutter doesn't render such string.
      buffer.writeCharCode(0xfffd);
    } else {
      buffer.writeCharCode(rune);
    }
  }
  final trimmed = buffer.toString().trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.runes.length > maxLength) {
    return String.fromCharCodes(trimmed.runes.take(maxLength));
  }
  return trimmed;
}

DateTime? parseUtc(Object? raw) {
  if (raw is! String || !raw.endsWith('Z')) return null;
  final parsed = DateTime.tryParse(raw);
  return parsed?.toUtc();
}

/// Episode from "New episodes" shelf: which feed and which episode.
class NewPodcastEpisode {
  final String feedUrl;
  final String feedTitle;
  final PodcastEpisode episode;

  const NewPodcastEpisode({
    required this.feedUrl,
    required this.feedTitle,
    required this.episode,
  });
}

/// Episode from "Continue" shelf (FT-756): feed, pause position, and episode.
class ContinuePodcastEpisode {
  final String feedUrl;
  final String feedTitle;
  final int positionMs;
  final PodcastEpisode episode;

  const ContinuePodcastEpisode({
    required this.feedUrl,
    required this.feedTitle,
    required this.positionMs,
    required this.episode,
  });
}

class FoundPodcast {
  final String feedUrl;
  final String title;
  final String author;
  final String? image;
  final int? episodes;

  const FoundPodcast({
    required this.feedUrl,
    required this.title,
    this.author = '',
    this.image,
    this.episodes,
  });

  static FoundPodcast? fromJson(Object? json) {
    if (json is! Map) return null;
    final feedUrl = podcastHttpUrl(json['feed_url']);
    if (feedUrl == null) return null;
    final title = cleanText(json['title'], maxLength: podcastMaxText);
    if (title == null) return null;
    final author = cleanText(json['author'], maxLength: podcastMaxText) ?? '';
    final image = podcastHttpUrl(json['image']);
    final rawEpisodes = json['episodes'];
    final episodes = (rawEpisodes is int && rawEpisodes >= 0)
        ? rawEpisodes
        : null;
    return FoundPodcast(
      feedUrl: feedUrl,
      title: title,
      author: author,
      image: image,
      episodes: episodes,
    );
  }

  @override
  String toString() => 'FoundPodcast';
}

class PodcastSubscription {
  final String feedUrl;
  final String? title;
  final String author;
  final String? image;
  final int episodes;
  final DateTime? newestAt;
  final DateTime? addedAt;

  const PodcastSubscription({
    required this.feedUrl,
    this.title,
    this.author = '',
    this.image,
    this.episodes = 0,
    this.newestAt,
    this.addedAt,
  });

  static PodcastSubscription? fromJson(Object? json) {
    if (json is! Map) return null;
    final feedUrl = podcastHttpUrl(json['feed_url']);
    if (feedUrl == null) return null;
    final title = cleanText(json['title'], maxLength: podcastMaxText);
    final author = cleanText(json['author'], maxLength: podcastMaxText) ?? '';
    final image = podcastHttpUrl(json['image']);
    final rawEpisodes = json['episodes'];
    final episodes = (rawEpisodes is int && rawEpisodes >= 0) ? rawEpisodes : 0;
    final newestAt = parseUtc(json['newest_at']);
    final addedAt = parseUtc(json['added_at']);
    return PodcastSubscription(
      feedUrl: feedUrl,
      title: title,
      author: author,
      image: image,
      episodes: episodes,
      newestAt: newestAt,
      addedAt: addedAt,
    );
  }

  @override
  String toString() => 'PodcastSubscription';
}

class PodcastEpisode {
  final String guid;
  final String title;
  final String description;
  final String audioUrl;
  final String? audioType;
  final int? audioBytes;
  final int? durationMs;
  final DateTime? published;
  final String? image;
  final int? season;
  final int? number;
  final bool explicit;

  const PodcastEpisode({
    required this.guid,
    this.title = '',
    this.description = '',
    required this.audioUrl,
    this.audioType,
    this.audioBytes,
    this.durationMs,
    this.published,
    this.image,
    this.season,
    this.number,
    this.explicit = false,
  });

  static PodcastEpisode? fromJson(Object? json) {
    if (json is! Map) return null;
    final rawGuid = json['guid'];
    if (rawGuid is! String ||
        rawGuid.isEmpty ||
        rawGuid.length > podcastMaxUrl) {
      return null;
    }
    final audioUrl = podcastHttpUrl(json['audio_url']);
    if (audioUrl == null) return null;

    final title = cleanText(json['title'], maxLength: podcastMaxText) ?? '';
    final description =
        cleanText(json['description'], maxLength: podcastMaxDescription) ?? '';
    final audioType = cleanText(json['audio_type'], maxLength: podcastMaxText);

    final rawBytes = json['audio_bytes'];
    final audioBytes = (rawBytes is int && rawBytes >= 0) ? rawBytes : null;

    final rawDuration = json['duration_ms'];
    final durationMs = (rawDuration is int && rawDuration > 0)
        ? rawDuration
        : null;

    final published = parseUtc(json['published']);
    final image = podcastHttpUrl(json['image']);

    final rawSeason = json['season'];
    final season = (rawSeason is int && rawSeason >= 0) ? rawSeason : null;

    final rawNumber = json['number'];
    final number = (rawNumber is int && rawNumber >= 0) ? rawNumber : null;

    final explicit = json['explicit'] == true;

    return PodcastEpisode(
      guid: rawGuid,
      title: title,
      description: description,
      audioUrl: audioUrl,
      audioType: audioType,
      audioBytes: audioBytes,
      durationMs: durationMs,
      published: published,
      image: image,
      season: season,
      number: number,
      explicit: explicit,
    );
  }

  @override
  String toString() => 'PodcastEpisode';
}

class PodcastSubscribed {
  final String feedUrl;
  final bool isNew;

  const PodcastSubscribed(this.feedUrl, {required this.isNew});

  @override
  String toString() => 'PodcastSubscribed';
}

class PodcastClient implements PodcastSyncPort {
  final PodcastSend _send;

  PodcastClient(this._send);

  Future<PodcastReply> _request(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
  }) async {
    final PodcastReply reply;
    try {
      reply = await _send(method, path, query: query, body: body);
    } on PodcastException {
      rethrow;
    } catch (_) {
      throw const PodcastException(PodcastFailure.offline);
    }

    final status = reply.status;
    if (status == 200) {
      return reply;
    }

    if (status == 401) {
      throw const PodcastException(PodcastFailure.signedOut);
    }
    if (status == 400) {
      throw const PodcastException(PodcastFailure.broken);
    }
    if (status == 404) {
      if (reply.json is Map &&
          (reply.json as Map)['status'] == 'not_subscribed') {
        throw const PodcastException(PodcastFailure.notSubscribed);
      }
      throw const PodcastException(PodcastFailure.unavailable);
    }
    if (status == 409) {
      if (reply.json is Map && (reply.json as Map)['status'] == 'limit') {
        throw const PodcastException(PodcastFailure.limit);
      }
      throw const PodcastException(PodcastFailure.unavailable);
    }
    if (status == 422) {
      if (reply.json is Map && (reply.json as Map)['status'] == 'bad_url') {
        throw const PodcastException(PodcastFailure.badUrl);
      }
      throw const PodcastException(PodcastFailure.broken);
    }
    if (status == 503) {
      if (reply.json is Map &&
          (reply.json as Map)['status'] == 'podcast_search_unavailable') {
        throw const PodcastException(PodcastFailure.searchUnavailable);
      }
      throw const PodcastException(PodcastFailure.unavailable);
    }

    throw const PodcastException(PodcastFailure.unavailable);
  }

  Future<List<FoundPodcast>> search(String query, {int limit = 20}) async {
    final trimmed = query.trim();
    if (trimmed.runes.length < 2) {
      return const [];
    }
    var q = trimmed;
    if (q.runes.length > 200) {
      q = String.fromCharCodes(q.runes.take(200));
    }
    final clampedLimit = limit.clamp(1, 50);

    final reply = await _request(
      'GET',
      '/v1/podcasts/search',
      query: {'q': q, 'limit': '$clampedLimit'},
    );

    final json = reply.json;
    if (json is! Map) {
      throw const PodcastException(PodcastFailure.broken);
    }
    final rawList = json['podcasts'];
    if (rawList is! List) {
      throw const PodcastException(PodcastFailure.broken);
    }

    final results = <FoundPodcast>[];
    final seen = <String>{};
    for (final item in rawList) {
      final parsed = FoundPodcast.fromJson(item);
      if (parsed == null) continue;
      if (seen.add(parsed.feedUrl)) {
        results.add(parsed);
        if (results.length >= podcastMaxRows) break;
      }
    }
    return List.unmodifiable(results);
  }

  Future<List<PodcastSubscription>> subscriptions() async {
    final reply = await _request('GET', '/v1/podcasts');
    final json = reply.json;
    if (json is! Map) {
      throw const PodcastException(PodcastFailure.broken);
    }
    final rawList = json['podcasts'];
    if (rawList is! List) {
      throw const PodcastException(PodcastFailure.broken);
    }

    final results = <PodcastSubscription>[];
    final seen = <String>{};
    for (final item in rawList) {
      final parsed = PodcastSubscription.fromJson(item);
      if (parsed == null) continue;
      if (seen.add(parsed.feedUrl)) {
        results.add(parsed);
        if (results.length >= podcastMaxRows) break;
      }
    }
    return List.unmodifiable(results);
  }

  Future<PodcastSubscribed> subscribe(String feedUrl) async {
    final reply = await _request(
      'POST',
      '/v1/podcasts/subscribe',
      body: {'feed_url': feedUrl},
    );
    final json = reply.json;
    if (json is! Map) {
      throw const PodcastException(PodcastFailure.broken);
    }
    final result = json['result'];
    if (result != 'new' && result != 'exists') {
      throw const PodcastException(PodcastFailure.broken);
    }
    final validFeedUrl = podcastHttpUrl(json['feed_url']);
    if (validFeedUrl == null) {
      throw const PodcastException(PodcastFailure.broken);
    }
    return PodcastSubscribed(validFeedUrl, isNew: result == 'new');
  }

  Future<bool> unsubscribe(String feedUrl) async {
    final reply = await _request(
      'POST',
      '/v1/podcasts/unsubscribe',
      body: {'feed_url': feedUrl},
    );
    final json = reply.json;
    if (json is! Map) {
      throw const PodcastException(PodcastFailure.broken);
    }
    final removed = json['removed'];
    if (removed is! bool) {
      throw const PodcastException(PodcastFailure.broken);
    }
    return removed;
  }

  Future<List<PodcastEpisode>> episodes(
    String feedUrl, {
    int limit = 50,
    int offset = 0,
    bool oldestFirst = false,
  }) async {
    final clampedLimit = limit.clamp(1, 200);
    final effectiveOffset = offset < 0 ? 0 : offset;

    final reply = await _request(
      'GET',
      '/v1/podcasts/episodes',
      query: {
        'feed_url': feedUrl,
        'limit': '$clampedLimit',
        'offset': '$effectiveOffset',
        // FT-732: "from first" — first page from other end of feed.
        if (oldestFirst) 'order': 'oldest',
      },
    );

    return _episodesFrom(reply);
  }

  /// Episodes of feed without subscription (FT-723): server downloads feed itself and doesn't store.
  Future<List<PodcastEpisode>> preview(String feedUrl) async {
    final reply = await _request(
      'GET',
      '/v1/podcasts/preview',
      query: {'feed_url': feedUrl},
    );
    return _episodesFrom(reply);
  }

  /// New episodes of all subscriptions (FT-732) — "New episodes" shelf.
  Future<List<NewPodcastEpisode>> newEpisodes() async {
    final reply = await _request('GET', '/v1/podcasts/new');
    final json = reply.json;
    final rawList = json is Map ? json['episodes'] : null;
    if (rawList is! List) {
      throw const PodcastException(PodcastFailure.broken);
    }
    final results = <NewPodcastEpisode>[];
    final seen = <(String, String)>{};
    for (final item in rawList) {
      if (item is! Map) continue;
      final feedUrl = podcastHttpUrl(item['feed_url']);
      final episode = PodcastEpisode.fromJson(item);
      if (feedUrl == null || episode == null) continue;
      // Duplicate episode — one row: identical keys crash the shelf.
      if (!seen.add((feedUrl, episode.guid))) continue;
      results.add(
        NewPodcastEpisode(
          feedUrl: feedUrl,
          feedTitle:
              cleanText(item['feed_title'], maxLength: podcastMaxText) ?? '',
          episode: episode,
        ),
      );
    }
    return List.unmodifiable(results);
  }

  /// Started episodes (FT-756) — "Continue" shelf.
  Future<List<ContinuePodcastEpisode>> continueEpisodes() async {
    final reply = await _request('GET', '/v1/podcasts/continue');
    final json = reply.json;
    final rawList = json is Map ? json['episodes'] : null;
    if (rawList is! List) {
      throw const PodcastException(PodcastFailure.broken);
    }
    final results = <ContinuePodcastEpisode>[];
    final seen = <(String, String)>{};
    for (final item in rawList) {
      if (item is! Map) continue;
      final feedUrl = podcastHttpUrl(item['feed_url']);
      final pos = item['position_ms'];
      if (pos is! int || pos < 0) continue;
      final episode = PodcastEpisode.fromJson(item);
      if (feedUrl == null || episode == null) continue;
      // Duplicate episode — one row: identical keys crash the shelf.
      if (!seen.add((feedUrl, episode.guid))) continue;
      results.add(
        ContinuePodcastEpisode(
          feedUrl: feedUrl,
          feedTitle:
              cleanText(item['feed_title'], maxLength: podcastMaxText) ?? '',
          positionMs: pos,
          episode: episode,
        ),
      );
    }
    return List.unmodifiable(results);
  }

  List<PodcastEpisode> _episodesFrom(PodcastReply reply) {
    final json = reply.json;
    if (json is! Map) {
      throw const PodcastException(PodcastFailure.broken);
    }
    final rawList = json['episodes'];
    if (rawList is! List) {
      throw const PodcastException(PodcastFailure.broken);
    }

    final results = <PodcastEpisode>[];
    final seen = <String>{};
    for (final item in rawList) {
      final parsed = PodcastEpisode.fromJson(item);
      if (parsed == null) continue;
      if (seen.add(parsed.guid)) {
        results.add(parsed);
        if (results.length >= podcastMaxRows) break;
      }
    }
    return List.unmodifiable(results);
  }

  @override
  Future<Map<String, EpisodeProgress>> put(
    Map<String, EpisodeProgress> items,
  ) async {
    if (items.isEmpty) {
      return const {};
    }
    final reply = await _request(
      'POST',
      '/v1/podcasts/progress',
      body: podcastToWire(items),
    );
    final json = reply.json;
    if (json is! Map) {
      throw const PodcastException(PodcastFailure.broken);
    }
    if (json['items'] is! List) {
      throw const PodcastException(PodcastFailure.broken);
    }
    return podcastFromWire(json);
  }

  @override
  Future<PodcastChanges> changes(int after) async {
    final effectiveAfter = after < 0 ? 0 : after;
    final reply = await _request(
      'GET',
      '/v1/podcasts/progress',
      query: {'after': '$effectiveAfter'},
    );
    final json = reply.json;
    if (json is! Map) {
      throw const PodcastException(PodcastFailure.broken);
    }
    if (json['items'] is! List) {
      throw const PodcastException(PodcastFailure.broken);
    }
    final mark = json['mark'];
    if (mark is! int || mark < effectiveAfter) {
      throw const PodcastException(PodcastFailure.broken);
    }
    return PodcastChanges(podcastFromWire(json), mark);
  }
}
