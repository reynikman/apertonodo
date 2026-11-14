import 'package:flutter/foundation.dart';

enum DeviceAccess { granted, denied, deniedForever }

enum DeviceLibraryState {
  idle,
  loading,
  noAccess,
  deniedForever,
  empty,
  ready,
  failed,
}

const int deviceMusicMinMs = 30000;

class DeviceSong {
  final String uri;
  final String title;
  final String artist;
  final String album;
  final String albumId;
  final int durationMs;
  final int? track;
  final String path;

  const DeviceSong({
    required this.uri,
    this.title = '',
    this.artist = '',
    this.album = '',
    this.albumId = '',
    this.durationMs = 0,
    this.track,
    this.path = '',
  });

  @override
  String toString() => 'DeviceSong';
}

class DeviceAlbum {
  final String name;
  final String artist;
  final List<DeviceSong> songs;

  DeviceAlbum({
    required this.name,
    required this.artist,
    required List<DeviceSong> songs,
  }) : songs = List.unmodifiable(songs);
}

class DeviceArtist {
  final String name;
  final List<DeviceSong> songs;
  final int albumCount;

  DeviceArtist({
    required this.name,
    required List<DeviceSong> songs,
    required this.albumCount,
  }) : songs = List.unmodifiable(songs);
}

class DeviceFolder {
  final String path;
  final String name;
  final List<DeviceSong> songs;

  DeviceFolder({
    required this.path,
    required this.name,
    required List<DeviceSong> songs,
  }) : songs = List.unmodifiable(songs);
}

abstract interface class DeviceMediaPort {
  Future<DeviceAccess> access();
  Future<DeviceAccess> request();
  Future<List<DeviceSong>> songs();
}

const _blacklistedFolders = <String>{
  'ringtones',
  'notifications',
  'alarms',
  'recordings',
  'call recordings',
  'voice recorder',
  'whatsapp voice notes',
};

bool isDeviceMusic(DeviceSong song) {
  if (song.uri.isEmpty) return false;
  if (song.durationMs > 0 && song.durationMs < deviceMusicMinMs) return false;

  final path = song.path;
  if (path.isEmpty) return true;

  final lastSlash = path.lastIndexOf('/');
  if (lastSlash <= 0) return true;

  final dir = path.substring(0, lastSlash);
  final segments = dir.split('/').where((s) => s.isNotEmpty).toList();

  for (var i = 0; i < segments.length; i++) {
    final s = segments[i].toLowerCase();
    if (_blacklistedFolders.contains(s)) return false;
    if (s == 'android' && i + 1 < segments.length) {
      final next = segments[i + 1].toLowerCase();
      if (next == 'data' || next == 'media' || next == 'obb') {
        return false;
      }
    }
  }

  return true;
}

DeviceSong tidyDeviceSong(DeviceSong song) {
  String clean(String value) {
    final trimmed = value.trim();
    if (trimmed.toLowerCase() == '<unknown>') {
      return '';
    }
    return trimmed;
  }

  var title = clean(song.title);
  final artist = clean(song.artist);
  final album = clean(song.album);

  if (title.isEmpty && song.path.isNotEmpty) {
    final lastSlash = song.path.lastIndexOf('/');
    final filename = lastSlash == -1
        ? song.path
        : song.path.substring(lastSlash + 1);
    final dotIndex = filename.lastIndexOf('.');
    title = (dotIndex > 0 ? filename.substring(0, dotIndex) : filename).trim();
  }

  int? track = song.track;
  if (track != null && track <= 0) {
    track = null;
  }

  final durationMs = song.durationMs < 0 ? 0 : song.durationMs;

  return DeviceSong(
    uri: song.uri,
    title: title,
    artist: artist,
    album: album,
    albumId: song.albumId,
    durationMs: durationMs,
    track: track,
    path: song.path,
  );
}

/// Sort key: case-insensitive, "ё" next to "е" — otherwise "Ёлка" sorts after "Яблоко".
String _sortKey(String value) => value.toLowerCase().replaceAll('ё', 'е');

int _compareNames(String a, String b) {
  final c = _sortKey(a).compareTo(_sortKey(b));
  return c != 0 ? c : a.compareTo(b);
}

int _compareSongs(DeviceSong a, DeviceSong b) {
  final ca = _sortKey(a.title).compareTo(_sortKey(b.title));
  if (ca != 0) return ca;
  final cb = a.title.compareTo(b.title);
  if (cb != 0) return cb;
  return a.uri.compareTo(b.uri);
}

class _SongSortEntry {
  final DeviceSong song;
  final String titleLower;

  _SongSortEntry(this.song) : titleLower = _sortKey(song.title);

  int compareTo(_SongSortEntry other) {
    final c1 = titleLower.compareTo(other.titleLower);
    if (c1 != 0) return c1;
    final c2 = song.title.compareTo(other.song.title);
    if (c2 != 0) return c2;
    return song.uri.compareTo(other.song.uri);
  }
}

class _AlbumBuilder {
  final String key;
  String name = '';
  String firstArtist = '';
  bool sameArtist = true;
  final List<DeviceSong> songs = [];

  _AlbumBuilder(this.key);

  void add(DeviceSong song) {
    if (songs.isEmpty) {
      name = song.album;
      firstArtist = song.artist;
    } else if (sameArtist) {
      if (song.artist.toLowerCase() != firstArtist.toLowerCase()) {
        sameArtist = false;
      }
    }
    songs.add(song);
  }

  DeviceAlbum build() {
    songs.sort((a, b) {
      final ta = a.track;
      final tb = b.track;
      if (ta != null && tb != null) {
        if (ta != tb) return ta.compareTo(tb);
      } else if (ta != null && tb == null) {
        return -1;
      } else if (ta == null && tb != null) {
        return 1;
      }
      return _compareSongs(a, b);
    });

    return DeviceAlbum(
      name: name,
      artist: sameArtist ? firstArtist : '',
      songs: songs,
    );
  }
}

class _ArtistBuilder {
  final String key;
  String name = '';
  final Set<String> albumKeys = <String>{};
  final List<DeviceSong> songs = [];

  _ArtistBuilder(this.key);

  void add(DeviceSong song) {
    if (songs.isEmpty) {
      name = song.artist;
    }
    songs.add(song);
    if (song.album.isNotEmpty) {
      final aKey = song.albumId.isNotEmpty
          ? 'id:${song.albumId}'
          : 'name:${song.album.toLowerCase()}';
      albumKeys.add(aKey);
    }
  }

  DeviceArtist build() {
    return DeviceArtist(name: name, songs: songs, albumCount: albumKeys.length);
  }
}

class _FolderBuilder {
  final String path;
  final String name;
  final List<DeviceSong> songs = [];

  _FolderBuilder({required this.path, required this.name});

  DeviceFolder build() {
    return DeviceFolder(path: path, name: name, songs: songs);
  }
}

class DeviceLibrary extends ChangeNotifier {
  final DeviceMediaPort _port;

  DeviceLibraryState _state = DeviceLibraryState.idle;
  List<DeviceSong> _songs = const [];
  List<DeviceAlbum> _albums = const [];
  List<DeviceArtist> _artists = const [];
  List<DeviceFolder> _folders = const [];

  int _operationId = 0;
  bool _disposed = false;

  DeviceLibrary(DeviceMediaPort port) : _port = port;

  DeviceLibraryState get state => _state;
  List<DeviceSong> get songs => _songs;
  List<DeviceAlbum> get albums => _albums;
  List<DeviceArtist> get artists => _artists;
  List<DeviceFolder> get folders => _folders;

  Future<void> open() => _load(_port.access);

  Future<void> ask() => _load(_port.request);

  Future<void> refresh() => _load(_port.access);

  Future<void> _load(Future<DeviceAccess> Function() getAccess) async {
    if (_disposed) return;
    final opId = ++_operationId;
    _state = DeviceLibraryState.loading;
    notifyListeners();

    final DeviceAccess access;
    try {
      access = await getAccess();
    } catch (_) {
      if (_disposed || opId != _operationId) return;
      _state = DeviceLibraryState.failed;
      notifyListeners();
      return;
    }

    if (_disposed || opId != _operationId) return;

    if (access != DeviceAccess.granted) {
      _songs = const [];
      _albums = const [];
      _artists = const [];
      _folders = const [];
      _state = access == DeviceAccess.deniedForever
          ? DeviceLibraryState.deniedForever
          : DeviceLibraryState.noAccess;
      notifyListeners();
      return;
    }

    try {
      final rawSongs = await _port.songs();
      if (_disposed || opId != _operationId) return;
      // Parsing under same lock: port list that fails while traversing won't leave "loading" forever.
      _processSongs(rawSongs);
    } catch (_) {
      if (_disposed || opId != _operationId) return;
      _state = DeviceLibraryState.failed;
      notifyListeners();
      return;
    }

    _state = _songs.isEmpty
        ? DeviceLibraryState.empty
        : DeviceLibraryState.ready;
    notifyListeners();
  }

  void _processSongs(List<DeviceSong> rawSongs) {
    final seenUris = <String>{};
    final entries = <_SongSortEntry>[];

    for (final raw in rawSongs) {
      if (!isDeviceMusic(raw)) continue;
      if (!seenUris.add(raw.uri)) continue;
      final song = tidyDeviceSong(raw);
      entries.add(_SongSortEntry(song));
    }

    entries.sort((a, b) => a.compareTo(b));
    final sortedSongs = List<DeviceSong>.unmodifiable(
      entries.map((e) => e.song),
    );

    final albumMap = <String, _AlbumBuilder>{};
    final artistMap = <String, _ArtistBuilder>{};
    final folderMap = <String, _FolderBuilder>{};

    for (final song in sortedSongs) {
      if (song.album.isNotEmpty) {
        final albumKey = song.albumId.isNotEmpty
            ? 'id:${song.albumId}'
            : 'name:${song.album.toLowerCase()}';
        albumMap.putIfAbsent(albumKey, () => _AlbumBuilder(albumKey)).add(song);
      }

      if (song.artist.isNotEmpty) {
        final artistKey = song.artist.toLowerCase();
        artistMap
            .putIfAbsent(artistKey, () => _ArtistBuilder(artistKey))
            .add(song);
      }

      final folderPath = _getFolderPath(song.path);
      if (folderPath != null) {
        folderMap
            .putIfAbsent(
              folderPath,
              () => _FolderBuilder(
                path: folderPath,
                name: _getFolderName(folderPath),
              ),
            )
            .songs
            .add(song);
      }
    }

    final albums = albumMap.values.map((b) => b.build()).toList();
    albums.sort((a, b) {
      final c = _compareNames(a.name, b.name);
      return c != 0 ? c : a.artist.compareTo(b.artist);
    });

    final artists = artistMap.values.map((b) => b.build()).toList();
    artists.sort((a, b) {
      return _compareNames(a.name, b.name);
    });

    final folders = folderMap.values.map((b) => b.build()).toList();
    folders.sort((a, b) {
      final c = _compareNames(a.name, b.name);
      return c != 0 ? c : a.path.compareTo(b.path);
    });

    _songs = sortedSongs;
    _albums = List<DeviceAlbum>.unmodifiable(albums);
    _artists = List<DeviceArtist>.unmodifiable(artists);
    _folders = List<DeviceFolder>.unmodifiable(folders);
  }

  static String? _getFolderPath(String path) {
    if (path.isEmpty) return null;
    final lastSlash = path.lastIndexOf('/');
    if (lastSlash <= 0) return null;
    final folder = path.substring(0, lastSlash);
    // Root of phone storage and SD card is not a folder: otherwise folder "0" appears in list.
    if (_volumeRoot.hasMatch(folder)) return null;
    return folder;
  }

  static final _volumeRoot = RegExp(
    r'^/(storage/emulated/\d+|storage/[^/]+|sdcard|mnt/sdcard)$',
  );

  static String _getFolderName(String folderPath) {
    final lastSlash = folderPath.lastIndexOf('/');
    if (lastSlash == -1) return folderPath;
    return folderPath.substring(lastSlash + 1);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
