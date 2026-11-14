import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../l10n/l10n.dart';
import '../models/track.dart';
import '../offline/downloads.dart';
import '../server_api.dart';
import '../theme.dart';
import 'artist_avatar.dart';
import 'known_as.dart';
import 'parts.dart';
import 'problem_sheet.dart';
import 'search_screen.dart';

/// First [count] sentences. Split on sentence boundaries, not characters.
String bioPreview(String bio, {int count = 3}) {
  final trimmed = bio.trim();
  final sentences = [
    for (final match in RegExp(r'[^.!?]+(?:[.!?]+|$)').allMatches(trimmed))
      match[0]!.trim(),
  ].where((part) => part.isNotEmpty).toList();
  if (sentences.length <= count) {
    return trimmed;
  }
  return sentences.take(count).join(' ');
}

/// Edition kind as text (FT-552): "album", "live", "compilation", "EP", "single".
String editionKind(String kind, AppLocalizations text) => switch (kind) {
  'live' => text.catalogKindLive,
  'compilation' => text.catalogKindCompilation,
  'ep' => 'EP',
  'single' => text.catalogKindSingle,
  _ => text.catalogKindAlbum,
};

/// Edition line: textual kind and year — "live · 2008".
String editionLine(AlbumEdition edition, AppLocalizations text) {
  final year = edition.year;
  return year == null
      ? editionKind(edition.kind, text)
      : '${editionKind(edition.kind, text)} · $year';
}

void openSearch(BuildContext context, Services services, {String query = ''}) {
  open(
    context,
    SearchScreen(
      key: const Key('catalog-search'),
      onSearch: services.search,
      onSelect: services.play,
      onResults: (tracks) => services.prepare(tracks.first),
      onSuggest: services.suggest,
      onArtist: services.openArtist,
      recent: services.recent,
      services: services,
      query: query,
    ),
  );
}

/// Row in complete genres list.
class GenreRow extends StatelessWidget {
  const GenreRow({super.key, required this.services, required this.genre});

  final Services services;
  final Genre genre;

  @override
  Widget build(BuildContext context) {
    final text = l10n(context);
    return ListTile(
      key: ValueKey('genre-row-${genre.id}'),
      title: Text(genre.name, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        countIn(
          text,
          genre.artists,
          text.catalogArtistOne,
          text.catalogArtistFew,
          text.catalogArtistMany,
        ),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => open(
        context,
        ArtistsScreen(
          services: services,
          title: genre.name,
          load: (offset) =>
              services.server.artistCatalog(genre: genre.id, offset: offset),
          letters: () => services.server.genreLetters(genre.id),
        ),
      ),
    );
  }
}

/// Artist row — identical to the one in artists list.
class ArtistRow extends StatelessWidget {
  const ArtistRow({
    super.key,
    required this.services,
    required this.name,
    this.photo,
  });

  final Services services;
  final String name;
  final String? photo;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: ValueKey('artist-row-$name'),
      leading: ArtistAvatar(
        name: name,
        photo: photo,
        server: services.server,
        size: 48,
      ),
      title: Text(name),
      onTap: () => open(context, ArtistScreen(services: services, name: name)),
    );
  }
}

/// Photo genre order — from dump, independent of server order.
const _photoGenreIds = [
  'rock',
  'metal',
  'pop',
  'hip-hop',
  'electronic',
  'jazz',
  'alternative',
  'classical',
  'rnb',
  'reggae',
];

/// Discover: photo genres and entry point to full list.
class GenresScreen extends StatefulWidget {
  const GenresScreen({super.key, required this.services});

  final Services services;

  @override
  State<GenresScreen> createState() => _GenresScreenState();
}

class _GenresScreenState extends State<GenresScreen> {
  Services get services => widget.services;

  // FT-800: until response arrives, tiles are active.
  bool _booksSet = true;
  bool _podcastsSet = true;

  @override
  void initState() {
    super.initState();
    services.server.features().then((features) {
      if (mounted) {
        setState(() {
          _booksSet = features.books;
          _podcastsSet = features.podcasts;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = l10n(context);
    return Scaffold(
      body: SafeArea(
        child: Loaded<List<Genre>>(
          server: services.server,
          screen: 'genres',
          load: services.server.genres,
          builder: (context, genres, reload) {
            if (genres.isEmpty) {
              return Message(text.catalogNoGenres, onRetry: reload);
            }
            final byId = {for (final genre in genres) genre.id: genre};
            final photoGenres = [for (final id in _photoGenreIds) ?byId[id]];
            final spoken = [
              if (services.podcasts case final podcasts?)
                _SpokenCard(
                  key: const Key('browse-podcasts'),
                  title: text.podcastsTitle,
                  image: 'assets/genres/podcasts.jpg',
                  configured: _podcastsSet,
                  onTap: () => open(context, podcasts(context)),
                ),
              if (services.books case final books?)
                _SpokenCard(
                  key: const Key('browse-books'),
                  title: text.browseBooks,
                  image: 'assets/genres/books.jpg',
                  configured: _booksSet,
                  onTap: () => open(context, books(context)),
                ),
            ];
            final cards = [
              for (final genre in photoGenres)
                _GenreCard(services: services, genre: genre),
            ];
            // No scroll: tiles divide height remaining after header
            // and "All genres". Podcasts and audiobooks are 1.5x higher than genre;
            // genre rows — as many as fit with tile at least 56 (from 5 down to 2).
            Widget pair(List<Widget> items, double height) => SizedBox(
              height: height,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < 2; i++) ...[
                    if (i > 0) const SizedBox(width: 12),
                    Expanded(
                      child: i < items.length ? items[i] : const SizedBox(),
                    ),
                  ],
                ],
              ),
            );
            Widget tiles(double room) {
              final hasSpoken = spoken.isNotEmpty;
              final most = (cards.length + 1) ~/ 2;
              var rows = most < 5 ? most : 5;
              double heightFor(int n) {
                final gaps = hasSpoken ? n : n - 1;
                return (room - 12 * gaps) / ((hasSpoken ? 1.5 : 0) + n);
              }

              while (rows > 2 && heightFor(rows) < 56) {
                rows--;
              }
              if (rows < 1) rows = 0;
              final h = rows == 0 ? 0.0 : heightFor(rows);
              return Column(
                children: [
                  if (hasSpoken) pair(spoken, h * 1.5),
                  for (var r = 0; r < rows; r++) ...[
                    if (hasSpoken || r > 0) const SizedBox(height: 12),
                    pair(
                      cards.sublist(
                        r * 2,
                        r * 2 + 2 > cards.length ? r * 2 + 1 : r * 2 + 2,
                      ),
                      h,
                    ),
                  ],
                ],
              );
            }

            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      text.catalogBrowseTitle,
                      key: const Key('browse-title'),
                      style: ApertonoText.screenTitle,
                    ),
                  ),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, box) => tiles(box.maxHeight),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 48,
                    child: ListTile(
                      key: const Key('browse-all-genres'),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(text.catalogAllGenres),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => open(
                        context,
                        _AllGenresScreen(services: services, genres: genres),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// "Podcasts" / "Audiobooks" tile in Discover: styled like genre tile (P-A108,
/// FT-797) — full-tile photo, scrim, label at bottom left.
class _SpokenCard extends StatelessWidget {
  const _SpokenCard({
    super.key,
    required this.title,
    required this.image,
    required this.onTap,
    this.configured = true,
  });

  final String title;
  final String image;

  /// FT-800: unconfigured on server — tile is dimmed and non-interactive.
  final bool configured;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scrim = Theme.of(context).colorScheme.scrim;
    final card = ClipRRect(
      borderRadius: BorderRadius.circular(ApertonoRadii.genre),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(image, fit: BoxFit.cover, excludeFromSemantics: true),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
                colors: [
                  scrim.withValues(alpha: 0),
                  scrim.withValues(alpha: 0.85),
                ],
              ),
            ),
          ),
          Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: configured ? onTap : null,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Word intact: on 360 dp "Audiobooks" overflows row font size,
                    // label scales down rather than wrapping or clipping.
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        title,
                        maxLines: 1,
                        softWrap: false,
                        style: ApertonoText.promoTitle.copyWith(
                          color: ApertonoColors.textPrimary,
                        ),
                      ),
                    ),
                    if (!configured)
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          l10n(context).browseNotSetUp,
                          maxLines: 1,
                          softWrap: false,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: ApertonoColors.textPrimary),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
    return configured ? card : Opacity(opacity: 0.5, child: card);
  }
}

class _GenreCard extends StatelessWidget {
  const _GenreCard({required this.services, required this.genre});

  final Services services;
  final Genre genre;

  @override
  Widget build(BuildContext context) {
    final scrim = Theme.of(context).colorScheme.scrim;
    return ClipRRect(
      key: ValueKey('genre-card-${genre.id}'),
      borderRadius: BorderRadius.circular(ApertonoRadii.genre),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            'assets/genres/${genre.id}.jpg',
            fit: BoxFit.cover,
            excludeFromSemantics: true,
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
                colors: [
                  scrim.withValues(alpha: 0),
                  scrim.withValues(alpha: 0.85),
                ],
              ),
            ),
          ),
          Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: () => open(
                context,
                ArtistsScreen(
                  services: services,
                  title: genre.name,
                  load: (offset) => services.server.artistCatalog(
                    genre: genre.id,
                    offset: offset,
                  ),
                  letters: () => services.server.genreLetters(genre.id),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: Text(
                    genre.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ApertonoText.promoTitle.copyWith(
                      color: ApertonoColors.textPrimary,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Already loaded genres: server order, without a second request.
class _AllGenresScreen extends StatelessWidget {
  const _AllGenresScreen({required this.services, required this.genres});

  final Services services;
  final List<Genre> genres;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(l10n(context).catalogAllGenres)),
      body: ListView.builder(
        itemCount: genres.length,
        itemBuilder: (context, index) =>
            GenreRow(services: services, genre: genres[index]),
      ),
    );
  }
}

class ArtistsScreen extends StatefulWidget {
  const ArtistsScreen({
    super.key,
    required this.services,
    required this.title,
    required this.load,
    this.letters,
  });

  final Services services;
  final String title;
  final Future<Chunk<CatalogArtist>> Function(int offset) load;
  final Future<List<GenreLetter>> Function()? letters;

  @override
  State<ArtistsScreen> createState() => _ArtistsScreenState();
}

class _ArtistsScreenState extends State<ArtistsScreen> {
  late final Future<List<GenreLetter>>? _letters = widget.letters?.call()
    ?..ignore();
  var _start = 0;
  Key _listKey = UniqueKey();

  @override
  Widget build(BuildContext context) {
    final gestureRight = MediaQuery.systemGestureInsetsOf(context).right;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: FutureBuilder<List<GenreLetter>>(
        future: _letters,
        builder: (context, snapshot) {
          final letters = snapshot.data ?? const <GenreLetter>[];
          // Row exists before letters arrive: list does not lose first page.
          return Stack(
            fit: StackFit.expand,
            children: [
              Row(
                children: [
                  Expanded(
                    child: PagedList<CatalogArtist>(
                      key: _listKey,
                      start: _start,
                      server: widget.services.server,
                      screen: 'artists',
                      load: widget.load,
                      empty: l10n(context).catalogNoArtists,
                      itemBuilder: (context, items, index) => ArtistRow(
                        services: widget.services,
                        name: items[index].name,
                        photo: items[index].photo,
                      ),
                    ),
                  ),
                  if (letters.length > 1) SizedBox(width: 40 + gestureRight),
                ],
              ),
              if (letters.length > 1)
                _GenreScrubber(
                  letters: letters,
                  start: _start,
                  onSelected: (letter) {
                    setState(() {
                      _start = letter.offset;
                      _listKey = UniqueKey();
                    });
                  },
                ),
            ],
          );
        },
      ),
    );
  }
}

class _GenreScrubber extends StatefulWidget {
  const _GenreScrubber({
    required this.letters,
    required this.start,
    required this.onSelected,
  });

  final List<GenreLetter> letters;
  final int start;
  final ValueChanged<GenreLetter> onSelected;

  @override
  State<_GenreScrubber> createState() => _GenreScrubberState();
}

class _GenreScrubberState extends State<_GenreScrubber> {
  int? _activeIndex;

  void _updateIndex(int index) {
    if (_activeIndex != index) {
      setState(() {
        _activeIndex = index;
      });
      HapticFeedback.selectionClick().ignore();
    }
  }

  void _handlePointer(Offset localPosition, double itemHeight) {
    final index = (localPosition.dy / itemHeight).floor().clamp(
      0,
      widget.letters.length - 1,
    );
    _updateIndex(index);
  }

  void _handlePointerUp(PointerUpEvent event) {
    final index = _activeIndex;
    if (index != null && index >= 0 && index < widget.letters.length) {
      widget.onSelected(widget.letters[index]);
    }
    setState(() {
      _activeIndex = null;
    });
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    setState(() {
      _activeIndex = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final gestureRight = MediaQuery.systemGestureInsetsOf(context).right;
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxHeight = constraints.maxHeight;
        const maxItemHeight = 24.0;
        const verticalPadding = 8.0;
        final usableHeight = (maxHeight - verticalPadding * 2).clamp(
          1.0,
          maxHeight,
        );
        final itemHeight = (usableHeight / widget.letters.length).clamp(
          1.0,
          maxItemHeight,
        );
        final columnHeight = itemHeight * widget.letters.length;
        final columnTop = (maxHeight - columnHeight) / 2;

        final activeIndex = _activeIndex;
        Widget? bubble;
        if (activeIndex != null &&
            activeIndex >= 0 &&
            activeIndex < widget.letters.length) {
          final activeLetter = widget.letters[activeIndex];
          final letterCenterY = columnTop + (activeIndex + 0.5) * itemHeight;
          const bubbleSize = 64.0;
          final bubbleTop = (letterCenterY - bubbleSize / 2).clamp(
            8.0,
            maxHeight - bubbleSize - 8.0,
          );
          bubble = Positioned(
            right: 48 + gestureRight,
            top: bubbleTop,
            child: Container(
              key: const Key('letter-bubble'),
              width: bubbleSize,
              height: bubbleSize,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: ApertonoColors.surfaceRaised,
                shape: BoxShape.circle,
                border: Border.all(
                  color: ApertonoColors.borderStrong,
                  width: 1.5,
                ),
                boxShadow: const [
                  BoxShadow(
                    color: ApertonoColors.shadow,
                    blurRadius: 16,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: Text(
                activeLetter.letter,
                style: const TextStyle(
                  fontFamily: ApertonoFonts.sans,
                  fontSize: 42,
                  fontWeight: FontWeight.w700,
                  color: ApertonoColors.accent,
                ),
              ),
            ),
          );
        }

        return Stack(
          children: [
            Positioned(
              right: gestureRight,
              top: columnTop,
              width: 40,
              height: columnHeight,
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (e) =>
                    _handlePointer(e.localPosition, itemHeight),
                onPointerMove: (e) =>
                    _handlePointer(e.localPosition, itemHeight),
                onPointerUp: _handlePointerUp,
                onPointerCancel: _handlePointerCancel,
                child: Container(
                  key: const Key('letter-strip'),
                  width: 40,
                  height: columnHeight,
                  alignment: Alignment.center,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final (index, letter) in widget.letters.indexed)
                        Semantics(
                          key: Key('letter-${letter.letter}'),
                          selected: widget.start == letter.offset,
                          button: true,
                          onTap: () => widget.onSelected(letter),
                          child: SizedBox(
                            width: 40,
                            height: itemHeight,
                            child: Center(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  letter.letter,
                                  style: TextStyle(
                                    fontFamily: ApertonoFonts.sans,
                                    fontSize: (itemHeight * 0.55).clamp(
                                      8.0,
                                      12.0,
                                    ),
                                    fontWeight: FontWeight.w600,
                                    color:
                                        (widget.start == letter.offset ||
                                            _activeIndex == index)
                                        ? ApertonoColors.accent
                                        : ApertonoColors.textSecondary,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            ?bubble,
          ],
        );
      },
    );
  }
}

const _artistNameStyle = TextStyle(
  fontFamily: ApertonoFonts.sans,
  fontSize: 34,
  height: 40 / 34,
  fontWeight: FontWeight.w700,
  letterSpacing: -0.68,
  color: ApertonoColors.textPrimary,
);

/// Artist: top tracks, albums by year; similar and biography only
/// if server provided them (Last.fm, Phase F2). Absent in response — absent on screen.
class ArtistScreen extends StatefulWidget {
  const ArtistScreen({super.key, required this.services, required this.name});

  final Services services;
  final String name;

  @override
  State<ArtistScreen> createState() => _ArtistScreenState();
}

class _ArtistScreenState extends State<ArtistScreen> {
  var _prepared = const <String>[];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          Loaded<ArtistPage>(
            server: widget.services.server,
            screen: 'artist',
            load: () => widget.services.server.artist(widget.name),
            notFound: l10n(context).catalogArtistNotFound,
            builder: (context, page, _) {
              final text = l10n(context);
              final tracks = [for (final top in page.topTracks) ?top.track];
              _prepared = warmTracks(
                widget.services,
                tracks,
                already: _prepared,
              );
              final albumRows = [
                (
                  text.catalogAlbums,
                  'artist-albums',
                  page.albums.where((album) => album.kind == 'album').toList(),
                ),
                (
                  text.catalogEpAndSingles,
                  'artist-albums-small',
                  page.albums
                      .where(
                        (album) => album.kind == 'ep' || album.kind == 'single',
                      )
                      .toList(),
                ),
                (
                  text.catalogLiveAndCompilations,
                  'artist-albums-live',
                  page.albums
                      .where(
                        (album) =>
                            album.kind == 'live' || album.kind == 'compilation',
                      )
                      .toList(),
                ),
              ];
              return SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (page.photo case final photo?)
                      _Photo(
                        services: widget.services,
                        path: photo,
                        artist: page.name,
                        // Attribution required: server does not serve photo without it.
                        credit: page.photoCredit ?? '',
                      )
                    else
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          16,
                          MediaQuery.paddingOf(context).top + 60,
                          16,
                          0,
                        ),
                        child: Text(
                          page.name,
                          key: const Key('artist-name'),
                          style: _artistNameStyle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    if (tracks.isNotEmpty)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                          child: Wrap(
                            spacing: 12,
                            children: [
                              DecoratedBox(
                                key: const Key('artist-play'),
                                decoration: BoxDecoration(
                                  color: ApertonoColors.surface,
                                  borderRadius: BorderRadius.circular(
                                    ApertonoRadii.pill,
                                  ),
                                  border: Border.all(
                                    color: ApertonoColors.border,
                                  ),
                                ),
                                child: SizedBox(
                                  height: 52,
                                  child: TextButton(
                                    style: TextButton.styleFrom(
                                      padding: const EdgeInsets.fromLTRB(
                                        6,
                                        6,
                                        24,
                                        6,
                                      ),
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                      shape: const StadiumBorder(),
                                    ),
                                    onPressed: () {
                                      final (queue, start) = queueFrom(
                                        tracks,
                                        0,
                                      );
                                      widget.services.play(queue, start);
                                    },
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const DecoratedBox(
                                          key: Key('artist-play-circle'),
                                          decoration: BoxDecoration(
                                            color: ApertonoColors.accent,
                                            shape: BoxShape.circle,
                                          ),
                                          child: SizedBox.square(
                                            dimension: 40,
                                            child: Icon(
                                              Icons.play_arrow_rounded,
                                              color: ApertonoColors.background,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 14),
                                        Text(
                                          text.catalogListen,
                                          style: const TextStyle(
                                            fontSize: 16,
                                            height: 20 / 16,
                                            fontWeight: FontWeight.w600,
                                            color: ApertonoColors.textPrimary,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              if (page.id case final id?)
                                _ArtistFollow(
                                  services: widget.services,
                                  artistId: id,
                                ),
                            ],
                          ),
                        ),
                      ),
                    if (page.topTracks.isNotEmpty) ...[
                      _ArtistHeading(
                        text.catalogPopular,
                        action: page.topTracks.length > 5
                            ? IconButton(
                                key: const Key('popular-more'),
                                tooltip: text.catalogAllPopular,
                                icon: const Icon(
                                  Icons.chevron_right,
                                  size: 20,
                                  color: ApertonoColors.textSecondary,
                                ),
                                onPressed: () {
                                  Navigator.of(context).push(
                                    MaterialPageRoute<void>(
                                      builder: (_) => ArtistSongsScreen(
                                        services: widget.services,
                                        name: page.name,
                                      ),
                                    ),
                                  );
                                },
                              )
                            : null,
                      ),
                      for (final (index, top) in page.topTracks.take(5).indexed)
                        _TopTrackTile(
                          key: Key('top-track-$index'),
                          services: widget.services,
                          artist: page.name,
                          top: top,
                          tracks: tracks,
                        ),
                    ],
                    if (page.albums.isEmpty) ...[
                      _ArtistHeading(text.catalogAlbums),
                      ListTile(title: Text(text.catalogNoAlbums)),
                    ] else
                      for (final (title, key, albums) in albumRows)
                        if (albums.isNotEmpty) ...[
                          _ArtistHeading(
                            title,
                            action: albums.length > 3
                                ? IconButton(
                                    key: Key('albums-more-$key'),
                                    tooltip: title == text.catalogAlbums
                                        ? text.catalogAllAlbums
                                        : title,
                                    icon: const Icon(
                                      Icons.chevron_right,
                                      size: 20,
                                      color: ApertonoColors.textSecondary,
                                    ),
                                    onPressed: () => open(
                                      context,
                                      ArtistAlbumsScreen(
                                        services: widget.services,
                                        title: title,
                                        artist: page.name,
                                        albums: albums,
                                      ),
                                    ),
                                  )
                                : null,
                          ),
                          SizedBox(
                            height:
                                132 +
                                8 +
                                MediaQuery.textScalerOf(context).scale(44),
                            child: ListView.separated(
                              key: Key(key),
                              scrollDirection: Axis.horizontal,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              itemCount: albums.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(width: 12),
                              itemBuilder: (context, index) => SizedBox(
                                width: 132,
                                child: _AlbumTile(
                                  services: widget.services,
                                  album: albums[index],
                                  artist: page.name,
                                  coverSize: 132,
                                ),
                              ),
                            ),
                          ),
                        ],
                    if (page.similar.isNotEmpty) ...[
                      _ArtistHeading(text.catalogSimilarArtists),
                      SizedBox(
                        height:
                            80 + 6 + MediaQuery.textScalerOf(context).scale(20),
                        child: ListView.separated(
                          key: const Key('artist-similar'),
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          itemCount: page.similar.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 12),
                          itemBuilder: (context, index) {
                            final other = page.similar[index];
                            return InkWell(
                              key: ValueKey('artist-row-${other.name}'),
                              onTap: () => open(
                                context,
                                ArtistScreen(
                                  services: widget.services,
                                  name: other.name,
                                ),
                              ),
                              child: SizedBox(
                                width: 88,
                                child: Column(
                                  children: [
                                    ArtistAvatar(
                                      name: other.name,
                                      photo: other.photo,
                                      server: widget.services.server,
                                      size: 80,
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      other.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                    KnownAs(name: page.name, aliases: page.aliases),
                    if (page.bio case final bio?) ...[
                      _ArtistHeading(text.catalogAboutArtist),
                      _ExpandableBio(bio),
                    ],
                    // At page end: corner icon covered "All albums" arrow
                    // that scrolled to the top.
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 16, 8, 24),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          key: const Key('artist-problem'),
                          icon: const Icon(Icons.outlined_flag),
                          label: Text(text.problemTitle),
                          onPressed: () => showProblemSheet(
                            context,
                            widget.services.server,
                            place: ProblemPlace.artist,
                            artist: widget.name,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          Positioned(
            left: 16,
            top: MediaQuery.paddingOf(context).top + 8,
            child: ClipOval(
              key: const Key('artist-back'),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                child: ColoredBox(
                  color: ApertonoColors.scrim.withValues(alpha: 0.35),
                  child: BackButton(
                    color: ApertonoColors.textPrimary,
                    style: IconButton.styleFrom(
                      fixedSize: const Size.square(40),
                      minimumSize: const Size.square(40),
                      padding: EdgeInsets.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Follow" / "Following" next to "Play" (FT-580): state is user's follow
/// on server (`GET /v1/news/follows`), tap toggles it
/// (`POST /v1/news/follows` or `/v1/news/follows/remove`).
///
/// Follow state unknown — hide button: page works without it, and guessing
/// whether user is subscribed is disallowed.
class _ArtistFollow extends StatefulWidget {
  const _ArtistFollow({required this.services, required this.artistId});

  final Services services;
  final String artistId;

  @override
  State<_ArtistFollow> createState() => _ArtistFollowState();
}

class _ArtistFollowState extends State<_ArtistFollow> {
  /// `null` — unknown yet: follow state not received from server.
  bool? _followed;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final follows = await widget.services.server.newsFollows();
      if (mounted) {
        setState(() => _followed = follows.contains(widget.artistId));
      }
    } on ServerFailed {
      // Follow status unavailable — do not show button.
    }
  }

  Future<void> _toggle() async {
    final followed = _followed;
    if (followed == null) return;
    setState(() => _followed = !followed);
    try {
      if (followed) {
        await widget.services.server.unfollowArtist(widget.artistId);
      } else {
        await widget.services.server.followArtist(widget.artistId);
      }
    } on ServerFailed {
      // Server rejected — revert button to previous state.
      if (mounted) setState(() => _followed = followed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final followed = _followed;
    if (followed == null) return const SizedBox.shrink();
    final text = l10n(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ApertonoColors.surface,
        borderRadius: BorderRadius.circular(ApertonoRadii.pill),
        border: Border.all(color: ApertonoColors.border),
      ),
      child: SizedBox(
        height: 52,
        child: TextButton(
          key: const Key('artist-follow'),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: const StadiumBorder(),
          ),
          onPressed: () => unawaited(_toggle()),
          child: Text(
            followed ? text.catalogFollowing : text.catalogFollow,
            style: const TextStyle(
              fontSize: 16,
              height: 20 / 16,
              fontWeight: FontWeight.w600,
              color: ApertonoColors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}

/// Artist photo from Wikimedia Commons and caption "photo: author, license".
///
/// Attribution is not decorative: Wikimedia Commons images require author
/// attribution under their licenses. Hence it sits next to photo, not in
/// a separate "About" screen, and server never serves photo without it.
class _Photo extends StatelessWidget {
  const _Photo({
    required this.services,
    required this.path,
    required this.artist,
    required this.credit,
  });

  final Services services;
  final String path;
  final String artist;
  final String credit;

  @override
  Widget build(BuildContext context) {
    // A square of the screen width (FT-845): a 250-high strip cut faces off portrait photos.
    final side = MediaQuery.sizeOf(context).width.clamp(0.0, 400.0);
    return SizedBox(
      key: const Key('artist-hero'),
      height: side,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.network(
            services.server.url(path),
            headers: services.server.headers,
            fit: BoxFit.cover,
            alignment: const Alignment(0, -0.6),
            errorBuilder: (_, _, _) => ArtistSquare(artist, size: side),
          ),
          DecoratedBox(
            key: const Key('artist-hero-shade'),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  ApertonoColors.background.withValues(alpha: 0.1),
                  ApertonoColors.background,
                ],
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 10,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  artist,
                  key: const Key('artist-name'),
                  style: _artistNameStyle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  l10n(context).catalogPhotoCredit(credit),
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    color: ApertonoColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AlbumTile extends StatelessWidget {
  const _AlbumTile({
    required this.services,
    required this.album,
    required this.artist,
    required this.coverSize,
  });

  final Services services;
  final Album album;
  final String artist;
  final double coverSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pale = album.playable ? null : paleColor(context);
    final details = [
      if (album.year case final year?) '$year',
      if (album.ep) 'EP',
    ];
    return InkWell(
      key: ValueKey('album-tile-${album.id}'),
      onTap: () => open(
        context,
        AlbumScreen(
          services: services,
          id: album.id,
          title: album.title,
          editions: album.editions,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(ApertonoRadii.album),
            child: Cover(
              server: services.server,
              path: album.cover,
              artist: artist,
              size: coverSize,
              radius: ApertonoRadii.album,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            album.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(
              color: pale ?? theme.colorScheme.onSurface,
            ),
          ),
          if (details.isNotEmpty)
            Text(
              details.join(' · '),
              style: theme.textTheme.bodySmall?.copyWith(
                color: pale ?? theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

class _ExpandableBio extends StatefulWidget {
  const _ExpandableBio(this.bio);

  final String bio;

  @override
  State<_ExpandableBio> createState() => _ExpandableBioState();
}

class _ExpandableBioState extends State<_ExpandableBio> {
  var _open = false;

  @override
  Widget build(BuildContext context) {
    final preview = bioPreview(widget.bio);
    final canOpen = preview != widget.bio.trim();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_open || !canOpen ? widget.bio : preview),
          if (canOpen)
            TextButton(
              onPressed: () => setState(() => _open = !_open),
              child: Text(
                _open
                    ? l10n(context).catalogCollapse
                    : l10n(context).catalogExpand,
              ),
            ),
        ],
      ),
    );
  }
}

class _ArtistHeading extends StatelessWidget {
  const _ArtistHeading(this.title, {this.action});

  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(child: Heading(title)),
          if (action case final action?)
            Padding(padding: const EdgeInsets.only(right: 8), child: action),
        ],
      ),
    );
  }
}

/// Album: tracks in order; "Play album" — queue G of playable tracks.
class AlbumScreen extends StatelessWidget {
  const AlbumScreen({
    super.key,
    required this.services,
    required this.id,
    required this.title,
    this.editions = const [],
  });

  final Services services;
  final String id;
  final String title;

  /// Other editions of the same title and year (FT-552). Empty means no rows.
  final List<AlbumEdition> editions;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            key: const Key('album-problem'),
            tooltip: l10n(context).problemTitle,
            icon: const Icon(Icons.outlined_flag),
            onPressed: () => showProblemSheet(
              context,
              services.server,
              place: ProblemPlace.album,
              albumId: id,
            ),
          ),
        ],
      ),
      body: Loaded<AlbumPage>(
        services: services,
        server: services.server,
        screen: 'album',
        load: () => services.server.album(id),
        notFound: l10n(context).catalogAlbumNotFound,
        builder: (context, page, _) {
          final text = l10n(context);
          final album = page.album;
          final cover = album.cover;
          final tracks = cover == null
              ? page.tracks
              : [for (final track in page.tracks) track.withArtwork(cover)];
          return Tracks(
            services: services,
            tracks: tracks,
            numbered: true,
            header: [
              ListTile(
                leading: Cover(
                  server: services.server,
                  path: album.cover,
                  artist: page.artist,
                  size: 64,
                  radius: ApertonoRadii.album,
                ),
                title: Text(album.title),
                subtitle: Text(
                  [
                    page.artist,
                    if (album.year case final year?) '$year',
                  ].join(' · '),
                ),
                textColor: album.playable ? null : paleColor(context),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 40),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: Text(text.catalogPlayAlbum),
                      onPressed: playAll(services, tracks),
                    ),
                    if (services.downloads case final downloads?) ...[
                      const SizedBox(width: 8),
                      Flexible(
                        child: DownloadAllButton(
                          key: const Key('download-album'),
                          downloads: downloads,
                          tracks: tracks,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (editions.isNotEmpty) ...[
                Heading(text.catalogOtherEditions),
                for (final edition in editions)
                  ListTile(
                    key: ValueKey('edition-${edition.id}'),
                    title: Text(editionLine(edition, text)),
                    onTap: () => open(
                      context,
                      AlbumScreen(
                        services: services,
                        id: edition.id,
                        title: edition.title,
                      ),
                    ),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _TopTrackTile extends StatelessWidget {
  const _TopTrackTile({
    super.key,
    required this.services,
    required this.artist,
    required this.top,
    required this.tracks,
  });

  final Services services;
  final String artist;
  final TopTrack top;
  final List<Track> tracks;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        final song = top.track;
        if (song == null) {
          openSearch(context, services, query: '$artist ${top.title}');
          return;
        }
        final index = tracks.indexWhere((item) => item.id == song.id);
        final (queue, start) = queueFrom(tracks, index < 0 ? 0 : index);
        services.play(queue, start);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(
          children: [
            Cover(
              server: services.server,
              path: top.track == null ? null : coverPath(top.track!),
              artist: artist,
              size: 56,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                top.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: ApertonoText.trackTitle.copyWith(
                  color: top.playable
                      ? ApertonoColors.textPrimary
                      : paleColor(context),
                ),
              ),
            ),
            if (top.track case final song?)
              if (song.durationMs > 0) ...[
                const SizedBox(width: 12),
                Text(
                  formatDuration(song.durationMs),
                  style: ApertonoText.time.copyWith(
                    fontSize: 13,
                    color: ApertonoColors.textSecondary,
                  ),
                ),
              ],
          ],
        ),
      ),
    );
  }
}

/// All popular tracks of artist (FT-553, P-A72).
class ArtistSongsScreen extends StatefulWidget {
  const ArtistSongsScreen({
    super.key,
    required this.services,
    required this.name,
  });

  final Services services;
  final String name;

  @override
  State<ArtistSongsScreen> createState() => _ArtistSongsScreenState();
}

class _ArtistSongsScreenState extends State<ArtistSongsScreen> {
  var _prepared = const <String>[];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(l10n(context).catalogPopular)),
      body: Loaded<List<TopTrack>>(
        services: widget.services,
        server: widget.services.server,
        screen: 'artist_songs',
        load: () => widget.services.server.artistSongs(widget.name),
        notFound: l10n(context).catalogArtistNotFoundSongs,
        builder: (context, topTracks, _) {
          final tracks = topTracks
              .map((t) => t.track)
              .whereType<Track>()
              .toList();
          _prepared = warmTracks(widget.services, tracks, already: _prepared);
          return ListView.builder(
            itemCount: topTracks.length,
            itemBuilder: (context, index) {
              final top = topTracks[index];
              return _TopTrackTile(
                services: widget.services,
                artist: widget.name,
                top: top,
                tracks: tracks,
              );
            },
          );
        },
      ),
    );
  }
}

/// All albums / EPs / compilations of artist in grid (FT-566, P-A82 item 2).
class ArtistAlbumsScreen extends StatelessWidget {
  const ArtistAlbumsScreen({
    super.key,
    required this.services,
    required this.title,
    required this.artist,
    required this.albums,
  });

  final Services services;
  final String title;
  final String artist;
  final List<Album> albums;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: LayoutBuilder(
        builder: (context, constraints) {
          const padding = 16.0;
          const spacing = 12.0;
          final width = constraints.maxWidth;
          final crossAxisCount = width >= 600 ? (width / 180).floor() : 2;
          final itemWidth =
              (width - padding * 2 - spacing * (crossAxisCount - 1)) /
              crossAxisCount;
          final itemHeight =
              itemWidth + 8 + MediaQuery.textScalerOf(context).scale(44);
          return GridView.builder(
            padding: const EdgeInsets.all(padding),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              mainAxisSpacing: 16,
              crossAxisSpacing: spacing,
              mainAxisExtent: itemHeight,
            ),
            itemCount: albums.length,
            itemBuilder: (context, index) => _AlbumTile(
              services: services,
              album: albums[index],
              artist: artist,
              coverSize: itemWidth,
            ),
          );
        },
      ),
    );
  }
}
