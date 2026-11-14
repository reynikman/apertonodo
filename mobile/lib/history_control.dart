import 'dart:async';

import 'package:flutter/foundation.dart';

/// Server response regarding history pause (FT-634, Р-A49).
///
/// `{"paused": true, "until": "<ISO>"}`. Anything malformed — missing field, `paused` not
/// `true`, `until` not a string or not a date, pause without deadline — means pause is not
/// active: `paused: false, until: null`, without exceptions. Response parsing must not
/// crash the screen, so unknown format equals "pause is off".
class HistoryPause {
  const HistoryPause({required this.paused, this.until});

  final bool paused;
  final DateTime? until;

  factory HistoryPause.fromJson(Map<String, Object?> json) {
    if (json['paused'] != true) return const HistoryPause(paused: false);
    final raw = json['until'];
    if (raw is! String) return const HistoryPause(paused: false);
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return const HistoryPause(paused: false);
    return HistoryPause(paused: true, until: parsed);
  }
}

/// What the app requests from the server. Real implementation on top of
/// `server_api.dart` is written by lead; here — contract only.
abstract interface class HistoryPort {
  Future<int> remove(String trackId, DateTime playedAt);
  Future<int> clear();
  Future<HistoryPause> pause(bool paused, {DateTime? until});
  Future<HistoryPause> pauseState();
}

/// History logic in the app: remove row with undo, clear all,
/// "do not record" for a chosen time (FT-634, FT-853).
///
/// A history row is a pair of "song + listened timestamp", not a song: the same
/// song played another time is a different row. Exactly the `track_id` and
/// time that came in the row are sent to the server, without rounding or timezone
/// change.
class HistoryControl extends ChangeNotifier {
  HistoryControl(
    this._port, {
    this.undoWindow = const Duration(seconds: 5),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final HistoryPort _port;
  final Duration undoWindow;
  final DateTime Function() _now;

  final Set<(String, DateTime)> _hidden = {};
  (String, DateTime)? _pending;
  Timer? _undoTimer;

  DateTime? _pausedUntil;
  Timer? _pauseTimer;
  int _pauseTurn = 0;

  bool _removeFailed = false;
  bool _disposed = false;

  /// Row is hidden: either awaiting send, or already removed on server.
  bool isHidden(String trackId, DateTime playedAt) =>
      _hidden.contains((trackId, playedAt));

  /// There is a pending row that can still be restored.
  bool get canUndo => _pending != null;

  /// Last deletion send failed — row returned, this needs to be
  /// communicated in words.
  bool get removeFailed => _removeFailed;

  /// Pause is active: there is a deadline, and it has not expired by phone clock.
  bool get paused {
    final until = _pausedUntil;
    return until != null && _now().isBefore(until);
  }

  /// Pause deadline while active, otherwise `null`.
  DateTime? get pausedUntil => paused ? _pausedUntil : null;

  /// "Until I turn it back on" (FT-853): for the server it is just a deadline
  /// far away; a deadline years ahead is shown without a clock time.
  bool get pausedForever {
    final until = pausedUntil;
    return until != null && until.difference(_now()) > foreverAfter;
  }

  /// A pause longer than this is "until turned back on".
  static const foreverAfter = Duration(days: 3650);

  /// Phone clock the pause is measured by.
  DateTime get now => _now();

  /// Hides row immediately, and sends it to server only after
  /// [undoWindow]. While waiting — row can be restored via [undo]. If there is already
  /// a pending row, it is sent to server immediately without waiting for timeout.
  void removeLater(String trackId, DateTime playedAt) {
    _removeFailed = false;
    if (_pending != null) _flushPending();
    _hidden.add((trackId, playedAt));
    _pending = (trackId, playedAt);
    _undoTimer?.cancel();
    _undoTimer = Timer(undoWindow, _flushPending);
    _notify();
  }

  /// Restores pending row. Does not make network requests.
  void undo() {
    _undoTimer?.cancel();
    _undoTimer = null;
    final pending = _pending;
    if (pending != null) {
      _hidden.remove(pending);
      _pending = null;
      _notify();
    }
  }

  /// Sends pending row now; repeated call does nothing.
  Future<void> flush() async {
    if (_pending != null) _flushPending();
  }

  /// Clears entire history. Cancels pending row without [remove] request,
  /// because history is being cleared completely anyway. `true` on success, `false`
  /// on exception.
  Future<bool> clear() async {
    _undoTimer?.cancel();
    _undoTimer = null;
    final pending = _pending;
    _pending = null;
    _notify();
    try {
      await _port.clear();
      _hidden.clear();
      _notify();
      return true;
    } catch (_) {
      // Clear failed: already removed rows stay hidden (they are
      // gone on server), and pending one goes via its own request — user removed it.
      if (pending != null) unawaited(_send(pending.$1, pending.$2));
      _notify();
      return false;
    }
  }

  /// Reads pause state from server. Failure — no pause, without exception.
  Future<void> load() async {
    final turn = ++_pauseTurn;
    try {
      final state = await _port.pauseState();
      if (_disposed || turn != _pauseTurn) return;
      _applyPause(state);
    } catch (_) {
      if (_disposed || turn != _pauseTurn) return;
      _applyPause(const HistoryPause(paused: false));
    }
  }

  /// Enables or disables pause via server. [until] is the deadline the person
  /// chose; without it the server takes its own three hours. State is taken
  /// from server response; failure — `false`, state unchanged.
  Future<bool> setPaused(bool value, {DateTime? until}) async {
    final turn = ++_pauseTurn;
    try {
      final state = await _port.pause(value, until: value ? until : null);
      if (_disposed) return false;
      // Response to an older request does not overwrite a newer one.
      if (turn == _pauseTurn) _applyPause(state);
      return true;
    } catch (_) {
      return false;
    }
  }

  void _flushPending() {
    final pending = _pending;
    if (pending == null) return;
    _pending = null;
    _undoTimer?.cancel();
    _undoTimer = null;
    _send(pending.$1, pending.$2);
    _notify();
  }

  Future<void> _send(String trackId, DateTime playedAt) async {
    try {
      await _port.remove(trackId, playedAt);
    } catch (_) {
      if (_disposed) return;
      _hidden.remove((trackId, playedAt));
      _removeFailed = true;
      _notify();
    }
  }

  void _applyPause(HistoryPause state) {
    _pauseTimer?.cancel();
    _pauseTimer = null;
    final until = state.paused ? state.until : null;
    _pausedUntil = until;
    // "Until turned back on" never runs out: no timer to arm.
    if (until != null && until.difference(_now()) <= foreverAfter) {
      final remaining = until.difference(_now());
      _pauseTimer = Timer(
        remaining.isNegative ? Duration.zero : remaining,
        _notify,
      );
    }
    _notify();
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _undoTimer?.cancel();
    _undoTimer = null;
    final pending = _pending;
    _pending = null;
    if (pending != null) _send(pending.$1, pending.$2);
    _pauseTimer?.cancel();
    _pauseTimer = null;
    super.dispose();
  }
}
