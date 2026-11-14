import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

enum ServerKind { apertonodo, subsonic, jellyfin, emby }

enum ServerDetectFailure { badAddress, unreachable, unknown }

class ServerDetectError implements Exception {
  const ServerDetectError(this.kind);

  final ServerDetectFailure kind;

  @override
  String toString() => 'ServerDetectError(${kind.name})';
}

class DetectedServer {
  const DetectedServer({
    required this.kind,
    required this.base,
    this.product,
    this.version,
  });

  final ServerKind kind;
  final Uri base;
  final String? product;
  final String? version;

  bool get insecure => base.scheme == 'http';

  @override
  String toString() => 'DetectedServer(${kind.name})';
}

const int serverProbeMaxBytes = 64 * 1024;

List<Uri> serverAddressCandidates(String input) {
  final typed = input.trim();
  if (typed.isEmpty || typed.length > 2048) {
    throw const ServerDetectError(ServerDetectFailure.badAddress);
  }
  if (RegExp(r'\s').hasMatch(typed)) {
    throw const ServerDetectError(ServerDetectFailure.badAddress);
  }
  // Query and fragment are stripped first: browser-pasted address can contain "://" and "@" in them.
  final tail = typed.indexOf(RegExp('[?#]'));
  final trimmed = tail == -1 ? typed : typed.substring(0, tail);
  if (trimmed.isEmpty) {
    throw const ServerDetectError(ServerDetectFailure.badAddress);
  }
  if (trimmed.contains('@')) {
    throw const ServerDetectError(ServerDetectFailure.badAddress);
  }
  if (trimmed.startsWith('://')) {
    throw const ServerDetectError(ServerDetectFailure.badAddress);
  }

  String? specifiedScheme;
  String rest;

  final slashSlashIdx = trimmed.indexOf('://');
  if (slashSlashIdx != -1) {
    final schemeStr = trimmed.substring(0, slashSlashIdx);
    if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*$').hasMatch(schemeStr)) {
      throw const ServerDetectError(ServerDetectFailure.badAddress);
    }
    final lower = schemeStr.toLowerCase();
    if (lower != 'http' && lower != 'https') {
      throw const ServerDetectError(ServerDetectFailure.badAddress);
    }
    specifiedScheme = lower;
    rest = trimmed.substring(slashSlashIdx + 3);
  } else {
    final firstSlash = trimmed.indexOf('/');
    final colonIdx = trimmed.indexOf(':');
    if (colonIdx != -1 && (firstSlash == -1 || colonIdx < firstSlash)) {
      if (trimmed.startsWith('[')) {
        rest = trimmed;
      } else {
        final potentialScheme = trimmed.substring(0, colonIdx);
        final potentialPortAndPath = trimmed.substring(colonIdx + 1);
        final portEnd = potentialPortAndPath.indexOf('/');
        final portStr = portEnd == -1
            ? potentialPortAndPath
            : potentialPortAndPath.substring(0, portEnd);
        if (!RegExp(r'^\d+$').hasMatch(portStr)) {
          throw const ServerDetectError(ServerDetectFailure.badAddress);
        }
        if (potentialScheme.toLowerCase() == 'http' ||
            potentialScheme.toLowerCase() == 'https') {
          throw const ServerDetectError(ServerDetectFailure.badAddress);
        }
        rest = trimmed;
      }
    } else {
      rest = trimmed;
    }
  }

  final hashIdx = rest.indexOf('#');
  if (hashIdx != -1) {
    rest = rest.substring(0, hashIdx);
  }
  final qIdx = rest.indexOf('?');
  if (qIdx != -1) {
    rest = rest.substring(0, qIdx);
  }

  final firstSlash = rest.indexOf('/');
  final String authority;
  final String rawPath;
  if (firstSlash != -1) {
    authority = rest.substring(0, firstSlash);
    rawPath = rest.substring(firstSlash);
  } else {
    authority = rest;
    rawPath = '';
  }

  if (authority.isEmpty) {
    throw const ServerDetectError(ServerDetectFailure.badAddress);
  }

  String host;
  int? port;

  if (authority.startsWith('[')) {
    final closeIdx = authority.indexOf(']');
    if (closeIdx == -1) {
      throw const ServerDetectError(ServerDetectFailure.badAddress);
    }
    final ipInside = authority.substring(1, closeIdx);
    if (!ipInside.contains(':')) {
      throw const ServerDetectError(ServerDetectFailure.badAddress);
    }
    host = ipInside;
    final afterBracket = authority.substring(closeIdx + 1);
    if (afterBracket.isNotEmpty) {
      if (!afterBracket.startsWith(':')) {
        throw const ServerDetectError(ServerDetectFailure.badAddress);
      }
      final portStr = afterBracket.substring(1);
      if (!RegExp(r'^\d+$').hasMatch(portStr)) {
        throw const ServerDetectError(ServerDetectFailure.badAddress);
      }
      final p = int.tryParse(portStr);
      if (p == null || p < 1 || p > 65535) {
        throw const ServerDetectError(ServerDetectFailure.badAddress);
      }
      port = p;
    }
  } else {
    final colonIdx = authority.lastIndexOf(':');
    if (colonIdx != -1) {
      if (authority.indexOf(':') != colonIdx) {
        throw const ServerDetectError(ServerDetectFailure.badAddress);
      }
      host = authority.substring(0, colonIdx);
      final portStr = authority.substring(colonIdx + 1);
      if (!RegExp(r'^\d+$').hasMatch(portStr)) {
        throw const ServerDetectError(ServerDetectFailure.badAddress);
      }
      final p = int.tryParse(portStr);
      if (p == null || p < 1 || p > 65535) {
        throw const ServerDetectError(ServerDetectFailure.badAddress);
      }
      port = p;
    } else {
      host = authority;
    }
  }

  if (host.isEmpty) {
    throw const ServerDetectError(ServerDetectFailure.badAddress);
  }
  if (!authority.startsWith('[') &&
      (host.contains('[') || host.contains(']'))) {
    throw const ServerDetectError(ServerDetectFailure.badAddress);
  }

  var cleanPath = rawPath.replaceAll(RegExp(r'/+'), '/');
  while (cleanPath.endsWith('/') && cleanPath.isNotEmpty) {
    cleanPath = cleanPath.substring(0, cleanPath.length - 1);
  }

  final schemes = specifiedScheme != null
      ? [specifiedScheme]
      : ['https', 'http'];
  try {
    return [
      for (final s in schemes)
        Uri(
          scheme: s,
          host: host.toLowerCase(),
          port: port,
          path: cleanPath.isEmpty ? '' : cleanPath,
        ),
    ];
  } on FormatException {
    throw const ServerDetectError(ServerDetectFailure.badAddress);
  }
}

Uri _probeUri(Uri base, String extraPath, [Map<String, String>? queryParams]) {
  final basePath = base.path;
  final fullPath = '$basePath$extraPath';
  return base.replace(path: fullPath, queryParameters: queryParams);
}

String? _getHeader(Map<String, String> headers, String name) {
  final lower = name.toLowerCase();
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == lower) {
      return entry.value;
    }
  }
  return null;
}

String? _sanitizeString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty || trimmed.length > 100) return null;
  // Foreign server does not render newlines or text direction overrides on login screen.
  if (RegExp(
    '[\\x00-\\x1f\\x7f\\u202a-\\u202e\\u2066-\\u2069]',
  ).hasMatch(trimmed)) {
    return null;
  }
  return trimmed;
}

Map<String, dynamic>? _parseJsonBody(http.Response response) {
  final bytes = response.bodyBytes;
  if (bytes.length > serverProbeMaxBytes) {
    return null;
  }
  try {
    final text = utf8.decode(bytes);
    final decoded = jsonDecode(text);
    if (decoded is Map) {
      return decoded.cast<String, dynamic>();
    }
    return null;
  } catch (_) {
    return null;
  }
}

/// Probe request. We do not follow redirects: otherwise an `http` server redirecting to `https`
/// is detected as `http`, and password follows in cleartext. Body is read up to limit.
Future<http.Response> _get(http.Client client, Uri uri) async {
  final request = http.Request('GET', uri)..followRedirects = false;
  final answer = await client.send(request);
  final bytes = <int>[];
  await for (final chunk in answer.stream) {
    bytes.addAll(chunk);
    if (bytes.length > serverProbeMaxBytes) break;
  }
  return http.Response.bytes(bytes, answer.statusCode, headers: answer.headers);
}

/// Base and its parent paths, longest first: browser tab URL carries page tail
/// (`/web/index.html`), while server under subpath (`/jellyfin`) must be found before root.
List<Uri> _withParents(Uri base) {
  final bases = [base];
  var path = base.path;
  while (path.isNotEmpty && bases.length < 4) {
    path = path.substring(0, path.lastIndexOf('/'));
    bases.add(base.replace(path: path));
  }
  return bases;
}

DetectedServer? _matchProbe(int probeIndex, Uri base, http.Response response) {
  if (probeIndex == 1) {
    if (response.statusCode == 200) {
      final json = _parseJsonBody(response);
      if (json != null && json['status'] == 'ok') {
        // Old server (before FT-888) sends only x-flowtune-revision.
        final rev =
            _getHeader(response.headers, 'x-apertonodo-revision') ??
            _getHeader(response.headers, 'x-flowtune-revision');
        return DetectedServer(
          kind: ServerKind.apertonodo,
          base: base,
          product: 'Apertonodo',
          version: _sanitizeString(rev),
        );
      }
    }
    return null;
  }

  if (probeIndex == 2) {
    if (response.statusCode == 200) {
      final json = _parseJsonBody(response);
      if (json != null) {
        final id = _sanitizeString(json['Id']);
        final version = _sanitizeString(json['Version']);
        if (id != null && version != null) {
          final productName = _sanitizeString(json['ProductName']);
          if (productName != null) {
            return DetectedServer(
              kind: ServerKind.jellyfin,
              base: base,
              product: productName,
              version: version,
            );
          } else {
            return DetectedServer(
              kind: ServerKind.emby,
              base: base,
              product: 'Emby',
              version: version,
            );
          }
        }
      }
    }
    return null;
  }

  if (probeIndex == 3) {
    if (response.statusCode < 500 &&
        (response.statusCode < 300 || response.statusCode >= 400)) {
      final json = _parseJsonBody(response);
      if (json != null) {
        final sub = json['subsonic-response'];
        if (sub is Map) {
          final status = sub['status'];
          if (status == 'ok' || status == 'failed') {
            final type = _sanitizeString(sub['type']);
            final serverVersion = _sanitizeString(sub['serverVersion']);
            final protocolVersion = _sanitizeString(sub['version']);
            return DetectedServer(
              kind: ServerKind.subsonic,
              base: base,
              product: type,
              version: serverVersion ?? protocolVersion,
            );
          }
        }
      }
    }
    return null;
  }

  return null;
}

Future<DetectedServer> detectServer(
  String input, {
  required http.Client client,
  Duration timeout = const Duration(seconds: 6),
}) async {
  final List<Uri> candidates;
  try {
    candidates = serverAddressCandidates(input);
  } on ServerDetectError {
    rethrow;
  } catch (_) {
    throw const ServerDetectError(ServerDetectFailure.badAddress);
  }

  bool anyResponded = false;

  for (final candidate in candidates) {
    var dead = false;
    for (final base in _withParents(candidate)) {
      if (dead) break;
      for (int probeIndex = 1; probeIndex <= 3; probeIndex++) {
        final Uri probeUri;
        if (probeIndex == 1) {
          probeUri = _probeUri(base, '/v1/health');
        } else if (probeIndex == 2) {
          probeUri = _probeUri(base, '/System/Info/Public');
        } else {
          probeUri = _probeUri(base, '/rest/ping.view', const {
            'f': 'json',
            'v': '1.16.1',
            'c': 'apertono',
          });
        }

        final http.Response response;
        try {
          response = await _get(client, probeUri).timeout(timeout);
        } catch (_) {
          dead = true;
          break;
        }

        anyResponded = true;

        final detected = _matchProbe(probeIndex, base, response);
        if (detected != null) {
          return detected;
        }
      }
    }
  }

  if (anyResponded) {
    throw const ServerDetectError(ServerDetectFailure.unknown);
  } else {
    throw const ServerDetectError(ServerDetectFailure.unreachable);
  }
}
