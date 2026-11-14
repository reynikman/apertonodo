import 'dart:async';

import 'package:flutter/services.dart';
import 'package:music_stream/device_library.dart';
import 'package:music_stream/models/track.dart';
import 'package:music_stream/playback.dart';

/// "Open with" (FT-767): audio file from file manager or
/// messenger plays directly from device, via system `content://` URI,
/// bypassing server. Server does not know this file: it doesn't go to history or reports.
class OpenedPlayback implements PlaybackPort {
  OpenedPlayback(this.inner);

  final PlaybackPort inner;
  final _uris = <String, String>{};
  var _next = 0;

  static bool isOpened(String trackId) => trackId.startsWith('opened:');

  /// Track for player and saving its URI.
  Track open(String uri, String name) {
    final id = 'opened:${_next++}';
    _uris[id] = uri;
    return Track(
      id: id,
      title: name.isEmpty ? uri.split('/').last : name,
      artist: '',
      durationMs: 0,
      artworkUrl: '',
    );
  }

  /// Track for device song and saving its URI (FT-783).
  Track openSong(DeviceSong song) {
    // Song URI in media library is permanent: one song — one ID, list does not grow.
    final id = 'opened:${song.uri}';
    _uris[id] = song.uri;
    return Track(
      id: id,
      title: song.title.isEmpty ? song.uri.split('/').last : song.title,
      artist: song.artist,
      durationMs: song.durationMs,
      artworkUrl: '',
    );
  }

  @override
  Future<String> start(String trackId, {bool prepare = false}) async {
    if (!isOpened(trackId)) return inner.start(trackId, prepare: prepare);
    final uri = _uris[trackId];
    // File from previous launch: system permission for it is already gone.
    if (uri == null) throw const PlaybackFailed(PlayFailure.unknownTrack);
    return uri;
  }

  @override
  Future<bool> isLocal(String trackId) =>
      isOpened(trackId) ? Future.value(false) : inner.isLocal(trackId);

  @override
  Future<void> failed(String url) async {
    // Failure of device file means nothing to server.
    if (_uris.containsValue(url)) return;
    await inner.failed(url);
  }
}

/// Channel to `MainActivity`: file app was opened with, and files
/// opened while it was already running.
class OpenedAudioChannel {
  OpenedAudioChannel([MethodChannel? channel])
    : _channel = channel ?? const MethodChannel('apertono/open');

  final MethodChannel _channel;

  /// [onOpen] receives URI and file name. First — launch file, if any.
  Future<void> listen(void Function(String uri, String name) onOpen) async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'openAudio') _deliver(call.arguments, onOpen);
    });
    try {
      _deliver(await _channel.invokeMethod<Object?>('initialAudio'), onOpen);
    } on MissingPluginException {
      // Tests and platforms without channel: nothing to open.
    } on PlatformException {
      // System did not provide file — app simply opens.
    }
  }

  void stop() => _channel.setMethodCallHandler(null);

  static void _deliver(
    Object? arguments,
    void Function(String uri, String name) onOpen,
  ) {
    if (arguments is! Map) return;
    final uri = arguments['uri'];
    final name = arguments['name'];
    if (uri is! String || uri.isEmpty) return;
    onOpen(uri, name is String ? name : '');
  }
}
