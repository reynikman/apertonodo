import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

enum JellyfinFailure {
  unavailable,
  notJellyfin,
  auth,
  forbidden,
  notFound,
  refused,
}

class JellyfinError implements Exception {
  const JellyfinError(this.kind, {this.status});

  final JellyfinFailure kind;
  final int? status;

  @override
  String toString() => status == null
      ? 'JellyfinError(${kind.name})'
      : 'JellyfinError(${kind.name}, $status)';
}

class JellyfinDevice {
  const JellyfinDevice({
    required this.id,
    required this.name,
    required this.version,
  });

  final String id;
  final String name;
  final String version;
}

class JellyfinSession {
  const JellyfinSession({
    required this.token,
    required this.userId,
    required this.serverId,
  });

  final String token;
  final String userId;
  final String serverId;

  @override
  String toString() => 'JellyfinSession(serverId: $serverId)';
}

class JellyfinServer {
  const JellyfinServer({
    required this.id,
    required this.name,
    required this.version,
    required this.product,
  });

  final String id;
  final String name;
  final String version;
  final String product;
}

class JellyfinArtist {
  const JellyfinArtist({
    required this.id,
    required this.name,
    required this.imageTag,
  });

  final String id;
  final String name;
  final String imageTag;
}

class JellyfinAlbum {
  const JellyfinAlbum({
    required this.id,
    required this.name,
    required this.artist,
    required this.artistId,
    required this.year,
    required this.songCount,
    required this.imageTag,
  });

  final String id;
  final String name;
  final String artist;
  final String artistId;
  final int? year;

  /// `null` — server did not specify (Jellyfin does not send numbers in lists and search).
  final int? songCount;
  final String imageTag;
}

class JellyfinSong {
  const JellyfinSong({
    required this.id,
    required this.title,
    required this.artist,
    required this.artistId,
    required this.album,
    required this.albumId,
    required this.durationMs,
    required this.track,
    required this.disc,
    required this.container,
    required this.imageItemId,
    required this.imageTag,
    required this.favorite,
  });

  final String id;
  final String title;
  final String artist;
  final String artistId;
  final String album;
  final String albumId;
  final int durationMs;
  final int? track;
  final int? disc;
  final String container;
  final String imageItemId;
  final String imageTag;
  final bool favorite;
}

class JellyfinPage<T> {
  const JellyfinPage({required this.items, required this.total});

  final List<T> items;
  final int total;
}

class JellyfinFound {
  const JellyfinFound({
    required this.artists,
    required this.albums,
    required this.songs,
  });

  final List<JellyfinArtist> artists;
  final List<JellyfinAlbum> albums;
  final List<JellyfinSong> songs;
}

class JellyfinClient {
  JellyfinClient({
    required this.base,
    required this.device,
    required this.client,
    this.session,
    this.timeout = const Duration(seconds: 15),
  });

  final Uri base;
  final JellyfinDevice device;
  final http.Client client;
  final JellyfinSession? session;
  final Duration timeout;

  Uri _buildUri(List<String> segments, [Map<String, String>? query]) {
    final baseSegments = base.pathSegments.where((s) => s.isNotEmpty);
    return Uri(
      scheme: base.scheme,
      host: base.host,
      port: base.hasPort ? base.port : null,
      pathSegments: [...baseSegments, ...segments],
      queryParameters: (query != null && query.isNotEmpty) ? query : null,
    );
  }

  String _authHeader({bool includeToken = true}) {
    final buffer = StringBuffer('MediaBrowser Client="Apertono"')
      ..write(', Device="${Uri.encodeComponent(device.name)}"')
      ..write(', DeviceId="${Uri.encodeComponent(device.id)}"')
      ..write(', Version="${Uri.encodeComponent(device.version)}"');
    final s = session;
    if (includeToken && s != null) {
      buffer.write(', Token="${Uri.encodeComponent(s.token)}"');
    }
    return buffer.toString();
  }

  JellyfinSession _requireSession() {
    final s = session;
    if (s == null) {
      throw const JellyfinError(JellyfinFailure.auth);
    }
    return s;
  }

  Future<http.Response> _send(http.Request request) async {
    try {
      return await (() async {
        final streamed = await client.send(request);
        return await http.Response.fromStream(streamed);
      })().timeout(timeout);
    } on TimeoutException {
      throw const JellyfinError(JellyfinFailure.unavailable);
    } catch (e) {
      if (e is JellyfinError) rethrow;
      throw const JellyfinError(JellyfinFailure.unavailable);
    }
  }

  void _checkStatus(http.Response response) {
    final status = response.statusCode;
    if (status >= 500) {
      throw JellyfinError(JellyfinFailure.unavailable, status: status);
    }
    if (status < 200 || status >= 300) {
      switch (status) {
        case 401:
          throw JellyfinError(JellyfinFailure.auth, status: status);
        case 403:
          throw JellyfinError(JellyfinFailure.forbidden, status: status);
        case 404:
          throw JellyfinError(JellyfinFailure.notFound, status: status);
        default:
          throw JellyfinError(JellyfinFailure.refused, status: status);
      }
    }
  }

  Future<Map<String, dynamic>> _sendJson(http.Request request) async {
    final response = await _send(request);
    _checkStatus(response);
    final String bodyString;
    try {
      bodyString = utf8.decode(response.bodyBytes);
    } catch (_) {
      throw const JellyfinError(JellyfinFailure.notJellyfin);
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(bodyString);
    } catch (_) {
      throw const JellyfinError(JellyfinFailure.notJellyfin);
    }
    if (decoded is! Map<String, dynamic>) {
      throw const JellyfinError(JellyfinFailure.notJellyfin);
    }
    return decoded;
  }

  Future<JellyfinServer> info() async {
    final uri = _buildUri(['System', 'Info', 'Public']);
    final request = http.Request('GET', uri);
    request.headers['Authorization'] = _authHeader();
    request.headers['Accept'] = 'application/json';
    final json = await _sendJson(request);
    final id = json['Id'];
    final version = json['Version'];
    if (id is! String || id.isEmpty || version is! String || version.isEmpty) {
      throw const JellyfinError(JellyfinFailure.notJellyfin);
    }
    return JellyfinServer(
      id: id,
      name: _parseString(json['ServerName']),
      version: version,
      product: _parseString(json['ProductName']),
    );
  }

  Future<JellyfinSession> login(String user, String password) async {
    final uri = _buildUri(['Users', 'AuthenticateByName']);
    final request = http.Request('POST', uri);
    request.headers['Authorization'] = _authHeader(includeToken: false);
    request.headers['Accept'] = 'application/json';
    request.headers['Content-Type'] = 'application/json';
    request.bodyBytes = utf8.encode(
      jsonEncode({'Username': user, 'Pw': password}),
    );
    final json = await _sendJson(request);
    final token = json['AccessToken'];
    final userObj = json['User'];
    final userId = userObj is Map ? userObj['Id'] : null;
    if (token is! String ||
        token.isEmpty ||
        userId is! String ||
        userId.isEmpty) {
      throw const JellyfinError(JellyfinFailure.notJellyfin);
    }
    var serverId = _parseString(json['ServerId']);
    if (serverId.isEmpty && userObj is Map) {
      serverId = _parseString(userObj['ServerId']);
    }
    return JellyfinSession(token: token, userId: userId, serverId: serverId);
  }

  Future<void> logout() async {
    _requireSession();
    final uri = _buildUri(['Sessions', 'Logout']);
    final request = http.Request('POST', uri);
    request.headers['Authorization'] = _authHeader();
    request.headers['Accept'] = 'application/json';
    final response = await _send(request);
    _checkStatus(response);
  }

  Future<JellyfinFound> search(String query, {int limit = 20}) async {
    final session = _requireSession();
    final uri = _buildUri(
      ['Items'],
      {
        'userId': session.userId,
        'SearchTerm': query,
        'IncludeItemTypes': 'Audio,MusicAlbum,MusicArtist',
        'Recursive': 'true',
        'Limit': '$limit',
      },
    );
    final request = http.Request('GET', uri);
    request.headers['Authorization'] = _authHeader();
    request.headers['Accept'] = 'application/json';
    final json = await _sendJson(request);
    final rawItems = json['Items'];
    final artists = <JellyfinArtist>[];
    final albums = <JellyfinAlbum>[];
    final songs = <JellyfinSong>[];
    if (rawItems is List) {
      for (final item in rawItems) {
        if (item is Map) {
          final type = item['Type'];
          if (type == 'Audio') {
            songs.add(_parseSong(item));
          } else if (type == 'MusicAlbum') {
            albums.add(_parseAlbum(item));
          } else if (type == 'MusicArtist') {
            artists.add(_parseArtist(item));
          }
        }
      }
    }
    return JellyfinFound(artists: artists, albums: albums, songs: songs);
  }

  Future<JellyfinPage<JellyfinArtist>> artists({
    int limit = 100,
    int startIndex = 0,
  }) async {
    final session = _requireSession();
    final uri = _buildUri(
      ['Artists', 'AlbumArtists'],
      {
        'userId': session.userId,
        'SortBy': 'SortName',
        'Limit': '$limit',
        'StartIndex': '$startIndex',
      },
    );
    final request = http.Request('GET', uri);
    request.headers['Authorization'] = _authHeader();
    request.headers['Accept'] = 'application/json';
    final json = await _sendJson(request);
    final rawItems = json['Items'];
    final items = <JellyfinArtist>[];
    if (rawItems is List) {
      for (final item in rawItems) {
        if (item is Map) {
          final type = item['Type'];
          if (type == null || type == 'MusicArtist') {
            items.add(_parseArtist(item));
          }
        }
      }
    }
    final total = _parseTotal(json['TotalRecordCount'], items.length);
    return JellyfinPage<JellyfinArtist>(items: items, total: total);
  }

  Future<List<JellyfinAlbum>> albums(String artistId) async {
    final session = _requireSession();
    final uri = _buildUri(
      ['Items'],
      {
        'userId': session.userId,
        'IncludeItemTypes': 'MusicAlbum',
        'Recursive': 'true',
        'AlbumArtistIds': artistId,
        'SortBy': 'ProductionYear,SortName',
      },
    );
    final request = http.Request('GET', uri);
    request.headers['Authorization'] = _authHeader();
    request.headers['Accept'] = 'application/json';
    final json = await _sendJson(request);
    final rawItems = json['Items'];
    final items = <JellyfinAlbum>[];
    if (rawItems is List) {
      for (final item in rawItems) {
        if (item is Map && item['Type'] == 'MusicAlbum') {
          items.add(_parseAlbum(item));
        }
      }
    }
    return items;
  }

  Future<List<JellyfinSong>> songs(String albumId) async {
    final session = _requireSession();
    final uri = _buildUri(
      ['Items'],
      {
        'userId': session.userId,
        'ParentId': albumId,
        'IncludeItemTypes': 'Audio',
        'SortBy': 'ParentIndexNumber,IndexNumber,SortName',
      },
    );
    final request = http.Request('GET', uri);
    request.headers['Authorization'] = _authHeader();
    request.headers['Accept'] = 'application/json';
    final json = await _sendJson(request);
    final rawItems = json['Items'];
    final items = <JellyfinSong>[];
    if (rawItems is List) {
      for (final item in rawItems) {
        if (item is Map && item['Type'] == 'Audio') {
          items.add(_parseSong(item));
        }
      }
    }
    return items;
  }

  Future<JellyfinAlbum> album(String id) async {
    final session = _requireSession();
    final uri = _buildUri(['Items', id], {'userId': session.userId});
    final request = http.Request('GET', uri);
    request.headers['Authorization'] = _authHeader();
    request.headers['Accept'] = 'application/json';
    final json = await _sendJson(request);
    if (json['Type'] != 'MusicAlbum' || !_idsMatch(id, json['Id'])) {
      throw const JellyfinError(JellyfinFailure.notFound);
    }
    return _parseAlbum(json);
  }

  Future<JellyfinSong> song(String id) async {
    final session = _requireSession();
    final uri = _buildUri(['Items', id], {'userId': session.userId});
    final request = http.Request('GET', uri);
    request.headers['Authorization'] = _authHeader();
    request.headers['Accept'] = 'application/json';
    final json = await _sendJson(request);
    if (json['Type'] != 'Audio' || !_idsMatch(id, json['Id'])) {
      throw const JellyfinError(JellyfinFailure.notFound);
    }
    return _parseSong(json);
  }

  Future<JellyfinPage<JellyfinSong>> favorites({
    int limit = 100,
    int startIndex = 0,
  }) async {
    final session = _requireSession();
    final uri = _buildUri(
      ['Items'],
      {
        'userId': session.userId,
        'IncludeItemTypes': 'Audio',
        'Recursive': 'true',
        'Filters': 'IsFavorite',
        'Limit': '$limit',
        'StartIndex': '$startIndex',
      },
    );
    final request = http.Request('GET', uri);
    request.headers['Authorization'] = _authHeader();
    request.headers['Accept'] = 'application/json';
    final json = await _sendJson(request);
    final rawItems = json['Items'];
    final items = <JellyfinSong>[];
    if (rawItems is List) {
      for (final item in rawItems) {
        if (item is Map && item['Type'] == 'Audio') {
          items.add(_parseSong(item));
        }
      }
    }
    final total = _parseTotal(json['TotalRecordCount'], items.length);
    return JellyfinPage<JellyfinSong>(items: items, total: total);
  }

  Future<void> setFavorite(String songId, {required bool favorite}) async {
    final session = _requireSession();
    final uri = _buildUri(
      ['UserFavoriteItems', songId],
      {'userId': session.userId},
    );
    final request = http.Request(favorite ? 'POST' : 'DELETE', uri);
    request.headers['Authorization'] = _authHeader();
    request.headers['Accept'] = 'application/json';
    final json = await _sendJson(request);
    if (!_idsMatch(songId, json['ItemId'])) {
      throw const JellyfinError(JellyfinFailure.notFound);
    }
  }

  Uri streamUri(String songId) {
    final session = _requireSession();
    return _buildUri(
      ['Audio', songId, 'stream'],
      {'static': 'true', 'ApiKey': session.token},
    );
  }

  Uri? imageUri(String itemId, String imageTag, {int maxWidth = 600}) {
    if (itemId.isEmpty || imageTag.isEmpty) return null;
    return _buildUri(
      ['Items', itemId, 'Images', 'Primary'],
      {'maxWidth': '$maxWidth', 'tag': imageTag},
    );
  }
}

bool _idsMatch(String requested, Object? actual) {
  if (actual is! String) return false;
  final normRequested = requested.replaceAll('-', '').toLowerCase();
  if (normRequested.isEmpty) return false;
  final normActual = actual.replaceAll('-', '').toLowerCase();
  return normRequested == normActual;
}

String _parseString(Object? value) {
  if (value is String) return value;
  return '';
}

int? _parseIntNullable(Object? value) {
  if (value is int) return value;
  if (value is double && value.isFinite) return value.round();
  return null;
}

int _parseDuration(Object? raw) {
  if (raw is num && raw.isFinite) {
    final ms = raw ~/ 10000;
    return ms > 0 ? ms : 0;
  }
  return 0;
}

int _parseTotal(Object? rawTotal, int itemsCount) {
  if (rawTotal is int && rawTotal >= itemsCount) {
    return rawTotal;
  }
  return itemsCount;
}

JellyfinArtist _parseArtist(Map item) {
  final id = _parseString(item['Id']);
  final name = _parseString(item['Name']);
  final imageTags = item['ImageTags'];
  final imageTag = imageTags is Map ? _parseString(imageTags['Primary']) : '';
  return JellyfinArtist(id: id, name: name, imageTag: imageTag);
}

JellyfinAlbum _parseAlbum(Map item) {
  final id = _parseString(item['Id']);
  final name = _parseString(item['Name']);
  final artist = _parseString(item['AlbumArtist']);
  String artistId = '';
  final albumArtists = item['AlbumArtists'];
  if (albumArtists is List) {
    for (final a in albumArtists) {
      if (a is Map) {
        artistId = _parseString(a['Id']);
        break;
      }
    }
  }
  final year = _parseIntNullable(item['ProductionYear']);
  final songCount = _parseIntNullable(item['ChildCount']);
  final imageTags = item['ImageTags'];
  final imageTag = imageTags is Map ? _parseString(imageTags['Primary']) : '';
  return JellyfinAlbum(
    id: id,
    name: name,
    artist: artist,
    artistId: artistId,
    year: year,
    songCount: songCount,
    imageTag: imageTag,
  );
}

JellyfinSong _parseSong(Map item) {
  final id = _parseString(item['Id']);
  final title = _parseString(item['Name']);

  String artist = '';
  final rawArtists = item['Artists'];
  if (rawArtists is List) {
    final list = [
      for (final a in rawArtists)
        if (a is String && a.isNotEmpty) a,
    ];
    if (list.isNotEmpty) {
      artist = list.join(', ');
    } else {
      artist = _parseString(item['AlbumArtist']);
    }
  } else {
    artist = _parseString(item['AlbumArtist']);
  }

  String artistId = '';
  final rawArtistItems = item['ArtistItems'];
  if (rawArtistItems is List) {
    for (final a in rawArtistItems) {
      if (a is Map) {
        artistId = _parseString(a['Id']);
        break;
      }
    }
  }

  final album = _parseString(item['Album']);
  final albumId = _parseString(item['AlbumId']);
  final durationMs = _parseDuration(item['RunTimeTicks']);
  final track = _parseIntNullable(item['IndexNumber']);
  final disc = _parseIntNullable(item['ParentIndexNumber']);
  final container = _parseString(item['Container']);

  final imageTags = item['ImageTags'];
  final ownTag = imageTags is Map ? _parseString(imageTags['Primary']) : '';
  final String imageItemId;
  final String imageTag;
  if (ownTag.isNotEmpty) {
    imageItemId = id;
    imageTag = ownTag;
  } else {
    imageItemId = albumId;
    imageTag = _parseString(item['AlbumPrimaryImageTag']);
  }

  final userData = item['UserData'];
  final favorite = userData is Map && userData['IsFavorite'] == true;

  return JellyfinSong(
    id: id,
    title: title,
    artist: artist,
    artistId: artistId,
    album: album,
    albumId: albumId,
    durationMs: durationMs,
    track: track,
    disc: disc,
    container: container,
    imageItemId: imageItemId,
    imageTag: imageTag,
    favorite: favorite,
  );
}
