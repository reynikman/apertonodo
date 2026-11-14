import 'history_control.dart';
import 'rated_list.dart';
import 'ratings.dart';
import 'server_api.dart';

/// History and ratings ports on top of real server (connection 2, 11.10).
/// Parsing responses is done by models themselves: malformed response does not crash screen.

class ServerHistoryPort implements HistoryPort {
  const ServerHistoryPort(this._server);

  final ServerApi _server;

  @override
  Future<int> remove(String trackId, DateTime playedAt) =>
      _server.historyRemove(trackId, playedAt);

  @override
  Future<int> clear() => _server.historyClear();

  @override
  Future<HistoryPause> pause(bool paused, {DateTime? until}) async =>
      _pause(await _server.historyPause(paused, until: until));

  @override
  Future<HistoryPause> pauseState() async =>
      _pause(await _server.historyPauseState());

  HistoryPause _pause(Object? json) => HistoryPause.fromJson(
    json is Map ? Map<String, Object?>.from(json) : const {},
  );
}

class ServerRatingsPort implements RatingsPort {
  const ServerRatingsPort(this._server);

  final ServerApi _server;

  @override
  Future<Map<String, Rating>> of(List<String> trackIds) async {
    final json = await _server.ratingsOf(trackIds);
    final rows = json is Map ? json['ratings'] : null;
    if (rows is! Map) return const {};
    return {
      for (final MapEntry(:key, :value) in rows.entries)
        if (key is String && value is Map)
          key: Rating.fromJson(Map<String, Object?>.from(value)),
    };
  }

  @override
  Future<Rating> set(String trackId, {int? stars, bool? disliked}) async {
    final json = await _server.rate(trackId, stars: stars, disliked: disliked);
    if (json is! Map) throw const FormatException('rating');
    return Rating.fromJson(Map<String, Object?>.from(json));
  }
}

class ServerRatedPort implements RatedPort {
  const ServerRatedPort(this._server);

  final ServerApi _server;

  @override
  Future<RatedPage> list({
    required int minStars,
    required bool disliked,
    required int limit,
    required int offset,
  }) async => RatedPage.fromJson(
    await _server.rated(
      minStars: minStars,
      disliked: disliked,
      limit: limit,
      offset: offset,
    ),
  );
}
