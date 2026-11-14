import 'package:flutter/foundation.dart';

import 'audio_info.dart';

/// Source file format of each song — for player badge (FT-633),
/// and loudness adjustment (FT-765).
///
/// Server specifies it in Play response (`audio` block, FT-684); stored
/// here by track ID so player screen shows badge without knowing
/// anything about Play request. Only format word: no file name, no release info.
class TrackFormats extends ChangeNotifier {
  /// How many tracks to remember: queue and prepped tracks with margin.
  static const limit = 200;

  final _byId = <String, _FormatEntry>{};

  String? of(String trackId) => _byId[trackId]?.format;

  double? gainOf(String trackId) => _byId[trackId]?.gainDb;

  /// The `audio` block from Play response for [trackId]. Missing block or
  /// unknown format clears previous entry: old badge on new release would
  /// be inaccurate, while missing badge keeps row unchanged.
  void note(String trackId, Object? audio) {
    final info = AudioInfo.fromJson(audio);
    final old = _byId.remove(trackId);
    if (info != null) {
      _byId[trackId] = _FormatEntry(info.format, info.gainDb);
    }
    if (old?.format == info?.format && old?.gainDb == info?.gainDb) return;
    while (_byId.length > limit) {
      _byId.remove(_byId.keys.first);
    }
    notifyListeners();
  }
}

class _FormatEntry {
  const _FormatEntry(this.format, this.gainDb);
  final String format;
  final double? gainDb;
}
