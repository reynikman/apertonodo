import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// Reason why Subsonic server gave no response.
enum SubsonicFailure {
  /// Network error, timeout, status 500 or higher.
  unavailable,

  /// Non-Subsonic response: HTML page, XML, foreign JSON.
  notSubsonic,

  /// Username or password incorrect (codes 40, 44).
  auth,

  /// Server does not support authentication method (codes 41–43, token in Navidrome).
  authUnsupported,

  /// User not authorized (code 50).
  forbidden,

  /// Artist, album, or song not found (code 70).
  notFound,

  /// Any other server refusal.
  refused,
}

/// Error without address, username, password, or server text: only cause and code.
class SubsonicError implements Exception {
  const SubsonicError(this.kind, {this.code});

  final SubsonicFailure kind;
  final int? code;

  @override
  String toString() => code == null
      ? 'SubsonicError(${kind.name})'
      : 'SubsonicError(${kind.name}, $code)';
}

class SubsonicAuth {
  const SubsonicAuth.password(String this.user, String this.password)
    : apiKey = null;
  const SubsonicAuth.apiKey(String this.apiKey) : user = null, password = null;

  final String? user;
  final String? password;
  final String? apiKey;

  @override
  String toString() =>
      'SubsonicAuth(${apiKey == null ? 'password' : 'apiKey'})';
}

class SubsonicServer {
  const SubsonicServer({
    required this.type,
    required this.version,
    required this.openSubsonic,
  });

  final String type;
  final String version;
  final bool openSubsonic;
}

class SubsonicArtist {
  const SubsonicArtist({
    required this.id,
    required this.name,
    required this.albumCount,
    required this.albums,
  });

  final String id;
  final String name;
  final int albumCount;
  final List<SubsonicAlbum> albums;
}

class SubsonicAlbum {
  const SubsonicAlbum({
    required this.id,
    required this.name,
    required this.artist,
    required this.artistId,
    required this.year,
    required this.songCount,
    required this.coverArt,
    required this.songs,
  });

  final String id;
  final String name;
  final String artist;
  final String artistId;
  final int? year;
  final int songCount;
  final String coverArt;
  final List<SubsonicSong> songs;
}

class SubsonicSong {
  const SubsonicSong({
    required this.id,
    required this.title,
    required this.artist,
    required this.artistId,
    required this.album,
    required this.albumId,
    required this.durationMs,
    required this.track,
    required this.suffix,
    required this.coverArt,
    required this.starred,
  });

  final String id;
  final String title;
  final String artist;
  final String artistId;
  final String album;
  final String albumId;
  final int durationMs;
  final int? track;
  final String suffix;
  final String coverArt;
  final bool starred;
}

class SubsonicFound {
  const SubsonicFound({
    required this.artists,
    required this.albums,
    required this.songs,
  });

  final List<SubsonicArtist> artists;
  final List<SubsonicAlbum> albums;
  final List<SubsonicSong> songs;
}

class SubsonicClient {
  SubsonicClient({
    required this.base,
    required this.auth,
    required this.client,
    this.timeout = const Duration(seconds: 15),
    String Function()? salt,
  }) : _salt = salt ?? _randomSalt;

  final Uri base;
  final SubsonicAuth auth;
  final Duration timeout;
  final http.Client client;
  final String Function() _salt;

  static const _letters =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  static final _random = Random.secure();

  static String _randomSalt() => String.fromCharCodes(
    List.generate(
      12,
      (_) => _letters.codeUnitAt(_random.nextInt(_letters.length)),
    ),
  );

  Uri _uri(String method, Map<String, String> params) {
    final path = base.path.replaceFirst(RegExp(r'/+$'), '');
    final user = auth.user;
    final password = auth.password;
    final String salt = user == null ? '' : _salt();
    return base.replace(
      path: '$path/rest/$method.view',
      queryParameters: {
        'v': '1.16.1',
        'c': 'apertono',
        'f': 'json',
        if (user != null && password != null) ...{
          'u': user,
          's': salt,
          't': md5.convert(utf8.encode('$password$salt')).toString(),
        } else
          'apiKey': auth.apiKey ?? '',
        ...params,
      },
    );
  }

  Future<Map<String, dynamic>> _call(
    String method, [
    Map<String, String> params = const {},
  ]) async {
    final http.Response response;
    try {
      response = await client.get(_uri(method, params)).timeout(timeout);
    } catch (_) {
      throw const SubsonicError(SubsonicFailure.unavailable);
    }
    if (response.statusCode >= 500) {
      throw const SubsonicError(SubsonicFailure.unavailable);
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(
        utf8.decode(response.bodyBytes, allowMalformed: true),
      );
    } catch (_) {
      throw const SubsonicError(SubsonicFailure.notSubsonic);
    }
    final root = decoded is Map ? decoded['subsonic-response'] : null;
    if (root is! Map) {
      throw const SubsonicError(SubsonicFailure.notSubsonic);
    }
    if (root['status'] == 'ok') {
      return Map<String, dynamic>.from(root);
    }
    final error = root['error'];
    final code = error is Map && error['code'] is int
        ? error['code'] as int
        : null;
    throw SubsonicError(_failureOf(code), code: code);
  }

  SubsonicFailure _failureOf(int? code) => switch (code) {
    40 || 44 => SubsonicFailure.auth,
    41 || 42 || 43 => SubsonicFailure.authUnsupported,
    10 when auth.apiKey != null => SubsonicFailure.authUnsupported,
    50 => SubsonicFailure.forbidden,
    70 => SubsonicFailure.notFound,
    _ => SubsonicFailure.refused,
  };

  Future<SubsonicServer> ping() async {
    final root = await _call('ping');
    return SubsonicServer(
      type: _str(root['type']),
      version: _str(root['serverVersion']),
      openSubsonic: root['openSubsonic'] == true,
    );
  }

  Future<SubsonicFound> search(
    String query, {
    int limit = 20,
    int songOffset = 0,
  }) async {
    final root = await _call('search3', {
      'query': query,
      'artistCount': '$limit',
      'albumCount': '$limit',
      'songCount': '$limit',
      'songOffset': '$songOffset',
    });
    final result = _map(root['searchResult3']);
    return SubsonicFound(
      artists: _objects(result['artist']).map(_artist).toList(),
      albums: _objects(result['album']).map(_album).toList(),
      songs: _objects(result['song']).map(_song).toList(),
    );
  }

  Future<List<SubsonicArtist>> artists() async {
    final root = await _call('getArtists');
    return [
      for (final letter in _objects(_map(root['artists'])['index']))
        ..._objects(letter['artist']).map(_artist),
    ];
  }

  Future<SubsonicArtist> artist(String id) async =>
      _artist(_map((await _call('getArtist', {'id': id}))['artist']));

  Future<SubsonicAlbum> album(String id) async =>
      _album(_map((await _call('getAlbum', {'id': id}))['album']));

  Future<SubsonicSong> song(String id) async =>
      _song(_map((await _call('getSong', {'id': id}))['song']));

  Future<List<SubsonicSong>> starred() async {
    final root = await _call('getStarred2');
    return _objects(_map(root['starred2'])['song']).map(_song).toList();
  }

  Future<void> star(String songId) async {
    await _call('star', {'id': songId});
  }

  Future<void> unstar(String songId) async {
    await _call('unstar', {'id': songId});
  }

  Uri streamUri(String songId) => _uri('stream', {'id': songId});

  Uri? coverUri(String coverArt, {int size = 600}) => coverArt.isEmpty
      ? null
      : _uri('getCoverArt', {'id': coverArt, 'size': '$size'});
}

Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : const {};

/// Legacy Subsonic servers collapse single-item list into an object.
Iterable<Map<String, dynamic>> _objects(Object? value) =>
    (value is List ? value : [value]).whereType<Map>().map(
      (e) => Map<String, dynamic>.from(e),
    );

String _str(Object? value) => switch (value) {
  String() => value,
  int() => '$value',
  double() when value.isFinite => '${value.round()}',
  _ => '',
};

int? _intOrNull(Object? value) => switch (value) {
  int() => value,
  double() when value.isFinite => value.round(),
  _ => null,
};

int _int(Object? value) => _intOrNull(value) ?? 0;

SubsonicArtist _artist(Map<String, dynamic> json) => SubsonicArtist(
  id: _str(json['id']),
  name: _str(json['name']),
  albumCount: _int(json['albumCount']),
  albums: _objects(json['album']).map(_album).toList(),
);

SubsonicAlbum _album(Map<String, dynamic> json) => SubsonicAlbum(
  id: _str(json['id']),
  name: _str(json['name']),
  artist: _str(json['artist']),
  artistId: _str(json['artistId']),
  year: _intOrNull(json['year']),
  songCount: _int(json['songCount']),
  coverArt: _str(json['coverArt']),
  songs: _objects(json['song']).map(_song).toList(),
);

SubsonicSong _song(Map<String, dynamic> json) => SubsonicSong(
  id: _str(json['id']),
  title: _str(json['title']),
  artist: _str(json['artist']),
  artistId: _str(json['artistId']),
  album: _str(json['album']),
  albumId: _str(json['albumId']),
  durationMs: _int(json['duration']) * 1000,
  track: _intOrNull(json['track']),
  suffix: _str(json['suffix']),
  coverArt: _str(json['coverArt']),
  starred: json['starred'] != null && json['starred'] != '',
);
