import 'dart:async';

import 'package:flutter/foundation.dart';

import 'player.dart';

/// Sleep timer: pauses playback after selected duration
/// or at end of current track (FT-619).
class SleepTimer extends ChangeNotifier {
  SleepTimer({required this.player, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now {
    player.addListener(_onPlayerChanged);
  }

  final Player player;
  final DateTime Function() _clock;

  Timer? _timer;
  DateTime? _deadline;
  bool _endOfTrack = false;

  /// Whether timer is active (by duration or until track end).
  bool get active => _timer != null || _endOfTrack;

  /// Whether timer is waiting for end of current track.
  bool get endOfTrack => _endOfTrack;

  /// Remaining time until pause. For [untilEndOfTrack] — null.
  Duration? get left {
    if (_deadline == null || _endOfTrack) {
      return null;
    }
    final remaining = _deadline!.difference(_clock());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// Start sleep timer to pause after [after].
  /// Successive call replaces previous deadline.
  void start(Duration after) {
    _timer?.cancel();
    if (_endOfTrack) {
      _endOfTrack = false;
      player.stopAfterCurrent = false;
    }
    _deadline = _clock().add(after);
    _timer = Timer(after, _onFired);
    notifyListeners();
  }

  /// Stop playback at end of current track.
  void untilEndOfTrack() {
    _timer?.cancel();
    _timer = null;
    _deadline = null;
    _endOfTrack = true;
    player.stopAfterCurrent = true;
    notifyListeners();
  }

  /// Cancel sleep timer.
  void cancel() {
    final wasActive = active;
    _timer?.cancel();
    _timer = null;
    _deadline = null;
    if (_endOfTrack) {
      _endOfTrack = false;
      player.stopAfterCurrent = false;
    }
    if (wasActive) {
      notifyListeners();
    }
  }

  void _onFired() {
    _timer = null;
    _deadline = null;
    unawaited(player.pause());
    notifyListeners();
  }

  void _onPlayerChanged() {
    if (_endOfTrack && !player.stopAfterCurrent) {
      _endOfTrack = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _deadline = null;
    if (_endOfTrack) {
      _endOfTrack = false;
      try {
        player.stopAfterCurrent = false;
      } catch (_) {}
    }
    try {
      player.removeListener(_onPlayerChanged);
    } catch (_) {}
    super.dispose();
  }
}
