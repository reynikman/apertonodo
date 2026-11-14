import 'dart:async';

/// Network monitoring port (FT-691).
abstract interface class NetworkPort {
  Stream<bool> get online;
  Future<bool> get isOnline;
}

/// Network state monitoring and "network returned" signal.
class NetworkWatch {
  NetworkWatch(this._port, {this.settle = const Duration(seconds: 2)});

  final NetworkPort _port;
  final Duration settle;

  final _controller = StreamController<void>.broadcast();
  StreamSubscription<bool>? _subscription;
  Timer? _timer;

  bool _isOnline = true;
  bool _started = false;
  bool _disposed = false;

  /// Last known network state (before start — true).
  bool get isOnline => _isOnline;

  /// Broadcast stream of "network returned" events.
  Stream<void> get returned => _controller.stream;

  /// Queries port state and subscribes to changes.
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;

    bool initial;
    try {
      initial = await _port.isOnline;
    } catch (_) {
      initial = true;
    }

    if (_disposed) return;
    _isOnline = initial;

    _subscription = _port.online.listen(
      _onData,
      onError: (_) {},
      onDone: _onDone,
      cancelOnError: false,
    );
  }

  void _onData(bool online) {
    if (_disposed) return;
    final wasOnline = _isOnline;
    _isOnline = online;

    if (!online) {
      _timer?.cancel();
      _timer = null;
    } else if (!wasOnline) {
      _timer?.cancel();
      _timer = Timer(settle, () {
        _timer = null;
        if (_disposed || _controller.isClosed) return;
        _controller.add(null);
      });
    }
  }

  void _onDone() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = null;
  }

  /// Frees resources. Does not await unsubscription and internal closing.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
    unawaited(_controller.close());
  }
}
