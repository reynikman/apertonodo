import '../catalog.dart';
import '../jellyfin_client.dart';
import '../models/track.dart';
import '../subsonic_client.dart';

/// Artist of foreign server. [imageUrl] — full URL or empty string.
class ForeignArtist {
  const ForeignArtist({
    required this.id,
    required this.name,
    this.imageUrl = '',
  });

  final String id;
  final String name;
  final String imageUrl;
}

/// Album in list (search results, artist page).
class ForeignAlbumRef {
  const ForeignAlbumRef({
    required this.id,
    required this.title,
    this.artist = '',
    this.year,
    this.coverUrl = '',
  });

  final String id;
  final String title;
  final String artist;
  final int? year;
  final String coverUrl;
}

class ForeignAlbum {
  const ForeignAlbum({
    required this.id,
    required this.title,
    required this.artist,
    required this.coverUrl,
    required this.tracks,
    this.year,
  });

  final String id;
  final String title;
  final String artist;
  final int? year;
  final String coverUrl;
  final List<Track> tracks;
}

class ForeignArtistPage {
  const ForeignArtistPage({
    required this.id,
    required this.name,
    required this.albums,
  });

  final String id;
  final String name;
  final List<ForeignAlbumRef> albums;
}

class ForeignFound {
  const ForeignFound({
    this.tracks = const [],
    this.albums = const [],
    this.artists = const [],
  });

  final List<Track> tracks;
  final List<ForeignAlbumRef> albums;
  final List<ForeignArtist> artists;
}

/// Unified view of foreign server (Navidrome, Jellyfin) for app screens.
abstract class ForeignLibrary {
  Future<ForeignFound> search(String query);
  Future<List<ForeignArtist>> artists();
  Future<ForeignArtistPage> artist(String id);
  Future<ForeignAlbum> album(String id);

  /// Favorites from the server itself (up to 500 songs for Jellyfin).
  Future<List<Track>> favorites();

  /// Server error (song missing) propagates outward: screen restores heart icon.
  Future<void> setFavorite(String trackId, {required bool favorite});

  /// Stream URL with credentials included; offline.
  Uri streamUrl(String trackId);
}

class SubsonicLibrary extends ForeignLibrary {
  SubsonicLibrary(this.client);

  final SubsonicClient client;

  @override
  Future<List<Track>> favorites() async =>
      (await client.starred()).map(_track).toList();

  @override
  Future<void> setFavorite(String trackId, {required bool favorite}) =>
      favorite ? client.star(trackId) : client.unstar(trackId);

  @override
  Uri streamUrl(String trackId) => client.streamUri(trackId);

  String _cover(String coverArt) => client.coverUri(coverArt)?.toString() ?? '';

  Track _track(SubsonicSong s) => Track(
    id: s.id,
    title: s.title,
    artist: s.artist,
    durationMs: s.durationMs,
    artworkUrl: _cover(s.coverArt),
  );

  ForeignAlbumRef _ref(SubsonicAlbum a) => ForeignAlbumRef(
    id: a.id,
    title: a.name,
    artist: a.artist,
    year: a.year,
    coverUrl: _cover(a.coverArt),
  );

  ForeignArtist _artist(SubsonicArtist a) =>
      ForeignArtist(id: a.id, name: a.name);

  @override
  Future<ForeignFound> search(String query) async {
    final found = await client.search(query);
    return ForeignFound(
      tracks: found.songs.map(_track).toList(),
      albums: found.albums.map(_ref).toList(),
      artists: found.artists.map(_artist).toList(),
    );
  }

  @override
  Future<List<ForeignArtist>> artists() async =>
      (await client.artists()).map(_artist).toList();

  @override
  Future<ForeignArtistPage> artist(String id) async {
    final a = await client.artist(id);
    return ForeignArtistPage(
      id: a.id,
      name: a.name,
      albums: a.albums.map(_ref).toList(),
    );
  }

  @override
  Future<ForeignAlbum> album(String id) async {
    final a = await client.album(id);
    return ForeignAlbum(
      id: a.id,
      title: a.name,
      artist: a.artist,
      year: a.year,
      coverUrl: _cover(a.coverArt),
      tracks: a.songs.map(_track).toList(),
    );
  }
}

class JellyfinLibrary extends ForeignLibrary {
  JellyfinLibrary(this.client);

  final JellyfinClient client;

  @override
  Future<List<Track>> favorites() async =>
      (await client.favorites(limit: 500)).items.map(_track).toList();

  @override
  Future<void> setFavorite(String trackId, {required bool favorite}) =>
      client.setFavorite(trackId, favorite: favorite);

  @override
  Uri streamUrl(String trackId) => client.streamUri(trackId);

  String _image(String itemId, String tag) =>
      client.imageUri(itemId, tag)?.toString() ?? '';

  Track _track(JellyfinSong s) => Track(
    id: s.id,
    title: s.title,
    artist: s.artist,
    durationMs: s.durationMs,
    artworkUrl: _image(s.imageItemId, s.imageTag),
  );

  ForeignAlbumRef _ref(JellyfinAlbum a) => ForeignAlbumRef(
    id: a.id,
    title: a.name,
    artist: a.artist,
    year: a.year,
    coverUrl: _image(a.id, a.imageTag),
  );

  ForeignArtist _artist(JellyfinArtist a) =>
      ForeignArtist(id: a.id, name: a.name, imageUrl: _image(a.id, a.imageTag));

  @override
  Future<ForeignFound> search(String query) async {
    final found = await client.search(query);
    return ForeignFound(
      tracks: found.songs.map(_track).toList(),
      albums: found.albums.map(_ref).toList(),
      artists: found.artists.map(_artist).toList(),
    );
  }

  /// Artists in pages of 100, until `total` is reached.
  @override
  Future<List<ForeignArtist>> artists() async {
    final all = <ForeignArtist>[];
    while (true) {
      final page = await client.artists(startIndex: all.length);
      all.addAll(page.items.map(_artist));
      if (page.items.isEmpty || all.length >= page.total) return all;
    }
  }

  /// Client has no "artist by id" query, so name is taken from albums.
  @override
  Future<ForeignArtistPage> artist(String id) async {
    final albums = await client.albums(id);
    return ForeignArtistPage(
      id: id,
      name: albums.isEmpty ? '' : albums.first.artist,
      albums: albums.map(_ref).toList(),
    );
  }

  @override
  Future<ForeignAlbum> album(String id) async {
    final a = await client.album(id);
    final songs = await client.songs(id);
    return ForeignAlbum(
      id: a.id,
      title: a.name,
      artist: a.artist,
      year: a.year,
      coverUrl: _image(a.id, a.imageTag),
      tracks: songs.map(_track).toList(),
    );
  }
}

/// [ForeignLibrary] acting as app catalog.
class ForeignCatalog implements CatalogPort {
  ForeignCatalog(this.library);

  final ForeignLibrary library;

  @override
  Future<SearchResult> search(String query) async {
    try {
      final found = await library.search(query);
      return SearchResult(
        tracks: found.tracks,
        artists: [for (final a in found.artists) a.name],
      );
    } on SubsonicError catch (e) {
      throw SearchFailed(switch (e.kind) {
        SubsonicFailure.auth ||
        SubsonicFailure.authUnsupported ||
        SubsonicFailure.forbidden => SearchFailure.noAccess,
        _ => SearchFailure.noAnswer,
      });
    } on JellyfinError catch (e) {
      throw SearchFailed(switch (e.kind) {
        JellyfinFailure.auth ||
        JellyfinFailure.forbidden => SearchFailure.noAccess,
        _ => SearchFailure.noAnswer,
      });
    } on SearchFailed {
      rethrow;
    } catch (_) {
      // Network, timeout, foreign format.
      throw const SearchFailed(SearchFailure.noAnswer);
    }
  }

  /// Foreign servers have no suggestions; do not touch network.
  @override
  Future<List<String>> suggest(String query) async => const [];
}
