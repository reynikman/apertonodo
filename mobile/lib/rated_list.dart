import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'models/track.dart';
import 'ratings.dart';

/// Single page of `GET /v1/ratings` response (FT-642).
@immutable
class RatedPage {
  const RatedPage({
    required this.tracks,
    required this.ratings,
    required this.total,
  });

  final List<Track> tracks;
  final Map<String, Rating> ratings;
  final int total;

  /// `{"tracks": [{...track..., "stars": 4, "disliked": false}], "total": 240}`.
  ///
  /// Malformed row skipped, remainder kept; malformed response — empty
  /// page. No unhandled exceptions: parsing must not crash screen.
  factory RatedPage.fromJson(Object? json) {
    final rows = json is Map ? json['tracks'] : null;
    if (rows is! List) {
      return const RatedPage(tracks: [], ratings: {}, total: 0);
    }
    final tracks = <Track>[];
    final ratings = <String, Rating>{};
    for (final row in rows) {
      if (row is! Map) continue;
      try {
        final map = Map<String, Object?>.from(row);
        final track = Track.fromJson(map);
        final rating = Rating.fromJson(map);
        if (track.id.isEmpty || rating.isNone) continue;
        if (ratings.containsKey(track.id)) continue;
        tracks.add(track);
        ratings[track.id] = rating;
      } catch (_) {
        continue;
      }
    }
    final total = json is Map ? json['total'] : null;
    return RatedPage(
      tracks: tracks,
      ratings: ratings,
      total: total is int && total >= tracks.length ? total : tracks.length,
    );
  }
}

/// What list requests from server. Concrete implementation on top of
/// `server_api.dart` is wired by lead; here — contract only.
abstract interface class RatedPort {
  Future<RatedPage> list({
    required int minStars,
    required bool disliked,
    required int limit,
    required int offset,
  });
}

/// Rated songs paginated: "from N stars" threshold or "Disliked" list.
///
/// Row does not vanish when user changes rating on this screen:
/// list is rebuilt only on network request, does not observe [RatingsStore].
class RatedList extends ChangeNotifier {
  RatedList(this._port, this._store, {this.disliked = false});

  static const pageSize = 100;

  final RatedPort _port;
  final RatingsStore _store;

  /// Whether this is "Disliked" list: has no star threshold.
  final bool disliked;

  final List<Track> _tracks = [];
  late final List<Track> _view = UnmodifiableListView(_tracks);
  int _total = 0;
  int _minStars = 1;
  bool _loading = false;
  bool _failed = false;

  /// How many items requested (next page offset), not how many displayed.
  int _asked = 0;
  bool _lastEmpty = false;

  /// Offset of failed request: retry requests same page.
  int _retryOffset = 0;

  /// Request generation number: response of previous generation is ignored.
  int _generation = 0;
  bool _disposed = false;

  List<Track> get tracks => _view;
  int get total => _total;
  int get minStars => _minStars;
  bool get loading => _loading;
  bool get failed => _failed;
  bool get hasMore => _asked < _total && !_lastEmpty;

  /// Refresh first page; previous rows remain in place until response arrives.
  Future<void> load() => _fetch(0);

  /// Next page; no-op while request in flight or when all items loaded.
  Future<void> loadMore() {
    if (_loading || !hasMore) return Future.value();
    return _fetch(_asked);
  }

  /// Threshold "from N stars": previous rows cleared immediately, reloads from start.
  Future<void> setMinStars(int stars) {
    if (stars < 1 || stars > 5) {
      throw ArgumentError.value(stars, 'stars', 'must be 1…5');
    }
    if (disliked || stars == _minStars) return Future.value();
    _minStars = stars;
    _tracks.clear();
    _total = 0;
    _asked = 0;
    _lastEmpty = false;
    return _fetch(0);
  }

  /// Retry failed request — requests the same page.
  Future<void> retry() {
    if (!_failed || _loading) return Future.value();
    return _fetch(_retryOffset);
  }

  Future<void> _fetch(int offset) async {
    if (_disposed) return;
    final mine = ++_generation;
    final asked = _store.clock;
    _loading = true;
    _failed = false;
    _notify();
    final RatedPage page;
    try {
      page = await _port.list(
        minStars: _minStars,
        disliked: disliked,
        limit: pageSize,
        offset: offset,
      );
    } catch (_) {
      if (_disposed || mine != _generation) return;
      _loading = false;
      _failed = true;
      _retryOffset = offset;
      _notify();
      return;
    }
    if (_disposed || mine != _generation) return;
    _store.adopt(page.ratings, since: asked);
    if (offset == 0) _tracks.clear();
    final have = {for (final t in _tracks) t.id};
    for (final track in page.tracks) {
      if (have.add(track.id)) _tracks.add(track);
    }
    _total = page.total;
    _asked = offset + pageSize;
    _lastEmpty = page.tracks.isEmpty;
    _loading = false;
    _notify();
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
