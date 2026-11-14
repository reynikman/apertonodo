// FT-730: podcast episode speed in player.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'playback.dart';
import 'player.dart';

/// Audio speed follows track: episode has its podcast's speed,
/// track always has normal. Audio player remembers speed itself and wouldn't reset
/// it when track plays after episode.
class PlaybackSpeed extends ChangeNotifier {
  PlaybackSpeed(
    this.player,
    this.audio, {
    required this.speedFor,
    required this.save,
  }) {
    player.addListener(_follow);
    player.canJoin = (current, next) => _speedOf(current) == _speedOf(next);
    _follow();
  }

  final Player player;
  final AudioPort audio;

  /// Speed of track with this id; `null` — its speed does not change.
  final double? Function(String trackId) speedFor;

  /// Remember chosen speed for track (for its podcast).
  final Future<void> Function(String trackId, double speed) save;

  String? _trackId;
  double _applied = 1.0;

  /// Choice on screen while being written to disk: button sees it immediately.
  double? _chosen;
  var _disposed = false;

  /// Speed of currently playing episode; `null` — track has no speed choice.
  double? get current {
    final id = _trackId;
    if (id == null) return null;
    final stored = speedFor(id);
    return stored == null ? null : _chosen ?? stored;
  }

  double _speedOf(String id) =>
      id == _trackId ? current ?? 1.0 : speedFor(id) ?? 1.0;

  void _follow() {
    final id = player.current?.id;
    if (id == _trackId) return;
    _trackId = id;
    _chosen = null;
    _apply(id == null ? 1.0 : speedFor(id) ?? 1.0);
    notifyListeners();
  }

  void _apply(double speed) {
    if (speed == _applied) return;
    _applied = speed;
    // Audio channel failure does not crash app; next choice will try again.
    unawaited(
      audio.setSpeed(speed).catchError((Object _) {
        if (_applied == speed) _applied = double.nan;
      }),
    );
  }

  /// Choice on player screen: directly into audio and podcast storage.
  Future<void> set(double speed) async {
    final id = _trackId;
    if (id == null || speedFor(id) == null) return;
    _chosen = speed;
    _apply(speed);
    player.refreshNext();
    notifyListeners();
    await save(id, speed);
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    player.removeListener(_follow);
    player.canJoin = null;
    super.dispose();
  }
}
