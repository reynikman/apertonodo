import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'models/track.dart';
import 'playback.dart';

/// What is playing and why it's not playing — single place for entire app.
///
/// Previously this lived in app widget, and selecting a track didn't launch anything: it
/// changed title in mini-player, while status and button remained from previous
/// track. Pause stopped old one, new one didn't start (owner bug
/// Sept 18). Now selection is a game, each launch has its own id, and
/// server response to an outdated click is simply discarded.
///
/// Queue — list from which track was selected (search results, then album):
/// "next" moves down through it, track end turns on next.
class Player extends ChangeNotifier {
  Player({
    this.playback,
    this.audio,
    this.listened,
    this.upcoming,
    this.mayPrefetchNext,
    Random? random,
    DateTime Function()? clock,
    this.reconnectDelays = defaultReconnectDelays,
    this.stallAfter = const Duration(seconds: 20),
  }) : _random = random ?? Random(),
       _clock = clock ?? DateTime.now {
    _subscription = audio?.states.listen(_onAudio);
  }

  final PlaybackPort? playback;
  final AudioPort? audio;

  /// "My Music" history: how long track actually played (`POST /v1/history`).
  /// Whether to count is decided by server, and consecutive same track it writes as single
  /// entry, so duplicate sending is harmless.
  final Future<void> Function(
    String trackId,
    int listenedMs, {
    String artworkUrl,
  })?
  listened;
  final void Function(List<String> ids)? upcoming;

  /// Whether next track can currently be prefetched in advance (FT-692, Р-A101).
  /// No response — permitted, as it was before setting.
  final Future<bool> Function()? mayPrefetchNext;
  final Random _random;

  /// Pauses between retries after network drop (FT-615): player goes to
  /// server itself until playing starts or schedule runs out.
  final List<Duration> reconnectDelays;

  /// Buffering in middle of track longer than this is a drop, not "still loading".
  final Duration stallAfter;

  /// How long after seek read error means "loading more", not a drop
  /// (P1b). Measurement P1a: a slow source provides seek position in
  /// 14–15s, while ExoPlayer waits 8s for bytes.
  static const seekPatience = Duration(seconds: 60);

  /// 1, 2, 4, 8, 15s, then 30s each — around 10 minutes total (~25 requests).
  static const defaultReconnectDelays = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(seconds: 30),
    Duration(seconds: 30),
    Duration(seconds: 30),
    Duration(seconds: 30),
    Duration(seconds: 30),
    Duration(seconds: 30),
    Duration(seconds: 30),
    Duration(seconds: 30),
    Duration(seconds: 30),
    Duration(seconds: 30),
    Duration(seconds: 30),
    Duration(seconds: 30),
    Duration(seconds: 30),
    Duration(seconds: 30),
    Duration(seconds: 30),
    Duration(seconds: 30),
    Duration(seconds: 30),
    Duration(seconds: 30),
  ];
  final DateTime Function() _clock;

  /// How long current track played: clock ticks only while phase is "playing".
  var _heard = Duration.zero;
  var _reported = Duration.zero;
  DateTime? _playingSince;

  /// "Previous" past this second restarts track, earlier goes to previous.
  static const restartAfter = Duration(seconds: 3);

  /// Token lives 1 hour; prepared item older than this is not used.
  static const preparedFor = Duration(minutes: 50);

  /// If stream drops in first 10 seconds — corrupt file is likely to blame
  /// (FT-546), not network: notify server to find another release.
  /// Drop later — almost always network, server is not notified.
  static const badStreamThreshold = Duration(seconds: 10);

  List<Track> _queue = const [];

  /// Play order: indices in [_queue]. When shuffled — random.
  List<int> _order = const [];
  var _cursor = -1;
  var _shuffle = false;
  var _repeat = Repeat.off;

  /// Next track prepared in advance: track id → stream URL.
  final _prepared = <String, (DateTime, Future<String>)>{};

  Track? _current;
  var _phase = AudioPhase.idle;
  PlayFailure? _failure;
  var _searching = false;

  /// Timestamp when waiting for current tap started (FT-568).
  DateTime? _bufferingSince;

  /// Stream URL of current attempt (FT-546).
  String? _streamUrl;

  /// Whether server was notified of stream failure in current attempt (FT-546).
  var _streamFailedReported = false;

  /// Second from which "retry" will resume.
  var _resumeAt = Duration.zero;

  /// "Play" from idle takes [_resumeAt] only after [restore].
  /// Otherwise finished track after "retry" from middle would start
  /// from that middle again instead of beginning.
  var _resumeFromMemory = false;

  /// Pending auto-retry and watchdog for perpetual buffering (FT-615).
  Timer? _retryTimer;
  Timer? _stallTimer;
  var _retryStep = 0;

  /// Track already played in this run: only then buffering is a potential drop.
  var _playedOnce = false;

  /// Seek after which playback hasn't resumed yet: where and when (P1b).
  Duration? _seekTo;
  DateTime? _seekAt;
  Timer? _reopenTimer;

  /// Run id: everything returned for an old id is garbage.
  var _attempt = 0;

  /// Run id whose source was last sent to player.
  var _loaded = 0;

  /// Player is playing source of current run. Until then — its states
  /// relate to previous track and do not change screen.
  var _live = false;
  AudioStatus? _pending;
  StreamSubscription<AudioStatus>? _subscription;

  /// Queued next track (FT-550).
  var _queueNextRunning = false;
  String? _queuedTrackId;
  String? _queuedUrl;
  String? _inFlightNextTrackId;
  Future<String>? _inFlightNextUrl;

  /// Stop after current track finishes (FT-619, sleep timer).
  var _stopAfterCurrent = false;

  bool get stopAfterCurrent => _stopAfterCurrent;

  set stopAfterCurrent(bool value) {
    if (_stopAfterCurrent == value) {
      return;
    }
    _stopAfterCurrent = value;
    if (value) {
      _queuedTrackId = null;
      _queuedUrl = null;
      audio?.clearNext().ignore();
    } else if (_phase == AudioPhase.playing) {
      _prepareNext();
    }
    notifyListeners();
  }

  Track? get current => _current;
  AudioPhase get phase => _phase;
  PlayFailure? get failure => _failure;
  bool get searching => _searching;

  /// Player awaits network and will auto-retry; schedule exhausted — false.
  bool get reconnecting => _retryTimer != null;
  bool get shuffle => _shuffle;
  Repeat get repeat => _repeat;
  DateTime? get bufferingSince =>
      _phase == AudioPhase.buffering ? _bufferingSince : null;

  /// Track already played in this run (FT-696: short buffering in middle
  /// of track doesn't write "preparing audio").
  bool get playedOnce => _playedOnce;

  /// Queue in playback order.
  List<Track> get queue => [for (final i in _order) _queue[i]];

  /// Discard the old account's playback before showing another account.
  Future<void> endSession() async {
    ++_attempt;
    _cancelWait();
    _current = null;
    _queue = const [];
    _order = const [];
    _cursor = -1;
    _stopAfterCurrent = false;
    _prepared.clear();
    _queuedTrackId = null;
    _queuedUrl = null;
    _live = false;
    _phase = AudioPhase.idle;
    _bufferingSince = null;
    _streamUrl = null;
    _streamFailedReported = false;
    audio?.setSkips();
    await audio?.clearNext();
    await audio?.stop();
    notifyListeners();
  }

  /// Which track of [queue] is currently playing.
  int get queueIndex => _cursor;

  bool get hasNext =>
      _order.isNotEmpty &&
      (_cursor + 1 < _order.length || _repeat == Repeat.all);

  /// Position for seek bar.
  Stream<Duration> get positions =>
      audio?.positions ?? const Stream<Duration>.empty();

  Duration get position => audio?.position ?? Duration.zero;

  /// Track duration: from player, until known — from catalog.
  Duration? get duration =>
      _duration ??
      (_current == null ? null : Duration(milliseconds: _current!.durationMs));
  Duration? _duration;

  /// Tap on track in list: play from beginning.
  Future<void> select(Track track, {Duration from = Duration.zero}) =>
      playQueue([track], from: from);

  /// Restore queue after app restart. Neither plays nor prepares anything.
  void restore(List<Track> tracks, {required int index, required Duration at}) {
    if (tracks.isEmpty || index < 0 || index >= tracks.length) {
      return;
    }
    _queue = List.unmodifiable(tracks);
    _order = List<int>.generate(tracks.length, (i) => i);
    _cursor = index;
    _current = tracks[index];
    _failure = null;
    _cancelWait();
    _resumeAt = at;
    _resumeFromMemory = true;
    _searching = false;
    _phase = AudioPhase.idle;
    _bufferingSince = null;
    _streamUrl = null;
    _streamFailedReported = false;
    _queuedTrackId = null;
    _queuedUrl = null;
    _stopAfterCurrent = false;
    audio?.clearNext().ignore();
    notifyListeners();
  }

  /// Play list starting from track [start]: search results, entire album.
  /// [from] — starting position: podcast episode continues where paused.
  Future<void> playQueue(
    List<Track> tracks, {
    int start = 0,
    Duration from = Duration.zero,
  }) async {
    if (tracks.isEmpty) {
      return;
    }
    final track = tracks[start];
    // Second tap on same track while launching or playing is not
    // a second trip to server: previously double-tap sent two Plays and two requests
    // to indexer.
    if (track.id == _current?.id &&
        (_phase == AudioPhase.buffering || _phase == AudioPhase.playing)) {
      return;
    }
    _queue = List.unmodifiable(tracks);
    _order = _playOrder(start);
    _cursor = 0;
    if (!_shuffle) {
      _cursor = start;
    }
    final asked = ++_queueGeneration;
    if (dislikedOf != null && tracks.length > 1) {
      unawaited(_dropDisliked(asked, track.id));
    }
    if (track.id != _queuedTrackId) {
      _queuedTrackId = null;
      _queuedUrl = null;
      audio?.clearNext().ignore();
    }
    await _start(track, from: from);
  }

  /// Insert immediately after current in playback order (in shuffled queue too).
  Future<void> playNext(Track track) async {
    if (_current == null) {
      return playQueue([track]);
    }
    final newIndex = _queue.length;
    _queue = [..._queue, track];
    final newOrder = [..._order];
    newOrder.insert(_cursor + 1, newIndex);
    _order = newOrder;
    _queuedTrackId = null;
    _queuedUrl = null;
    await audio?.clearNext();
    _syncQueue();
    _notifyUpcoming();
  }

  /// Append to the end of playback order.
  Future<void> enqueue(Track track) async {
    if (_current == null) {
      return playQueue([track]);
    }
    final newIndex = _queue.length;
    _queue = [..._queue, track];
    _order = [..._order, newIndex];
    final nextTrack = hasNext && _repeat != Repeat.one
        ? _queue[_order[(_cursor + 1) % _order.length]]
        : null;
    if (_queuedTrackId != nextTrack?.id) {
      _queuedTrackId = null;
      _queuedUrl = null;
      await audio?.clearNext();
    }
    _syncQueue();
    _notifyUpcoming();
  }

  /// Track [index] of [queue].
  Future<void> jump(int index) async {
    if (index < 0 || index >= _order.length) {
      return;
    }
    _cursor = index;
    await _start(_queue[_order[index]], from: Duration.zero);
  }

  /// "Next". At end of queue without repeat — does nothing.
  Future<void> next() async {
    if (!hasNext) {
      return;
    }
    await jump((_cursor + 1) % _order.length);
  }

  /// "Previous": from middle of track — to its start, from start — to previous.
  Future<void> previous() async {
    if (_current == null) {
      return;
    }
    final first = _cursor <= 0 && _repeat != Repeat.all;
    if (first || position > restartAfter) {
      await seek(Duration.zero);
      return;
    }
    await jump((_cursor - 1 + _order.length) % _order.length);
  }

  /// Seek along the bar.
  Future<void> seek(Duration to) async {
    if (_live && _phase != AudioPhase.error) {
      // On pause read error is not a reason to start audio on its own.
      final playing = _phase != AudioPhase.paused;
      _seekTo = playing ? to : null;
      _seekAt = playing ? _clock() : null;
      await audio?.seek(to);
    }
  }

  /// Shuffle: playing track stays, remaining — in random order.
  /// Turn off — original list order starting from playing track.
  void toggleShuffle() {
    _shuffle = !_shuffle;
    if (_order.isNotEmpty) {
      final playing = _order[_cursor];
      _order = _playOrder(playing);
      _cursor = _shuffle ? 0 : playing;
    }
    if (!hasNext || _repeat == Repeat.one || _stopAfterCurrent) {
      _queuedTrackId = null;
      _queuedUrl = null;
      audio?.clearNext().ignore();
    } else {
      final nextTrack = _queue[_order[(_cursor + 1) % _order.length]];
      if (_queuedTrackId != nextTrack.id) {
        _queuedTrackId = null;
        _queuedUrl = null;
        audio?.clearNext().ignore();
      }
    }
    _syncQueue();
  }

  /// Repeat: off → entire queue → one track → off.
  void cycleRepeat() {
    _repeat = Repeat.values[(_repeat.index + 1) % Repeat.values.length];
    if (!hasNext || _repeat == Repeat.one || _stopAfterCurrent) {
      _queuedTrackId = null;
      _queuedUrl = null;
      audio?.clearNext().ignore();
    } else {
      final nextTrack = _queue[_order[(_cursor + 1) % _order.length]];
      if (_queuedTrackId != nextTrack.id) {
        _queuedTrackId = null;
        _queuedUrl = null;
        audio?.clearNext().ignore();
      }
    }
    _syncQueue();
  }

  /// Which tracks are marked "dislike" (Р-A95): such tracks do not enter
  /// queue on their own. Response arrives after selected track starts — Play doesn't wait.
  Future<Set<String>> Function(List<String> trackIds)? dislikedOf;
  int _queueGeneration = 0;

  /// Drop disliked from playback order. Manually selected track is untouched,
  /// "Play next" and "Add to queue" are also manual, we don't query for them.
  Future<void> _dropDisliked(int asked, String chosen) async {
    final Set<String> disliked;
    try {
      disliked = await dislikedOf!([
        for (final t in _queue)
          if (t.id != chosen) t.id,
      ]);
    } catch (_) {
      return;
    }
    if (asked != _queueGeneration || disliked.isEmpty || _order.isEmpty) {
      return;
    }
    final before = hasNext
        ? _queue[_order[(_cursor + 1) % _order.length]]
        : null;
    final playing = _order[_cursor];
    _order = [
      for (final i in _order)
        if (i == playing || !disliked.contains(_queue[i].id)) i,
    ];
    _cursor = _order.indexOf(playing);
    final after = hasNext
        ? _queue[_order[(_cursor + 1) % _order.length]]
        : null;
    if (before?.id != after?.id) {
      _queuedTrackId = null;
      _queuedUrl = null;
      audio?.clearNext().ignore();
    }
    _syncQueue();
    _notifyUpcoming();
  }

  List<int> _playOrder(int first) {
    final all = List<int>.generate(_queue.length, (i) => i);
    if (!_shuffle) {
      return all;
    }
    all
      ..remove(first)
      ..shuffle(_random);
    return [first, ...all];
  }

  /// Queue changed: update system buttons and prefetch next.
  void _syncQueue() {
    audio?.setSkips(
      next: hasNext ? next : null,
      previous: _current == null ? null : previous,
      pause: pause,
    );
    if (!hasNext || _repeat == Repeat.one || _stopAfterCurrent) {
      _queuedTrackId = null;
      _queuedUrl = null;
      audio?.clearNext().ignore();
    } else if (_phase == AudioPhase.playing) {
      _prepareNext();
    }
    notifyListeners();
  }

  /// Whether [nextId] can be joined ahead of [currentId]. Speed in audio player
  /// is shared by all: track following sped-up episode would start sped-up
  /// (FT-730). `false` — ending follows old path, via [_ended].
  bool Function(String currentId, String nextId)? canJoin;

  /// Re-evaluate joined track: [canJoin] condition has changed.
  void refreshNext() {
    _queuedTrackId = null;
    _queuedUrl = null;
    audio?.clearNext().ignore();
    if (_phase == AudioPhase.playing) _prepareNext();
  }

  /// While track is playing, join next track to player in advance (FT-550).
  void _prepareNext() {
    if (!hasNext || _repeat == Repeat.one || _stopAfterCurrent) {
      return;
    }
    final ask = mayPrefetchNext;
    if (ask == null) {
      _prepareNextNow();
      return;
    }
    unawaited(
      ask().then((allowed) {
        if (allowed) _prepareNextNow();
      }),
    );
  }

  void _prepareNextNow() {
    if (!hasNext || _repeat == Repeat.one || _stopAfterCurrent) {
      return;
    }
    prepare(_queue[_order[(_cursor + 1) % _order.length]]);
    unawaited(_queueNext());
  }

  Future<void> _queueNext() async {
    final audio = this.audio;
    final playback = this.playback;
    if (audio == null || playback == null) {
      return;
    }
    if (!hasNext || _repeat == Repeat.one || _stopAfterCurrent) {
      _queuedTrackId = null;
      _queuedUrl = null;
      audio.clearNext().ignore();
      return;
    }
    final nextTrack = _queue[_order[(_cursor + 1) % _order.length]];
    if (_queuedTrackId == nextTrack.id) {
      return;
    }
    if (_queueNextRunning) {
      return;
    }
    _queueNextRunning = true;
    try {
      while (true) {
        if (!hasNext || _repeat == Repeat.one || _stopAfterCurrent) {
          _queuedTrackId = null;
          _queuedUrl = null;
          audio.clearNext().ignore();
          break;
        }
        final target = _queue[_order[(_cursor + 1) % _order.length]];
        final playing = _current;
        if (playing != null && canJoin?.call(playing.id, target.id) == false) {
          _queuedTrackId = null;
          _queuedUrl = null;
          audio.clearNext().ignore();
          break;
        }
        if (_queuedTrackId == target.id) {
          break;
        }
        final currentAttempt = _attempt;
        final currentTrackId = _current?.id;
        final Future<String> future;
        if (_inFlightNextTrackId == target.id && _inFlightNextUrl != null) {
          future = _inFlightNextUrl!;
        } else {
          _inFlightNextTrackId = target.id;
          future = _url(target);
          _inFlightNextUrl = future;
        }
        final String url;
        try {
          url = await future;
        } finally {
          if (_inFlightNextTrackId == target.id) {
            _inFlightNextTrackId = null;
            _inFlightNextUrl = null;
          }
        }
        if (currentAttempt != _attempt ||
            currentTrackId != _current?.id ||
            !hasNext ||
            _repeat == Repeat.one ||
            _stopAfterCurrent) {
          break;
        }
        final targetAfter = _queue[_order[(_cursor + 1) % _order.length]];
        if (targetAfter.id != target.id) {
          continue;
        }
        await audio.queueNext(
          url,
          AudioMetadata(
            id: target.id,
            title: target.title,
            artist: target.artist,
            artworkUrl: target.artworkUrl,
          ),
        );
        if (currentAttempt == _attempt && currentTrackId == _current?.id) {
          _queuedTrackId = target.id;
          _queuedUrl = url;
        }
        break;
      }
    } catch (_) {
      // Refusal is not an error, end of track will follow old path (_ended).
    } finally {
      _queueNextRunning = false;
    }
  }

  /// Ask server to prepare track about to be played: next
  /// in queue or first in search results. Server searches only its own
  /// list and doesn't query the source.
  void prepare(Track track) {
    final playback = this.playback;
    final now = DateTime.now();
    _prepared.removeWhere(
      (_, value) => now.difference(value.$1) >= preparedFor,
    );
    if (playback == null ||
        track.id == _current?.id ||
        _prepared.containsKey(track.id)) {
      return;
    }
    final url = playback.start(track.id, prepare: true);
    // Preparation failure is not an error: track will be taken regular way.
    url.ignore();
    _prepared[track.id] = (now, url);
  }

  Future<String> _url(Track track) async {
    final playback = this.playback!;
    final prepared = _prepared.remove(track.id);
    // Prepared address is a stream from server. Track downloaded after
    // preparation plays from device: without network address won't open (FT-530).
    if (prepared != null &&
        DateTime.now().difference(prepared.$1) < preparedFor &&
        !await playback.isLocal(track.id)) {
      try {
        return await prepared.$2;
      } on Object {
        // Not found in own list or network blipped — regular path.
      }
    }
    return playback.start(track.id);
  }

  /// Mini-player button.
  Future<void> toggle() async {
    final track = _current;
    if (track == null) {
      return;
    }
    switch (_phase) {
      case AudioPhase.playing:
        await pause();
      case AudioPhase.paused:
        _cancelWait();
        // Resume rather than requesting new token: previously Play after pause
        // restarted track from beginning with new trip to server.
        await audio?.resume();
      case AudioPhase.buffering:
        await _stopLoading();
      case AudioPhase.idle:
        final from = _resumeFromMemory ? _resumeAt : Duration.zero;
        await _start(track, from: from);
      case AudioPhase.error:
        await retry();
    }
  }

  /// Tap on the "loading" button (FT-850): give up waiting. The song stays
  /// chosen; Play starts it again, from the same second if it already played.
  Future<void> _stopLoading() async {
    final at = _live ? position : _resumeAt;
    // Whatever is still on its way — server answer, opening stream — now
    // belongs to an abandoned attempt.
    _attempt++;
    _cancelWait();
    _count(AudioPhase.idle);
    _searching = false;
    _live = false;
    _pending = null;
    _seekTo = null;
    _seekAt = null;
    _resumeAt = at;
    _resumeFromMemory = true;
    _bufferingSince = null;
    _phase = AudioPhase.idle;
    notifyListeners();
    await audio?.pause();
  }

  /// Pause playback if playing (FT-619). While the song is still loading,
  /// stop the loading (FT-858): headset, shade and sleep timer meant "silence".
  Future<void> pause() async {
    if (_phase == AudioPhase.buffering) {
      await _stopLoading();
      return;
    }
    if (_phase == AudioPhase.playing) {
      _cancelWait();
      await audio?.pause();
    }
  }

  /// Network returned (FT-691): network error retries immediately from beginning
  /// of schedule without waiting for next pause. Manual pause is not an error,
  /// this signal does not unpause it.
  void networkReturned() {
    final track = _current;
    if (track == null ||
        _phase != AudioPhase.error ||
        (_failure != PlayFailure.noAnswer && _failure != PlayFailure.dropped)) {
      return;
    }
    _retryStep = 0;
    unawaited(_start(track, from: _resumeAt, auto: true));
  }

  /// "Retry". After drop in middle of track — from same second.
  Future<void> retry() async {
    final track = _current;
    if (track == null) {
      return;
    }
    await _start(track, from: _resumeAt);
  }

  /// Re-query Play for current track and continue from where it
  /// is currently playing (FT-809). Leaves queue untouched.
  Future<void> reloadCurrent() async {
    final track = _current;
    if (track == null) {
      return;
    }
    await _start(track, from: position);
  }

  Future<void> _start(
    Track track, {
    required Duration from,
    bool auto = false,
  }) async {
    _resumeFromMemory = false;
    final attempt = ++_attempt;
    _seekTo = null;
    _seekAt = null;
    // Any user action cancels pending retry and restarts
    // schedule anew; own retry continues schedule.
    _cancelWait();
    _playedOnce = false;
    if (!auto) {
      _retryStep = 0;
    }
    _bufferingSince = _clock();
    _streamUrl = null;
    _streamFailedReported = false;
    _count(AudioPhase.idle);
    // Different track or same from beginning — new listen; "retry"
    // after drop continues previous one.
    if (!auto && (track.id != _current?.id || from == Duration.zero)) {
      _report();
      _heard = Duration.zero;
      _reported = Duration.zero;
    }
    _current = track;
    _failure = null;
    _resumeAt = from;
    _live = false;
    _duration = null;
    final queuedUrl = _queuedUrl;
    final queuedTrackId = _queuedTrackId;
    final inFlightUrl = _inFlightNextUrl;
    final inFlightTrackId = _inFlightNextTrackId;
    _queuedTrackId = null;
    _queuedUrl = null;
    if (queuedTrackId != track.id) {
      this.audio?.clearNext().ignore();
    }
    this.audio?.setSkips(
      next: hasNext ? next : null,
      previous: previous,
      pause: pause,
    );
    final playback = this.playback;
    final audio = this.audio;
    if (playback == null || audio == null) {
      // Headless shell without audio: this is how screen tests launch app.
      _searching = false;
      _phase = AudioPhase.idle;
      _bufferingSince = null;
      notifyListeners();
      return;
    }
    _phase = AudioPhase.buffering;
    _searching = true;
    notifyListeners();
    String? streamUrl;
    try {
      // Old track stops immediately, rather than when server finds source for new one.
      await audio.pause();
      final String url;
      if (queuedTrackId == track.id &&
          queuedUrl != null &&
          !await playback.isLocal(track.id)) {
        url = queuedUrl;
      } else if (inFlightTrackId == track.id &&
          inFlightUrl != null &&
          !await playback.isLocal(track.id)) {
        url = await inFlightUrl;
      } else {
        url = await _url(track);
      }
      if (attempt != _attempt) {
        return; // while waiting for the server, another song was chosen
      }
      streamUrl = url;
      _streamUrl = url;
      _searching = false;
      notifyListeners();
      _pending = null;
      _loaded = attempt;
      await audio.playUrl(url, _metadata(track), from: from);
      if (attempt != _attempt) {
        // While source was opening, another track was selected, but player already
        // launched this opened source. If new track hasn't reached player yet,
        // this one would play under its "Buffering" — and continue on failure.
        if (_loaded == attempt) {
          await audio.pause();
        }
        return;
      }
      _live = true;
      _notifyUpcoming();
      // While source was opening, player could already report playing or
      // failed. "Paused" and "idle" during this time are loading steps, not state.
      final pending = _pending;
      _pending = null;
      if (pending != null &&
          pending.phase != AudioPhase.paused &&
          pending.phase != AudioPhase.idle) {
        _apply(pending);
      }
    } on PlaybackFailed catch (failed) {
      _fail(attempt, failed.reason);
    } catch (_) {
      // Player failed to open stream: expired token, network, server restart.
      // Previously exception escaped outwards, and screen stayed permanently
      // on "Buffering".
      if (streamUrl != null && !_streamFailedReported) {
        _streamFailedReported = true;
        unawaited(playback.failed(streamUrl));
      }
      _fail(attempt, PlayFailure.player);
    }
  }

  AudioMetadata _metadata(Track track) => AudioMetadata(
    id: track.id,
    title: track.title,
    artist: track.artist,
    artworkUrl: track.artworkUrl,
  );

  /// Error or long buffering shortly after seek — chunk from seek position
  /// is still downloading (P1b). Same stream is reopened from same
  /// position: do not ask server again, do not show "Interrupted".
  bool _reopenAfterSeek() {
    final to = _seekTo;
    final at = _seekAt;
    final url = _streamUrl;
    final track = _current;
    final audio = this.audio;
    if (to == null || at == null || url == null || track == null) {
      return false;
    }
    if (audio == null || _clock().difference(at) > seekPatience) {
      _seekTo = null;
      _seekAt = null;
      return false;
    }
    final attempt = _attempt;
    _stallTimer?.cancel();
    _stallTimer = null;
    _failure = null;
    _phase = AudioPhase.buffering;
    _bufferingSince ??= _clock();
    _live = false;
    _pending = null;
    notifyListeners();
    if (_reopenTimer != null) return true; // a reopen is already pending
    // Pause like scheduled retry: rapid consecutive errors do not
    // turn into a queue of reopen attempts.
    _reopenTimer = Timer(reconnectDelays.first, () async {
      _reopenTimer = null;
      if (attempt != _attempt) return;
      _loaded = attempt;
      try {
        await audio.playUrl(url, _metadata(track), from: to);
      } catch (_) {
        if (attempt == _attempt) {
          _seekTo = null;
          _seekAt = null;
          _resumeAt = to;
          _fail(attempt, PlayFailure.dropped);
        }
        return;
      }
      if (attempt != _attempt) {
        // While stream was opening, another track was selected — old one shouldn't
        // play under its "Buffering".
        if (_loaded == attempt) {
          await audio.pause();
        }
        return;
      }
      _live = true;
      final pending = _pending;
      _pending = null;
      if (pending != null &&
          pending.phase != AudioPhase.paused &&
          pending.phase != AudioPhase.idle) {
        _apply(pending);
      }
    });
    return true;
  }

  void _notifyUpcoming() {
    final callback = upcoming;
    if (callback == null) return;
    final ids = <String>[];
    if (_cursor >= 0) {
      for (var i = _cursor + 1; i < min(_cursor + 3, _order.length); i++) {
        ids.add(_queue[_order[i]].id);
      }
    }
    callback(ids);
  }

  void _fail(int attempt, PlayFailure reason) {
    if (attempt != _attempt) {
      return;
    }
    _searching = false;
    _phase = AudioPhase.error;
    _failure = reason;
    _bufferingSince = null;
    notifyListeners();
    if (reason == PlayFailure.noAnswer || reason == PlayFailure.dropped) {
      _scheduleRetry(attempt);
    }
  }

  void _cancelWait() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _reopenTimer?.cancel();
    _reopenTimer = null;
    _stallTimer?.cancel();
    _stallTimer = null;
  }

  /// Network lost: retry from same second after next pause.
  void _scheduleRetry(int attempt) {
    // Player can report "error" twice in a row — retry is already waiting.
    if (_retryTimer != null || _retryStep >= reconnectDelays.length) {
      return;
    }
    _retryTimer = Timer(reconnectDelays[_retryStep++], () {
      _retryTimer = null;
      final track = _current;
      if (track != null && attempt == _attempt) {
        unawaited(_start(track, from: _resumeAt, auto: true));
      }
    });
    notifyListeners();
  }

  /// Buffering drags longer than [stallAfter] — treat as drop from this second.
  void _stalled(int attempt, Duration at) {
    _stallTimer = null;
    if (attempt != _attempt || _phase != AudioPhase.buffering) {
      return;
    }
    if (_reopenAfterSeek()) return;
    _resumeAt = at;
    _failure = PlayFailure.dropped;
    _live = false;
    _phase = AudioPhase.error;
    _bufferingSince = null;
    _scheduleRetry(attempt);
    notifyListeners();
  }

  void _onAudio(AudioStatus status) {
    if (!_live && !status.advanced) {
      _pending = status;
      return;
    }
    _apply(status);
  }

  void _apply(AudioStatus status) {
    if (status.advanced) {
      _advanced(status);
      return;
    }
    final was = _phase;
    _count(status.completed ? AudioPhase.idle : status.phase);
    if (status.completed) {
      unawaited(_ended());
      return;
    }
    _duration = status.duration ?? _duration;
    if (status.phase == AudioPhase.error && _reopenAfterSeek()) {
      return;
    }
    if (status.phase == AudioPhase.playing) {
      _seekTo = null;
      _seekAt = null;
    }
    if (status.phase == AudioPhase.error) {
      // Drop in middle of track: remember second for "retry".
      _resumeAt = status.position;
      _failure = PlayFailure.dropped;
      _live = false;
      _bufferingSince = null;
      _stallTimer?.cancel();
      _stallTimer = null;
      if (status.position < badStreamThreshold && !_streamFailedReported) {
        _streamFailedReported = true;
        final url = _streamUrl;
        final playback = this.playback;
        if (url != null && playback != null) {
          unawaited(playback.failed(url));
        }
      }
    } else {
      _failure = null;
    }
    _phase = status.phase;
    if (_phase != AudioPhase.buffering) {
      _bufferingSince = null;
    } else {
      // Buffering in middle of track — own waiting, from this second.
      _bufferingSince ??= _clock();
    }
    if (_phase == AudioPhase.playing) {
      _playedOnce = true;
      _retryStep = 0;
      _prepareNext();
    }
    if (_phase == AudioPhase.buffering) {
      if (_playedOnce && _stallTimer == null) {
        final attempt = _attempt;
        final at = status.position;
        _stallTimer = Timer(stallAfter, () => _stalled(attempt, at));
      }
    } else {
      _stallTimer?.cancel();
      _stallTimer = null;
    }
    if (_phase == AudioPhase.error) {
      _scheduleRetry(_attempt);
    }
    // Pause is possibly the last thing user did before closing
    // the app: without sending here track would disappear from history.
    if (was == AudioPhase.playing && _phase == AudioPhase.paused) {
      _report();
    }
    notifyListeners();
  }

  void _advanced(AudioStatus status) {
    _count(AudioPhase.idle);
    if (_heard <= _reported) {
      _heard = Duration(milliseconds: _current?.durationMs ?? 1);
    }
    _report();
    _heard = Duration.zero;
    _reported = Duration.zero;
    _resumeFromMemory = false;
    final attempt = ++_attempt;
    _cancelWait();
    _playedOnce = false;
    _retryStep = 0;
    _loaded = attempt;
    _live = true;
    _cursor = (_cursor + 1) % _order.length;
    _current = _queue[_order[_cursor]];
    _failure = null;
    _resumeAt = Duration.zero;
    _seekTo = null;
    _seekAt = null;
    _streamUrl = _queuedUrl;
    _streamFailedReported = false;
    _duration = status.duration;
    _searching = false;
    _queuedTrackId = null;
    _queuedUrl = null;
    audio?.setSkips(
      next: hasNext ? next : null,
      previous: previous,
      pause: pause,
    );
    _count(status.phase);
    _phase = status.phase;
    if (_phase != AudioPhase.buffering) {
      _bufferingSince = null;
    } else {
      // Buffering in middle of track — own waiting, from this second.
      _bufferingSince ??= _clock();
    }
    _notifyUpcoming();
    notifyListeners();
    if (_phase == AudioPhase.playing) {
      _prepareNext();
    }
  }

  /// Listening clock: accumulates time in "playing" phase and stops in
  /// any other — pause and buffering do not go into history.
  void _count(AudioPhase next) {
    final now = _clock();
    final since = _playingSince;
    if (since != null) {
      _heard += now.difference(since);
    }
    _playingSince = next == AudioPhase.playing ? now : null;
  }

  /// Send to history how long current track played if increased since last
  /// send. Server error does not hinder audio.
  void _report() {
    final track = _current;
    final listened = this.listened;
    if (track == null || listened == null || _heard <= _reported) {
      return;
    }
    _reported = _heard;
    listened(
      track.id,
      _heard.inMilliseconds,
      artworkUrl: track.artworkUrl,
    ).ignore();
  }

  /// Track finished: repeat one, next, or silence at end of queue.
  Future<void> _ended() async {
    _report();
    _heard = Duration.zero;
    _reported = Duration.zero;
    if (_stopAfterCurrent) {
      _stopAfterCurrent = false;
      _searching = false;
      _phase = AudioPhase.idle;
      _bufferingSince = null;
      notifyListeners();
      return;
    }
    if (_repeat == Repeat.one) {
      await audio?.seek(Duration.zero);
      await audio?.resume();
      return;
    }
    if (hasNext) {
      await next();
      return;
    }
    _searching = false;
    _phase = AudioPhase.idle;
    _bufferingSince = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _cancelWait();
    _stopAfterCurrent = false;
    _queuedTrackId = null;
    _queuedUrl = null;
    audio?.clearNext().ignore();
    audio?.setSkips();
    _subscription?.cancel();
    super.dispose();
  }
}

enum Repeat { off, all, one }
