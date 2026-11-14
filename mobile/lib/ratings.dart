import 'dart:async';

import 'package:flutter/foundation.dart';

/// Track rating: from one to five stars or disliked (FT-638, P-A94).
///
/// Stars and disliked cannot co-exist. Without a rating: [none].
@immutable
class Rating {
  const Rating({this.stars = 0, this.disliked = false});

  static const none = Rating();

  final int stars;
  final bool disliked;

  bool get isNone => stars == 0 && !disliked;

  /// Server response `{"stars": 4, "disliked": false}`.
  ///
  /// `disliked` exactly `true` means disliked without stars. Otherwise stars is an integer
  /// 1…5. Malformed payload yields no rating without throwing: response parsing must not
  /// crash the screen.
  factory Rating.fromJson(Map<String, Object?> json) {
    if (json['disliked'] == true) return const Rating(disliked: true);
    final stars = json['stars'];
    if (stars is int && stars >= 1 && stars <= 5) return Rating(stars: stars);
    return none;
  }

  @override
  bool operator ==(Object other) =>
      other is Rating && other.stars == stars && other.disliked == disliked;

  @override
  int get hashCode => Object.hash(stars, disliked);
}

/// What the app requests from the server. The actual implementation on top of
/// `server_api.dart` is written by the lead; here is only the contract.
abstract interface class RatingsPort {
  /// Only rated tracks.
  Future<Map<String, Rating>> of(List<String> trackIds);
  Future<Rating> set(String trackId, {int? stars, bool? disliked});
}

/// What the app knows about ratings while running (FT-638).
///
/// Displayed value and server-confirmed value are different things: star
/// lights up immediately, and upon error reverts to what the server last confirmed.
/// Rapid taps on the same track are sent to the server sequentially, in
/// order of taps: the last tap wins both on screen and on the server.
class RatingsStore extends ChangeNotifier {
  RatingsStore(this._port);

  static const _batch = 500;

  final RatingsPort _port;

  /// What is shown on screen.
  final Map<String, Rating> _shown = {};

  /// What the server confirmed last.
  final Map<String, Rating> _confirmed = {};

  /// Number of in-flight taps for the track that have not received a response yet.
  final Map<String, int> _waiting = {};

  /// Tail of request queue for the track: next request is sent after previous completes.
  final Map<String, Future<void>> _tail = {};

  /// Tracks whose last tap the server failed to save.
  final Set<String> _failed = {};

  /// Tracks the app already knows about (including unrated ones).
  final Set<String> _known = {};

  /// Tap counter and timestamp of last tap on track: used by list
  /// to distinguish responses captured before the tap.
  int _clock = 0;
  final Map<String, int> _pressed = {};

  bool _disposed = false;

  /// Increments with each tap; see [adopt].
  int get clock => _clock;

  Rating ratingOf(String trackId) => _shown[trackId] ?? Rating.none;

  /// Last tap on track failed to save; clears after a successful tap.
  bool failedOf(String trackId) => _failed.contains(trackId);

  /// Queries server only for unknown tracks, in batches up to 500. Failure
  /// does not throw, tracks remain unknown.
  Future<void> load(List<String> trackIds) async {
    final ask = <String>[];
    final seen = <String>{};
    for (final id in trackIds) {
      if (!_known.contains(id) && seen.add(id)) ask.add(id);
    }
    for (var i = 0; i < ask.length; i += _batch) {
      final end = i + _batch < ask.length ? i + _batch : ask.length;
      final ids = ask.sublist(i, end);
      final Map<String, Rating> answer;
      try {
        answer = await _port.of(ids);
      } catch (_) {
        continue;
      }
      if (_disposed) return;
      var changed = false;
      for (final id in ids) {
        _known.add(id);
        // Server already replied to tap — its response is fresher than load.
        if (_confirmed.containsKey(id)) continue;
        final rating = answer[id] ?? Rating.none;
        _confirmed[id] = rating;
        // Tap is still in flight: screen follows tap, and on error this value will return.
        if (_waiting.containsKey(id)) continue;
        _shown[id] = rating;
        changed = true;
      }
      if (changed) notifyListeners();
    }
  }

  /// Server just returned ratings for these tracks (the "Rated" list).
  ///
  /// They are visible immediately, known and confirmed. Tracks with in-flight taps
  /// are untouched: screen follows tap. Single notification, only on change.
  ///
  /// [since] is [clock] when list was requested: tracks tapped by user
  /// afterwards are left untouched — the response was snapshot before the tap.
  void adopt(Map<String, Rating> ratings, {int? since}) {
    var changed = false;
    for (final entry in ratings.entries) {
      final id = entry.key;
      if (_waiting.containsKey(id)) continue;
      if (since != null && (_pressed[id] ?? 0) > since) continue;
      _known.add(id);
      _confirmed[id] = entry.value;
      if (_shown[id] != entry.value) {
        _shown[id] = entry.value;
        changed = true;
      }
    }
    if (changed) _notify();
  }

  /// Tapping the same star a second time clears rating (sends `stars: 0` to server).
  Future<bool> setStars(String trackId, int stars) {
    if (stars < 0 || stars > 5) {
      throw ArgumentError.value(stars, 'stars', 'must be 0…5');
    }
    final value = stars == ratingOf(trackId).stars ? 0 : stars;
    return _save(
      trackId,
      Rating(stars: value),
      () => _port.set(trackId, stars: value),
    );
  }

  Future<bool> setDisliked(String trackId, bool disliked) => _save(
    trackId,
    Rating(disliked: disliked),
    () => _port.set(trackId, disliked: disliked),
  );

  Future<bool> _save(
    String trackId,
    Rating next,
    Future<Rating> Function() send,
  ) async {
    _waiting[trackId] = (_waiting[trackId] ?? 0) + 1;
    _pressed[trackId] = ++_clock;
    _known.add(trackId);
    _shown[trackId] = next;
    _notify();
    // Two simultaneous requests could be processed in any order by server —
    // which would leave something other than the last tap on the server.
    final before = _tail[trackId];
    final done = Completer<void>();
    _tail[trackId] = done.future;
    if (before != null) await before;
    var saved = false;
    try {
      _confirmed[trackId] = await send();
      saved = true;
    } catch (_) {}
    final left = _waiting[trackId]! - 1;
    if (left > 0) {
      _waiting[trackId] = left;
    } else {
      // This was the last tap: screen shows what is on the server.
      _waiting.remove(trackId);
      _tail.remove(trackId);
      _shown[trackId] = _confirmed[trackId] ?? Rating.none;
      saved ? _failed.remove(trackId) : _failed.add(trackId);
      _notify();
    }
    done.complete();
    return saved;
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
