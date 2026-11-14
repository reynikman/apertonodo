import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:just_audio/just_audio.dart' show AndroidEqualizer;
import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'app_update.dart';
import 'update_platform.dart';
import 'crash_notice.dart';
import 'auth/foreign_login.dart';
import 'auth/foreign_session.dart';
import 'auth/session_store.dart';
import 'auth/token_provider.dart';
import 'auth/login.dart';
import 'catalog.dart';
import 'device_audio.dart';
import 'connectivity_network.dart';
import 'device_equalizer.dart';
import 'device_info.dart';
import 'device_library.dart';
import 'device_media.dart';
import 'env.dart';
import 'foreign/foreign_library.dart';
import 'foreign/foreign_playback.dart';
import 'foreign/foreign_shell.dart';
import 'equalizer.dart';
import 'error_reports.dart';
import 'l10n/l10n.dart';
import 'offline/background_transfer.dart';
import 'offline/cover_store.dart';
import 'offline/download_queue.dart';
import 'offline/downloads.dart';
import 'offline/offline_playback.dart';
import 'offline/track_store.dart';
import 'podcast_downloads.dart';
import 'podcast_playback.dart' show TrackEpisodeStore;
import 'player.dart';
import 'playback.dart';
import 'loudness.dart';
import 'prefetch_policy.dart';
import 'quality_prefs.dart';
import 'lossless_once.dart';
import 'track_formats.dart';
import 'opened_audio.dart';
import 'server_api.dart';
import 'screens/login_screen.dart';
import 'screens/storage_step.dart';
import 'server_kind.dart';
import 'system_session.dart';
import 'theme.dart';

/// Whether listen buffer size has been chosen on this device (FT-529, Р-A60).
const _spaceChosenKey = 'music-space-chosen';

Widget buildProductionApp({
  AudioPort? audio,
  TokenProvider? tokens,
  SessionStore? sessions,
  http.Client? client,
  Uri? initialServer,
  Future<int?> Function()? freeBytes,
  Future<void> Function(int bytes)? saveReserveLimit,
  Future<TrackStore> Function(String namespace)? openStore,
  CrashNotice? crash,
  AppUpdate? update,
  ForeignSession? foreignSession,
  ForeignAccount? foreignAccount,
  DeviceMediaPort? deviceMedia,
}) => _ProductionApp(
  audio: audio,
  sessions: sessions ?? tokens?.store ?? SessionStore(),
  client: client,
  initialServer: initialServer ?? tokens?.server,
  tokens: tokens,
  freeBytes: freeBytes,
  saveReserveLimit: saveReserveLimit,
  openStore: openStore,
  crash: crash,
  update: update,
  foreignSession: foreignSession ?? ForeignSession(),
  foreignAccount: foreignAccount,
  deviceMedia: deviceMedia,
);

class _ProductionApp extends StatefulWidget {
  const _ProductionApp({
    this.audio,
    required this.sessions,
    this.client,
    this.initialServer,
    this.tokens,
    this.freeBytes,
    this.saveReserveLimit,
    this.openStore,
    this.crash,
    this.update,
    required this.foreignSession,
    this.foreignAccount,
    this.deviceMedia,
  });
  final AudioPort? audio;
  final SessionStore sessions;
  final http.Client? client;
  final Uri? initialServer;
  final TokenProvider? tokens;
  final DeviceMediaPort? deviceMedia;
  final Future<int?> Function()? freeBytes;
  final Future<void> Function(int bytes)? saveReserveLimit;
  final Future<TrackStore> Function(String namespace)? openStore;

  /// Crash memory (FT-698): report is accumulated here, [MusicApp] asks question.
  final CrashNotice? crash;

  /// Auto-update (FT-768).
  final AppUpdate? update;

  /// Login to Navidrome or Jellyfin (FT-779): storage and already read login.
  final ForeignSession foreignSession;
  final ForeignAccount? foreignAccount;

  @override
  State<_ProductionApp> createState() => _ProductionAppState();
}

class _ProductionAppState extends State<_ProductionApp>
    with WidgetsBindingObserver {
  late Uri _server = widget.initialServer ?? Uri.parse(AppEnv.apiBaseUrl);
  // Old origin of a person who came from a renamed address: their data stays
  // under its namespace. Read from `server-moved-from`, never written here.
  Uri? _movedFrom;
  late TokenProvider _tokens =
      widget.tokens ?? TokenProvider(widget.sessions, server: _server);
  OfflinePlayback? _offline;
  String? _offlineNs;
  // Last opened database: shared across all accounts, single file.
  Future<TrackStore>? _store;
  Downloads? _downloads;

  /// Podcast episodes on device (FT-710): same storage and same space
  /// limit as tracks, and same toggle "over mobile network".
  PodcastDownloads? _podcastDownloads;
  CoverStore? _covers;
  late final http.Client _fallbackClient = http.Client();
  http.Client get _httpClient => widget.client ?? _fallbackClient;

  /// Equalizer in device audio pipeline (FT-621) — only for real
  /// audio; player passed externally (tests, scenarios) runs without it.
  late final AndroidEqualizer? _androidEqualizer = widget.audio == null
      ? AndroidEqualizer()
      : null;
  late final Equalizer? _equalizer = switch (_androidEqualizer) {
    final device? => Equalizer(port: DeviceEqualizerPort(device))..load(),
    null => null,
  };
  late final AudioPort _audio =
      widget.audio ??
      DeviceAudio(
        tokens: _tokens,
        equalizer: _androidEqualizer,
        reserveCache: (id) async => _offline?.cacheFileFor(id),
        onCached: (id, file) async => _offline?.adopt(id, file),
      );
  late ForeignAccount? _foreign = widget.foreignAccount;
  Player? _foreignPlayer;
  ForeignLibrary? _foreignLibrary;
  late bool _signedIn =
      widget.sessions.cachedToken != null || widget.tokens?.loggedOut == false;
  String _userId = 'unknown';
  Uri? _wizardServer;
  // With an address handed in, the login screen waits for the saved prefs to
  // be read, so the saved address is there from its first frame.
  late bool _accountRead = !(widget.initialServer?.hasScheme ?? false);
  bool _expired = false;
  int _generation = 0;
  bool _askingSpace = false;
  int? _spaceFreeBytes;
  late ErrorReports _reports;

  /// Audio quality (FT-633): single setting on device, read on
  /// every Play.
  final _quality = QualityPrefs();

  /// File formats from Play responses — badge in player.
  final _formats = TrackFormats();

  /// One-time request "this track lossless" (FT-809).
  final _losslessOnce = LosslessOnce();

  /// Prefetching next track (FT-692): single setting on device.
  final _prefetch = PrefetchPolicy();

  /// Loudness leveling (FT-765): single setting on device.
  var _loudness = LoudnessGate();
  void Function(FlutterErrorDetails)? _previousFlutterError;
  bool Function(Object, StackTrace)? _previousPlatformError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_quality.load());
    unawaited(_prefetch.load());
    unawaited(_loudness.load());
    _bindReports();
    _previousFlutterError = FlutterError.onError;
    _previousPlatformError = PlatformDispatcher.instance.onError;
    FlutterError.onError = (details) {
      final stack = details.stack ?? StackTrace.empty;
      unawaited(_reports.crash(details.exception, stack));
      unawaited(widget.crash?.remember(details.exception, stack));
      final previous = _previousFlutterError;
      if (previous != null) {
        previous(details);
      } else {
        FlutterError.presentError(details);
      }
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      unawaited(_reports.crash(error, stack));
      unawaited(widget.crash?.remember(error, stack));
      // false keeps the runtime's standard error output when no handler exists.
      return _previousPlatformError?.call(error, stack) ?? false;
    };
    _tokens.addListener(_sessionChanged);
    // A player handed in from outside (phone scenarios) streams with this
    // session too; without it every Play throws before a request is made.
    if (_audio is DeviceAudio) _audio.bindTokens(_tokens);
    if (widget.tokens == null) unawaited(_tokens.load());
    unawaited(_loadAccount());
  }

  void _bindReports() {
    // A fresh install of the public build has no server yet: an address
    // without a scheme has no origin, and asking for it fails the first frame.
    final base = _server.hasScheme ? _server.origin : '';
    _reports = ErrorReports(
      ServerApi(
        base,
        tokens: _tokens,
        client: widget.client,
        language: () => PlatformDispatcher.instance.locale.languageCode,
      ),
    );
    unawaited(_reports.load());
  }

  Future<void> _loadAccount() async {
    try {
      await _readAccount();
    } finally {
      // A failed read must not leave the login screen blank for good.
      if (mounted && !_accountRead) setState(() => _accountRead = true);
    }
  }

  Future<void> _readAccount() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final stored = serverOrigin(prefs.getString('active-server') ?? '');
    final user = prefs.getString('active-user');
    final saved = stored;
    // Work out everything first, then redraw once: the login screen reads its
    // address only in initState, so it must not be built half-filled.
    setState(() {
      _accountRead = true;
      if (stored == null) return;
      final from = serverOrigin(prefs.getString('server-moved-from') ?? '');
      if (from != null) _movedFrom = from;
      // Cold start without a token: offer the saved address on the login screen.
      if (!_signedIn) _wizardServer ??= _expired ? null : saved;
    });
    if (saved == null) return;
    if (!_signedIn) return;
    if (user == null) return;
    if (saved != _server) {
      _attach(saved);
      unawaited(_tokens.load());
    }
    setState(() => _userId = user);
  }

  Uri get _dataServer {
    final from = _movedFrom;
    // The move always went to the build's default address.
    return from != null && _server.origin == Uri.parse(AppEnv.apiBaseUrl).origin
        ? from
        : _server;
  }

  void _attach(Uri server) {
    _tokens.removeListener(_sessionChanged);
    _server = server;
    _tokens = TokenProvider(widget.sessions, server: server)
      ..addListener(_sessionChanged);
    _reports.dispose();
    _bindReports();
    if (_audio is DeviceAudio) _audio.bindTokens(_tokens);
  }

  void _sessionChanged() {
    if (!_signedIn || !_tokens.loggedOut || !mounted) return;
    _downloads?.dispose();
    _downloads = null;
    _podcastDownloads?.dispose();
    _podcastDownloads = null;
    _covers = null;
    _offline = null;
    _offlineNs = null;
    setState(() {
      _signedIn = false;
      _expired = true;
      _wizardServer = _server;
      _generation++;
    });
  }

  Future<void> _login(Uri server, String username, String password) =>
      _signedInAt(
        server,
        loginAt(server, username, password, widget.client ?? http.Client()),
      );

  /// FT-856: first sign-in with the admin's code.
  Future<void> _claim(
    Uri server,
    String username,
    String code,
    String password,
  ) => _signedInAt(
    server,
    claimAt(server, username, code, password, widget.client ?? http.Client()),
  );

  Future<void> _signedInAt(
    Uri server,
    Future<({String token, String userId})> request,
  ) async {
    final response = await request;
    final prefs = await SharedPreferences.getInstance();
    _attach(server);
    await _tokens.signIn(response.token);
    await prefs.setString('active-server', server.origin);
    await prefs.setString('active-user', response.userId);
    // Ask listen buffer size once on this device.
    final askSpace = prefs.getBool(_spaceChosenKey) != true;
    final freeBytes = askSpace ? await _freeBytes() : null;
    if (!mounted) return;
    setState(() {
      _server = server;
      _userId = response.userId;
      _signedIn = true;
      _expired = false;
      _generation++;
      _askingSpace = askSpace;
      _spaceFreeBytes = freeBytes;
    });
  }

  /// Foreign server login: verify, save, show shell.
  Future<void> _foreignLogin(ForeignLogin login) async {
    final account = await signInForeign(login, _httpClient);
    await widget.foreignSession.save(account);
    if (!mounted) return;
    setState(() => _foreign = account);
  }

  /// Leave foreign server (button or 401): stop audio, close session,
  /// clear login, return login wizard.
  Future<void> _foreignLeave() async {
    final account = _foreign;
    final player = _foreignPlayer;
    if (account == null) return;
    _foreignPlayer = null;
    _foreignLibrary = null;
    await player?.endSession();
    try {
      await account.logout(_httpClient);
    } catch (_) {
      // Server did not respond or token is dead — session is cleared anyway.
    }
    await widget.foreignSession.clear();
    if (!mounted) return;
    setState(() {
      _foreign = null;
      _generation++;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => player?.dispose());
  }

  Future<int?> Function() get _freeBytes =>
      widget.freeBytes ?? DeviceInfo.freeBytes;

  /// Step passed: save buffer size and never ask on this device again.
  Future<void> _spaceChosen(int bytes) async {
    final save = widget.saveReserveLimit;
    if (save != null) {
      await save(bytes);
    } else {
      final store = await TrackStore.forAccount(
        accountNamespace(_dataServer, _userId),
      );
      try {
        await store.setReserveLimitBytes(bytes);
      } finally {
        await store.close();
      }
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_spaceChosenKey, true);
    if (!mounted) return;
    setState(() => _askingSpace = false);
  }

  Future<void> _leave(String action) async {
    _signedIn = false;
    _downloads?.dispose();
    _downloads = null;
    _podcastDownloads?.dispose();
    _podcastDownloads = null;
    _covers = null;
    _offline = null;
    _offlineNs = null;
    _loudness.dispose();
    _loudness = LoudnessGate();
    unawaited(_loudness.load());
    await _tokens.onUnauthorized();
    if (!mounted) return;
    setState(() {
      _expired = false;
      _wizardServer = action == 'switch-server' ? null : _server;
      _generation++;
    });
  }

  static Future<void> _closeStore(Future<TrackStore>? store) async {
    if (store == null) return;
    try {
      await (await store).close();
    } catch (_) {
      // Did not open — nothing to close.
    }
  }

  // System kill in background is not a crash: minimized app clears the flag.
  // Here in root, not on music screen: login screen is also minimized.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (widget.crash case final crash?) {
      if (state == AppLifecycleState.paused) unawaited(crash.paused());
      if (state == AppLifecycleState.resumed) unawaited(crash.resumed());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    FlutterError.onError = _previousFlutterError;
    PlatformDispatcher.instance.onError = _previousPlatformError;
    _reports.dispose();
    _tokens.removeListener(_sessionChanged);
    _downloads?.dispose();
    _podcastDownloads?.dispose();
    _loudness.dispose();
    _fallbackClient.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_foreign case final account?) {
      final library = _foreignLibrary ??= account.library(_httpClient);
      // Audio is the same as home server; our token is not sent to foreign address.
      final player = _foreignPlayer ??= Player(
        playback: ForeignPlayback(library),
        audio: _audio,
      );
      return MaterialApp(
        title: 'Apertono',
        theme: apertonoTheme(),
        darkTheme: apertonoTheme(),
        themeMode: ThemeMode.dark,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ForeignShell(
          key: ValueKey(('foreign', _generation)),
          library: library,
          player: player,
          onLeave: _foreignLeave,
        ),
      );
    }
    if (!_signedIn) {
      if (!_accountRead) return const SizedBox.shrink();
      return LoginWizard(
        key: ValueKey(_generation),
        onLogin: _login,
        onClaim: _claim,
        onForeignLogin: _foreignLogin,
        detect: (origin) =>
            detectServer(origin.toString(), client: _httpClient),
        initialServer: _wizardServer,
        expired: _expired,
      );
    }
    if (_askingSpace) {
      return StorageStep(
        key: ValueKey('space-$_generation'),
        freeBytes: _spaceFreeBytes,
        onDone: _spaceChosen,
      );
    }
    final base = _server.origin;
    final ns = accountNamespace(_dataServer, _userId);
    if (_offline?.tokens != _tokens || _offlineNs != ns) {
      _offlineNs = ns;
      _downloads?.dispose();
      _downloads = null;
      _podcastDownloads?.dispose();
      _podcastDownloads = null;
      _covers = null;
      // Close previous database, then open: on cold start account is read
      // a frame later, and opening same file on top of first locked both —
      // neither Play nor "Downloaded" worked (FT-535).
      final open = widget.openStore ?? TrackStore.forAccount;
      final storeFuture = _closeStore(_store).then((_) => open(ns));
      _store = storeFuture;
      final serverApi = ServerApi(
        base,
        tokens: _tokens,
        client: widget.client,
        language: () => PlatformDispatcher.instance.locale.languageCode,
      );
      _offline = OfflinePlayback(
        inner: HttpPlayback(
          base,
          tokens: _tokens,
          client: widget.client,
          preferOpus: () => _quality.preferOpus(DeviceInfo.isMetered),
          preferLossless: () => _quality.mode == QualityMode.lossless,
          formats: _formats,
          losslessOnce: _losslessOnce,
        ),
        store: storeFuture,
        tokens: _tokens,
        formats: _formats,
        client: widget.client,
      );
      unawaited(
        storeFuture.then((store) async {
          if (!mounted || _offlineNs != ns) return;
          final queue = DownloadQueue(
            server: serverApi,
            store: store,
            transfer: BackgroundTransfer(),
            isMetered: DeviceInfo.isMetered,
          );
          final coverStore = CoverStore(
            root: Directory('${store.accountDirectory.path}/covers'),
            fetch: (path) async {
              try {
                final uri = Uri.parse(serverApi.url(path));
                final response = await _httpClient
                    .get(uri, headers: serverApi.headers)
                    .timeout(serverApi.timeout);
                if (response.statusCode == 200) {
                  return response.bodyBytes;
                }
                return null;
              } catch (_) {
                return null;
              }
            },
          );
          final downloads = Downloads(
            queue: queue,
            store: store,
            covers: coverStore,
            freeBytes: widget.freeBytes,
            activeTracks: () => {?_offline?.playing},
          );
          await downloads.load();
          if (!mounted || _offlineNs != ns) {
            downloads.dispose();
            return;
          }
          final podcastDownloads = PodcastDownloads(
            store: TrackEpisodeStore(store),
            transfer: BackgroundTransfer(),
            isMetered: DeviceInfo.isMetered,
            allowMobile: queue.allowMobile,
            prefs: await SharedPreferences.getInstance(),
            namespace: store.namespace,
          );
          await podcastDownloads.restore();
          if (!mounted || _offlineNs != ns) {
            podcastDownloads.dispose();
            downloads.dispose();
            return;
          }
          setState(() {
            _downloads = downloads;
            _podcastDownloads = podcastDownloads;
            _covers = coverStore;
          });
        }),
      );
    }
    final offline = _offline!;
    final app = MusicApp(
      // New database — new screen: player, "recent" and recent queries
      // are built once and would hold closed database and "unknown" account
      // from the first cold start frame (FT-535).
      key: ValueKey((_generation, offline)),
      namespace: ns,
      onAccountAction: _leave,
      reports: _reports,
      crash: widget.crash,
      catalogSource: HttpCatalog(base, tokens: _tokens, client: widget.client),
      playback: offline,
      upcoming: offline.ahead,
      audio: _audio,
      server: ServerApi(
        base,
        tokens: _tokens,
        client: widget.client,
        language: () => PlatformDispatcher.instance.locale.languageCode,
      ),
      downloads: _downloads,
      podcastDownloads: _podcastDownloads,
      quality: _quality,
      prefetch: _prefetch,
      loudness: _loudness,
      network: ConnectivityNetwork(),
      equalizer: _equalizer,
      formats: _formats,
      losslessOnce: _losslessOnce,
      update: widget.update,
      opened: OpenedAudioChannel(),
      deviceMedia: widget.deviceMedia ?? ChannelDeviceMedia(),
    );
    return CoverFiles(store: _covers, child: app);
  }
}

/// Background service, notification, and system session: without it audio dies
/// along with minimized app, and headset pause button goes nowhere.
///
/// Extracted from [main] as a separate function not for aesthetics: device scenario
/// launches app directly, doesn't call [main] — and without this call would test
/// player without system session, which is not what users experience.
Future<void> initBackgroundAudio() async {
  final text = lookupAppLocalizations(
    Locale(
      WidgetsBinding.instance.platformDispatcher.locale.languageCode == 'ru'
          ? 'ru'
          : 'en',
    ),
  );
  systemSession ??= await AudioService.init(
    builder: SystemSession.new,
    config: AudioServiceConfig(
      // stored on phones: do not rename
      androidNotificationChannelId: 'flowtune.channel.audio',
      androidNotificationChannelName: text.appPlaybackChannel,
      androidNotificationIcon: 'drawable/ic_stat_apertono',
      androidNotificationOngoing: true,
    ),
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DeviceInfo.load();
  registerFontLicenses();
  await initBackgroundAudio();
  final sessions = SessionStore();
  await sessions.readToken();
  final prefs = await SharedPreferences.getInstance();
  final crash = CrashNotice(prefs);
  await crash.start();
  final saved = serverOrigin(prefs.getString('active-server') ?? '');
  final server = saved;
  AppUpdate? update;
  const updateRepo = String.fromEnvironment('UPDATE_REPO');
  if (updateRepo.isNotEmpty) {
    update = AppUpdate(
      current: const String.fromEnvironment('APP_RELEASE', defaultValue: 'dev'),
      source: GithubUpdateSource(repo: updateRepo),
      installer: ApkInstaller(dir: getApplicationSupportDirectory),
      prefs: prefs,
    );
  }
  final foreignSession = ForeignSession();
  runApp(
    buildProductionApp(
      sessions: sessions,
      initialServer: server,
      crash: crash,
      update: update,
      foreignSession: foreignSession,
      foreignAccount: await foreignSession.read(),
    ),
  );
}
