// FT-703: sections and popular podcasts in app (Р-A108 item 2).

import 'dart:async';

import 'podcast_client.dart';

const int podcastMaxCategories = 50;

final RegExp _countryPattern = RegExp(r'^[a-z]{2}$');

class PodcastCategory {
  final int id;
  final String ru;
  final String en;

  const PodcastCategory({required this.id, required this.ru, required this.en});

  String title(String languageCode) =>
      languageCode.toLowerCase() == 'ru' ? ru : en;

  static PodcastCategory? fromJson(Object? json) {
    if (json is! Map) return null;
    final rawId = json['id'];
    if (rawId is! int || rawId <= 0) return null;
    final ru = cleanText(json['ru']);
    if (ru == null) return null;
    final en = cleanText(json['en']);
    if (en == null) return null;
    return PodcastCategory(id: rawId, ru: ru, en: en);
  }

  @override
  String toString() => 'PodcastCategory($id)';
}

class PodcastCatalogClient {
  final PodcastSend _send;

  PodcastCatalogClient(this._send);

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
    if (status == 503) {
      if (reply.json is Map &&
          (reply.json as Map)['status'] == 'podcast_search_unavailable') {
        throw const PodcastException(PodcastFailure.searchUnavailable);
      }
      throw const PodcastException(PodcastFailure.unavailable);
    }

    throw const PodcastException(PodcastFailure.unavailable);
  }

  Future<List<PodcastCategory>> categories() async {
    final reply = await _request('GET', '/v1/podcasts/categories');
    final json = reply.json;
    if (json is! Map) {
      throw const PodcastException(PodcastFailure.broken);
    }
    final rawList = json['categories'];
    if (rawList is! List) {
      throw const PodcastException(PodcastFailure.broken);
    }

    final results = <PodcastCategory>[];
    final seen = <int>{};
    for (final item in rawList) {
      final parsed = PodcastCategory.fromJson(item);
      if (parsed == null) continue;
      if (seen.add(parsed.id)) {
        results.add(parsed);
        if (results.length >= podcastMaxCategories) break;
      }
    }
    return List.unmodifiable(results);
  }

  Future<List<FoundPodcast>> top({int? category, String? country}) async {
    Map<String, String>? query;
    if (category != null && category > 0) {
      query ??= <String, String>{};
      query['category'] = '$category';
    }
    if (country != null && _countryPattern.hasMatch(country)) {
      query ??= <String, String>{};
      query['country'] = country;
    }

    final reply = await _request('GET', '/v1/podcasts/top', query: query);
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

  @override
  String toString() => 'PodcastCatalogClient';
}
