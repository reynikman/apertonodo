// ignore_for_file: experimental_member_use
import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

import 'auth/token_provider.dart';
import 'playback.dart';
import 'system_session.dart';

/// System session of the process; `initBackgroundAudio` starts it.
SystemSession? systemSession;

IndexedAudioSource buildAudioSource(
  String url,
  AudioMetadata metadata, {
  TokenProvider? tokens,
  File? cacheFile,
}) {
  final streamUri = Uri.parse(url);
  final parsed = Uri.tryParse(metadata.artworkUrl);
  final Uri? artUri;
  final Map<String, String>? artHeaders;
  if (metadata.artworkUrl.isEmpty) {
    artUri = null;
    artHeaders = null;
  } else if (parsed?.hasScheme == true) {
    artUri = parsed;
    artHeaders = null;
  } else if (tokens != null) {
    // Artwork is stored on login server. Address hardcoded in build will not do: in
    // production build it is empty (address entered on login). Deriving from song URL
    // is also impossible: cached song is a local file, yielding file:///v1/covers/...,
    // on which Play crashed before player (FT-535).
    artUri = tokens.server.resolve(metadata.artworkUrl);
    final headers = tokens.headersFor(artUri);
    artHeaders = headers.isEmpty ? null : headers;
  } else {
    artUri = streamUri.resolve(metadata.artworkUrl);
    artHeaders = null;
  }
  final tag = MediaItem(
    id: metadata.id,
    album: 'Apertono',
    title: metadata.title,
    artist: metadata.artist,
    artUri: artUri,
    // Android downloads artwork itself by artUri; artHeaders is its only way
    // to receive the bearer. TokenProvider limits it to our own origin.
    artHeaders: artHeaders,
  );
  // Phone file: local or handed by system ("Open with", FT-767).
  if (streamUri.scheme == 'file' || streamUri.scheme == 'content') {
    return AudioSource.uri(streamUri, headers: null, tag: tag);
  }
  final streamHeaders =
      tokens?.headersFor(streamUri) ?? const <String, String>{};
  // ExoPlayer fetches the file with Range requests; each one needs the bearer
  // or the song stops halfway. One value for both paths: the negative control
  // `stream-key` breaks it here, whichever path the player takes.
  final authHeaders = streamHeaders.isEmpty ? null : streamHeaders;
  if (cacheFile != null) {
    return LockCachingAudioSource(
      streamUri,
      headers: authHeaders,
      cacheFile: cacheFile,
      tag: tag,
    );
  }
  return AudioSource.uri(streamUri, headers: authHeaders, tag: tag);
}

/// UI phase according to state of the real player.
///
/// Two just_audio pitfalls that caused UI to say "Playing" in silence
/// (audit September 18). On stream error player transitions to idle, but playing flag
/// remains true: Android reports an error, but playing is cleared only by
/// pause and stop. After song completion — completed with the same playing.
AudioPhase phaseOf(ProcessingState state, {required bool playing}) {
  return switch (state) {
    ProcessingState.loading ||
    ProcessingState.buffering => AudioPhase.buffering,
    ProcessingState.ready => playing ? AudioPhase.playing : AudioPhase.paused,
    ProcessingState.completed => AudioPhase.idle,
    ProcessingState.idle => playing ? AudioPhase.error : AudioPhase.idle,
  };
}

class DeviceAudio implements AudioPort {
  DeviceAudio({
    AudioPlayer? player,
    this.tokens,
    SystemSession? session,
    this.reserveCache,
    this.onCached,
    AndroidEqualizer? equalizer,
  }) : _player =
           player ??
           // Without this flag just_audio launches its own local HTTP proxy on
           // phone solely to inject headers, and requests cleartext traffic
           // permission. ExoPlayer can send them itself — setDefaultRequestProperties.
           AudioPlayer(
             useProxyForRequestHeaders: false,
             audioPipeline: equalizer == null
                 ? null
                 : AudioPipeline(androidAudioEffects: [equalizer]),
             // A minute of already played audio stays in memory. By default ExoPlayer
             // discards it immediately, and seeking ten seconds back means
             // another network request and more waiting. Slow sources can be
             // slow, and a brief seek backward is the most annoying wait.
             // Other buffer sizes stay untouched.
             audioLoadConfiguration: const AudioLoadConfiguration(
               androidLoadControl: AndroidLoadControl(
                 backBufferDuration: Duration(seconds: 60),
               ),
             ),
           ),
       _session = session ?? systemSession {
    _session?.attach(_player);
  }

  final AudioPlayer _player;
  TokenProvider? tokens;
  final SystemSession? _session;
  final Future<File?> Function(String trackId)? reserveCache;
  final Future<void> Function(String trackId, File cache)? onCached;
  StreamSubscription<double>? _cacheSubscription;
  StreamSubscription<double>? _nextCacheSubscription;
  MediaItem? _nextMediaItem;
  String? _currentTrackId;

  Future<void>? _queueOp;

  Future<T> _synchronized<T>(Future<T> Function() action) async {
    final prev = _queueOp;
    final completer = Completer<T>();
    _queueOp = completer.future.then<void>((_) {}, onError: (_) {});
    if (prev != null) {
      await prev;
    }
    try {
      final result = await action();
      completer.complete(result);
      return result;
    } catch (e, st) {
      completer.completeError(e, st);
      rethrow;
    }
  }

  void bindTokens(TokenProvider tokens) => this.tokens = tokens;

  @override
  Stream<Duration> get positions => _player.positionStream;

  @override
  void setSkips({
    Future<void> Function()? next,
    Future<void> Function()? previous,
    Future<void> Function()? pause,
  }) => _session?.setSkips(next: next, previous: previous, pause: pause);

  /// Position of the real player. Android does not draw frames for backgrounded app,
  /// and background scenario cannot look at screen — it looks here.
  @override
  Duration get position => _player.position;

  Future<void> _handleAdvance(StreamController<AudioStatus> controller) async {
    await _synchronized(() async {
      final nextItem = _nextMediaItem;
      if (nextItem != null) {
        _session?.show(nextItem);
        _currentTrackId = nextItem.id;
      }
      await _cacheSubscription?.cancel();
      _cacheSubscription = _nextCacheSubscription;
      _nextCacheSubscription = null;
      _nextMediaItem = null;

      try {
        if (_player.audioSources.length > 1) {
          await _player.removeAudioSourceAt(0);
        }
      } catch (_) {}

      if (!controller.isClosed) {
        controller.add(
          AudioStatus(
            phase: phaseOf(_player.processingState, playing: _player.playing),
            position: _player.position,
            duration: _player.duration,
            advanced: true,
          ),
        );
      }
    });
  }

  @override
  Stream<AudioStatus> get states {
    final subscriptions = <StreamSubscription<Object?>>[];
    late final StreamController<AudioStatus> controller;
    controller = StreamController<AudioStatus>.broadcast(
      onListen: () {
        subscriptions
          ..add(
            _player.playerStateStream.listen(
              (state) => controller.add(
                AudioStatus(
                  phase: phaseOf(state.processingState, playing: state.playing),
                  position: _player.position,
                  duration: _player.duration,
                  completed: state.processingState == ProcessingState.completed,
                ),
              ),
            ),
          )
          ..add(
            _player.currentIndexStream.listen((index) {
              if (index == 1) {
                unawaited(_handleAdvance(controller));
              }
            }),
          )
          // We also listen to stream error separately: disconnect on pause does not change
          // playing, and by state alone it cannot be distinguished from "never started".
          ..add(
            _player.errorStream.listen(
              (_) => controller.add(
                AudioStatus(
                  phase: AudioPhase.error,
                  position: _player.position,
                ),
              ),
            ),
          );
      },
      onCancel: () {
        for (final subscription in subscriptions) {
          subscription.cancel();
        }
        subscriptions.clear();
      },
    );
    return controller.stream;
  }

  @override
  Future<void> playUrl(
    String url,
    AudioMetadata metadata, {
    Duration from = Duration.zero,
  }) async {
    final tokens = this.tokens;
    if (tokens == null) {
      throw StateError('DeviceAudio has no token provider');
    }
    await _synchronized(() async {
      if (_nextMediaItem?.id == metadata.id &&
          _player.audioSources.length > 1) {
        final nextItem = _nextMediaItem!;
        _session?.show(nextItem);
        _currentTrackId = nextItem.id;
        await _cacheSubscription?.cancel();
        _cacheSubscription = _nextCacheSubscription;
        _nextCacheSubscription = null;
        _nextMediaItem = null;

        await _player.removeAudioSourceAt(0);
        await _player.seek(from);
      } else {
        _currentTrackId = metadata.id;
        await _cacheSubscription?.cancel();
        _cacheSubscription = null;
        await _nextCacheSubscription?.cancel();
        _nextCacheSubscription = null;
        _nextMediaItem = null;

        final isFile = const {
          'file',
          'content',
        }.contains(Uri.tryParse(url)?.scheme);
        final cacheFile = !isFile && reserveCache != null
            ? await reserveCache!(metadata.id)
            : null;

        final source = buildAudioSource(
          url,
          metadata,
          tokens: tokens,
          cacheFile: cacheFile,
        );
        _session?.show(source.tag as MediaItem);
        if (source is LockCachingAudioSource && cacheFile != null) {
          late final StreamSubscription<double> sub;
          sub = source.downloadProgressStream.listen((progress) {
            if (progress >= 1.0) {
              sub.cancel();
              if (_cacheSubscription == sub) _cacheSubscription = null;
              if (_nextCacheSubscription == sub) _nextCacheSubscription = null;
              unawaited(onCached?.call(metadata.id, cacheFile));
            }
          });
          _cacheSubscription = sub;
        }
        await _player.setAudioSources([source], initialPosition: from);
      }
      unawaited(_player.play());
    });
  }

  @override
  Future<void> queueNext(String url, AudioMetadata metadata) async {
    final tokens = this.tokens;
    if (tokens == null) {
      throw StateError('DeviceAudio has no token provider');
    }
    await _synchronized(() async {
      await _nextCacheSubscription?.cancel();
      _nextCacheSubscription = null;

      final isFile = const {
        'file',
        'content',
      }.contains(Uri.tryParse(url)?.scheme);
      final cacheFile =
          !isFile && reserveCache != null && metadata.id != _currentTrackId
          ? await reserveCache!(metadata.id)
          : null;

      final nextSource = buildAudioSource(
        url,
        metadata,
        tokens: tokens,
        cacheFile: cacheFile,
      );
      _nextMediaItem = nextSource.tag as MediaItem;

      if (nextSource is LockCachingAudioSource && cacheFile != null) {
        late final StreamSubscription<double> sub;
        sub = nextSource.downloadProgressStream.listen((progress) {
          if (progress >= 1.0) {
            sub.cancel();
            if (_nextCacheSubscription == sub) _nextCacheSubscription = null;
            if (_cacheSubscription == sub) _cacheSubscription = null;
            unawaited(onCached?.call(metadata.id, cacheFile));
          }
        });
        _nextCacheSubscription = sub;
      }

      if (_player.audioSources.length > 1) {
        try {
          await _player.removeAudioSourceAt(1);
        } catch (_) {}
      }
      if (_player.audioSources.isNotEmpty) {
        await _player.addAudioSource(nextSource);
      }
    });
  }

  @override
  Future<void> clearNext() async {
    await _synchronized(() async {
      await _nextCacheSubscription?.cancel();
      _nextCacheSubscription = null;
      _nextMediaItem = null;
      if (_player.audioSources.length > 1) {
        try {
          await _player.removeAudioSourceAt(1);
        } catch (_) {}
      }
    });
  }

  @override
  Future<void> pause() => _player.pause();

  /// Release the old account's source and its buffered stream on sign-out.
  @override
  Future<void> stop() async {
    await _synchronized(() async {
      _currentTrackId = null;
      await _cacheSubscription?.cancel();
      _cacheSubscription = null;
      await _nextCacheSubscription?.cancel();
      _nextCacheSubscription = null;
      _nextMediaItem = null;
      await _player.stop();
    });
  }

  @override
  Future<void> resume() => _player.play();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);
}
