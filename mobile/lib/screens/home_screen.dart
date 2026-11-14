import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/track.dart';
import '../server_api.dart';
import '../theme.dart';
import 'artist_avatar.dart';
import 'library_screens.dart';
import 'parts.dart';

/// Home: artists, favorite songs, playlists, and recently played songs.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.services, this.active});

  final Services services;
  final ValueListenable<bool>? active;

  /// Frequent artists from history or catalog start.
  static const artistCount = 4;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with LibraryRefresh<HomeScreen> {
  List<CatalogArtist> _artists = const [];
  List<Track> _recent = const [];
  List<Track> _favorites = const [];
  List<Track?> _playlistCovers = const [];
  int? _favoriteCount;
  int? _playlistCount;

  @override
  ServerApi get libraryServer => widget.services.server;

  @override
  ValueListenable<bool>? get libraryActive => widget.active;

  @override
  RouteObserver<ModalRoute<dynamic>>? get libraryRoutes =>
      widget.services.routes;

  @override
  void reloadLibrary() {
    unawaited(_loadFavorites());
    unawaited(_loadPlaylists());
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Timer.run(() {
        if (!mounted) return;
        unawaited(_load());
      });
    });
  }

  Future<void> _load() async {
    final server = widget.services.server;
    Chunk<Listen> history;
    try {
      history = await server.history();
    } catch (_) {
      history = (items: <Listen>[], total: 0);
    }
    if (!mounted) {
      return;
    }
    final rows = [
      for (final row in history.items)
        if (!row.testTone) row,
    ];
    final tracks = [for (final row in rows) row.track];
    final recent = _uniqueRecent(tracks);
    final listened = _frequentArtists(rows);
    if (listened.isNotEmpty) {
      setState(() {
        _artists = listened.take(HomeScreen.artistCount).toList();
        _recent = recent;
      });
      return;
    }
    Chunk<CatalogArtist> catalog;
    try {
      catalog = await server.artistCatalog();
    } catch (_) {
      catalog = (items: <CatalogArtist>[], total: 0);
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _artists = catalog.items.take(HomeScreen.artistCount).toList();
      _recent = const [];
    });
  }

  Future<void> _loadFavorites() async {
    try {
      final tracks = await widget.services.server.favorites();
      if (!mounted) return;
      setState(() {
        _favoriteCount = tracks.length;
        _favorites = tracks.take(3).toList();
      });
    } catch (_) {
      // No response — no count, tile keeps neutral fan.
    }
  }

  Future<void> _loadPlaylists() async {
    final server = widget.services.server;
    List<PlaylistInfo> playlists;
    try {
      playlists = await server.playlists();
    } catch (_) {
      return;
    }
    if (!mounted) return;
    setState(() => _playlistCount = playlists.length);
    final covers = await Future.wait([
      for (final info in playlists.take(3))
        () async {
          try {
            final playlist = await server.playlist(info.id);
            return playlist.tracks.firstOrNull;
          } catch (_) {
            return null;
          }
        }(),
    ]);
    if (!mounted) return;
    setState(() => _playlistCovers = covers);
  }

  static List<CatalogArtist> _frequentArtists(List<Listen> rows) {
    final counts = <String, int>{};
    final photos = <String, String?>{};
    for (final row in rows) {
      final name = row.track.artist;
      counts[name] = (counts[name] ?? 0) + 1;
      final photo = row.artistPhoto;
      if (photo != null && photo.isNotEmpty) {
        photos[name] ??= photo;
      }
    }
    final names = counts.keys.toList()
      ..sort((a, b) {
        final byCount = counts[b]!.compareTo(counts[a]!);
        return byCount != 0 ? byCount : a.compareTo(b);
      });
    return [
      for (final name in names) CatalogArtist(name: name, photo: photos[name]),
    ];
  }

  static List<Track> _uniqueRecent(List<Track> tracks) {
    final seen = <String>{};
    final out = <Track>[];
    for (final track in tracks) {
      final key = '${track.artist}\u0000${track.title}';
      if (!seen.add(key)) {
        continue;
      }
      out.add(track);
      if (out.length == 4) {
        break;
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final services = widget.services;
    final text = l10n(context);
    // Top is system notification bar: without SafeArea "Home" slipped under
    // clock (01.10). Bottom inset is held by tab bar.
    return SafeArea(
      bottom: false,
      child: CustomScrollView(
        key: const Key('home-screen'),
        slivers: [
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    text.homeTitle,
                    key: const Key('home-title'),
                    style: ApertonoText.screenTitle,
                  ),
                  const SizedBox(height: 10),
                  if (_artists.isNotEmpty) ...[
                    _artistCard(),
                    const SizedBox(height: 10),
                  ],
                  if (_recent.isNotEmpty) ...[
                    _recentCard(),
                    const SizedBox(height: 10),
                  ],
                  Flexible(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: 180,
                        maxHeight: MediaQuery.textScalerOf(context).scale(260),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: _promoCard(
                              key: const Key('home-favorites'),
                              title: text.homeFavorites,
                              count: switch (_favoriteCount) {
                                null => null,
                                0 => text.homeEmpty,
                                final n => countIn(
                                  text,
                                  n,
                                  text.homeTrackOne,
                                  text.homeTrackFew,
                                  text.homeTrackMany,
                                ),
                              },
                              icon: Icons.favorite_border,
                              iconColor: ApertonoColors.textPrimary,
                              tracks: _favorites,
                              onTap: () => open(
                                context,
                                FavoritesScreen(services: services),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _promoCard(
                              key: const Key('home-playlists'),
                              title: text.homePlaylists,
                              count: switch (_playlistCount) {
                                null => null,
                                0 => text.homeEmpty,
                                final n => countIn(
                                  text,
                                  n,
                                  text.homePlaylistOne,
                                  text.homePlaylistFew,
                                  text.homePlaylistMany,
                                ),
                              },
                              icon: Icons.queue_music,
                              iconColor: ApertonoColors.textPrimary,
                              tracks: _playlistCovers,
                              onTap: () => open(
                                context,
                                PlaylistsScreen(services: services),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  BoxDecoration get _cardDecoration => BoxDecoration(
    gradient: ApertonoColors.cardGradient,
    border: Border.all(color: ApertonoColors.border),
    borderRadius: BorderRadius.circular(ApertonoRadii.large),
  );

  Widget _artistCard() {
    final services = widget.services;
    return DecoratedBox(
      key: const Key('home-artists'),
      decoration: _cardDecoration,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (final artist in _artists)
              InkWell(
                onTap: switch (services.openArtist) {
                  final open? => () => open(artist.name),
                  null => null,
                },
                child: SizedBox(
                  width: 74,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox.square(
                        key: const Key('home-artist-avatar'),
                        dimension: 56,
                        child: ArtistAvatar(
                          name: artist.name,
                          photo: artist.photo,
                          server: services.server,
                          size: 56,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        artist.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: ApertonoText.artistName.copyWith(
                          color: ApertonoColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _promoCard({
    required Key key,
    required String title,
    required String? count,
    required IconData icon,
    required Color iconColor,
    required List<Track?> tracks,
    required VoidCallback onTap,
  }) {
    final radius = BorderRadius.circular(ApertonoRadii.large);
    return DecoratedBox(
      key: key,
      decoration: _cardDecoration,
      child: ClipRRect(
        borderRadius: radius,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: radius,
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, size: 28, color: iconColor),
                  const SizedBox(height: 6),
                  Text(
                    title,
                    style: ApertonoText.promoTitle.copyWith(
                      color: ApertonoColors.textPrimary,
                    ),
                  ),
                  if (count != null) ...[
                    const SizedBox(height: 3),
                    Text(count, style: ApertonoText.trackArtist),
                  ],
                  Expanded(
                    // Fan occupies allocated remainder, but does not impose its
                    // intrinsic height during SliverFillRemaining measurement.
                    child: SizedBox(height: 0, child: _coverFan(tracks)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _coverFan(List<Track?> tracks) {
    Widget cover(int index) {
      final track = index < tracks.length ? tracks[index] : null;
      return SizedBox.square(
        key: const Key('home-fan-cover'),
        dimension: 100,
        child: track != null
            ? Cover(
                server: widget.services.server,
                path: coverPath(track),
                artist: track.artist,
                size: 100,
              )
            : DecoratedBox(
                decoration: BoxDecoration(
                  color: ApertonoColors.surfaceRaised,
                  border: Border.all(color: ApertonoColors.border),
                  borderRadius: BorderRadius.circular(ApertonoRadii.cover),
                ),
              ),
      );
    }

    // Outer covers peek from under middle by nearly half, leaving bottom
    // breathing room for rotation: fan does not hit tile edge in layout.
    return FittedBox(
      alignment: Alignment.bottomCenter,
      child: SizedBox(
        width: 190,
        height: 135,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: 0,
              bottom: 14,
              child: Transform.rotate(angle: -0.12, child: cover(1)),
            ),
            Positioned(
              right: 0,
              bottom: 14,
              child: Transform.rotate(angle: 0.12, child: cover(2)),
            ),
            Positioned(left: 45, bottom: 24, child: cover(0)),
          ],
        ),
      ),
    );
  }

  Widget _recentCard() {
    final services = widget.services;
    return DecoratedBox(
      key: const Key('home-recent'),
      decoration: _cardDecoration,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var index = 0; index < _recent.length; index++) ...[
              if (index > 0)
                const Divider(
                  height: 5,
                  thickness: 1,
                  color: ApertonoColors.divider,
                ),
              InkWell(
                onTap: () {
                  final (queue, start) = queueFrom(_recent, index);
                  services.play(queue, start);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      SizedBox.square(
                        key: const Key('home-recent-cover'),
                        dimension: 44,
                        child: Cover(
                          server: services.server,
                          path: coverPath(_recent[index]),
                          artist: _recent[index].artist,
                          size: 44,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _recent[index].title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: ApertonoText.trackTitle.copyWith(
                                fontSize: 14.5,
                                color: ApertonoColors.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _recent[index].artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: ApertonoText.trackArtist,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
