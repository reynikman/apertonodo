import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'auth/token_provider.dart';
import 'models/track.dart';

/// Why search produced no results.
///
/// Previously any response other than 200 became an empty list: "nothing
/// found", even though there was nothing to search — key changed, catalog down, network
/// lost (audit September 18).
enum SearchFailure {
  /// Build key does not match server (401).
  noAccess,

  /// Server is alive, but live catalog did not respond (503).
  catalogDown,

  /// Server rate-limited requests (429).
  tooMany,

  /// Server did not respond: network, timeout, failure.
  noAnswer,
}

class SearchFailed implements Exception {
  const SearchFailed(this.reason);

  final SearchFailure reason;

  @override
  String toString() => 'SearchFailed(${reason.name})';
}

/// Search results: artists from own catalog and songs.
///
/// Artists come as a separate list, not rows among songs: tapping
/// them opens artist page rather than starting playback.
class SearchResult {
  const SearchResult({
    this.artists = const [],
    this.photos = const <String, String>{},
    this.tracks = const [],
  });

  final List<String> artists;

  /// Photo path by name. No key — circle with letters suffices.
  final Map<String, String> photos;
  final List<Track> tracks;

  bool get isEmpty => artists.isEmpty && tracks.isEmpty;
}

abstract class CatalogPort {
  /// Results for query. On failure — [SearchFailed] with reason.
  Future<SearchResult> search(String query);

  /// Suggestions while typing — from server's own database.
  ///
  /// Suggestion is not an answer, but convenience: its failure stays silent with empty list, otherwise
  /// every typed letter without network would look like a search error.
  Future<List<String>> suggest(String query);
}

class LocalCatalog implements CatalogPort {
  LocalCatalog(this.tracks);

  final List<Track> tracks;

  @override
  Future<SearchResult> search(String query) async {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) {
      return SearchResult(tracks: tracks);
    }
    return SearchResult(
      tracks: tracks
          .where(
            (track) =>
                track.title.toLowerCase().contains(needle) ||
                track.artist.toLowerCase().contains(needle),
          )
          .toList(),
    );
  }

  /// List on disk has no suggestions: they come from server db, which is absent here.
  @override
  Future<List<String>> suggest(String query) async => const [];
}

class HttpCatalog implements CatalogPort {
  HttpCatalog(
    this.baseUrl, {
    required this.tokens,
    http.Client? client,
    this.timeout = searchTimeout,
  }) : _client = client ?? http.Client();

  /// Server waits for live catalog up to 6 seconds; remainder is margin for mobile
  /// network. Without limit, a hung connection meant forever-empty results.
  static const searchTimeout = Duration(seconds: 25);

  /// Suggestion either arrives in time while user types, or is not needed at all.
  /// Server responds in tens of milliseconds, remainder is margin for network.
  static const suggestTimeout = Duration(seconds: 3);

  final String baseUrl;
  final TokenProvider tokens;
  final Duration timeout;
  final http.Client _client;

  @override
  Future<SearchResult> search(String query) async {
    final uri = Uri.parse(
      '$baseUrl/v1/search',
    ).replace(queryParameters: {'q': query, 'limit': '20'});
    final http.Response response;
    try {
      response = await _client
          .get(uri, headers: tokens.headersFor(uri))
          .timeout(timeout);
    } on Exception {
      throw const SearchFailed(SearchFailure.noAnswer);
    }
    if (response.statusCode == 401) {
      await tokens.onUnauthorized();
    }
    switch (response.statusCode) {
      case 200:
        break;
      case 401:
        throw const SearchFailed(SearchFailure.noAccess);
      case 429:
        throw const SearchFailed(SearchFailure.tooMany);
      case 503:
        throw const SearchFailed(SearchFailure.catalogDown);
      default:
        throw const SearchFailed(SearchFailure.noAnswer);
    }
    try {
      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final rows = payload['tracks'] as List<dynamic>? ?? const [];
      final names = payload['artists'] as List<dynamic>? ?? const [];
      final artistRows = [for (final row in names) row as Map<String, dynamic>];
      return SearchResult(
        artists: [for (final row in artistRows) row['name'] as String],
        photos: {
          for (final row in artistRows)
            if (row['photo'] is String)
              row['name'] as String: row['photo'] as String,
        },
        tracks: rows
            .map((row) => Track.fromJson(row as Map<String, dynamic>))
            .toList(),
      );
    } catch (_) {
      throw const SearchFailed(SearchFailure.noAnswer);
    }
  }

  /// Suggestions from server's own database. Nothing typed is known to anyone except
  /// the owner's server: neither Apple, nor Deezer, nor Last.fm. Suggestion failure
  /// stays silent, except 429: distinguishing it from lack of network is important.
  @override
  Future<List<String>> suggest(String query) async {
    final uri = Uri.parse(
      '$baseUrl/v1/suggest',
    ).replace(queryParameters: {'q': query, 'limit': '10'});
    try {
      final response = await _client
          .get(uri, headers: tokens.headersFor(uri))
          .timeout(suggestTimeout);
      if (response.statusCode == 401) {
        await tokens.onUnauthorized();
      }
      if (response.statusCode == 429) {
        throw const SearchFailed(SearchFailure.tooMany);
      }
      if (response.statusCode != 200) {
        return const [];
      }
      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final rows = payload['suggestions'] as List<dynamic>? ?? const [];
      return rows.map((row) => row as String).toList();
    } on SearchFailed {
      rethrow;
    } catch (_) {
      return const [];
    }
  }
}
