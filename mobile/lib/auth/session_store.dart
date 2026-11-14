import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SessionStore {
  SessionStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();
  static const _tokenKey = 'session_token';
  final FlutterSecureStorage _storage;
  String? cachedToken;
  Future<void> saveToken(String token) async {
    await _storage.write(key: _tokenKey, value: token);
    cachedToken = token;
  }

  Future<String?> readToken() async {
    cachedToken = await _storage.read(key: _tokenKey);
    return cachedToken;
  }

  Future<void> clear() async {
    cachedToken = null;
    await _storage.delete(key: _tokenKey);
  }
}
