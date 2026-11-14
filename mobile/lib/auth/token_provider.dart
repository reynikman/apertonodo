import 'dart:io';
import 'package:flutter/foundation.dart';

import 'login.dart' show isHomeNetworkHost;
import 'session_store.dart';

class TokenProvider extends ChangeNotifier {
  TokenProvider(this.store, {required this.server})
    : _token = store.cachedToken;
  final SessionStore store;
  final Uri server;
  String? _token;
  Future<void>? _loading;
  bool _unauthorized = false;
  bool get loggedOut => _unauthorized || _token?.isNotEmpty != true;
  Future<void> load() => _loading ??= _readToken();
  Future<void> _readToken() async {
    try {
      _token = await store.readToken();
    } catch (_) {
      _token = null;
    }
    _loading = null;
    notifyListeners();
  }

  Future<void> signIn(String token) async {
    await store.saveToken(token);
    _token = token;
    _unauthorized = false;
    notifyListeners();
  }

  Map<String, String> headersFor(Uri uri) {
    if (loggedOut || !_sameOrigin(uri) || !_isSecure(uri)) return const {};
    return {'authorization': 'Bearer $_token'};
  }

  Future<void> onUnauthorized() async {
    if (_unauthorized) return;
    final loading = _loading;
    _unauthorized = true;
    _token = null;
    if (loading != null) await loading;
    _token = null;
    await store.clear();
    notifyListeners();
  }

  bool _sameOrigin(Uri uri) => uri.origin == server.origin;
  bool _isSecure(Uri uri) =>
      uri.scheme.toLowerCase() == 'https' ||
      uri.host.toLowerCase() == 'localhost' ||
      (InternetAddress.tryParse(uri.host)?.isLoopback ?? false) ||
      // Same rule as login (serverOrigin): a home server over http.
      isHomeNetworkHost(uri.host);
}
