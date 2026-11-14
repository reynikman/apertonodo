// FT-663: podcasts: screen model (subscriptions, search, episodes) (Р-A93, block В-5).

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'podcast_client.dart';

const int podcastSearchMinChars = 2;
const int podcastSearchLimit = 30;
const int podcastEpisodePage = 50;

enum PodcastLoad { idle, loading, ready, empty, failed }

abstract interface class PodcastSource {
  Future<List<PodcastSubscription>> subscriptions();
  Future<List<FoundPodcast>> search(String query, {int limit = 20});
  Future<PodcastSubscribed> subscribe(String feedUrl);
  Future<bool> unsubscribe(String feedUrl);
  Future<List<PodcastEpisode>> episodes(
    String feedUrl, {
    int limit = 50,
    int offset = 0,
  });
}

PodcastFailure _toFailure(Object error) {
  if (error is PodcastException) {
    return error.reason;
  }
  return PodcastFailure.broken;
}

int _compareSubscriptions(PodcastSubscription a, PodcastSubscription b) {
  if (a.newestAt != null && b.newestAt != null) {
    final cmp = b.newestAt!.compareTo(a.newestAt!);
    if (cmp != 0) return cmp;
  } else if (a.newestAt != null) {
    return -1;
  } else if (b.newestAt != null) {
    return 1;
  }
  final titleA = (a.title ?? '').toLowerCase();
  final titleB = (b.title ?? '').toLowerCase();
  final titleCmp = titleA.compareTo(titleB);
  if (titleCmp != 0) return titleCmp;
  return a.feedUrl.compareTo(b.feedUrl);
}

class PodcastLibrary extends ChangeNotifier {
  PodcastLibrary(this._source);

  final PodcastSource _source;

  bool _disposed = false;
  int _epoch = 0;

  // Subscriptions state
  PodcastLoad _subscriptionsState = PodcastLoad.idle;
  PodcastFailure? _subscriptionsFailure;
  List<PodcastSubscription> _subscriptions = const [];
  int _subsReqId = 0;

  final Set<String> _locallySubscribed = {};
  final Map<String, String> _serverUrl = {};
  final Set<String> _busyUrls = {};
  final Map<String, int> _unsubscribedAtReq = {};

  // Search state
  PodcastLoad _searchState = PodcastLoad.idle;
  PodcastFailure? _searchFailure;
  List<FoundPodcast> _found = const [];
  String _query = '';
  int _searchReqId = 0;

  // Episodes state
  String? _feedUrl;
  PodcastLoad _episodesState = PodcastLoad.idle;
  PodcastFailure? _episodesFailure;
  List<PodcastEpisode> _episodes = const [];
  bool _hasMore = false;
  bool _loadingMore = false;
  bool _moreFailed = false;
  int _feedOffset = 0;
  int _feedReqId = 0;

  // Getters
  PodcastLoad get subscriptionsState => _subscriptionsState;
  PodcastFailure? get subscriptionsFailure => _subscriptionsFailure;
  List<PodcastSubscription> get subscriptions => _subscriptions;

  PodcastLoad get searchState => _searchState;
  PodcastFailure? get searchFailure => _searchFailure;
  List<FoundPodcast> get found => _found;
  String get query => _query;

  String? get feedUrl => _feedUrl;
  PodcastLoad get episodesState => _episodesState;
  PodcastFailure? get episodesFailure => _episodesFailure;
  List<PodcastEpisode> get episodes => _episodes;
  bool get hasMore => _hasMore;
  bool get loadingMore => _loadingMore;
  bool get moreFailed => _moreFailed;

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  bool isSubscribed(String feedUrl) {
    final target = _serverUrl[feedUrl] ?? feedUrl;
    if (_locallySubscribed.contains(feedUrl) ||
        _locallySubscribed.contains(target)) {
      return true;
    }
    for (final s in _subscriptions) {
      if (s.feedUrl == feedUrl || s.feedUrl == target) {
        return true;
      }
      if (_serverUrl[s.feedUrl] == target || _serverUrl[s.feedUrl] == feedUrl) {
        return true;
      }
    }
    return false;
  }

  bool isBusy(String feedUrl) {
    final target = _serverUrl[feedUrl];
    return _busyUrls.contains(feedUrl) ||
        (target != null && _busyUrls.contains(target));
  }

  Future<void> loadSubscriptions() async {
    if (_disposed) return;

    final reqId = ++_subsReqId;
    final epoch = _epoch;
    _subscriptionsState = PodcastLoad.loading;
    _notify();

    try {
      final raw = await _source.subscriptions();
      if (_disposed || _epoch != epoch || _subsReqId != reqId) return;

      final seen = <String>{};
      final unique = <PodcastSubscription>[];
      for (final s in raw) {
        if ((_unsubscribedAtReq[s.feedUrl] ?? 0) >= reqId) {
          continue;
        }
        final target = _serverUrl[s.feedUrl];
        if (target != null && (_unsubscribedAtReq[target] ?? 0) >= reqId) {
          continue;
        }
        if (seen.add(s.feedUrl)) {
          unique.add(s);
        }
      }
      unique.sort(_compareSubscriptions);

      _subscriptions = List.unmodifiable(unique);
      _subscriptionsFailure = null;
      _subscriptionsState = _subscriptions.isEmpty
          ? PodcastLoad.empty
          : PodcastLoad.ready;
      _locallySubscribed.clear();
      _notify();
    } catch (error) {
      if (_disposed || _epoch != epoch || _subsReqId != reqId) return;

      _subscriptionsFailure = _toFailure(error);
      _subscriptionsState = PodcastLoad.failed;
      _notify();
    }
  }

  Future<void> search(String text) async {
    if (_disposed) return;

    final trimmed = text.trim();
    _query = trimmed;
    final reqId = ++_searchReqId;
    final epoch = _epoch;

    if (trimmed.runes.length < podcastSearchMinChars) {
      _found = const [];
      _searchFailure = null;
      _searchState = PodcastLoad.idle;
      _notify();
      return;
    }

    _searchState = PodcastLoad.loading;
    _searchFailure = null;
    _notify();

    try {
      final raw = await _source.search(trimmed, limit: podcastSearchLimit);
      if (_disposed || _epoch != epoch || _searchReqId != reqId) return;

      final seen = <String>{};
      final unique = <FoundPodcast>[];
      for (final f in raw) {
        if (seen.add(f.feedUrl)) {
          unique.add(f);
        }
      }

      _found = List.unmodifiable(unique);
      _searchFailure = null;
      _searchState = _found.isEmpty ? PodcastLoad.empty : PodcastLoad.ready;
      _notify();
    } catch (error) {
      if (_disposed || _epoch != epoch || _searchReqId != reqId) return;

      _found = const [];
      _searchFailure = _toFailure(error);
      _searchState = PodcastLoad.failed;
      _notify();
    }
  }

  Future<PodcastFailure?> subscribe(String feedUrl) async {
    if (_disposed) return null;
    if (isSubscribed(feedUrl)) return null;
    if (isBusy(feedUrl)) return null;

    final epoch = _epoch;
    _busyUrls.add(feedUrl);
    _notify();

    try {
      PodcastSubscribed subscribed;
      try {
        subscribed = await _source.subscribe(feedUrl);
      } on PodcastException catch (e) {
        if (_disposed || _epoch != epoch) return null;
        return e.reason;
      } catch (_) {
        if (_disposed || _epoch != epoch) return null;
        return PodcastFailure.broken;
      }

      if (_disposed || _epoch != epoch) return null;

      final storedUrl = subscribed.feedUrl;
      _serverUrl[feedUrl] = storedUrl;
      _serverUrl[storedUrl] = storedUrl;
      _locallySubscribed.add(feedUrl);
      _locallySubscribed.add(storedUrl);
      _unsubscribedAtReq.remove(feedUrl);
      _unsubscribedAtReq.remove(storedUrl);
      _notify();

      await loadSubscriptions();
      return null;
    } finally {
      if (_epoch == epoch) {
        _busyUrls.remove(feedUrl);
        _notify();
      }
    }
  }

  Future<PodcastFailure?> unsubscribe(String feedUrl) async {
    if (_disposed) return null;
    if (isBusy(feedUrl)) return null;

    final epoch = _epoch;
    final serverUrl = _serverUrl[feedUrl] ?? feedUrl;
    _busyUrls.add(feedUrl);
    if (serverUrl != feedUrl) {
      _busyUrls.add(serverUrl);
    }
    _notify();

    try {
      try {
        await _source.unsubscribe(serverUrl);
      } on PodcastException catch (e) {
        if (_disposed || _epoch != epoch) return null;
        if (e.reason != PodcastFailure.notSubscribed) {
          return e.reason;
        }
      } catch (_) {
        if (_disposed || _epoch != epoch) return null;
        return PodcastFailure.broken;
      }

      if (_disposed || _epoch != epoch) return null;

      _unsubscribedAtReq[feedUrl] = _subsReqId;
      _unsubscribedAtReq[serverUrl] = _subsReqId;
      _locallySubscribed.remove(feedUrl);
      _locallySubscribed.remove(serverUrl);
      // Feed could have been added under multiple URLs: none remains subscribed.
      final gone = [
        for (final entry in _serverUrl.entries)
          if (entry.value == serverUrl) entry.key,
      ];
      for (final url in gone) {
        _serverUrl.remove(url);
        _locallySubscribed.remove(url);
      }
      _serverUrl.remove(feedUrl);

      _subscriptions = List.unmodifiable(
        _subscriptions
            .where(
              (s) =>
                  s.feedUrl != feedUrl &&
                  s.feedUrl != serverUrl &&
                  _serverUrl[s.feedUrl] != serverUrl &&
                  _serverUrl[s.feedUrl] != feedUrl,
            )
            .toList(),
      );

      // List is not loaded (not requested, in flight, error) — unsubscribe doesn't pretend it's loaded:
      // otherwise "failed to load" would turn into "no subscriptions".
      if (_subscriptionsState == PodcastLoad.ready ||
          _subscriptionsState == PodcastLoad.empty) {
        _subscriptionsState = _subscriptions.isEmpty
            ? PodcastLoad.empty
            : PodcastLoad.ready;
      }
      _notify();
      return null;
    } finally {
      if (_epoch == epoch) {
        _busyUrls.remove(feedUrl);
        _busyUrls.remove(serverUrl);
        _notify();
      }
    }
  }

  Future<void> openFeed(String feedUrl) async {
    if (_disposed) return;

    final reqId = ++_feedReqId;
    final epoch = _epoch;

    _feedUrl = feedUrl;
    _episodes = const [];
    _hasMore = false;
    _loadingMore = false;
    _moreFailed = false;
    _feedOffset = 0;
    _episodesFailure = null;
    _episodesState = PodcastLoad.loading;
    _notify();

    try {
      final raw = await _source.episodes(
        feedUrl,
        limit: podcastEpisodePage,
        offset: 0,
      );
      if (_disposed || _epoch != epoch || _feedReqId != reqId) return;

      final seen = <String>{};
      final unique = <PodcastEpisode>[];
      for (final e in raw) {
        if (seen.add(e.guid)) {
          unique.add(e);
        }
      }

      _episodes = List.unmodifiable(unique);
      // Client drops broken episodes and duplicates, so incomplete page is not end-of-list:
      // end-of-list is an empty page.
      _hasMore = raw.isNotEmpty;
      _feedOffset = podcastEpisodePage;
      _episodesFailure = null;
      _episodesState = _episodes.isEmpty
          ? PodcastLoad.empty
          : PodcastLoad.ready;
      _notify();
    } catch (error) {
      if (_disposed || _epoch != epoch || _feedReqId != reqId) return;

      _episodes = const [];
      _hasMore = false;
      _episodesFailure = _toFailure(error);
      _episodesState = PodcastLoad.failed;
      _notify();
    }
  }

  Future<void> loadMore() async {
    if (_disposed) return;
    if (_feedUrl == null) return;
    if (_episodesState != PodcastLoad.ready) return;
    if (!_hasMore) return;
    if (_loadingMore) return;

    final reqId = _feedReqId;
    final epoch = _epoch;
    final feed = _feedUrl!;
    final offset = _feedOffset;

    _loadingMore = true;
    _moreFailed = false;
    _notify();

    try {
      final raw = await _source.episodes(
        feed,
        limit: podcastEpisodePage,
        offset: offset,
      );
      if (_disposed || _epoch != epoch || _feedReqId != reqId) return;

      final seen = _episodes.map((e) => e.guid).toSet();
      final next = List<PodcastEpisode>.of(_episodes);
      for (final e in raw) {
        if (seen.add(e.guid)) {
          next.add(e);
        }
      }

      _episodes = List.unmodifiable(next);
      // Client drops broken episodes and duplicates, so incomplete page is not end-of-list:
      // end-of-list is an empty page.
      _hasMore = raw.isNotEmpty;
      _feedOffset += podcastEpisodePage;
      _loadingMore = false;
      _moreFailed = false;
      _notify();
    } catch (error) {
      if (_disposed || _epoch != epoch || _feedReqId != reqId) return;

      _loadingMore = false;
      _moreFailed = true;
      _notify();
    }
  }

  void closeFeed() {
    if (_disposed) return;
    if (_feedUrl == null && _episodesState == PodcastLoad.idle) return;

    _feedReqId++;
    _feedUrl = null;
    _episodesState = PodcastLoad.idle;
    _episodesFailure = null;
    _episodes = const [];
    _hasMore = false;
    _loadingMore = false;
    _moreFailed = false;
    _feedOffset = 0;
    _notify();
  }

  void clear() {
    if (_disposed) return;

    _epoch++;
    _subsReqId++;
    _searchReqId++;
    _feedReqId++;

    _subscriptionsState = PodcastLoad.idle;
    _subscriptionsFailure = null;
    _subscriptions = const [];
    _locallySubscribed.clear();
    _serverUrl.clear();
    _busyUrls.clear();
    _unsubscribedAtReq.clear();

    _searchState = PodcastLoad.idle;
    _searchFailure = null;
    _found = const [];
    _query = '';

    _feedUrl = null;
    _episodesState = PodcastLoad.idle;
    _episodesFailure = null;
    _episodes = const [];
    _hasMore = false;
    _loadingMore = false;
    _moreFailed = false;
    _feedOffset = 0;

    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  String toString() =>
      'PodcastLibrary(${subscriptionsState.name}/${searchState.name}/${episodesState.name})';
}
