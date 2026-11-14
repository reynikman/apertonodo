import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'book_client.dart';
import 'book_playback.dart';
import 'book_progress.dart';
import 'book_sync.dart';
import 'catalog.dart';
import 'crash_notice.dart';
import 'device_info.dart';
import 'device_library.dart';
import 'equalizer.dart';
import 'app_update.dart';
import 'screens/update_sheet.dart';
import 'error_reports.dart';
import 'feed_order.dart';
import 'last_played.dart';
import 'listen_reports.dart';
import 'l10n/l10n.dart';
import 'links.dart';
import 'listening_languages.dart';
import 'models/track.dart';
import 'network_watch.dart';
import 'news_prefs.dart';
import 'offline/downloads.dart';
import 'opened_audio.dart';
import 'playback.dart';
import 'player.dart';
import 'podcast_catalog_client.dart';
import 'podcast_client.dart';
import 'podcast_downloads.dart';
import 'recent_queries.dart';
import 'scrobble_settings.dart';
import 'screens/account_bar.dart';
import 'screens/change_password.dart';
import 'screens/books_screen.dart';
import 'screens/catalog_screens.dart';
import 'screens/crash_sheet.dart';
import 'screens/downloads_screen.dart';
import 'screens/home_screen.dart';
import 'screens/library_screens.dart';
import 'screens/menu_screen.dart';
import 'loudness.dart';
import 'playback_speed.dart';
import 'prefetch_policy.dart';
import 'quality_prefs.dart';
import 'lossless_once.dart';
import 'track_formats.dart';
import 'ratings.dart';
import 'server_ports.dart';
import 'sleep_timer.dart';
import 'podcast_playback.dart';
import 'podcast_progress.dart';
import 'podcast_sync.dart';
import 'screens/mini_player.dart';
import 'screens/nav_bar.dart';
import 'screens/news_screen.dart';
import 'screens/parts.dart';
import 'screens/player_screen.dart';
import 'screens/podcast_screen.dart';
import 'screens/podcasts_screen.dart';
import 'screens/equalizer_screen.dart';
import 'screens/quality_sheet.dart';
import 'screens/scrobble_view.dart';
import 'screens/search_screen.dart';
import 'server_api.dart';
import 'theme.dart';

class MusicApp extends StatefulWidget {
  const MusicApp({
    super.key,
    this.catalog = const [],
    this.catalogSource,
    this.playback,
    this.audio,
    this.server,
    this.recent,
    this.lastPlayed,
    this.namespace,
    this.onAccountAction,
    this.reports,
    this.crash,
    this.upcoming,
    this.downloads,
    this.podcastDownloads,
    this.quality,
    this.prefetch,
    this.loudness,
    this.network,
    this.formats,
    this.losslessOnce,
    this.equalizer,
    this.update,
    this.opened,
    this.deviceMedia,
  });

  final List<Track> catalog;
  final CatalogPort? catalogSource;
  final PlaybackPort? playback;
  final AudioPort? audio;

  /// Catalog (genres, Artists, artist, album) and "My Music". If absent — shell:
  /// a single search tab, this is how search and player tests spin up the app.
  final ServerApi? server;

  /// Recent queries of the phone. Custom ones — in tests only: real ones live in
  /// `shared_preferences`, and there is no need to substitute them.
  final RecentQueries? recent;

  /// Last queue on the phone. Custom ones — in tests only.
  final LastPlayed? lastPlayed;
  final String? namespace;
  final Future<void> Function(String action)? onAccountAction;
  final ErrorReports? reports;

  /// Whether there was a crash last time (FT-698): ask once, send report.
  final CrashNotice? crash;

  /// "Open with" (FT-767): files that the system hands over to the app.
  final OpenedAudioChannel? opened;

  /// The next two songs in the queue — to pre-cache them on the phone.
  final void Function(List<String> ids)? upcoming;

  final DownloadsPort? downloads;

  /// Downloading podcast episodes (FT-710). If absent — "Download" buttons do nothing.
  final PodcastDownloads? podcastDownloads;

  /// Audio quality (FT-633): shared setting with Play request in `main.dart`.
  final QualityPrefs? quality;

  /// Prefetching the next song (FT-692): always / unmetered only / never.
  final PrefetchPolicy? prefetch;

  /// Loudness normalization (FT-765).
  final LoudnessGate? loudness;

  /// Phone network (FT-691): returned — player retries immediately. If absent —
  /// retry on schedule only, as before.
  final NetworkPort? network;

  /// Phone equalizer (FT-621); if absent — no menu item.
  final Equalizer? equalizer;

  /// File formats from Play responses (FT-633): same object as for request.
  final TrackFormats? formats;

  /// One-time request "this song lossless" (FT-809): same object as for request.
  final LosslessOnce? losslessOnce;

  /// Auto-update (FT-768); if absent — no auto-check and no menu item.
  final AppUpdate? update;

  /// Audio files on the phone (FT-783): section in "My Music".
  final DeviceMediaPort? deviceMedia;

  @override
  State<MusicApp> createState() => _MusicAppState();
}

class _MusicAppState extends State<MusicApp> with WidgetsBindingObserver {
  final _nav = GlobalKey<NavigatorState>();
  final _outerNav = GlobalKey<NavigatorState>();
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  final _tabs = Tabs();
  final _innerChild = ValueNotifier<Widget?>(null);

  final _searchActive = ValueNotifier(false);

  /// Second tap on opened "Search" tab (B-3): start over.
  final _searchAgain = ValueNotifier(0);
  final _homeActive = ValueNotifier(true);
  final _libraryActive = ValueNotifier(false);
  final _libraryRoutes = RouteObserver<ModalRoute<dynamic>>();
  final _onPlayer = ValueNotifier(false);

  /// How many times tab was tapped: artist closed by tab does not restore
  /// the player (FT-739).
  var _tabOpens = 0;

  /// How many times player was opened: opened and closed manually — "back" from
  /// artist does not restore it (review FT-739).
  var _playerOpens = 0;
  late final _routes = _RouteDepth(_onPlayer);

  bool _updateSheetShown = false;
  bool _sheetOpen = false;

  /// Podcast episodes play via author link, bypassing the server (FT-717).
  late final _podcastPlayback = switch (widget.playback) {
    final playback? => PodcastPlayback(playback),
    null => null,
  };

  /// Audiobooks play via part token from our server (FT-773).
  late final _bookPlayback = switch (widget.server) {
    final server? => BookPlayback(
      _podcastPlayback ?? widget.playback,
      client: BookClient(server.bookSend),
      baseUrl: server.baseUrl,
    ),
    null => switch (_podcastPlayback ?? widget.playback) {
      final playback? => BookPlayback(playback, client: null, baseUrl: ''),
      null => null,
    },
  };

  /// File from phone — via system address, bypassing the server (FT-767).
  late final _openedPlayback = switch (_bookPlayback ?? _podcastPlayback) {
    final playback? => OpenedPlayback(playback),
    null => null,
  };
  late final _player = Player(
    playback: _openedPlayback,
    audio: widget.audio,
    listened: _listened,
    upcoming: widget.upcoming,
    mayPrefetchNext: _mayPrefetchNext,
  );

  /// We distinguish Wi-Fi from mobile network just like downloading (FT-522): by
  /// Android response "network is metered". Metered Wi-Fi (phone hotspot)
  /// counts as mobile network — data there is also paid.
  Future<bool> _mayPrefetchNext() async {
    final policy = widget.prefetch;
    if (policy == null || policy.mode != PrefetchMode.wifiOnly) {
      return policy?.mode != PrefetchMode.never;
    }
    final metered = await DeviceInfo.isMetered();
    return mayPrefetch(policy.mode, onWifi: !metered, metered: metered);
  }

  /// Podcast and book languages (FT-689): shared across the whole app.
  /// Sleep timer lifetime matches the player (FT-619).
  late final _sleep = SleepTimer(player: _player);

  /// Signal "network returned" (FT-691); lifetime matches the player.
  NetworkWatch? _network;

  late final _languages = ListeningLanguages()..load();

  /// Progress position in each episode (FT-717).
  late final _podcastProgress = PodcastProgressStore(
    PrefsPodcastProgressBox(widget.namespace),
  )..restore();

  /// Episode positions — to and from server (FT-659, FT-735): another
  /// phone with same account will resume from the same minute.
  late final _podcastSync = switch (widget.server) {
    final server? => PodcastSync(
      _podcastProgress,
      PodcastClient(server.podcastSend),
      PrefsPodcastMarkBox(widget.namespace),
    ),
    null => null,
  };

  /// Progress position in each book (FT-773). Created on first access;
  /// [_bookProgressMade] — so closing does not instantiate storage just for teardown.
  BookProgressStore? _bookProgressMade;
  late final BookProgressStore _bookProgress = _bookProgressMade =
      BookProgressStore(PrefsBookProgressBox(widget.namespace))..restore();

  /// Book positions — to and from server (FT-773).
  late final _bookSync = switch (widget.server) {
    final server? => BookSync(
      _bookProgress,
      BookClientSyncPort(BookClient(server.bookSend)),
      PrefsBookMarkBox(widget.namespace),
    ),
    null => null,
  };

  /// Episode playback speed: per-podcast setting, songs use normal speed (FT-730).
  late final _speed = switch ((widget.audio, _podcastPlayback)) {
    (final audio?, final playback?) => PlaybackSpeed(
      _player,
      audio,
      speedFor: (id) => switch (playback.feedOf(id)) {
        final feed? => _podcastProgress.speedOf(feed),
        null => null,
      },
      save: (id, speed) async {
        final feed = playback.feedOf(id);
        if (feed != null) await _podcastProgress.setSpeed(feed, speed);
      },
    ),
    _ => null,
  };

  /// Episode order for each podcast (FT-707).
  late final _feedOrders = FeedOrderStore(PrefsFeedOrderBox())..restore();

  late final _recent =
      widget.recent ?? RecentQueries(namespace: widget.namespace);
  late final _lastPlayed =
      widget.lastPlayed ?? LastPlayed(namespace: widget.namespace);

  /// News consent and feed toggle switch (FT-581). Single instance per app:
  /// account menu and "News" tab read from it.
  final _news = NewsPrefs();
  late final _quality = widget.quality ?? (QualityPrefs()..load());
  late final LoudnessGate _loudness =
      widget.loudness ?? (LoudnessGate()..load());
  LoudnessWire? _loudnessWire;
  bool _leaving = false;
  String? _rememberedId;
  var _rememberedIndex = -1;
  DateTime? _wrotePosition;
  StreamSubscription<Duration>? _positions;
  late Services? _services = _buildServices();

  /// Route "/" is built once, and new services do not reach tabs on their
  /// own. "Downloads" arrive after the first frame (`main.dart`), and without
  /// this signal the phone lacked "download" buttons (FT-530).
  final _servicesChanged = ValueNotifier(0);

  /// Ratings live while server remains unchanged: new login -> new storage.
  RatingsStore? _ratings;
  ServerApi? _ratingsServer;

  RatingsStore _ratingsFor(ServerApi server) {
    final kept = _ratings;
    if (kept != null && identical(_ratingsServer, server)) return kept;
    // Dispose old after frame: screens of previous login are still unsubscribing.
    if (kept != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => kept.dispose());
    }
    _ratingsServer = server;
    return _ratings = RatingsStore(ServerRatingsPort(server));
  }

  Services? _buildServices() => switch (widget.server) {
    final server? => Services(
      server: server,
      search: _search,
      play: _play,
      prepare: _player.prepare,
      playNext: _playNext,
      enqueue: _enqueue,
      suggest: widget.catalogSource?.suggest,
      openArtist: _openArtist,
      openPodcast: (track) => _openPodcast(server, track),
      openPage: _openPage,
      recent: _recent,
      routes: _libraryRoutes,
      downloads: widget.downloads,
      openLink: Links.open,
      speed: _speed,
      sleepTimer: _sleep,
      ratings: _ratingsFor(server),
      quality: _quality,
      prefetch: widget.prefetch,
      formats: widget.formats,
      losslessOnce: widget.losslessOnce,
      podcastDownloads: widget.podcastDownloads,
      loudness: _loudness,
      deviceMedia: widget.deviceMedia,
      playDevice: _playDevice,
      podcasts: (_) => PodcastsScreen(
        source: _podcastSource(server),
        languages: _languages,
        orders: _feedOrders,
        downloads: widget.podcastDownloads,
        onPlay: _playEpisode,
        art: _podcastArt(server),
      ),
      books: (_) => BooksScreen(
        services: _services!,
        onPlayBook: _playBook,
        bookProgress: _bookProgress,
        languages: _languages,
      ),
    ),
    null => null,
  };

  void _say(String text) {
    final messenger =
        _messenger.currentState ??
        (_nav.currentContext != null
            ? ScaffoldMessenger.maybeOf(_nav.currentContext!)
            : null);
    if (messenger != null) {
      say(messenger, text);
    }
  }

  void _playNext(Track track) {
    unawaited(_player.playNext(track));
    final text = l10n(_nav.currentContext ?? context);
    _say(text.appPlayNext);
  }

  void _enqueue(Track track) {
    unawaited(_player.enqueue(track));
    final text = l10n(_nav.currentContext ?? context);
    _say(text.appEnqueued);
  }

  @override
  void didUpdateWidget(MusicApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.update != widget.update) {
      oldWidget.update?.removeListener(_onUpdatePhase);
      widget.update?.addListener(_onUpdatePhase);
    }
    if (oldWidget.downloads != widget.downloads ||
        oldWidget.podcastDownloads != widget.podcastDownloads ||
        oldWidget.server != widget.server ||
        oldWidget.catalogSource != widget.catalogSource ||
        oldWidget.deviceMedia != widget.deviceMedia) {
      _services = _buildServices();
      _servicesChanged.value++;
    }
  }

  void _play(List<Track> tracks, int index) =>
      unawaited(_player.playQueue(tracks, start: index));

  void _playDevice(List<DeviceSong> queue, int index) {
    final playback = _openedPlayback;
    if (playback == null) return;
    final tracks = queue.map(playback.openSong).toList();
    unawaited(_player.playQueue(tracks, start: index));
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final update = widget.update;
    if (update != null) {
      update.addListener(_onUpdatePhase);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(update.check());
      });
    }
    _player.addListener(_onSong);
    final audio = widget.audio;
    if (audio != null) {
      _loudnessWire = LoudnessWire(
        player: _player,
        audio: audio,
        gate: _loudness,
        formats: widget.formats,
      );
    }
    if (widget.network case final network?) {
      final watch = _network = NetworkWatch(network);
      watch.returned.listen((_) => _player.networkReturned());
      unawaited(watch.start());
    }
    _player.dislikedOf = _dislikedOf;
    _positions = _player.positions.listen(_onPosition);
    unawaited(widget.opened?.listen(_playOpened));
    unawaited(_restore());
    // Reserve from previous launch is flushed immediately, not with next song.
    _listenReports;
    _news.addListener(_newsChanged);
    unawaited(_news.load());
    if (widget.crash?.shouldAsk ?? false) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _askCrash());
    }
    if (_podcastPlayback case final podcasts?) {
      unawaited(podcasts.ready(_podcastProgress));
    }
    if (_bookPlayback case final books?) {
      unawaited(books.ready(_bookProgress));
    }
    // First frame without network (Stage 1): sync runs after it.
    if (_podcastSync != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _firstSync = Timer(Duration.zero, () => unawaited(_syncPodcasts()));
      });
    }
  }

  void _onUpdatePhase() {
    final update = widget.update;
    if (update == null || !mounted) return;
    if (update.phase == UpdatePhase.available && !_updateSheetShown) {
      _updateSheetShown = true;
      _showUpdateSheet(update);
    }
  }

  void _showUpdateSheet(AppUpdate update) {
    final context = _nav.currentContext;
    if (context == null || _sheetOpen) return;
    _sheetOpen = true;
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        useRootNavigator: true,
        isScrollControlled: true,
        builder: (_) => UpdateSheet(update: update),
      ).whenComplete(() {
        _sheetOpen = false;
      }),
    );
  }

  Future<void> _checkUpdate() async {
    final update = widget.update;
    if (update == null) return;
    await update.check(force: true);
    if (!mounted) return;
    if (update.available != null) {
      _showUpdateSheet(update);
    } else {
      final text = l10n(_nav.currentContext ?? context);
      _say(text.updateLatest);
    }
  }

  Timer? _firstSync;

  /// Sync episode positions — only after reading own from disk: otherwise
  /// reading from disk would overwrite positions received from server.
  Future<void> _syncPodcasts() async {
    final sync = _podcastSync;
    final podcasts = _podcastPlayback;
    if (sync == null || podcasts == null) return;
    await podcasts.ready(_podcastProgress);
    if (!mounted || _leaving) return;
    await sync.run();
  }

  /// Server only accepts catalog ids (UUID), at most 500 at a time:
  /// podcast episodes and files from phone are not included in the query.
  Future<Set<String>> _dislikedOf(List<String> trackIds) async {
    final server = widget.server;
    final ids = [
      for (final id in trackIds)
        if (_catalogId.hasMatch(id)) id,
    ].take(500).toList();
    if (server == null || ids.isEmpty) return const {};
    final ratings = await ServerRatingsPort(server).of(ids);
    return {
      for (final MapEntry(:key, :value) in ratings.entries)
        if (value.disliked) key,
    };
  }

  static final _catalogId = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  Future<void> _askCrash() async {
    final crash = widget.crash;
    final context = _nav.currentContext;
    if (crash == null || context == null || !crash.shouldAsk) return;
    final choice = await askCrashReport(context);
    final report = await crash.answer(
      send: choice == CrashChoice.send,
      neverAgain: choice == CrashChoice.never,
    );
    final api = widget.reports?.api;
    if (report == null || api == null || !mounted) return;
    final result = await api.sendReport(report);
    if (!mounted) return;
    final text = l10n(_nav.currentContext ?? this.context);
    _say(result == ReportResult.sent ? text.crashSent : text.crashNotSent);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returned to app — fetch remote positions; backgrounded — push own.
    if (state == AppLifecycleState.resumed ||
        state == AppLifecycleState.paused) {
      unawaited(_syncPodcasts());
      unawaited(_syncBooks());
    }
  }

  /// Sync book positions with the server.
  Future<void> _syncBooks() async {
    final sync = _bookSync;
    final books = _bookPlayback;
    if (sync == null || books == null) return;
    await books.ready(_bookProgress);
    if (!mounted || _leaving) return;
    await sync.run();
  }

  Future<void> _restore() async {
    final saved = await _lastPlayed.load();
    if (!mounted || _leaving || saved == null || _player.current != null) {
      return;
    }
    _rememberedId = saved.tracks[saved.index].id;
    _rememberedIndex = saved.index;
    _player.restore(saved.tracks, index: saved.index, at: saved.position);
  }

  /// File from "Open with" — play immediately, single song.
  void _playOpened(String uri, String name) {
    final playback = _openedPlayback;
    if (playback == null) return;
    unawaited(_player.playQueue([playback.open(uri, name)]));
  }

  PodcastsSource _podcastSource(ServerApi server) => ServerPodcastsSource(
    PodcastClient(server.podcastSend),
    PodcastCatalogClient(server.podcastSend),
  );

  Widget Function(String?, String, double) _podcastArt(ServerApi server) =>
      (image, title, size) => Cover(
        server: server,
        path: podcastCoverPath(image),
        artist: title,
        size: size,
      );

  /// "Go to podcast" from an episode's player (FT-865): the page opens inside
  /// the shell with the real subscription state; without it — as not subscribed.
  Future<void> _openPodcast(ServerApi server, Track track) async {
    final feed = _podcastPlayback?.feedOf(track.id);
    if (feed == null) return;
    final source = _podcastSource(server);
    var subscribed = false;
    try {
      subscribed = (await source.subscriptions()).any((s) => s.feedUrl == feed);
    } catch (_) {}
    if (!mounted) return;
    _openPage(
      PodcastScreen(
        source: source,
        podcast: FoundPodcast(
          feedUrl: feed,
          title: track.artist,
          image: track.artworkUrl.isEmpty ? null : track.artworkUrl,
        ),
        subscribed: subscribed,
        onSubscribe: () async {
          try {
            return await source.subscribe(feed);
          } catch (_) {
            return false;
          }
        },
        orders: _feedOrders,
        onPlay: _playEpisode,
        downloads: widget.podcastDownloads,
        art: _podcastArt(server),
      ),
    );
  }

  /// "Listen" on episode: from where left off.
  void _playEpisode(FoundPodcast podcast, PodcastEpisode episode) {
    widget.podcastDownloads?.registerEpisode(
      feedUrl: podcast.feedUrl,
      guid: episode.guid,
      enclosureUrl: episode.audioUrl,
    );
    final playback = _podcastPlayback;
    if (playback == null) return;
    unawaited(playback.listen(_player, _podcastProgress, podcast, episode));
  }

  /// "Listen" on book: from where left off.
  void _playBook(ShelfBook book) {
    final playback = _bookPlayback;
    if (playback == null) return;
    unawaited(playback.listen(_player, _bookProgress, book));
  }

  /// History of "My Music" — songs only: server does not know podcast episodes.
  Future<void> Function(String, int, {String artworkUrl})? get _listened {
    if (widget.server == null) return null;
    return (id, ms, {artworkUrl = ''}) async {
      if (PodcastPlayback.isPodcast(id) ||
          OpenedPlayback.isOpened(id) ||
          BookPlayback.isBook(id)) {
        return;
      }
      await _listenReports?.heard(id, ms, artworkUrl: artworkUrl);
    };
  }

  /// Reports with launch number (D1): first to buffer on phone, from there to
  /// server — songs played offline arrive later.
  ListenReports? _reportsKept;
  ServerApi? _reportsServer;
  ListenReports? get _listenReports {
    final server = widget.server;
    if (server == null) return null;
    final kept = _reportsKept;
    if (kept != null && identical(_reportsServer, server)) return kept;
    _reportsServer = server;
    final reports = ListenReports(
      server,
      PrefsListenBox('listen-outbox-${widget.namespace ?? 'default'}'),
    );
    unawaited(reports.outbox.restore().then((_) => reports.outbox.flush()));
    return _reportsKept = reports;
  }

  /// Queue with episode is not persisted: after restart episode address
  /// is not in memory, and restored queue would not play.
  bool get _podcastInQueue => _player.queue.any(
    (track) =>
        PodcastPlayback.isPodcast(track.id) ||
        OpenedPlayback.isOpened(track.id),
  );

  bool get _bookInQueue =>
      _player.queue.any((track) => BookPlayback.isBook(track.id));

  void _onSong() {
    final current = _player.current;
    // Pause on episode or book — position to disk immediately, not after 5 seconds.
    if (_player.phase == AudioPhase.paused) {
      _podcastPlayback?.remember(
        _player,
        _podcastProgress,
        _player.position,
        force: true,
      );
      _bookPlayback?.remember(
        _player,
        _bookProgress,
        _player.position,
        force: true,
      );
    }
    if (current == null || _leaving || _podcastInQueue || _bookInQueue) {
      return;
    }
    if (current.id == _rememberedId && _player.queueIndex == _rememberedIndex) {
      return;
    }
    _rememberedId = current.id;
    _rememberedIndex = _player.queueIndex;
    unawaited(
      _lastPlayed.save(
        tracks: _player.queue,
        index: _player.queueIndex,
        position: Duration.zero,
      ),
    );
  }

  void _onPosition(Duration position) {
    if (_player.phase != AudioPhase.playing) {
      return;
    }
    if (_podcastPlayback?.remember(_player, _podcastProgress, position) ??
        false) {
      return;
    }
    if (_bookPlayback?.remember(_player, _bookProgress, position) ?? false) {
      return;
    }
    if (_podcastInQueue || _bookInQueue) {
      return;
    }
    final now = DateTime.now();
    // Track bar position arrives every second: writing more often churns
    // storage unnecessarily, less often loses a minute of listened audio.
    if (_wrotePosition != null &&
        now.difference(_wrotePosition!) < const Duration(seconds: 10)) {
      return;
    }
    _wrotePosition = now;
    unawaited(
      _lastPlayed.save(
        tracks: _player.queue,
        index: _player.queueIndex,
        position: position,
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _firstSync?.cancel();
    _podcastSync?.cancel();
    _positions?.cancel();
    _player.removeListener(_onSong);
    widget.opened?.stop();
    unawaited(_network?.dispose());
    _speed?.dispose();
    _sleep.dispose();
    _ratings?.dispose();
    _player.dispose();
    _languages.dispose();
    _feedOrders.dispose();
    // Episode position to disk before close: periodic write happens every 5 seconds.
    final progress = _podcastProgress;
    unawaited(progress.flush().whenComplete(progress.dispose));
    final bookProgress = _bookProgressMade;
    if (bookProgress != null) {
      unawaited(bookProgress.flush().whenComplete(bookProgress.dispose));
    }
    _tabs.dispose();
    _servicesChanged.dispose();
    _searchActive.dispose();
    _searchAgain.dispose();
    _homeActive.dispose();
    _libraryActive.dispose();
    _onPlayer.dispose();
    _innerChild.dispose();
    _news.removeListener(_newsChanged);
    _news.dispose();
    _loudnessWire?.dispose();
    if (widget.loudness == null) {
      _loudness.dispose();
    }
    if (widget.quality == null) {
      _quality.dispose();
    }
    widget.update?.removeListener(_onUpdatePhase);
    super.dispose();
  }

  @override
  Future<bool> didPopRoute() async {
    final outerNav = _outerNav.currentState;
    if (outerNav != null && await outerNav.maybePop()) {
      return true;
    }
    return false;
  }

  Future<SearchResult> _search(String query) {
    final source = widget.catalogSource;
    if (source != null) {
      return source.search(query);
    }
    return LocalCatalog(widget.catalog).search(query);
  }

  /// Open artist page from search results. Without catalog it doesn't exist: search
  /// test shell runs without server, and clicking there simply does nothing.
  ///
  /// Artist is always inside the shell — with panel and mini-player (P2,
  /// FT-739): on outer navigator it covered them, and switching tabs didn't
  /// dismiss it. From player: player collapses, "back" restores it unless
  /// the user navigated to another tab.
  void _openArtist(String name) {
    final services = _services;
    if (services == null) return;
    _openPage(ArtistScreen(services: services, name: name));
  }

  /// Screen inside the shell (FT-743: and album from player menu) — follows rules
  /// of artist above.
  void _openPage(Widget page) {
    final nav = _nav.currentState;
    if (nav == null) return;
    final fromPlayer = _onPlayer.value;
    if (fromPlayer) {
      _outerNav.currentState?.popUntil((route) => route.isFirst);
      // Immediately, do not wait for frame: second click in same frame must not
      // be considered "from player" and restore it a second time (review FT-739).
      _onPlayer.value = false;
    }
    final opens = _tabOpens;
    final players = _playerOpens;
    final shown = nav.push(MaterialPageRoute<void>(builder: (_) => page));
    if (fromPlayer) {
      unawaited(
        shown.then((_) {
          if (mounted && _tabOpens == opens && _playerOpens == players) {
            _openPlayer();
          }
        }),
      );
    }
  }

  /// Open player if it is not open yet.
  ///
  /// Do not stack another full player route on top of the current one.
  void _openPlayer() {
    final nav = _outerNav.currentState;
    if (nav == null) {
      return;
    }
    var onPlayer = false;
    nav.popUntil((route) {
      onPlayer = route.settings.name == '/player';
      return true;
    });
    if (!onPlayer) {
      _playerOpens++;
      nav.pushNamed('/player');
    }
  }

  /// The `onSelect` line of search is an anchor for device negative control
  /// (`select-plays` in scripts/unlazy/mutation_control.mjs): do not change
  /// its text or indentation.
  SearchScreen _searchScreen({
    ValueListenable<bool>? active,
    Listenable? again,
  }) {
    final services = _services;
    return SearchScreen(
      onSearch: _search,
      // dart format off
      onSelect: (tracks, index) =>
              unawaited(_player.playQueue(tracks, start: index)),
      // dart format on
      onResults: (tracks) => _player.prepare(tracks.first),
      onSuggest: widget.catalogSource?.suggest,
      onArtist: services == null ? null : _openArtist,
      recent: _recent,
      services: services,
      active: active,
      again: again,
    );
  }

  /// Disabled news while standing on feed — navigate to "Home" (FT-796).
  void _newsChanged() {
    if (!_news.enabled && _tabs.current == 2) _openTab(0);
  }

  void _openTab(int tab) {
    _tabOpens++;
    // Repeated "Search" starts over, but page on top of results first
    // simply closes: user likely wanted to return to results.
    final over = _nav.currentState?.canPop() ?? false;
    if (tab == 3 && _tabs.current == 3 && !over) {
      _searchAgain.value++;
    }
    // Visibility first: popUntil must not re-read tab being left.
    _homeActive.value = tab == 0;
    _libraryActive.value = tab == 4;
    _nav.currentState?.popUntil((route) => route.isFirst);
    _tabs.open(tab);
    _searchActive.value = tab == 3;
  }

  Future<void> _leave(String action) async {
    if (_leaving) return;
    _leaving = true;
    await _player.endSession();
    // Buffer memory is cleared immediately; writing to settings does not hold exit.
    unawaited(_reportsKept?.clear());
    await widget.onAccountAction?.call(action);
  }

  Widget _accountBar() {
    final reports = widget.reports;
    Widget bar() => AccountBar(
      automaticReports: reports?.automatic ?? false,
      newsEnabled: _news.enabled,
      quality: true,
      equalizer: widget.equalizer != null,
      update: widget.update != null,
      changePassword: widget.server != null,
      onAction: (action) {
        switch (action) {
          case 'check-update':
            unawaited(_checkUpdate());
            break;
          case 'auto-reports':
            if (reports != null) {
              unawaited(reports.setAutomatic(!reports.automatic));
            }
            break;
          case 'news-switch':
            unawaited(_news.setEnabled(!_news.enabled));
            break;
          case 'sound-quality':
            _openSoundQuality();
            break;
          case 'equalizer':
            _openEqualizer();
            break;
          case 'scrobble':
            _openScrobble();
            break;
          case 'change-password':
            unawaited(_openChangePassword());
            break;
          default:
            unawaited(_leave(action));
        }
      },
    );
    return ListenableBuilder(
      listenable: Listenable.merge([_news, ?reports]),
      builder: (_, _) => bar(),
    );
  }

  void _openSoundQuality() {
    final context = _nav.currentContext;
    if (context == null) return;
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        useRootNavigator: true,
        isScrollControlled: true,
        builder: (sheet) => SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              QualitySheet(prefs: _quality, loudness: _loudness),
              if (widget.prefetch case final prefetch?)
                PrefetchSection(
                  policy: prefetch,
                  texts: PrefetchTexts(
                    title: l10n(sheet).prefetchTitle,
                    always: l10n(sheet).prefetchAlways,
                    wifiOnly: l10n(sheet).prefetchWifiOnly,
                    never: l10n(sheet).prefetchNever,
                    neverHint: l10n(sheet).prefetchNeverHint,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _openEqualizer() {
    final equalizer = widget.equalizer;
    if (equalizer == null) return;
    _nav.currentState?.push(
      MaterialPageRoute<void>(
        builder: (_) => EqualizerScreen(equalizer: equalizer),
      ),
    );
  }

  Future<void> _openChangePassword() async {
    final server = widget.server;
    final context = _nav.currentContext;
    if (server == null || context == null) return;
    final changed = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (_) => ChangePasswordDialog(change: server.changePassword),
    );
    final shown = _nav.currentContext;
    if (changed != true || shown == null || !shown.mounted) return;
    _messenger.currentState?.showSnackBar(
      SnackBar(content: Text(l10n(shown).passwordChanged)),
    );
  }

  /// Scrobbling to ListenBrainz and Last.fm (FT-631, FT-645, FT-647).
  void _openScrobble() {
    final server = widget.server;
    if (server == null) return;
    _nav.currentState?.push(
      MaterialPageRoute<void>(builder: (_) => _ScrobbleScreen(server: server)),
    );
  }

  void _openDownloads() {
    final downloads = widget.downloads;
    if (downloads == null) return;
    _nav.currentState?.push(
      MaterialPageRoute<void>(
        builder: (_) => DownloadsScreen(
          downloads: downloads,
          play: _play,
          episodes: widget.podcastDownloads,
          playEpisode: (e) => _playEpisode(
            FoundPodcast(feedUrl: e.feedUrl, title: e.show, image: e.image),
            PodcastEpisode(
              guid: e.guid,
              title: e.title,
              audioUrl: e.enclosureUrl,
              durationMs: e.durationMs,
              image: e.image,
            ),
          ),
        ),
      ),
    );
  }

  /// Menu, home screen first. Without server, test shell is search only.
  Widget _home() {
    final services = _services;
    if (services == null) {
      return _searchScreen();
    }
    return ListenableBuilder(
      listenable: _news,
      builder: (_, _) => MenuScreen(
        state: _tabs,
        tabs: [
          HomeScreen(services: services, active: _homeActive),
          GenresScreen(services: services),
          if (_news.enabled)
            NewsScreen(services: services, news: _news)
          else
            const SizedBox.shrink(),
          _searchScreen(active: _searchActive, again: _searchAgain),
          LibraryScreen(
            services: services,
            active: _libraryActive,
            account: widget.onAccountAction == null ? null : _accountBar(),
            onDownloads: widget.downloads == null ? null : _openDownloads,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Apertono',
      navigatorKey: _nav,
      scaffoldMessengerKey: _messenger,
      navigatorObservers: [_libraryRoutes],
      theme: apertonoTheme(),
      darkTheme: apertonoTheme(),
      themeMode: ThemeMode.dark,
      // Language — matching phone: Russian or English (FT-600, Р-A91).
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routes: {
        '/': (_) => ValueListenableBuilder(
          valueListenable: _servicesChanged,
          builder: (_, _, _) => _home(),
        ),
      },
      builder: (context, child) {
        _innerChild.value = child;
        return Navigator(
          key: _outerNav,
          observers: [_routes],
          onGenerateRoute: (settings) {
            if (settings.name == '/player') {
              return _PlayerRoute(
                settings: settings,
                builder: (context) => PlayerScreen(
                  player: _player,
                  services: _services,
                  onDownload: widget.downloads == null
                      ? null
                      : (track) => widget.downloads!.download([track]),
                ),
              );
            }
            return null;
          },
          onGenerateInitialRoutes: (navigator, initialRoute) {
            return [
              MaterialPageRoute<void>(
                settings: const RouteSettings(name: '/'),
                builder: (context) => Overlay(
                  initialEntries: [
                    OverlayEntry(
                      builder: (context) => ListenableBuilder(
                        listenable: Listenable.merge([_player, _tabs, _news]),
                        builder: (context, _) {
                          final showBottom =
                              MediaQuery.viewInsetsOf(context).bottom == 0;
                          final showTabs = _services != null && showBottom;
                          final hasTrack = _player.current != null;
                          final showMini = showBottom && hasTrack;
                          return Material(
                            color: Theme.of(context).colorScheme.surface,
                            child: Column(
                              children: [
                                Expanded(
                                  child: ValueListenableBuilder<Widget?>(
                                    valueListenable: _innerChild,
                                    builder: (context, current, _) =>
                                        current ?? const SizedBox.shrink(),
                                  ),
                                ),
                                if (showMini)
                                  MiniPlayer(
                                    player: _player,
                                    server: _services?.server,
                                    onOpen: _openPlayer,
                                  ),
                                // Under card there is always gap 8. Without navbar, system
                                // gesture bar is added to avoid covering the card.
                                if (showMini)
                                  SizedBox(
                                    height:
                                        8 +
                                        (showTabs
                                            ? 0
                                            : MediaQuery.paddingOf(
                                                context,
                                              ).bottom),
                                  ),
                                if (showTabs)
                                  ApertonoNavBar(
                                    current: _tabs.current,
                                    onOpen: _openTab,
                                    showNews: _news.enabled,
                                  ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ];
          },
        );
      },
    );
  }
}

/// Tracks whether full player is open.
///
/// Navigator calls the observer mid-frame, and state cannot change immediately:
/// that would be rebuilding the tree during its build. Therefore response is deferred
/// to end of frame.
class _RouteDepth extends NavigatorObserver {
  _RouteDepth(this.onPlayer);

  final ValueNotifier<bool> onPlayer;
  final _stack = <Route<dynamic>>[];

  void _look() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Menus and dialogs do not change the page they were opened over.
      final page = _stack.reversed.whereType<PageRoute<dynamic>>().firstOrNull;
      onPlayer.value = page?.settings.name == '/player';
    });
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.add(route);
    _look();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      didRemove(route, previousRoute);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
    _look();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _stack.indexOf(oldRoute);
    if (index >= 0) {
      if (newRoute == null) {
        _stack.removeAt(index);
      } else {
        _stack[index] = newRoute;
      }
    }
    _look();
  }
}

class _PlayerRoute extends PageRoute<void> {
  _PlayerRoute({required this.builder, super.settings});

  final WidgetBuilder builder;

  @override
  bool get opaque => false;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 300);

  @override
  Widget buildModalBarrier() => const SizedBox.shrink();

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => builder(context);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final tween = Tween<Offset>(
      begin: const Offset(0.0, 1.0),
      end: Offset.zero,
    ).chain(CurveTween(curve: Curves.fastOutSlowIn));
    return SlideTransition(position: animation.drive(tween), child: child);
  }
}

/// Listening services screen: settings live while it is open.
class _ScrobbleScreen extends StatefulWidget {
  const _ScrobbleScreen({required this.server});

  final ServerApi server;

  @override
  State<_ScrobbleScreen> createState() => _ScrobbleScreenState();
}

class _ScrobbleScreenState extends State<_ScrobbleScreen> {
  late final _settings = ScrobbleSettings(widget.server)..load();

  @override
  void dispose() {
    _settings.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(l10n(context).accountScrobble)),
    body: ScrobbleView(settings: _settings, onOpen: Links.open),
  );
}
