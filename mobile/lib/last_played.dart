import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'models/track.dart';

/// What was playing when app was killed. Stored on the phone.
class LastPlayed {
  LastPlayed({Future<SharedPreferences>? store, String? namespace})
    : _store = store ?? SharedPreferences.getInstance(),
      _key = namespace == null ? key : '$namespace/$key';

  static const key = 'last-played';

  final Future<SharedPreferences> _store;
  final String _key;

  Future<LastPlayedSnapshot?> load() async {
    try {
      final raw = (await _store).getString(_key);
      if (raw == null || raw.isEmpty) {
        return null;
      }
      return LastPlayedSnapshot.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      // Storage unavailable or corrupted entry — pretend nothing happened.
      // Crashing the screen due to saved playback state is unacceptable.
      return null;
    }
  }

  Future<void> save({
    required List<Track> tracks,
    required int index,
    required Duration position,
  }) async {
    try {
      await (await _store).setString(
        _key,
        jsonEncode(
          LastPlayedSnapshot(
            tracks: tracks,
            index: index,
            position: position,
          ).toJson(),
        ),
      );
    } catch (_) {
      // Failed to write — next launch will have no restored state.
    }
  }
}

class LastPlayedSnapshot {
  const LastPlayedSnapshot({
    required this.tracks,
    required this.index,
    required this.position,
  });

  final List<Track> tracks;
  final int index;
  final Duration position;

  factory LastPlayedSnapshot.fromJson(Map<String, dynamic> json) {
    final tracks = [
      for (final item in json['tracks'] as List)
        Track.fromJson(Map<String, dynamic>.from(item as Map)),
    ];
    final index = json['index'] as int;
    if (tracks.isEmpty || index < 0 || index >= tracks.length) {
      throw const FormatException('last-played');
    }
    return LastPlayedSnapshot(
      tracks: tracks,
      index: index,
      position: Duration(milliseconds: json['position_ms'] as int? ?? 0),
    );
  }

  Map<String, dynamic> toJson() => {
    'tracks': [
      for (final track in tracks)
        {...track.toJson(), 'playable': track.playable},
    ],
    'index': index,
    'position_ms': position.inMilliseconds,
  };
}
