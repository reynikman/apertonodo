import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../auth/token_provider.dart';
import '../playback.dart';
import '../track_formats.dart';
import 'track_store.dart';

class OfflinePlayback implements PlaybackPort {
  OfflinePlayback({
    required this.inner,
    required this.store,
    required this.tokens,
    this.formats,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final PlaybackPort inner;
  final Future<TrackStore> store;
  final TokenProvider tokens;

  /// Format badge for downloaded track: file extension is its format.
  final TrackFormats? formats;
  final http.Client _client;
  final _downloadingAhead = <String>{};
  final _cachingForPlayer = <String>{};
  var _cacheSequence = 0;

  /// Last started track — "Clear cache" does not touch it.
  String? playing;

  @override
  Future<String> start(String trackId, {bool prepare = false}) async {
    if (!prepare) playing = trackId;
    final s = await store;
    final file = await s.fileFor(trackId);
    if (file != null) {
      final dot = file.path.lastIndexOf('.');
      formats?.note(trackId, {'format': file.path.substring(dot + 1)});
      if (!prepare) {
        await s.markPlayed(trackId);
      }
      return Uri.file(file.path).toString();
    }
    return inner.start(trackId, prepare: prepare);
  }

  @override
  Future<bool> isLocal(String trackId) async =>
      await (await store).fileFor(trackId) != null;

  @override
  Future<void> failed(String url) => inner.failed(url);

  static String? _formatFromMime(String mime) {
    final clean = mime.split(';').first.trim().toLowerCase();
    return switch (clean) {
      'audio/ogg' || 'audio/opus' => 'opus',
      'audio/flac' => 'flac',
      'audio/mpeg' => 'mp3',
      'audio/mp4' => 'm4a',
      _ => null,
    };
  }

  static String _hash(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  Future<void> ahead(List<String> ids) async {
    final s = await store;
    final targets = <String>[];
    for (final id in ids) {
      if (await s.fileFor(id) == null && !_cachingForPlayer.contains(id)) {
        targets.add(id);
        if (targets.length == 2) break;
      }
    }
    if (targets.isEmpty) return;

    for (final id in targets) {
      if (_cachingForPlayer.contains(id) || await s.fileFor(id) != null) {
        continue;
      }
      _downloadingAhead.add(id);
      File? part;
      try {
        final streamUrl = await inner.start(id, prepare: true);
        final uri = Uri.parse(streamUrl);
        final request = http.Request('GET', uri);
        request.headers.addAll(tokens.headersFor(uri));
        final response = await _client.send(request);
        if (response.statusCode >= 200 && response.statusCode < 300) {
          final contentType = response.headers['content-type'] ?? '';
          final format = _formatFromMime(contentType);
          if (format != null) {
            part = s.partFile(id, format: format);
            await part.parent.create(recursive: true);
            final sink = part.openWrite();
            try {
              await response.stream.pipe(sink);
            } catch (_) {
              await sink.close();
              rethrow;
            }
            await s.commit(id, format: format, hold: Hold.reserve);
            part = null;
          }
        }
      } catch (_) {
        // Errors silently, don't leave .part behind
      } finally {
        _downloadingAhead.remove(id);
        if (part != null && await part.exists()) {
          try {
            await part.delete();
          } catch (_) {}
        }
      }
    }

    try {
      await s.evict(keep: targets.toSet());
    } catch (_) {}
  }

  Future<File?> cacheFileFor(String trackId) async {
    if (_downloadingAhead.contains(trackId)) return null;
    final s = await store;
    if (_downloadingAhead.contains(trackId)) return null;
    final limit = await s.reserveLimitBytes();
    if (limit <= 0) return null;
    final dummyPart = s.partFile(trackId, format: 'opus');
    final cacheDir = Directory('${dummyPart.parent.path}/cache');
    final seq = ++_cacheSequence;
    final file = File('${cacheDir.path}/${_hash('cache-$trackId-$seq')}');
    _cachingForPlayer.add(trackId);
    return file;
  }

  Future<void> adopt(String trackId, File cache) async {
    File? part;
    try {
      final s = await store;
      if (await s.fileFor(trackId) != null) {
        try {
          if (await cache.exists()) await cache.delete();
        } catch (_) {}
        try {
          final mimeFile = File('${cache.path}.mime');
          if (await mimeFile.exists()) await mimeFile.delete();
        } catch (_) {}
        return;
      }
      if (!await cache.exists()) return;
      final mimeFile = File('${cache.path}.mime');
      if (!await mimeFile.exists()) return;
      final mime = (await mimeFile.readAsString()).trim();
      final format = _formatFromMime(mime);
      if (format == null) return;

      part = s.partFile(trackId, format: format);
      await part.parent.create(recursive: true);
      await cache.rename(part.path);
      await s.commit(trackId, format: format, hold: Hold.reserve);
      part = null;
      if (await mimeFile.exists()) {
        await mimeFile.delete();
      }
      await s.evict();
    } catch (_) {
      // Errors silently
    } finally {
      _cachingForPlayer.remove(trackId);
      if (part != null && await part.exists()) {
        try {
          await part.delete();
        } catch (_) {}
        try {
          final mimeFile = File('${cache.path}.mime');
          if (await mimeFile.exists()) {
            await mimeFile.delete();
          }
        } catch (_) {}
      }
    }
  }
}
