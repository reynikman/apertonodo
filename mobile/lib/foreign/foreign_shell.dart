import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../jellyfin_client.dart';
import '../l10n/l10n.dart';
import '../models/track.dart';
import '../player.dart';
import '../screens/mini_player.dart';
import '../screens/player_screen.dart';
import '../subsonic_client.dart';
import '../theme.dart';
import 'foreign_library.dart';

/// Lightweight shell for Navidrome and Jellyfin (FT-779): search, library,
/// favorites and the same player. Heavy app is not needed here: news,
/// podcasts and imports are absent on foreign servers.
class ForeignShell extends StatefulWidget {
  const ForeignShell({
    super.key,
    required this.library,
    required this.player,
    required this.onLeave,
  });

  final ForeignLibrary library;
  final Player player;
  final Future<void> Function() onLeave;

  @override
  State<ForeignShell> createState() => _ForeignShellState();
}

/// Server favorites: single instance across all lists so heart icon matches everywhere.
class _Likes extends ChangeNotifier {
  final ids = <String>{};
  List<Track> tracks = const [];
  Object? error;
  bool loading = true;

  void done(List<Track> found, Object? failure) {
    tracks = found;
    ids
      ..clear()
      ..addAll(found.map((t) => t.id));
    error = failure;
    loading = false;
    notifyListeners();
  }

  void restart() {
    loading = true;
    error = null;
    notifyListeners();
  }

  void set(String id, bool favorite) {
    favorite ? ids.add(id) : ids.remove(id);
    notifyListeners();
  }
}

class _ForeignShellState extends State<ForeignShell> {
  final _likes = _Likes();
  final _navs = [for (var i = 0; i < 2; i++) GlobalKey<NavigatorState>()];
  final _visited = {0};
  var _index = 0;
  var _leaving = false;

  ForeignLibrary get _library => widget.library;

  @override
  void initState() {
    super.initState();
    // First frame is rendered before any request to the server.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_loadLikes());
    });
  }

  @override
  void dispose() {
    _likes.dispose();
    super.dispose();
  }

  static bool _isAuth(Object e) =>
      (e is SubsonicError && e.kind == SubsonicFailure.auth) ||
      (e is JellyfinError && e.kind == JellyfinFailure.auth);

  /// Any request to foreign server; auth failure (401) -> back to login.
  Future<T> _call<T>(Future<T> Function() request) async {
    try {
      return await request();
    } catch (e) {
      if (_isAuth(e) && !_leaving) {
        _leaving = true;
        unawaited(widget.onLeave());
      }
      rethrow;
    }
  }

  Future<void> _loadLikes() async {
    _likes.restart();
    try {
      final found = await _call(_library.favorites);
      if (mounted) _likes.done(found, null);
    } catch (e) {
      if (mounted) _likes.done(const [], e);
    }
  }

  Future<void> _toggle(Track track) async {
    final favorite = !_likes.ids.contains(track.id);
    _likes.set(track.id, favorite);
    try {
      await _call(() => _library.setFavorite(track.id, favorite: favorite));
    } catch (_) {
      if (!mounted) return;
      _likes.set(track.id, !favorite);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n(context).foreignLikeFailed)));
    }
  }

  void _back(bool didPop, Object? result) {
    if (didPop) return;
    final tab = _index < 2 ? _navs[_index].currentState : null;
    if (tab != null && tab.canPop()) {
      tab.pop();
    } else {
      SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = l10n(context);
    final ctx = _Ctx(
      library: _library,
      player: widget.player,
      likes: _likes,
      call: _call,
      toggle: _toggle,
    );
    Widget tab(int i, Widget Function() page) => _visited.contains(i)
        ? Navigator(
            key: _navs[i],
            onGenerateRoute: (_) =>
                MaterialPageRoute<void>(builder: (_) => _Frame(child: page())),
          )
        : const SizedBox.shrink();
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: _back,
      child: Scaffold(
        backgroundColor: ApertonoColors.background,
        appBar: AppBar(
          backgroundColor: ApertonoColors.background,
          title: const Text('Apertono'),
          actions: [
            IconButton(
              key: const Key('foreign-leave'),
              tooltip: text.foreignLeave,
              icon: const Icon(Icons.logout),
              onPressed: () => unawaited(widget.onLeave()),
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: IndexedStack(
                index: _index,
                children: [
                  tab(0, () => _SearchPage(ctx)),
                  tab(1, () => _ArtistsPage(ctx)),
                  _visited.contains(2)
                      ? _FavoritesPage(ctx, retry: _loadLikes)
                      : const SizedBox.shrink(),
                ],
              ),
            ),
            MiniPlayer(
              player: widget.player,
              onOpen: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => PlayerScreen(player: widget.player),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          backgroundColor: ApertonoColors.surface,
          indicatorColor: ApertonoColors.accentSoft,
          selectedIndex: _index,
          onDestinationSelected: (i) => setState(() {
            _index = i;
            _visited.add(i);
          }),
          destinations: [
            NavigationDestination(
              key: const Key('foreign-tab-search'),
              icon: const Icon(Icons.search),
              label: text.searchTitle,
            ),
            NavigationDestination(
              key: const Key('foreign-tab-library'),
              icon: const Icon(Icons.library_music_outlined),
              label: text.foreignTabLibrary,
            ),
            NavigationDestination(
              key: const Key('foreign-tab-favorites'),
              icon: const Icon(Icons.favorite_border),
              label: text.foreignTabFavorites,
            ),
          ],
        ),
      ),
    );
  }
}

class _Ctx {
  const _Ctx({
    required this.library,
    required this.player,
    required this.likes,
    required this.call,
    required this.toggle,
  });

  final ForeignLibrary library;
  final Player player;
  final _Likes likes;
  final Future<T> Function<T>(Future<T> Function() request) call;
  final Future<void> Function(Track track) toggle;

  void play(List<Track> tracks, int start) =>
      unawaited(player.playQueue(tracks, start: start));
}

/// Tab page: header with "back" when there is somewhere to return to.
class _Frame extends StatelessWidget {
  const _Frame({required this.child, this.title});

  final Widget child;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final canPop = Navigator.of(context).canPop();
    return Column(
      children: [
        if (canPop)
          Row(
            children: [
              IconButton(
                tooltip: l10n(context).foreignBack,
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.of(context).pop(),
              ),
              Expanded(
                child: Text(
                  title ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ApertonoText.sectionTitle,
                ),
              ),
            ],
          ),
        Expanded(child: child),
      ],
    );
  }
}

void _open(BuildContext context, String title, Widget page) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _Frame(title: title, child: page),
      ),
    );

/// Loading with spinner and "Retry" row.
class _Load<T> extends StatefulWidget {
  const _Load({
    super.key,
    required this.ctx,
    required this.load,
    required this.builder,
  });

  final _Ctx ctx;
  final Future<T> Function() load;
  final Widget Function(BuildContext context, T data) builder;

  @override
  State<_Load<T>> createState() => _LoadState<T>();
}

class _LoadState<T> extends State<_Load<T>> {
  late Future<T> _future = widget.ctx.call(widget.load);

  @override
  Widget build(BuildContext context) => FutureBuilder<T>(
    future: _future,
    builder: (context, snapshot) {
      if (snapshot.hasData ||
          snapshot.connectionState == ConnectionState.done &&
              !snapshot.hasError) {
        return widget.builder(context, snapshot.data as T);
      }
      if (snapshot.hasError) {
        return _Failed(
          onRetry: () => setState(() => _future = widget.ctx.call(widget.load)),
        );
      }
      return const Center(child: CircularProgressIndicator());
    },
  );
}

class _Failed extends StatelessWidget {
  const _Failed({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final text = l10n(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text.foreignLoadFailed,
            textAlign: TextAlign.center,
            style: ApertonoText.trackArtist,
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            key: const Key('foreign-retry'),
            onPressed: onRetry,
            child: Text(text.foreignRetry),
          ),
        ],
      ),
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover(this.url, {this.round = false});

  final String url;
  final bool round;

  @override
  Widget build(BuildContext context) {
    const size = 48.0;
    final placeholder = ColoredBox(
      color: ApertonoColors.surfaceRaised,
      child: Icon(
        round ? Icons.person : Icons.music_note,
        color: ApertonoColors.textMuted,
      ),
    );
    return SizedBox.square(
      dimension: size,
      child: ClipRRect(
        borderRadius: round
            ? BorderRadius.circular(size)
            : BorderRadius.circular(ApertonoRadii.cover),
        child: url.isEmpty
            ? placeholder
            : Image.network(
                url,
                fit: BoxFit.cover,
                cacheWidth: 144,
                errorBuilder: (_, _, _) => placeholder,
              ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(label, style: ApertonoText.sectionTitle),
  );
}

class _TrackRow extends StatelessWidget {
  const _TrackRow(this.ctx, this.track, {required this.onTap});

  final _Ctx ctx;
  final Track track;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = l10n(context);
    return ListTile(
      onTap: onTap,
      leading: _Cover(track.artworkUrl),
      title: Text(
        track.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: ApertonoText.trackTitle,
      ),
      subtitle: Text(
        track.artist,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: ApertonoText.trackArtist,
      ),
      trailing: ListenableBuilder(
        listenable: ctx.likes,
        builder: (context, _) {
          final liked = ctx.likes.ids.contains(track.id);
          return IconButton(
            key: Key('foreign-like-${track.id}'),
            tooltip: liked ? text.foreignUnlike : text.foreignLike,
            icon: Icon(
              liked ? Icons.favorite : Icons.favorite_border,
              color: liked
                  ? ApertonoColors.accent
                  : ApertonoColors.textSecondary,
            ),
            onPressed: () => unawaited(ctx.toggle(track)),
          );
        },
      ),
    );
  }
}

class _AlbumRow extends StatelessWidget {
  const _AlbumRow(this.ctx, this.album);

  final _Ctx ctx;
  final ForeignAlbumRef album;

  @override
  Widget build(BuildContext context) => ListTile(
    onTap: () => _open(context, album.title, _AlbumPage(ctx, album.id)),
    leading: _Cover(album.coverUrl),
    title: Text(
      album.title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: ApertonoText.trackTitle,
    ),
    subtitle: Text(
      [
        album.artist,
        if (album.year != null) '${album.year}',
      ].where((s) => s.isNotEmpty).join(' · '),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: ApertonoText.trackArtist,
    ),
  );
}

class _ArtistRow extends StatelessWidget {
  const _ArtistRow(this.ctx, this.artist);

  final _Ctx ctx;
  final ForeignArtist artist;

  @override
  Widget build(BuildContext context) => ListTile(
    onTap: () => _open(context, artist.name, _ArtistPage(ctx, artist.id)),
    leading: _Cover(artist.imageUrl, round: true),
    title: Text(
      artist.name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: ApertonoText.trackTitle,
    ),
  );
}

class _SearchPage extends StatefulWidget {
  const _SearchPage(this.ctx);

  final _Ctx ctx;

  @override
  State<_SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<_SearchPage> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final text = l10n(context);
    final ctx = widget.ctx;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TextField(
            key: const Key('foreign-search-field'),
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: text.searchHint,
              prefixIcon: const Icon(Icons.search),
              filled: true,
              fillColor: ApertonoColors.surface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(ApertonoRadii.medium),
                borderSide: BorderSide.none,
              ),
            ),
            onSubmitted: (value) => setState(() => _query = value.trim()),
          ),
        ),
        Expanded(
          child: _query.isEmpty
              ? const SizedBox.shrink()
              : _Load<ForeignFound>(
                  key: ValueKey(_query),
                  ctx: ctx,
                  load: () => ctx.library.search(_query),
                  builder: (context, found) {
                    if (found.tracks.isEmpty &&
                        found.albums.isEmpty &&
                        found.artists.isEmpty) {
                      return Center(
                        child: Text(
                          text.searchEmpty,
                          style: ApertonoText.trackArtist,
                        ),
                      );
                    }
                    return ListView(
                      children: [
                        if (found.tracks.isNotEmpty)
                          _Heading(text.searchTracks),
                        for (final (i, t) in found.tracks.indexed)
                          _TrackRow(
                            ctx,
                            t,
                            onTap: () => ctx.play(found.tracks, i),
                          ),
                        if (found.albums.isNotEmpty)
                          _Heading(text.foreignAlbums),
                        for (final a in found.albums) _AlbumRow(ctx, a),
                        if (found.artists.isNotEmpty)
                          _Heading(text.foreignArtists),
                        for (final a in found.artists) _ArtistRow(ctx, a),
                      ],
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _ArtistsPage extends StatelessWidget {
  const _ArtistsPage(this.ctx);

  final _Ctx ctx;

  @override
  Widget build(BuildContext context) => _Load<List<ForeignArtist>>(
    ctx: ctx,
    load: ctx.library.artists,
    builder: (context, artists) =>
        ListView(children: [for (final a in artists) _ArtistRow(ctx, a)]),
  );
}

class _ArtistPage extends StatelessWidget {
  const _ArtistPage(this.ctx, this.id);

  final _Ctx ctx;
  final String id;

  @override
  Widget build(BuildContext context) => _Load<ForeignArtistPage>(
    ctx: ctx,
    load: () => ctx.library.artist(id),
    builder: (context, page) =>
        ListView(children: [for (final a in page.albums) _AlbumRow(ctx, a)]),
  );
}

class _AlbumPage extends StatelessWidget {
  const _AlbumPage(this.ctx, this.id);

  final _Ctx ctx;
  final String id;

  @override
  Widget build(BuildContext context) => _Load<ForeignAlbum>(
    ctx: ctx,
    load: () => ctx.library.album(id),
    builder: (context, album) => ListView(
      children: [
        for (final (i, t) in album.tracks.indexed)
          _TrackRow(ctx, t, onTap: () => ctx.play(album.tracks, i)),
      ],
    ),
  );
}

class _FavoritesPage extends StatelessWidget {
  const _FavoritesPage(this.ctx, {required this.retry});

  final _Ctx ctx;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: ctx.likes,
    builder: (context, _) {
      final likes = ctx.likes;
      if (likes.loading) {
        return const Center(child: CircularProgressIndicator());
      }
      if (likes.error != null) return _Failed(onRetry: retry);
      if (likes.tracks.isEmpty) {
        return Center(
          child: Text(
            l10n(context).foreignFavoritesEmpty,
            style: ApertonoText.trackArtist,
          ),
        );
      }
      return ListView(
        children: [
          for (final (i, t) in likes.tracks.indexed)
            _TrackRow(ctx, t, onTap: () => ctx.play(likes.tracks, i)),
        ],
      );
    },
  );
}
