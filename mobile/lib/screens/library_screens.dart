import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../device_library.dart';
import '../device_media.dart';
import '../history_control.dart';
import '../l10n/l10n.dart';
import '../models/track.dart';
import '../offline/downloads.dart';
import '../server_api.dart';
import '../server_ports.dart';
import '../theme.dart';
import 'device_library_view.dart';
import 'history_controls.dart';
import 'import_screen.dart';
import 'rated_screen.dart';
import 'trash_reveal.dart';
import 'parts.dart';

/// My Music: favorites, history, user playlists. No curated selections from service.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    required this.services,
    this.active,
    this.account,
    this.onDownloads,
  });

  final Services services;

  final ValueListenable<bool>? active;

  /// Account right of header; no login means no button.
  final Widget? account;
  final VoidCallback? onDownloads;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen>
    with LibraryRefresh<LibraryScreen> {
  List<Track> _favorites = const [];
  List<PlaylistInfo> _playlists = const [];
  var _ready = false;

  Services get _services => widget.services;
  DeviceMediaPort? get _deviceMedia => _services.deviceMedia;

  @override
  ServerApi get libraryServer => _services.server;

  @override
  ValueListenable<bool>? get libraryActive => widget.active;

  @override
  RouteObserver<ModalRoute<dynamic>>? get libraryRoutes => _services.routes;

  @override
  void reloadLibrary() => unawaited(_load());

  Future<void> _load() async {
    final server = _services.server;
    var favorites = const <Track>[];
    var playlists = const <PlaylistInfo>[];
    // Two requests in parallel rather than sequential: over VPN each takes
    // seconds, and sequentially screen waited for their sum.
    await Future.wait([
      () async {
        try {
          favorites = await server.favorites();
        } catch (_) {}
      }(),
      () async {
        try {
          playlists = await server.playlists();
        } catch (_) {}
      }(),
    ]);
    if (!mounted) {
      return;
    }
    setState(() {
      _favorites = favorites;
      _playlists = playlists;
      _ready = true;
    });
  }

  Future<void> _openThenReload(Widget page) async {
    await open(context, page);
    // Without observer (standalone screen in tests), watch return ourselves.
    if (mounted && libraryRoutes == null) {
      unawaited(_load());
    }
  }

  void _openDevice(DeviceMediaPort deviceMedia) => unawaited(
    _openThenReload(
      DeviceLibraryScreen(
        deviceMedia: deviceMedia,
        onPlay: _services.playDevice ?? (_, _) {},
        onOpenSettings: () {
          if (deviceMedia is ChannelDeviceMedia) {
            unawaited(deviceMedia.openSettings());
          }
        },
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final text = l10n(context);
    final scaler = MediaQuery.textScalerOf(context);
    final ratings = _services.ratings;
    final deviceMedia = _deviceMedia;
    final onDownloads = widget.onDownloads;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: LayoutBuilder(
          builder: (context, box) {
            // Tile heights derived from available height, as in Discover: on standard
            // phone everything fits without scroll, on small screen or with large
            // font tiles are at least content height and screen scrolls.
            // Tile half-height: padding 12+12, icon 24, gap 8, title, 2, subtitle.
            final gridMin = scaler.scale(19 + 16) + 12 + 24 + 8 + 2 + 12;
            final wideMin = scaler.scale(22 + 16) + 24 + 8 + 2 + 20;
            const rowHeight = 48.0;
            final section = scaler.scale(22) + 18; // section header
            final fixed =
                12 + // top padding
                48 + // header and account
                12 +
                section * (ratings == null ? 1 : 2) +
                12 + // grid gap
                (ratings == null ? 0 : 2 * rowHeight + 1) +
                12 + // gap before the import
                math.max(48, scaler.scale(19 + 32) + 10); // import
            final free = box.maxHeight - fixed;
            // Grid at least content height; Favorites at least 1.1x grid tile,
            // remaining space goes to them, no gap at the bottom.
            final grid = math.max(gridMin, (free / 3.3).floorToDouble());
            final wide = math.max(
              wideMin,
              math.max((grid * 1.1).ceilToDouble(), free - 2 * grid),
            );
            final tileHeight = grid;
            final favorites = _favorites.take(3).toList();
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: 48,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            text.libraryTitle,
                            key: const Key('library-title'),
                            style: ApertonoText.screenTitle,
                          ),
                        ),
                        Transform.translate(
                          offset: const Offset(12, 0),
                          child: widget.account,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _FavoritesTile(
                    height: wide,
                    title: text.libraryFavorites,
                    subtitle: text.libraryTracksCount(_favorites.length),
                    tracks: favorites,
                    server: _services.server,
                    onTap: () => unawaited(
                      _openThenReload(FavoritesScreen(services: _services)),
                    ),
                  ),
                  _Section(text.libraryMediaSection),
                  _GridRow(
                    height: tileHeight,
                    left: _GridTile(
                      tileKey: const Key('library-playlists'),
                      icon: Icons.playlist_play,
                      title: text.libraryPlaylists,
                      subtitle: text.libraryPlaylistsCount(_playlists.length),
                      onTap: () => unawaited(
                        _openThenReload(PlaylistsScreen(services: _services)),
                      ),
                    ),
                    right: _GridTile(
                      tileKey: const Key('library-history'),
                      icon: Icons.schedule,
                      title: text.libraryHistory,
                      subtitle: text.libraryHistorySubtitle,
                      onTap: () => unawaited(
                        _openThenReload(HistoryScreen(services: _services)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _GridRow(
                    height: tileHeight,
                    left: _GridTile(
                      tileKey: const Key('library-downloads'),
                      icon: Icons.download,
                      title: text.libraryDownloads,
                      subtitle: text.libraryDownloadsSubtitle,
                      onTap: onDownloads,
                    ),
                    right: _GridTile(
                      tileKey: const Key('library-device'),
                      icon: Icons.phone_android,
                      title: text.libraryDeviceTile,
                      subtitle: text.libraryDeviceSubtitle,
                      onTap: deviceMedia == null
                          ? null
                          : () => _openDevice(deviceMedia),
                    ),
                  ),
                  if (ratings != null) ...[
                    _Section(text.libraryRatingsSection),
                    _Card(
                      child: Column(
                        children: [
                          _RatingRow(
                            tileKey: const Key('library-rated'),
                            icon: Icons.star_border,
                            title: text.libraryRated,
                            height: rowHeight,
                            onTap: () => unawaited(
                              _openThenReload(
                                RatedScreen(
                                  services: _services,
                                  store: ratings,
                                ),
                              ),
                            ),
                          ),
                          const Divider(
                            height: 1,
                            thickness: 1,
                            indent: 16,
                            endIndent: 16,
                            color: ApertonoColors.border,
                          ),
                          _RatingRow(
                            tileKey: const Key('library-disliked'),
                            icon: Icons.thumb_down_off_alt,
                            title: text.ratingDislike,
                            height: rowHeight,
                            onTap: () => unawaited(
                              _openThenReload(
                                RatedScreen(
                                  services: _services,
                                  store: ratings,
                                  disliked: true,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  _Card(
                    key: const Key('library-import'),
                    onTap: () => unawaited(
                      _openThenReload(ImportScreen(services: _services)),
                    ),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 4,
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.file_upload_outlined,
                              size: 24,
                              color: ApertonoColors.textPrimary,
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(text.libraryImport, style: _titleStyle),
                                  const SizedBox(height: 2),
                                  Text(
                                    text.libraryImportSubtitle,
                                    style: ApertonoText.trackArtist,
                                  ),
                                ],
                              ),
                            ),
                            const _Chevron(),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (!_ready)
                    const Padding(
                      padding: EdgeInsets.only(top: 24),
                      child: Center(child: CircularProgressIndicator()),
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

final _titleStyle = ApertonoText.trackTitle.copyWith(
  fontWeight: FontWeight.w500,
  color: ApertonoColors.textPrimary,
);

class _Chevron extends StatelessWidget {
  const _Chevron();

  @override
  Widget build(BuildContext context) => const Icon(
    Icons.chevron_right,
    size: 20,
    color: ApertonoColors.textSecondary,
  );
}

class _Section extends StatelessWidget {
  const _Section(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 10, bottom: 8),
    child: Text(
      title,
      style: ApertonoText.sectionTitle.copyWith(
        fontWeight: FontWeight.w600,
        color: ApertonoColors.textPrimary,
      ),
    ),
  );
}

/// Card border in app styling; [onTap] == null creates non-clickable card.
class _Card extends StatelessWidget {
  const _Card({super.key, required this.child, this.onTap, this.gradient});

  final Widget child;
  final VoidCallback? onTap;
  final Gradient? gradient;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(ApertonoRadii.row);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ApertonoColors.surface,
        gradient: gradient,
        borderRadius: radius,
        border: Border.all(color: ApertonoColors.border),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        child: onTap == null
            ? child
            : InkWell(borderRadius: radius, onTap: onTap, child: child),
      ),
    );
  }
}

/// Two grid tiles of equal height; expand by content, no less than [height].
class _GridRow extends StatelessWidget {
  const _GridRow({
    required this.height,
    required this.left,
    required this.right,
  });

  final double height;
  final Widget left;
  final Widget right;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: BoxConstraints(minHeight: height),
    child: IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: left),
          const SizedBox(width: 12),
          Expanded(child: right),
        ],
      ),
    ),
  );
}

/// Grid tile: icon, title, and gray subtitle in one group on the left,
/// arrow centered on the right.
/// [onTap] == null means unavailable: content dimmed, key outside.
class _GridTile extends StatelessWidget {
  const _GridTile({
    required this.tileKey,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final Key tileKey;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    // Icon, title, and subtitle form one tight group vertically centered;
    // arrow is vertically centered on the right, like rows below.
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 24, color: ApertonoColors.textPrimary),
                const SizedBox(height: 8),
                Text(
                  title,
                  style: _titleStyle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: ApertonoText.trackArtist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          const _Chevron(),
        ],
      ),
    );
    return KeyedSubtree(
      key: tileKey,
      child: _Card(
        onTap: onTap,
        child: onTap == null ? Opacity(opacity: 0.4, child: content) : content,
      ),
    );
  }
}

/// Wide tile "Favorite Songs": heart, title, track count, and fan
/// of three covers on the right. Background is a subtle accent gradient.
class _FavoritesTile extends StatelessWidget {
  const _FavoritesTile({
    required this.height,
    required this.title,
    required this.subtitle,
    required this.tracks,
    required this.server,
    required this.onTap,
  });

  final double height;
  final String title;
  final String subtitle;
  final List<Track> tracks;
  final ServerApi server;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cover = math.min(84.0, height - 20);
    final step = cover * 0.36;
    const tilt = [-0.10, 0.0, 0.09];
    final fan = tracks.isEmpty
        ? null
        : SizedBox(
            width: cover + (tracks.length - 1) * step,
            height: cover,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                for (var i = tracks.length - 1; i >= 0; i--)
                  Positioned(
                    left: i * step,
                    child: Transform.rotate(
                      angle: tilt[i],
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(
                            ApertonoRadii.cover,
                          ),
                          boxShadow: const [
                            BoxShadow(
                              color: ApertonoColors.shadow,
                              blurRadius: 8,
                            ),
                          ],
                        ),
                        child: Cover(
                          server: server,
                          path: coverPath(tracks[i]),
                          artist: tracks[i].artist,
                          size: cover,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
    return KeyedSubtree(
      key: const Key('library-favorites'),
      child: _Card(
        onTap: onTap,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(
              ApertonoColors.accent.withValues(alpha: 0.16),
              ApertonoColors.surface,
            ),
            ApertonoColors.surface,
          ],
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: height),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.favorite_border,
                        size: 24,
                        color: ApertonoColors.textPrimary,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        title,
                        style: ApertonoText.sectionTitle.copyWith(
                          fontWeight: FontWeight.w600,
                          color: ApertonoColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(subtitle, style: ApertonoText.trackArtist),
                    ],
                  ),
                ),
                if (fan != null) ...[const SizedBox(width: 8), fan],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RatingRow extends StatelessWidget {
  const _RatingRow({
    required this.tileKey,
    required this.icon,
    required this.title,
    required this.height,
    required this.onTap,
  });

  final Key tileKey;
  final IconData icon;
  final String title;
  final double height;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    key: tileKey,
    onTap: onTap,
    child: ConstrainedBox(
      constraints: BoxConstraints(minHeight: height),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Icon(icon, size: 24, color: ApertonoColors.textPrimary),
            const SizedBox(width: 16),
            Expanded(child: Text(title, style: _titleStyle)),
            const _Chevron(),
          ],
        ),
      ),
    ),
  );
}

/// Device library screen (FT-783): opened from "My Music",
/// loads list on enter, not placed in IndexedStack.
class DeviceLibraryScreen extends StatefulWidget {
  const DeviceLibraryScreen({
    super.key,
    required this.deviceMedia,
    required this.onPlay,
    required this.onOpenSettings,
  });

  final DeviceMediaPort deviceMedia;
  final void Function(List<DeviceSong> queue, int index) onPlay;
  final VoidCallback onOpenSettings;

  @override
  State<DeviceLibraryScreen> createState() => _DeviceLibraryScreenState();
}

class _DeviceLibraryScreenState extends State<DeviceLibraryScreen> {
  late final DeviceLibrary _library = DeviceLibrary(widget.deviceMedia);

  @override
  void initState() {
    super.initState();
    unawaited(_library.open());
  }

  @override
  void dispose() {
    _library.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = l10n(context);
    return Scaffold(
      appBar: AppBar(title: Text(text.libraryDevice)),
      body: DeviceLibraryView(
        library: _library,
        onPlay: widget.onPlay,
        onOpenSettings: widget.onOpenSettings,
      ),
    );
  }
}

class FavoritesScreen extends StatelessWidget {
  const FavoritesScreen({super.key, required this.services});

  final Services services;

  @override
  Widget build(BuildContext context) {
    final text = l10n(context);
    return Scaffold(
      appBar: AppBar(title: Text(text.libraryFavorites)),
      body: Loaded<List<Track>>(
        services: services,
        server: services.server,
        screen: 'favorites',
        load: services.server.favorites,
        // Heart toggled off removes track from list, so it reloads.
        builder: (context, tracks, reload) => tracks.isEmpty
            ? Message(text.libraryFavoritesEmpty)
            : Tracks(
                services: services,
                tracks: tracks,
                onChanged: reload,
                header: [
                  if (services.downloads case final downloads?)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: DownloadAllButton(
                          key: const Key('download-favorites'),
                          downloads: downloads,
                          tracks: tracks,
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

/// "19.09 18:04" — when track was played, device local time.
String when(DateTime at) {
  final local = at.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(local.day)}.${two(local.month)} '
      '${two(local.hour)}:${two(local.minute)}';
}

/// History: played tracks, newest on top. Server records listening history.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, required this.services});

  final Services services;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  late final _hearts = Hearts(widget.services.server);

  /// Remove item, clear all, pause history recording (FT-630, FT-634).
  late final _control = HistoryControl(
    ServerHistoryPort(widget.services.server),
  )..load().ignore();

  /// After "Clear", list reloads from the first page.
  var _round = 0;

  @override
  void dispose() {
    _control.dispose();
    _hearts.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = l10n(context);
    final services = widget.services;
    return Scaffold(
      appBar: AppBar(title: Text(text.libraryHistory)),
      body: Column(
        children: [
          HistoryPauseTile(control: _control),
          HistoryClearButton(
            control: _control,
            onCleared: () => setState(() => _round++),
          ),
          Expanded(
            child: PagedList<Listen>(
              key: ValueKey(_round),
              server: services.server,
              screen: 'history',
              load: (offset) => services.server.history(offset: offset),
              empty: text.libraryHistoryEmpty,
              onItems: (items) =>
                  _hearts.show([for (final item in items) item.track]).ignore(),
              itemBuilder: (context, items, index) {
                final listen = items[index];
                return ListenableBuilder(
                  listenable: _control,
                  builder: (context, _) {
                    if (_control.isHidden(listen.track.id, listen.at)) {
                      return const SizedBox.shrink();
                    }
                    return TrashReveal(
                      key: ValueKey('${listen.track.id} ${listen.at}'),
                      label: text.historyRemove,
                      onRemove: () =>
                          _control.removeLater(listen.track.id, listen.at),
                      child: TrackTile(
                        track: listen.track,
                        services: services,
                        hearts: _hearts,
                        swipe: false,
                        subtitle: '${listen.track.artist} · ${when(listen.at)}',
                        onTap: () {
                          final tracks = [for (final item in items) item.track];
                          final (queue, start) = queueFrom(tracks, index);
                          services.play(queue, start);
                        },
                      ),
                    );
                  },
                );
              },
            ),
          ),
          HistoryUndoBar(control: _control),
        ],
      ),
    );
  }
}

class PlaylistsScreen extends StatelessWidget {
  const PlaylistsScreen({super.key, required this.services});

  final Services services;

  @override
  Widget build(BuildContext context) {
    final text = l10n(context);
    return Scaffold(
      appBar: AppBar(title: Text(text.libraryPlaylists)),
      body: Loaded<List<PlaylistInfo>>(
        server: services.server,
        screen: 'playlists',
        load: services.server.playlists,
        builder: (context, playlists, reload) => ListView(
          children: [
            ListTile(
              leading: const Icon(Icons.add),
              title: Text(text.libraryNewPlaylist),
              onTap: () async {
                if (await createPlaylist(context, services) != null) {
                  reload();
                }
              },
            ),
            for (final playlist in playlists)
              ListTile(
                leading: const Icon(Icons.queue_music),
                title: Text(playlist.name),
                trailing: Text('${playlist.tracks}'),
                onTap: () async {
                  await open(
                    context,
                    PlaylistScreen(
                      services: services,
                      id: playlist.id,
                      name: playlist.name,
                    ),
                  );
                  // Title, content, or playlist itself could have changed.
                  reload();
                },
              ),
          ],
        ),
      ),
    );
  }
}

/// User playlist: play, reorder (long press), remove track,
/// rename, delete.
class PlaylistScreen extends StatefulWidget {
  const PlaylistScreen({
    super.key,
    required this.services,
    required this.id,
    required this.name,
  });

  final Services services;
  final String id;
  final String name;

  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends State<PlaylistScreen> {
  late var _name = widget.name;

  ServerApi get _server => widget.services.server;

  /// Order is sent as full list. 409 means playlist changed while screen
  /// was open: reload and display server state.
  Future<void> _order(List<String> trackIds, VoidCallback reload) async {
    final text = l10n(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _server.orderPlaylist(widget.id, trackIds);
    } on ServerFailed catch (failed) {
      reload();
      say(
        messenger,
        failureText(failed.reason, notFound: text.libraryPlaylistNotFound),
      );
    }
  }

  Future<void> _rename() async {
    final text = l10n(context);
    final messenger = ScaffoldMessenger.of(context);
    final name = await askName(
      context,
      title: text.libraryRename,
      initial: _name,
    );
    if (name == null) {
      return;
    }
    try {
      await _server.renamePlaylist(widget.id, name);
      if (mounted) {
        setState(() => _name = name);
      }
    } on ServerFailed catch (failed) {
      say(
        messenger,
        failureText(failed.reason, notFound: text.libraryPlaylistNotFound),
      );
    }
  }

  Future<void> _delete() async {
    final text = l10n(context);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(text.libraryDeletePlaylistConfirm(_name)),
        content: Text(text.libraryDeletePlaylistMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(text.libraryCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(text.libraryDelete),
          ),
        ],
      ),
    );
    if (sure != true) {
      return;
    }
    try {
      await _server.deletePlaylist(widget.id);
      navigator.pop();
    } on ServerFailed catch (failed) {
      say(
        messenger,
        failureText(failed.reason, notFound: text.libraryPlaylistNotFound),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = l10n(context);
    final services = widget.services;
    return Scaffold(
      appBar: AppBar(
        title: Text(_name),
        actions: [
          IconButton(
            tooltip: text.libraryRename,
            icon: const Icon(Icons.edit_outlined),
            onPressed: _rename,
          ),
          IconButton(
            tooltip: text.libraryDeletePlaylist,
            icon: const Icon(Icons.delete_outline),
            onPressed: _delete,
          ),
        ],
      ),
      body: Loaded<Playlist>(
        services: services,
        server: _server,
        screen: 'playlist',
        load: () async {
          final playlist = await _server.playlist(widget.id);
          unawaited(
            services.downloads?.playlistLoaded(widget.id, playlist.tracks),
          );
          return playlist;
        },
        notFound: text.libraryPlaylistNotFound,
        builder: (context, playlist, reload) => Tracks(
          services: services,
          tracks: playlist.tracks,
          playlist: widget.id,
          onChanged: reload,
          onReorder: (trackIds) => _order(trackIds, reload),
          header: [
            if (playlist.tracks.isEmpty)
              Message(text.libraryPlaylistEmpty)
            else
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    FilledButton.icon(
                      icon: const Icon(Icons.play_arrow),
                      label: Text(text.libraryPlayPlaylist),
                      onPressed: playAll(services, playlist.tracks),
                    ),
                    if (services.downloads case final downloads?) ...[
                      const SizedBox(width: 8),
                      Flexible(
                        child: DownloadAllButton(
                          key: const Key('download-playlist'),
                          downloads: downloads,
                          tracks: playlist.tracks,
                          playlist: widget.id,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
