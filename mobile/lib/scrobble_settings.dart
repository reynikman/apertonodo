import 'package:flutter/foundation.dart';

enum ScrobbleState { unavailable, off, pending, on, badToken }

enum ScrobbleError {
  load,
  tokenShape,
  save,
  lastfmStart,
  lastfmNotYet,
  lastfmExpired,
}

ScrobbleState? _word(Object? value) => switch (value) {
  'unavailable' => ScrobbleState.unavailable,
  'off' => ScrobbleState.off,
  'pending' => ScrobbleState.pending,
  'on' => ScrobbleState.on,
  'bad_token' => ScrobbleState.badToken,
  _ => null,
};

class ScrobbleStatus {
  const ScrobbleStatus({required this.listenbrainz, required this.lastfm});

  /// Server response `{"listenbrainz": "on", "lastfm": "pending"}`; malformed — no exceptions thrown.
  factory ScrobbleStatus.fromJson(Object? json) {
    final map = json is Map ? json : const {};
    final lb = _word(map['listenbrainz']);
    return ScrobbleStatus(
      listenbrainz: lb == ScrobbleState.on || lb == ScrobbleState.badToken
          ? lb!
          : ScrobbleState.off,
      lastfm: _word(map['lastfm']) ?? ScrobbleState.unavailable,
    );
  }

  final ScrobbleState listenbrainz;
  final ScrobbleState lastfm;
}

abstract interface class ScrobblePort {
  Future<ScrobbleStatus> status();
  Future<void> connectListenBrainz(String token);
  Future<void> removeListenBrainz();

  /// Last.fm authorization page URL.
  Future<Uri> startLastfm();
  Future<ScrobbleState> finishLastfm();
  Future<void> removeLastfm();
}

final _tokenShape = RegExp(r'^[\x21-\x7e]{8,200}$');

class ScrobbleSettings extends ChangeNotifier {
  ScrobbleSettings(this._port);

  final ScrobblePort _port;
  ScrobbleState _listenbrainz = ScrobbleState.off;
  ScrobbleState _lastfm = ScrobbleState.unavailable;
  bool _loaded = false;
  bool _busy = false;
  bool _disposed = false;
  ScrobbleError? _error;

  ScrobbleState get listenbrainz => _listenbrainz;
  ScrobbleState get lastfm => _lastfm;
  bool get loaded => _loaded;
  bool get busy => _busy;
  ScrobbleError? get error => _error;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  bool get _blocked => _busy || _disposed;

  void _begin() {
    _busy = true;
    _error = null;
    notifyListeners();
  }

  void _end() {
    _busy = false;
    notifyListeners();
  }

  /// Request lifecycle: start, response, end. Failure is `failure`, no unhandled exception.
  Future<T?> _run<T>(
    Future<T> Function() ask,
    void Function(T value) apply,
    ScrobbleError failure,
  ) async {
    _begin();
    try {
      final value = await ask();
      if (_disposed) return null;
      apply(value);
      _end();
      return value;
    } catch (_) {
      if (_disposed) return null;
      _error = failure;
      _end();
      return null;
    }
  }

  Future<void> load() async {
    if (_blocked) return;
    await _run(_port.status, (status) {
      _listenbrainz = status.listenbrainz;
      _lastfm = status.lastfm;
      _loaded = true;
    }, ScrobbleError.load);
  }

  Future<bool> connectListenBrainz(String raw) async {
    if (_blocked || !_loaded) return false;
    final token = raw.trim();
    if (!_tokenShape.hasMatch(token)) {
      _error = ScrobbleError.tokenShape;
      notifyListeners();
      return false;
    }
    final done = await _run<bool>(
      () async {
        await _port.connectListenBrainz(token);
        return true;
      },
      (_) => _listenbrainz = ScrobbleState.on,
      ScrobbleError.save,
    );
    return done ?? false;
  }

  Future<void> removeListenBrainz() async {
    if (_blocked || !_loaded || _listenbrainz == ScrobbleState.off) return;
    await _run(
      _port.removeListenBrainz,
      (_) => _listenbrainz = ScrobbleState.off,
      ScrobbleError.save,
    );
  }

  Future<Uri?> startLastfm() async {
    if (_blocked || !_loaded) return null;
    if (_lastfm != ScrobbleState.off &&
        _lastfm != ScrobbleState.badToken &&
        _lastfm != ScrobbleState.pending) {
      return null;
    }
    _begin();
    try {
      final page = await _port.startLastfm();
      if (_disposed) return null;
      // URL comes from server and opens in browser: only https and www.last.fm.
      if (page.scheme == 'https' && page.host == 'www.last.fm') {
        _lastfm = ScrobbleState.pending;
        _end();
        return page;
      }
    } catch (_) {
      if (_disposed) return null;
    }
    _error = ScrobbleError.lastfmStart;
    _end();
    return null;
  }

  Future<void> finishLastfm() async {
    if (_blocked || !_loaded || _lastfm != ScrobbleState.pending) return;
    await _run(_port.finishLastfm, (answer) {
      if (answer == ScrobbleState.on) {
        _lastfm = ScrobbleState.on;
      } else if (answer == ScrobbleState.pending) {
        _error = ScrobbleError.lastfmNotYet;
      } else {
        _lastfm = ScrobbleState.off;
        _error = ScrobbleError.lastfmExpired;
      }
    }, ScrobbleError.lastfmStart);
  }

  Future<void> removeLastfm() async {
    if (_blocked || !_loaded) return;
    if (_lastfm != ScrobbleState.on &&
        _lastfm != ScrobbleState.pending &&
        _lastfm != ScrobbleState.badToken) {
      return;
    }
    await _run(
      _port.removeLastfm,
      (_) => _lastfm = ScrobbleState.off,
      ScrobbleError.save,
    );
  }
}
