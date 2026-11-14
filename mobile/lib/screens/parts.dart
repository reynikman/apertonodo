import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../catalog.dart';
import '../device_library.dart';
import '../error_reports.dart';
import '../l10n/l10n.dart';
import '../models/track.dart';
import '../offline/cover_store.dart';
import '../offline/download_queue.dart' show DownloadStatus;
import '../offline/downloads.dart';
import '../podcast_downloads.dart';

export '../offline/cover_store.dart' show CoverFiles;
import '../loudness.dart';
import '../playback.dart';
import '../playback_speed.dart';
import '../player.dart';
import '../playlist_duplicates.dart';
import '../prefetch_policy.dart';
import '../quality_prefs.dart';
import '../lossless_once.dart';
import '../track_formats.dart';
import '../ratings.dart';
import '../recent_queries.dart';
import '../server_api.dart';
import 'problem_sheet.dart';
import '../sleep_timer.dart';
import '../theme.dart';
import 'catalog_screens.dart' show AlbumScreen, openSearch;
import 'downloads_screen.dart';
import 'swipe_row.dart';

/// What menu screens need: server, search, and the player queue G.
class Services {
  const Services({
    required this.server,
    required this.search,
    required this.play,
    required this.prepare,
    this.suggest,
    this.openArtist,
    this.openPodcast,
    this.openPage,
    this.recent,
    this.routes,
    this.downloads,
    this.playNext,
    this.enqueue,
    this.openLink,
    this.podcasts,
    this.books,
    this.speed,
    this.sleepTimer,
    this.ratings,
    this.quality,
    this.prefetch,
    this.formats,
    this.losslessOnce,
    this.podcastDownloads,
    this.loudness,
    this.deviceMedia,
    this.playDevice,
  });

  final ServerApi server;
  final Future<SearchResult> Function(String query) search;

  /// Play list starting from track [index] using queue G (`Player.playQueue`). Screens
  /// do not have their own queue.
  final void Function(List<Track> tracks, int index) play;

  /// Prepare a track about to be pressed (`Player.prepare`, Phase D).
  final void Function(Track track) prepare;

  /// Search suggestions while typing. If null, the screen searches only on "Search".
  final Future<List<String>> Function(String query)? suggest;

  /// Open the artist page from search results.
  final ValueChanged<String>? openArtist;

  /// Open the podcast of an episode from its player (FT-865).
  final ValueChanged<Track>? openPodcast;

  /// Open screen inside shell — with nav bar and mini-player; from player,
  /// player collapses and returns on "back" (FT-739, FT-743).
  final ValueChanged<Widget>? openPage;

  /// Recent queries. Stored on the device.
  final RecentQueries? recent;

  /// Return to the tab from any screen opened on top of it.
  final RouteObserver<ModalRoute<dynamic>>? routes;

  final DownloadsPort? downloads;

  /// Place the track next in the player queue.
  final ValueChanged<Track>? playNext;

  /// Place the track at the end of the player queue.
  final ValueChanged<Track>? enqueue;

  /// "Podcasts" screen (FT-717). If null, the tile in "Browse" is omitted.
  final WidgetBuilder? podcasts;

  /// "Audiobooks" screen (FT-793). If null, the tile in "Browse" is omitted.
  final Widget Function(BuildContext context)? books;

  /// Episode playback speed on player screen (FT-730). If null, no button.
  final PlaybackSpeed? speed;

  /// Sleep timer in the player menu (FT-619). If null, no menu item.
  final SleepTimer? sleepTimer;

  /// Star ratings and "dislike" (FT-638): a single store per login.
  final RatingsStore? ratings;

  /// Audio quality in player menu (FT-633). If null, no menu item.
  final QualityPrefs? quality;

  /// Prefetching next track (FT-692) — in the same sheet as quality.
  final PrefetchPolicy? prefetch;

  /// File format of each track from Play response — badge in player (FT-633).
  final TrackFormats? formats;

  /// One-time request "this track lossless" (FT-809).
  final LosslessOnce? losslessOnce;

  /// Downloading podcast episodes (FT-710, FT-764).
  final PodcastDownloads? podcastDownloads;

  /// Volume normalization (FT-765).
  final LoudnessGate? loudness;

  /// Open external link — the only exit from news (FT-579).
  /// If null, the "Source" button on the card is hidden.
  final Future<void> Function(Uri uri)? openLink;

  /// Access to audio files on device (FT-783). If null, no section in "My Music".
  final DeviceMediaPort? deviceMedia;

  /// Set queue of tracks from device into player (FT-783).
  final void Function(List<DeviceSong> queue, int index)? playDevice;
}

/// Signal only marks data: queries wait for visible tab and route.
mixin LibraryRefresh<T extends StatefulWidget> on State<T>
    implements RouteAware {
  ServerApi get libraryServer;
  ValueListenable<bool>? get libraryActive;
  RouteObserver<ModalRoute<dynamic>>? get libraryRoutes;
  void reloadLibrary();

  var _libraryStale = true;
  ModalRoute<dynamic>? _libraryRoute;

  @override
  void initState() {
    super.initState();
    libraryServer.libraryRevision.addListener(_markLibraryStale);
    libraryActive?.addListener(_refreshLibrary);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Timer.run(() {
        if (mounted) _refreshLibrary();
      });
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route == _libraryRoute) return;
    libraryRoutes?.unsubscribe(this);
    _libraryRoute = route;
    if (route != null) libraryRoutes?.subscribe(this, route);
  }

  void _markLibraryStale() => _libraryStale = true;

  void _refreshLibrary() {
    if (!mounted ||
        !_libraryStale ||
        libraryActive?.value == false ||
        _libraryRoute?.isCurrent == false) {
      return;
    }
    _libraryStale = false;
    reloadLibrary();
  }

  @override
  void didPopNext() => _refreshLibrary();

  @override
  void didPush() {}

  @override
  void didPushNext() {}

  @override
  void didPop() {}

  @override
  void dispose() {
    libraryRoutes?.unsubscribe(this);
    libraryActive?.removeListener(_refreshLibrary);
    libraryServer.libraryRevision.removeListener(_markLibraryStale);
    super.dispose();
  }
}

/// Queue from list: playable tracks and the pressed one, even if dim.
///
/// Server searches for a dim track for up to 50s and halts queue on it, so
/// "next" skips it. For the pressed one we try: fallback search may find it.
(List<Track>, int) queueFrom(List<Track> tracks, int index) {
  final queue = <Track>[];
  var start = 0;
  for (var i = 0; i < tracks.length; i++) {
    if (i == index) {
      start = queue.length;
    }
    if (tracks[i].playable || i == index) {
      queue.add(tracks[i]);
    }
  }
  return (queue, start);
}

/// Play an entire album or playlist — starting from the first playable track.
VoidCallback? playAll(Services services, List<Track> tracks) {
  final first = tracks.indexWhere((track) => track.playable);
  if (first < 0) {
    return null;
  }
  return () {
    final (queue, start) = queueFrom(tracks, first);
    services.play(queue, start);
  };
}

/// Strings without `BuildContext` — using device language, like `l10n(context)`.
AppLocalizations _deviceText() => lookupAppLocalizations(
  Locale(
    WidgetsBinding.instance.platformDispatcher.locale.languageCode == 'ru'
        ? 'ru'
        : 'en',
  ),
);

String failureText(
  ServerFailure reason, {
  String? notFound,
  AppLocalizations? text,
}) {
  final t = text ?? _deviceText();
  return switch (reason) {
    ServerFailure.unavailable => t.partsServerUnavailable,
    ServerFailure.tooMany => t.partsTooMany,
    ServerFailure.noAnswer => t.partsNoAnswer,
    ServerFailure.noAccess => t.partsNoAccess,
    ServerFailure.notFound => notFound ?? t.partsNotFound,
    ServerFailure.conflict => t.partsConflict,
  };
}

void say(ScaffoldMessengerState messenger, String text) {
  messenger.showSnackBar(SnackBar(content: Text(text)));
}

/// Dim color of unplayable items: the same as disabled state in Material 3.
Color paleColor(BuildContext context) {
  return Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.38);
}

Future<void> open(BuildContext context, Widget screen) {
  return Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => screen));
}

/// Track album: query server and display via [show]; if not found, notify.
/// If response arrives when screen is closed or [still] says "track changed", —
/// neither navigate nor display a message.
Future<void> openTrackAlbum(
  BuildContext context,
  Services services,
  Track track,
  void Function(Widget page) show, {
  bool Function()? still,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final text = l10n(context);
  bool gone() => !context.mounted || (still != null && !still());
  try {
    final album = await services.server.trackAlbum(track.id);
    if (gone()) return;
    if (album == null) {
      say(messenger, text.partsAlbumGone);
      return;
    }
    show(AlbumScreen(services: services, id: album.id, title: album.title));
  } on ServerFailed catch (failed) {
    if (gone()) return;
    say(messenger, failureText(failed.reason, notFound: text.partsAlbumGone));
  }
}

/// Centered text on screen and a "Retry" button if retryable.
class Message extends StatelessWidget {
  const Message(
    this.text, {
    super.key,
    this.onRetry,
    this.report,
    this.server,
    this.onDownloads,
  });

  final String text;
  final VoidCallback? onRetry;
  final ErrorReport? report;
  final ServerApi? server;
  final VoidCallback? onDownloads;

  @override
  Widget build(BuildContext context) {
    final onRetry = this.onRetry;
    final onDownloads = this.onDownloads;
    final t = l10n(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              text,
              textAlign: TextAlign.center,
              style: ApertonoText.trackTitle.copyWith(
                color: ApertonoColors.textPrimary,
              ),
            ),
            if (onDownloads != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: FilledButton.tonal(
                  key: const Key('offline-downloads'),
                  onPressed: onDownloads,
                  child: Text(t.partsDownloads),
                ),
              ),
            if (onRetry != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: FilledButton.tonal(
                  onPressed: onRetry,
                  child: Text(t.partsRetry),
                ),
              ),
            if (report != null && server != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: ReportButton(server: server!, report: report!),
              ),
          ],
        ),
      ),
    );
  }
}

/// A single attempt, with a truthful result instead of a second send button.
class ReportButton extends StatefulWidget {
  const ReportButton({
    super.key,
    required this.server,
    required this.report,
    this.problem,
  });

  final ServerApi server;
  final ErrorReport report;

  /// FT-857: the song that did not play goes to the problem list, where the
  /// lead reads complaints; the error report itself carries no song by design.
  final ProblemReport? problem;

  @override
  State<ReportButton> createState() => _ReportButtonState();
}

class _ReportButtonState extends State<ReportButton> {
  bool _sending = false;
  ReportResult? _result;

  Future<void> _send() async {
    if (_sending || _result != null) return;
    setState(() => _sending = true);
    final problem = widget.problem;
    final (result, _) = await (
      widget.server.sendReport(widget.report),
      problem == null
          ? Future<ProblemResult?>.value()
          : widget.server.sendProblem(problem),
    ).wait;
    if (mounted) setState(() => _result = result);
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final label = switch (result) {
      null => l10n(context).partsReportSend,
      ReportResult.sent => l10n(context).partsReportSent,
      ReportResult.off => l10n(context).partsReportOff,
      ReportResult.failed => l10n(context).partsReportFailed,
    };

    final content = Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: SizedBox(
        width: double.infinity,
        child: Text(
          label,
          style: ApertonoText.trackArtist,
          textAlign: TextAlign.center,
        ),
      ),
    );

    return Material(
      key: const Key('report-plate'),
      color: ApertonoColors.surface,
      clipBehavior: Clip.antiAlias,
      borderRadius: BorderRadius.circular(ApertonoRadii.xLarge),
      child: result == null
          ? InkWell(
              key: const Key('send-report'),
              onTap: _sending ? null : _send,
              child: content,
            )
          : content,
    );
  }
}

/// Server page: spinner while loading, failure reason and
/// "Retry" on error, otherwise the page itself.
class Loaded<T> extends StatefulWidget {
  const Loaded({
    super.key,
    required this.load,
    required this.builder,
    this.notFound,
    this.screen = 'app',
    this.server,
    this.services,
    this.downloads,
    this.play,
  });

  final Future<T> Function() load;
  final Widget Function(BuildContext context, T value, VoidCallback reload)
  builder;

  /// Custom message on 404 for artist, album, playlist.
  /// `null` uses default "Not found" from localized strings.
  final String? notFound;
  final String screen;
  final ServerApi? server;
  final Services? services;
  final DownloadsPort? downloads;
  final void Function(List<Track> tracks, int index)? play;

  @override
  State<Loaded<T>> createState() => _LoadedState<T>();
}

class _LoadedState<T> extends State<Loaded<T>> {
  late Future<T> _future = widget.load()..ignore();

  void _reload() {
    setState(() {
      // A fast failure can arrive before the next frame attaches FutureBuilder.
      // Keep it on the future for the error UI, without an unhandled crash.
      _future = widget.load()..ignore();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<T>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final error = snapshot.error;
        if (error != null) {
          final reason = error is ServerFailed
              ? error.reason
              : ServerFailure.noAnswer;
          final downloads = widget.downloads ?? widget.services?.downloads;
          final play = widget.play ?? widget.services?.play;
          return Message(
            failureText(reason, notFound: widget.notFound, text: l10n(context)),
            key: ObjectKey(_future),
            onRetry: reason == ServerFailure.notFound ? null : _reload,
            onDownloads: (reason == ServerFailure.noAnswer && downloads != null)
                ? () => open(
                    context,
                    DownloadsScreen(
                      downloads: downloads,
                      play: play ?? (_, _) {},
                    ),
                  )
                : null,
            server: widget.server ?? widget.services?.server,
            report: ErrorReport(
              kind: 'server.${reportName(reason.name)}',
              screen: widget.screen,
            ),
          );
        }
        return widget.builder(context, snapshot.data as T, _reload);
      },
    );
  }
}

/// Long list loaded incrementally in chunks as the user scrolls.
class PagedList<T> extends StatefulWidget {
  const PagedList({
    super.key,
    required this.load,
    required this.itemBuilder,
    required this.empty,
    this.start = 0,
    this.onItems,
    this.onTotal,
    this.screen = 'app',
    this.server,
  });

  final Future<Chunk<T>> Function(int offset) load;
  final Widget Function(BuildContext context, List<T> items, int index)
  itemBuilder;
  final String empty;
  final String screen;
  final ServerApi? server;

  /// Offset in full list where the first page begins loading.
  final int start;

  /// New chunk arrived: all items loaded up to now.
  final void Function(List<T> items)? onItems;

  /// Total count on the server. Needed for "N artists" header.
  final void Function(int total)? onTotal;

  @override
  State<PagedList<T>> createState() => _PagedListState<T>();
}

class _PagedListState<T> extends State<PagedList<T>> {
  final _items = <T>[];
  int? _total;
  ServerFailure? _failure;
  var _loading = false;
  var _attempt = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_more());
  }

  Future<void> _more() async {
    if (_loading) {
      return;
    }
    _loading = true;
    _attempt++;
    if (_failure != null) {
      setState(() => _failure = null);
    }
    ServerFailure? failure;
    try {
      final chunk = await widget.load(widget.start + _items.length);
      _items.addAll(chunk.items);
      // Empty chunk when "has more" — list changed on the server; stop
      // requesting, otherwise it would loop indefinitely.
      _total = chunk.items.isEmpty ? widget.start + _items.length : chunk.total;
      widget.onItems?.call(List.unmodifiable(_items));
      widget.onTotal?.call(_total!);
    } on ServerFailed catch (failed) {
      failure = failed.reason;
    } catch (_) {
      failure = ServerFailure.noAnswer;
    }
    _loading = false;
    if (mounted) {
      setState(() => _failure = failure);
    }
  }

  @override
  Widget build(BuildContext context) {
    final failure = _failure;
    final total = _total;
    if (_items.isEmpty) {
      if (failure != null) {
        return _error(failure, l10n(context));
      }
      if (total == null) {
        return const Center(child: CircularProgressIndicator());
      }
      return Message(widget.empty);
    }
    final more = total == null || widget.start + _items.length < total;
    return ListView.builder(
      itemCount: _items.length + (more ? 1 : 0),
      itemBuilder: (context, index) {
        if (index < _items.length) {
          return widget.itemBuilder(context, _items, index);
        }
        if (failure != null) {
          return _error(failure, l10n(context));
        }
        unawaited(Future.microtask(_more));
        return const Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator()),
        );
      },
    );
  }

  Widget _error(ServerFailure failure, AppLocalizations text) => Message(
    failureText(failure, text: text),
    key: ValueKey(_attempt),
    onRetry: _more,
    server: widget.server,
    report: ErrorReport(
      kind: 'server.${reportName(failure.name)}',
      screen: widget.screen,
    ),
  );
}

/// Block header on the artist page.
class Heading extends StatelessWidget {
  const Heading(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        text,
        style: ApertonoText.sectionTitle.copyWith(
          color: ApertonoColors.textPrimary,
        ),
      ),
    );
  }
}

/// Artist initials: first letters of first two words, "Pink Floyd" -> "PF".
String initials(String name) {
  return RegExp(r'[\p{L}\p{N}]\S*', unicode: true)
      .allMatches(name)
      .take(2)
      .map((word) => word[0]!.characters.first.toUpperCase())
      .join();
}

/// No cover — colored square with artist initials. Color is hashed from
/// the name, so it stays consistent for the artist across app runs.
class ArtistSquare extends StatelessWidget {
  const ArtistSquare(
    this.name, {
    super.key,
    this.size = 48,
    this.radius = ApertonoRadii.cover,
  });

  final String name;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final hue = name.codeUnits.fold(0, (sum, unit) => (sum * 31 + unit) % 360);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final color = HSLColor.fromAHSL(
      1,
      hue.toDouble(),
      0.5,
      dark ? 0.3 : 0.8,
    ).toColor();
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox.square(
        dimension: size,
        child: ColoredBox(
          color: color,
          child: Center(
            child: Text(
              initials(name),
              style: TextStyle(
                fontSize: size * 0.4,
                color: dark
                    ? ApertonoColors.textPrimary
                    : ApertonoColors.inkOnLight,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Empty string means "no cover": [Cover] expects `null`, otherwise it would
/// request an empty URL from the server.
String? coverPath(Track track) =>
    track.artworkUrl.isEmpty ? null : track.artworkUrl;

/// Podcast or episode picture through own server (FT-859): the phone never
/// asks the podcast's site itself.
String? podcastCoverPath(String? image) => image == null || image.isEmpty
    ? null
    : '/v1/covers/podcast/image?u=${Uri.encodeQueryComponent(image)}';

/// Album cover from own server, with key. If missing or failed to load —
/// square with artist initials. No external URLs here.
class Cover extends StatelessWidget {
  const Cover({
    super.key,
    required this.server,
    required this.path,
    required this.artist,
    this.size = 48,
    this.radius = ApertonoRadii.cover,
  });

  final ServerApi server;
  final String? path;
  final String artist;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final path = this.path;
    final square = ArtistSquare(artist, size: size, radius: radius);
    final store = path == null ? null : CoverFiles.maybeOf(context);
    final file = path == null ? null : store?.fileFor(path);
    // errorBuilder stays silent: without it Flutter logs URL with album id.
    final Widget image;
    if (path == null) {
      image = square;
    } else if (file != null) {
      image = Image.file(
        file,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => square,
      );
    } else {
      image = Image.network(
        server.url(path),
        headers: server.headers,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => square,
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox.square(dimension: size, child: image),
    );
  }
}

/// "Play / pause" based on player phase. Used in two places — in mini-player and on
/// full player screen, — so it lives here as a single instance.
///
/// Keys differ: device tests look for mini-player button via `pause-button`,
/// while both locations are visible at once. Same key would match two buttons,
/// failing the test for reasons unrelated to audio.
class PlayPauseButton extends StatelessWidget {
  const PlayPauseButton({
    super.key,
    required this.player,
    this.prefix = '',
    this.tooltips = false,
    this.filled = false,
    this.size,
    this.iconSize,
  });

  final Player player;
  final String prefix;

  /// Tooltip on long press. Must be omitted in mini-player: measurement on
  /// 20.09 — tooltip fails accessibility tree assert in rendering, breaking
  /// thirteen tests where mini-player is visible; without it all
  /// pass. Likely because mini-player sits outside Navigator,
  /// but that is a guess; only the effect was verified.
  final bool tooltips;

  /// Circular amber button on full screen and in mini-player.
  final bool filled;

  /// More compact button in mini-player; without value, size does not change.
  final double? size;
  final double? iconSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = l10n(context);
    final size = this.size;
    final style = filled || size != null
        ? IconButton.styleFrom(
            backgroundColor: filled ? theme.colorScheme.primary : null,
            foregroundColor: filled ? theme.colorScheme.onPrimary : null,
            // Circle is under 48, but tap target stays 48: a slight miss
            // would otherwise open the full player instead of pausing.
            padding: size == null ? null : EdgeInsets.zero,
          )
        : null;
    final constraints = size == null
        ? null
        : BoxConstraints.tightFor(width: size, height: size);
    return switch (player.phase) {
      AudioPhase.playing => IconButton(
        key: Key('${prefix}pause-button'),
        tooltip: t.partsPause,
        style: style,
        constraints: constraints,
        iconSize: iconSize,
        icon: const Icon(Icons.pause),
        onPressed: player.toggle,
      ),
      // While the song loads, a tap gives up waiting (FT-850); it never
      // sends a second Play.
      AudioPhase.buffering => IconButton(
        key: Key('${prefix}buffering-indicator'),
        tooltip: t.partsStopLoading,
        style: style,
        constraints: constraints,
        iconSize: iconSize,
        icon: const Icon(Icons.hourglass_empty),
        onPressed: player.toggle,
      ),
      AudioPhase.error => IconButton(
        key: Key('${prefix}retry-button'),
        tooltip: t.partsRetry,
        style: style,
        constraints: constraints,
        iconSize: iconSize,
        icon: const Icon(Icons.refresh),
        onPressed: player.retry,
      ),
      AudioPhase.paused || AudioPhase.idle => IconButton(
        key: Key('${prefix}play-button'),
        tooltip: t.partsPlay,
        style: style,
        constraints: constraints,
        iconSize: iconSize,
        icon: const Icon(Icons.play_arrow),
        onPressed: player.toggle,
      ),
    };
  }
}

/// Heart icons on screen: which of the displayed tracks are favorited.
///
/// Answered by server (`POST /v1/favorites/contains`), not by id match on
/// device: the same track has different IDs in search vs album page. After
/// each toggle, the server is queried again for all tracks on screen.
class Hearts extends ChangeNotifier {
  Hearts(this.server);

  final ServerApi server;
  var _ids = <String>[];
  var _liked = <String>{};
  var _disposed = false;

  bool isLiked(String trackId) => _liked.contains(trackId);

  Future<void> show(List<Track> tracks) {
    _ids = [for (final track in tracks) track.id];
    return _ask();
  }

  Future<void> _ask() async {
    final ids = _ids;
    try {
      final liked = await server.liked(ids);
      if (_disposed || !identical(ids, _ids)) {
        return;
      }
      _liked = liked;
      notifyListeners();
    } on ServerFailed {
      // Server did not respond — favorite states remain unchanged.
    }
  }

  /// Heart toggled. Throws [ServerFailed] on error.
  Future<void> toggle(Track track) async {
    if (isLiked(track.id)) {
      await server.unlike(track.id);
    } else {
      await server.like(track.id, artworkUrl: track.artworkUrl);
    }
    await _ask();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// "3:42" from milliseconds. Zero or negative is empty: duration unknown to server.
String formatDuration(int durationMs) {
  if (durationMs <= 0) return '';
  final total = durationMs ~/ 1000;
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  final ss = seconds.toString().padLeft(2, '0');
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:$ss';
  }
  return '$minutes:$ss';
}

/// "3 genres", "21 artists", "352 844 artists".
String ruCount(int n, String one, String few, String many) {
  final mod10 = n % 10;
  final mod100 = n % 100;
  final word = (mod10 == 1 && mod100 != 11)
      ? one
      : (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14))
      ? few
      : many;
  // Thousands separated by narrow non-breaking space: "352844" looked like
  // unreadable digit soup.
  final digits = n.abs().toString().replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => '\u202F',
  );
  return '${n < 0 ? '-' : ''}$digits $word';
}

/// Number with localized plural form: Russian three forms [ruCount], English two ("1 track", "21 tracks").
String countIn(
  AppLocalizations text,
  int n,
  String one,
  String few,
  String many,
) {
  if (text.localeName == 'ru') return ruCount(n, one, few, many);
  return '${ruCount(n, '', '', '').trimRight()} ${n == 1 ? one : many}';
}

/// "Artist · 3:42". Without duration — artist only.
String trackLine(Track track) {
  final duration = formatDuration(track.durationMs);
  return duration.isEmpty ? track.artist : '${track.artist} · $duration';
}

/// Track row. Unplayable is dim, but stays in place and is tappable.
class TrackTile extends StatelessWidget {
  const TrackTile({
    super.key,
    required this.track,
    required this.onTap,
    this.services,
    this.hearts,
    this.leading,
    this.subtitle,
    this.playlist,
    this.onChanged,
    this.oneTap = false,
    this.swipe = true,
  });

  final Track track;
  final VoidCallback onTap;

  /// Swipe right to "play next" (FT-695). In "History", rows are already
  /// dismissed by swipe left — its own gesture would conflict.
  final bool swipe;

  /// Without server (search test harness) — plain row, no favorite or menu.
  final Services? services;
  final Hearts? hearts;
  final Widget? leading;
  final String? subtitle;

  /// Search results: cover, artist, mono duration, and ▶ button.
  final bool oneTap;

  /// Playlist from which the track can be removed.
  final String? playlist;

  /// Heart toggled or track removed — screen may need to refresh.
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    final services = this.services;
    final hearts = this.hearts;
    final t = l10n(context);
    final pale = track.playable ? null : paleColor(context);
    // Duration is placed under the title rather than in a separate right column:
    // on a 360dp phone, a duration column plus "play" button left only
    // 3-4 letters for the title. Tapping the row itself plays the track.
    final line = track.missing
        ? t.partsTrackMissing(track.artist)
        : subtitle ?? trackLine(track);
    final cover =
        leading ??
        (oneTap && services != null
            ? Cover(
                server: services.server,
                path: coverPath(track),
                artist: track.artist,
                size: 46,
              )
            : null);
    final extras = <Widget>[
      if (services?.downloads case final downloads?)
        ListenableBuilder(
          listenable: downloads,
          builder: (context, _) {
            final mark = downloads.markOf([track.id]);
            if (mark == DownloadMark.none) {
              return const SizedBox.shrink();
            }
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: KeyedSubtree(
                key: Key('track-download-${track.id}'),
                child: DownloadStateMark(mark, size: 20),
              ),
            );
          },
        ),
      if (services != null && hearts != null) ...[
        if (!track.missing) _heart(hearts),
        SizedBox.square(
          dimension: 48,
          child: PopupMenuButton<VoidCallback>(
            tooltip: t.partsMore,
            padding: EdgeInsets.zero,
            icon: Icon(
              Icons.more_vert,
              color: pale ?? ApertonoColors.textSecondary,
            ),
            onSelected: (action) => action(),
            itemBuilder: (context) {
              final playNext = services.playNext;
              final enqueue = services.enqueue;
              final openArtist = services.openArtist;
              final downloads = services.downloads;
              final status = downloads?.statusOf(track.id);
              final canPlayNext =
                  playNext != null && track.playable && !track.missing;
              final canEnqueue =
                  enqueue != null && track.playable && !track.missing;
              final canOpenArtist = openArtist != null;
              final canDownload =
                  downloads != null &&
                  track.playable &&
                  !track.missing &&
                  (status == null || status == DownloadStatus.failed);
              final canDelete =
                  downloads != null &&
                  (status == DownloadStatus.waiting ||
                      status == DownloadStatus.preparing ||
                      status == DownloadStatus.downloading ||
                      status == DownloadStatus.done);
              return [
                if (canPlayNext)
                  PopupMenuItem(
                    value: () => playNext(track),
                    child: Text(t.partsPlayNext),
                  ),
                if (canEnqueue)
                  PopupMenuItem(
                    value: () => enqueue(track),
                    child: Text(t.partsQueueEnd),
                  ),
                if (canOpenArtist)
                  PopupMenuItem(
                    value: () => openArtist(track.artist),
                    child: Text(t.partsOpenArtist),
                  ),
                if (!track.missing)
                  PopupMenuItem(
                    value: () => _openAlbum(context, services),
                    child: Text(t.partsOpenAlbum),
                  ),
                if (canDownload)
                  PopupMenuItem(
                    value: () => downloads.download([track]),
                    child: Text(t.partsDownload),
                  ),
                if (canDelete)
                  PopupMenuItem(
                    value: () => downloads.remove([track.id]),
                    child: Text(t.partsDeleteFromPhone),
                  ),
                if (!track.missing)
                  PopupMenuItem(
                    value: () => addToPlaylist(context, services, track),
                    child: Text(t.partsAddToPlaylist),
                  ),
                if (playlist case final playlist?)
                  PopupMenuItem(
                    value: () => _remove(context, services, playlist),
                    child: Text(t.partsRemoveFromPlaylist),
                  ),
              ];
            },
          ),
        ),
      ],
    ];
    // Height is minimum rather than rigid: with large system fonts the row
    // expands without clipping text. 62 is cover 46 plus 8 top and bottom.
    final hasCover = cover is Cover;
    final row = ConstrainedBox(
      constraints: BoxConstraints(minHeight: hasCover ? 62 : 56),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              if (cover != null) ...[cover, const SizedBox(width: 12)],
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ApertonoText.trackTitle.copyWith(
                        color: pale ?? ApertonoColors.textPrimary,
                      ),
                    ),
                    Text(
                      line,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ApertonoText.trackArtist.copyWith(
                        color: pale ?? ApertonoColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              if (extras.isNotEmpty)
                Row(mainAxisSize: MainAxisSize.min, children: extras),
            ],
          ),
        ),
      ),
    );
    // Swipe right — "play next" in a single gesture (FT-695).
    final playNext = services?.playNext;
    if (!swipe || playNext == null || !track.playable || track.missing) {
      return row;
    }
    return SwipeRow(
      label: t.partsPlayNext,
      onPlayNext: () {
        playNext(track);
        say(ScaffoldMessenger.of(context), t.partsWillPlayNext);
      },
      child: row,
    );
  }

  Widget _heart(Hearts hearts) {
    return ListenableBuilder(
      listenable: hearts,
      builder: (context, _) {
        final liked = hearts.isLiked(track.id);
        final text = l10n(context);
        return IconButton(
          key: ValueKey('heart-${track.id}'),
          tooltip: liked
              ? text.partsRemoveFromFavorites
              : text.partsAddToFavorites,
          isSelected: liked,
          icon: const Icon(Icons.favorite_border),
          selectedIcon: const Icon(Icons.favorite),
          style: IconButton.styleFrom(
            foregroundColor: liked
                ? ApertonoColors.accent
                : ApertonoColors.textSecondary,
            minimumSize: const Size(48, 48),
            padding: EdgeInsets.zero,
          ),
          onPressed: () async {
            final messenger = ScaffoldMessenger.of(context);
            try {
              await hearts.toggle(track);
              onChanged?.call();
            } on ServerFailed catch (failed) {
              say(messenger, failureText(failed.reason, text: text));
            }
          },
        );
      },
    );
  }

  Future<void> _remove(
    BuildContext context,
    Services services,
    String playlist,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final text = l10n(context);
    try {
      await services.server.removeFromPlaylist(playlist, track.id);
      onChanged?.call();
    } on ServerFailed catch (failed) {
      say(
        messenger,
        failureText(failed.reason, notFound: text.partsPlaylistGone),
      );
    }
  }

  Future<void> _openAlbum(BuildContext context, Services services) =>
      openTrackAlbum(context, services, track, (page) => open(context, page));
}

/// Track list: tapping plays as queue G, each track has heart and menu.
/// With [onReorder], rows can be dragged to reorder (long press).
class Tracks extends StatefulWidget {
  const Tracks({
    super.key,
    required this.services,
    required this.tracks,
    this.header = const [],
    this.numbered = false,
    this.playlist,
    this.onChanged,
    this.onReorder,
  });

  final Services services;
  final List<Track> tracks;

  /// Above tracks: album header, "Play" button.
  final List<Widget> header;

  /// Album track index on the left.
  final bool numbered;
  final String? playlist;
  final VoidCallback? onChanged;

  /// New order — full list of IDs.
  final void Function(List<String> trackIds)? onReorder;

  @override
  State<Tracks> createState() => _TracksState();
}

/// Prepare the first three playable tracks from the list (Р-A76).
List<String> warmTracks(
  Services services,
  List<Track> tracks, {
  List<String> already = const [],
}) {
  final playable = tracks
      .where((track) => track.playable && !track.missing)
      .take(3)
      .toList();
  final ids = [for (final track in playable) track.id];
  if (listEquals(already, ids)) return already;
  for (final track in playable) {
    services.prepare(track);
  }
  return ids;
}

class _TracksState extends State<Tracks> {
  late final _hearts = Hearts(widget.services.server);
  late var _tracks = widget.tracks;
  var _prepared = const <String>[];

  @override
  void initState() {
    super.initState();
    unawaited(_hearts.show(_tracks));
    _prepared = warmTracks(widget.services, _tracks, already: _prepared);
  }

  @override
  void didUpdateWidget(Tracks old) {
    super.didUpdateWidget(old);
    if (!identical(old.tracks, widget.tracks)) {
      _tracks = widget.tracks;
      unawaited(_hearts.show(_tracks));
      _prepared = warmTracks(widget.services, _tracks, already: _prepared);
    }
  }

  @override
  void dispose() {
    _hearts.dispose();
    super.dispose();
  }

  Widget _tile(int index) {
    final track = _tracks[index];
    return TrackTile(
      key: ValueKey(track.id),
      track: track,
      services: widget.services,
      hearts: _hearts,
      leading: widget.numbered ? Text('${index + 1}') : null,
      playlist: widget.playlist,
      onChanged: widget.onChanged,
      onTap: () {
        if (track.missing) {
          openSearch(
            context,
            widget.services,
            query: '${track.artist} ${track.title}',
          );
          return;
        }
        final (queue, start) = queueFrom(_tracks, index);
        widget.services.play(queue, start);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final onReorder = widget.onReorder;
    if (onReorder == null) {
      return ListView(
        children: [
          ...widget.header,
          for (var i = 0; i < _tracks.length; i++) _tile(i),
        ],
      );
    }
    return ReorderableListView.builder(
      header: Column(children: widget.header),
      itemCount: _tracks.length,
      itemBuilder: (context, index) => _tile(index),
      onReorderItem: (from, to) {
        final tracks = [..._tracks];
        tracks.insert(to, tracks.removeAt(from));
        setState(() => _tracks = tracks);
        onReorder([for (final track in tracks) track.id]);
      },
    );
  }
}

/// Playlist title: non-empty and within server length limit.
Future<String?> askName(
  BuildContext context, {
  required String title,
  String initial = '',
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _NameDialog(title: title, initial: initial),
  );
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.title, required this.initial});

  final String title;
  final String initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _field = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        key: const Key('name-field'),
        controller: _field,
        autofocus: true,
        // NAME_MAX in server/app/library.py.
        maxLength: 100,
        decoration: InputDecoration(hintText: l10n(context).partsName),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n(context).partsCancel),
        ),
        ListenableBuilder(
          listenable: _field,
          builder: (context, _) {
            final name = _field.text.trim();
            return FilledButton(
              onPressed: name.isEmpty
                  ? null
                  : () => Navigator.pop(context, name),
              child: Text(l10n(context).partsSave),
            );
          },
        ),
      ],
    );
  }
}

/// New playlist: prompt for title and return created one. Cancel returns `null`.
Future<PlaylistInfo?> createPlaylist(
  BuildContext context,
  Services services,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final name = await askName(context, title: l10n(context).partsNewPlaylist);
  if (name == null) {
    return null;
  }
  try {
    return await services.server.createPlaylist(name);
  } on ServerFailed catch (failed) {
    say(messenger, failureText(failed.reason));
    return null;
  }
}

Future<void> addToPlaylist(
  BuildContext context,
  Services services,
  Track track,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final text = l10n(context);
  final chosen = await showDialog<PlaylistInfo>(
    context: context,
    builder: (_) => _PlaylistPicker(services: services),
  );
  if (chosen == null) {
    return;
  }
  try {
    // Track already in playlist — prompt instead of adding duplicate (FT-693).
    final current = await services.server.playlist(chosen.id);
    final split = duplicatesOf(
      [for (final t in current.tracks) t.id],
      [track.id],
    );
    if (!context.mounted) return;
    final choice = await askDuplicates(
      context,
      split,
      DuplicateTexts(
        title: text.partsDuplicatesTitle,
        addAll: text.partsDuplicatesAddAll,
        onlyNew: text.partsDuplicatesOnlyNew,
        cancel: text.partsCancel,
      ),
    );
    if (resolveDuplicates(split, choice) == null) return;
    await services.server.addToPlaylist(
      chosen.id,
      track.id,
      artworkUrl: track.artworkUrl,
    );
    say(messenger, text.partsAddedToPlaylist(chosen.name));
  } on ServerFailed catch (failed) {
    say(messenger, failureText(failed.reason, notFound: text.partsSongsGone));
  }
}

class _PlaylistPicker extends StatelessWidget {
  const _PlaylistPicker({required this.services});

  final Services services;

  @override
  Widget build(BuildContext context) {
    final text = l10n(context);
    return AlertDialog(
      title: Text(text.partsAddToPlaylist),
      content: SizedBox(
        width: double.maxFinite,
        child: Loaded<List<PlaylistInfo>>(
          server: services.server,
          screen: 'playlist_picker',
          load: services.server.playlists,
          builder: (context, playlists, reload) => ListView(
            shrinkWrap: true,
            children: [
              for (final playlist in playlists)
                ListTile(
                  leading: const _PlaylistPickerIcon(),
                  horizontalTitleGap: 12,
                  title: Text(playlist.name),
                  onTap: () => Navigator.pop(context, playlist),
                ),
              ListTile(
                leading: const _PlaylistPickerIcon(create: true),
                horizontalTitleGap: 12,
                title: Text(text.partsNewPlaylist),
                onTap: () async {
                  final playlist = await createPlaylist(context, services);
                  if (playlist != null && context.mounted) {
                    Navigator.pop(context, playlist);
                  }
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(text.partsCancel),
        ),
      ],
    );
  }
}

class _PlaylistPickerIcon extends StatelessWidget {
  const _PlaylistPickerIcon({this.create = false});

  final bool create;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: create ? ApertonoColors.accentSoft : ApertonoColors.surface,
        borderRadius: BorderRadius.circular(ApertonoRadii.cover),
      ),
      child: Icon(
        create ? Icons.add : Icons.queue_music,
        color: create ? ApertonoColors.accent : ApertonoColors.textSecondary,
      ),
    );
  }
}
