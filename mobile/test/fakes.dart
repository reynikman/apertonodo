import 'dart:async';

import 'package:music_stream/auth/session_store.dart';
import 'package:music_stream/auth/token_provider.dart';
import 'package:music_stream/models/track.dart';
import 'package:music_stream/offline/download_queue.dart';
import 'package:music_stream/offline/downloads.dart';
import 'package:music_stream/playback.dart';

class EmptySessionStore extends SessionStore {
  @override
  Future<void> saveToken(String token) async {}
  @override
  Future<String?> readToken() async => null;
  @override
  Future<void> clear() async {}
}

TokenProvider tokensFor(String baseUrl) =>
    TokenProvider(EmptySessionStore(), server: Uri.parse(baseUrl));

const sandman = Track(
  id: '5e1f0000-0000-4000-8000-000000000001',
  title: 'Enter Sandman',
  artist: 'Metallica',
  durationMs: 331000,
  artworkUrl: '',
);

const duality = Track(
  id: '33333333-3333-3333-3333-333333333333',
  title: 'Duality',
  artist: 'Slipknot',
  durationMs: 252000,
  artworkUrl: 'https://example.test/cover',
);

/// Mock server with sequentially ordered responses.
///
/// String is stream URL, [PlayFailure] is server failure, [Completer] is response
/// that arrives when test dictates. Last response is repeated.
class FakePlayback implements PlaybackPort {
  FakePlayback([List<Object> answers = const ['https://example.test/s/1']])
    : _answers = List.of(answers);

  final List<Object> _answers;
  final started = <String>[];

  /// Tracks requested by app for preloading.
  final prepared = <String>[];

  /// Preload response; if unset — server didn't find in its index (409).
  Object Function(String trackId)? onPrepare;

  /// Tracks stored locally on phone.
  final local = <String>{};

  /// Stream URLs reported by app as failed playback (FT-546).
  final failedUrls = <String>[];

  @override
  Future<bool> isLocal(String trackId) async => local.contains(trackId);

  @override
  Future<void> failed(String url) async => failedUrls.add(url);

  @override
  Future<String> start(String trackId, {bool prepare = false}) async {
    if (prepare) {
      prepared.add(trackId);
      final answer = onPrepare?.call(trackId) ?? PlayFailure.noSource;
      if (answer is PlayFailure) {
        throw PlaybackFailed(answer);
      }
      return answer as String;
    }
    started.add(trackId);
    final answer = _answers.length > 1 ? _answers.removeAt(0) : _answers.first;
    if (answer is Completer<String>) {
      return answer.future;
    }
    if (answer is PlayFailure) {
      throw PlaybackFailed(answer);
    }
    return answer as String;
  }
}

/// Player whose state test drives manually — mirroring real audio events.
class FakeAudio implements AudioPort {
  final _states = StreamController<AudioStatus>.broadcast();
  final _positions = StreamController<Duration>.broadcast();
  final played = <(String, Duration)>[];
  final seeks = <Duration>[];
  var pauses = 0;
  var stops = 0;
  var resumes = 0;

  /// Playback speeds applied to audio by player, in order.
  final speeds = <double>[];

  /// Volume levels applied to audio by player, in order.
  final volumes = <double>[];

  /// System session skip buttons configured by player.
  Future<void> Function()? skipNext;
  Future<void> Function()? skipPrevious;
  Future<void> Function()? systemPause;

  /// Exception thrown by next [playUrl].
  Object? failNextPlay;

  /// If set, next [playUrl] awaits it: audio source is still opening.
  Completer<void>? holdNextPlay;

  /// What is currently audible. Real [playUrl], upon opening source, starts
  /// playback itself; pause stops, "resume" restores last source.
  String? sounding;
  String? _loaded;

  @override
  Duration position = Duration.zero;

  @override
  Stream<AudioStatus> get states => _states.stream;

  /// Subsequent [setSpeed] calls throw, simulating platform channel failure.
  var failSpeed = false;

  @override
  Future<void> setSpeed(double speed) async {
    if (failSpeed) throw StateError('скорость не принята');
    speeds.add(speed);
  }

  /// Subsequent [setVolume] calls throw, simulating platform channel failure.
  var failVolume = false;

  @override
  Future<void> setVolume(double volume) async {
    if (failVolume) throw StateError('громкость не принята');
    volumes.add(volume);
  }

  @override
  Stream<Duration> get positions => _positions.stream;

  @override
  void setSkips({
    Future<void> Function()? next,
    Future<void> Function()? previous,
    Future<void> Function()? pause,
  }) {
    skipNext = next;
    skipPrevious = previous;
    systemPause = pause;
  }

  @override
  Future<void> playUrl(
    String url,
    AudioMetadata metadata, {
    Duration from = Duration.zero,
  }) async {
    final failure = failNextPlay;
    failNextPlay = null;
    if (failure != null) {
      throw failure;
    }
    final hold = holdNextPlay;
    holdNextPlay = null;
    if (hold != null) {
      await hold.future;
    }
    played.add((url, from));
    _loaded = url;
    sounding = url;
  }

  @override
  Future<void> pause() async {
    pauses++;
    sounding = null;
  }

  @override
  Future<void> stop() async {
    stops++;
    sounding = null;
    _loaded = null;
  }

  @override
  Future<void> resume() async {
    resumes++;
    sounding = _loaded;
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    this.position = position;
  }

  void emit(
    AudioPhase phase, {
    Duration position = Duration.zero,
    bool completed = false,
  }) {
    _states.add(
      AudioStatus(phase: phase, position: position, completed: completed),
    );
  }

  /// Player reported position: updates seek bar in mini-player.
  void tick(Duration at) {
    position = at;
    _positions.add(at);
  }

  /// Track finished playing: just_audio reports completion.
  void finish() => emit(AudioPhase.idle, completed: true);

  /// Tracks queued next (FT-550), in order of [queueNext] calls.
  final queued = <String>[];

  /// What is currently queued: player transitions to it automatically, gaplessly.
  String? queuedNow;
  var clears = 0;

  @override
  Future<void> queueNext(String url, AudioMetadata metadata) async {
    queued.add(url);
    queuedNow = url;
  }

  @override
  Future<void> clearNext() async {
    clears++;
    queuedNow = null;
  }

  /// Track completed, and player seamlessly transitioned to queued track — like just_audio
  /// when next audio source is already in concatenation queue.
  void advance() {
    final next = queuedNow;
    if (next == null) {
      throw StateError('нечего играть следом: queueNext не вызывали');
    }
    queuedNow = null;
    _loaded = next;
    sounding = next;
    _states.add(const AudioStatus(phase: AudioPhase.playing, advanced: true));
  }

  Future<void> close() async {
    await _states.close();
    await _positions.close();
  }
}

/// Allow stream events and pending `await` continuations to settle.
Future<void> settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// "Downloads" without phone and server (FT-528): test controls what is downloaded.
class FakeDownloads extends DownloadsPort {
  FakeDownloads([List<Track> done = const []]) {
    for (final track in done) {
      tracks[track.id] = track;
      statuses[track.id] = DownloadStatus.done;
    }
  }

  final tracks = <String, Track>{};
  final statuses = <String, DownloadStatus>{};
  final bytes = <String, int>{};

  /// Download requests: track IDs and playlist if whole playlist requested.
  final asked = <(List<String>, String?)>[];
  final removed = <List<String>>[];

  /// Which playlist was deleted together with tracks (FT-540); null — not playlist.
  final removedPlaylists = <String?>[];
  final loadedPlaylists = <(String, List<String>)>[];

  @override
  QueueHold hold = QueueHold.none;
  @override
  bool allowMobile = false;
  @override
  int reserveLimitBytes = 10 * 1024 * 1024 * 1024;
  @override
  int? freeBytes = 50 * 1024 * 1024 * 1024;

  void set(String id, DownloadStatus status) {
    statuses[id] = status;
    notifyListeners();
  }

  @override
  DownloadStatus? statusOf(String trackId) => statuses[trackId];

  @override
  List<DownloadedTrack> get items => [
    for (final entry in tracks.entries)
      DownloadedTrack(
        track: entry.value,
        status: statuses[entry.key] ?? DownloadStatus.waiting,
        bytes: bytes[entry.key],
      ),
  ];

  @override
  ({int done, int total}) get progress => (
    done: statuses.values.where((s) => s == DownloadStatus.done).length,
    total: statuses.length,
  );

  @override
  Future<void> download(List<Track> tracks, {String? playlist}) async {
    asked.add(([for (final t in tracks) t.id], playlist));
    for (final track in tracks) {
      this.tracks[track.id] = track;
      statuses.putIfAbsent(track.id, () => DownloadStatus.waiting);
    }
    notifyListeners();
  }

  @override
  Future<void> remove(List<String> trackIds, {String? playlist}) async {
    removed.add(trackIds);
    removedPlaylists.add(playlist);
    for (final id in trackIds) {
      tracks.remove(id);
      statuses.remove(id);
    }
    notifyListeners();
  }

  @override
  Future<void> setAllowMobile(bool value) async {
    allowMobile = value;
    notifyListeners();
  }

  @override
  Future<void> setReserveLimit(int bytes) async {
    reserveLimitBytes = bytes;
    notifyListeners();
  }

  @override
  Future<void> playlistLoaded(String playlistId, List<Track> tracks) async {
    loadedPlaylists.add((playlistId, [for (final t in tracks) t.id]));
  }

  // "Storage" sheet (FT-560): storage used and two cleanup options.
  @override
  int downloadBytes = 0;
  @override
  int reserveBytes = 0;
  var clearedReserve = 0;
  var removedAll = 0;

  @override
  Future<void> clearReserve() async {
    clearedReserve++;
    reserveBytes = 0;
    notifyListeners();
  }

  @override
  Future<void> removeAll() async {
    removedAll++;
    tracks.clear();
    statuses.clear();
    downloadBytes = 0;
    notifyListeners();
  }
}
