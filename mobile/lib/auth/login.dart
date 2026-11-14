import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'login_errors.dart';

/// 10/8, 172.16/12, 192.168/16 — home network address; name of shape `*.local`;
/// a name without a dot (`nas`) — only a home router resolves it; 100.64/10 — the
/// range of Tailscale and other overlay networks, where traffic is already encrypted.
bool isHomeNetworkHost(String host) {
  final lower = host.toLowerCase();
  if (lower.endsWith('.local') && lower.length > '.local'.length) return true;
  final address = InternetAddress.tryParse(lower);
  if (address == null) {
    return RegExp(r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?$').hasMatch(lower) &&
        lower != 'localhost';
  }
  if (address.type != InternetAddressType.IPv4) return false;
  final b = address.rawAddress;
  return b[0] == 10 ||
      (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
      (b[0] == 192 && b[1] == 168) ||
      (b[0] == 100 && b[1] >= 64 && b[1] <= 127);
}

/// Only a secure origin (or loopback / home network over http) can receive credentials.
/// Scheme that wizard prepends to address without one: home network ->
/// `http://` (Navidrome and Jellyfin at home usually lack certificates), else `https://`.
String schemeFor(String address) {
  final host = address.split(RegExp('[:/]')).first;
  return isHomeNetworkHost(host) ? 'http://' : 'https://';
}

Uri? serverOrigin(String value) {
  if (value.length > 2048 || value.trim() != value) return null;
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.host.isEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/')) {
    return null;
  }
  final loopback =
      uri.host.toLowerCase() == 'localhost' ||
      (InternetAddress.tryParse(uri.host)?.isLoopback ?? false);
  if (uri.scheme != 'https' &&
      !(uri.scheme == 'http' && (loopback || isHomeNetworkHost(uri.host)))) {
    return null;
  }
  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
  );
}

/// No automatic redirects: even a 307 must not forward the login body.
Future<({String token, String userId})> loginAt(
  Uri server,
  String username,
  String password,
  http.Client client,
) =>
    // Schema is contracts/auth-login.request.json; device_name is required by server,
    // the owner recognizes the device in active logins list by it.
    _signIn(
      server.resolve('/v1/auth/login'),
      {
        'username': username,
        'password': password,
        'device_name': 'Apertono ${Platform.operatingSystem}',
      },
      client,
      LoginError.unauthorized,
    );

/// FT-856: first sign-in with the admin's one-time code; the person makes up
/// [password] here, and the server signs this device in at once.
Future<({String token, String userId})> claimAt(
  Uri server,
  String username,
  String code,
  String password,
  http.Client client,
) => _signIn(
  server.resolve('/v1/auth/claim'),
  {
    'username': username,
    'code': code,
    'password': password,
    'device_name': 'Apertono ${Platform.operatingSystem}',
  },
  client,
  LoginError.badCode,
);

Future<({String token, String userId})> _signIn(
  Uri address,
  Map<String, String> fields,
  http.Client client,
  LoginError refused,
) async {
  final request = http.Request('POST', address)
    ..followRedirects = false
    ..headers['content-type'] = 'application/json'
    ..body = jsonEncode(fields);
  try {
    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 15));
    if (response.statusCode == 401) {
      await response.stream.drain<void>();
      throw LoginFailed(refused);
    }
    // Only a claim sets a password, so only a claim can hear "too weak".
    if (response.statusCode == 422 && refused == LoginError.badCode) {
      await response.stream.drain<void>();
      throw const LoginFailed(LoginError.weakPassword);
    }
    if (response.statusCode != 200) {
      await response.stream.drain<void>();
      throw const LoginFailed(LoginError.network);
    }
    final body =
        jsonDecode(await response.stream.bytesToString())
            as Map<String, dynamic>;
    final token = body['token'];
    final userId = body['user_id'];
    if (token is! String ||
        token.isEmpty ||
        userId is! String ||
        userId.isEmpty) {
      throw const LoginFailed(LoginError.network);
    }
    return (token: token, userId: userId);
  } on LoginFailed {
    rethrow;
  } on TimeoutException {
    throw const LoginFailed(LoginError.timeout);
  } on HandshakeException {
    throw const LoginFailed(LoginError.badCertificate);
  } on Exception {
    throw const LoginFailed(LoginError.network);
  }
}

String accountNamespace(Uri server, String userId) =>
    'account/${Uri.encodeComponent(server.origin)}/${Uri.encodeComponent(userId)}';
