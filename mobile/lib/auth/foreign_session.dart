import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../foreign/foreign_library.dart';
import '../jellyfin_client.dart';
import '../server_kind.dart';
import '../subsonic_client.dart';
import 'foreign_login.dart';
import 'login_errors.dart';

/// Saved login to a foreign server (FT-779).
///
/// Subsonic: password (salt and token are computed per request). Jellyfin: session
/// token, `userId`, `serverId` and device ID — password is not stored at all.
class ForeignAccount {
  const ForeignAccount({
    required this.kind,
    required this.base,
    required this.username,
    this.password,
    this.token,
    this.userId,
    this.serverId,
    this.deviceId,
  });

  final ServerKind kind;
  final Uri base;
  final String username;
  final String? password;
  final String? token;
  final String? userId;
  final String? serverId;
  final String? deviceId;

  Map<String, String> toJson() => {
    'kind': kind.name,
    'base': base.toString(),
    'username': username,
    'password': ?password,
    'token': ?token,
    'userId': ?userId,
    'serverId': ?serverId,
    'deviceId': ?deviceId,
  };

  static ForeignAccount? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = ServerKind.values.asNameMap()[json['kind']];
    final base = Uri.tryParse('${json['base']}');
    final username = json['username'];
    if ((kind != ServerKind.subsonic && kind != ServerKind.jellyfin) ||
        base == null ||
        username is! String) {
      return null;
    }
    String? field(String key) =>
        json[key] is String ? json[key] as String : null;
    final account = ForeignAccount(
      kind: kind!,
      base: base,
      username: username,
      password: field('password'),
      token: field('token'),
      userId: field('userId'),
      serverId: field('serverId'),
      deviceId: field('deviceId'),
    );
    final complete = kind == ServerKind.subsonic
        ? account.password != null
        : account.token != null && account.userId != null;
    return complete ? account : null;
  }

  JellyfinClient? _jellyfin(http.Client client) => kind != ServerKind.jellyfin
      ? null
      : JellyfinClient(
          base: base,
          device: JellyfinDevice(
            id: deviceId ?? 'apertono',
            name: 'Apertono',
            version: '1',
          ),
          client: client,
          session: JellyfinSession(
            token: token!,
            userId: userId!,
            serverId: serverId ?? '',
          ),
        );

  ForeignLibrary library(http.Client client) => switch (kind) {
    ServerKind.jellyfin => JellyfinLibrary(_jellyfin(client)!),
    _ => SubsonicLibrary(
      SubsonicClient(
        base: base,
        auth: SubsonicAuth.password(username, password!),
        client: client,
      ),
    ),
  };

  /// End session on the server. The caller ignores errors.
  Future<void> logout(http.Client client) async =>
      kind == ServerKind.jellyfin ? _jellyfin(client)!.logout() : null;

  @override
  String toString() => 'ForeignAccount(${kind.name}, $base, $username)';
}

/// Verify login on foreign server. Invalid password -> [LoginFailed], same as
/// for own server.
Future<ForeignAccount> signInForeign(
  ForeignLogin login,
  http.Client client,
) async {
  try {
    if (login.kind == ServerKind.jellyfin) {
      final device = JellyfinDevice(
        id: _deviceId(),
        name: 'Apertono',
        version: '1',
      );
      final session = await JellyfinClient(
        base: login.base,
        device: device,
        client: client,
      ).login(login.username, login.password);
      return ForeignAccount(
        kind: login.kind,
        base: login.base,
        username: login.username,
        token: session.token,
        userId: session.userId,
        serverId: session.serverId,
        deviceId: device.id,
      );
    }
    await SubsonicClient(
      base: login.base,
      auth: SubsonicAuth.password(login.username, login.password),
      client: client,
    ).ping();
    return ForeignAccount(
      kind: login.kind,
      base: login.base,
      username: login.username,
      password: login.password,
    );
  } on SubsonicError catch (e) {
    throw LoginFailed(switch (e.kind) {
      SubsonicFailure.auth ||
      SubsonicFailure.authUnsupported ||
      SubsonicFailure.forbidden => LoginError.unauthorized,
      _ => LoginError.network,
    });
  } on JellyfinError catch (e) {
    throw LoginFailed(switch (e.kind) {
      JellyfinFailure.auth ||
      JellyfinFailure.forbidden => LoginError.unauthorized,
      _ => LoginError.network,
    });
  } on TimeoutException {
    throw const LoginFailed(LoginError.timeout);
  } on HandshakeException {
    throw const LoginFailed(LoginError.badCertificate);
  } catch (_) {
    throw const LoginFailed(LoginError.network);
  }
}

String _deviceId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

/// Foreign server login in secure phone storage (key `foreign_login`).
/// Neither password nor token goes to `SharedPreferences`.
class ForeignSession {
  ForeignSession({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'foreign_login';
  final FlutterSecureStorage _storage;

  Future<void> save(ForeignAccount account) =>
      _storage.write(key: _key, value: jsonEncode(account.toJson()));

  Future<ForeignAccount?> read() async {
    try {
      final raw = await _storage.read(key: _key);
      return raw == null ? null : ForeignAccount.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  Future<void> clear() => _storage.delete(key: _key);
}
