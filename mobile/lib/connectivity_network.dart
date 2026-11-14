import 'package:connectivity_plus/connectivity_plus.dart';

import 'network_watch.dart';

/// Device network for [NetworkWatch] (FT-691): "available" means any connection
/// other than "none". Whether the internet works behind it is decided by player retry.
class ConnectivityNetwork implements NetworkPort {
  ConnectivityNetwork([Connectivity? connectivity])
    : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  static bool _any(List<ConnectivityResult> results) =>
      results.any((result) => result != ConnectivityResult.none);

  @override
  Stream<bool> get online => _connectivity.onConnectivityChanged.map(_any);

  @override
  Future<bool> get isOnline => _connectivity.checkConnectivity().then(_any);
}
