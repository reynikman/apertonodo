import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../device_info.dart';
import '../l10n/l10n.dart';
import '../models/track.dart';
import '../theme.dart';
import 'cover_store.dart';
import 'download_queue.dart';
import 'track_store.dart';

enum DownloadMark { none, progress, done }

class DownloadedTrack {
  const DownloadedTrack({
    required this.track,
    required this.status,
    this.bytes,
  });

  final Track track;
  final DownloadStatus status;
  final int? bytes;
}

abstract class DownloadsPort extends ChangeNotifier {
  DownloadStatus? statusOf(String trackId);
  List<DownloadedTrack> get items;
  ({int done, int total}) get progress;
  QueueHold get hold;
  bool get allowMobile;
  int get reserveLimitBytes;
  int? get freeBytes;

  int get downloadBytes;
  int get reserveBytes;
  Future<void> clearReserve();
  Future<void> removeAll();

  Future<void> download(List<Track> tracks, {String? playlist});
  Future<void> remove(List<String> trackIds, {String? playlist});
  Future<void> setAllowMobile(bool value);
  Future<void> setReserveLimit(int bytes);
  Future<void> playlistLoaded(String playlistId, List<Track> tracks);

  DownloadMark markOf(List<String> ids) {
    if (ids.isEmpty) return DownloadMark.none;
    var anyProgress = false;
    var allDone = true;
    for (final id in ids) {
      final status = statusOf(id);
      if (status == DownloadStatus.waiting ||
          status == DownloadStatus.preparing ||
          status == DownloadStatus.downloading) {
        anyProgress = true;
      }
      if (status != DownloadStatus.done) {
        allDone = false;
      }
    }
    if (allDone) return DownloadMark.done;
    if (anyProgress) return DownloadMark.progress;
    return DownloadMark.none;
  }
}

class Downloads extends DownloadsPort {
  Downloads({
    required this.queue,
    required this.store,
    this.covers,
    this.poll = const Duration(seconds: 3),
    Future<int?> Function()? freeBytes,
    this.activeTracks,
  }) : _getFreeBytes = freeBytes ?? DeviceInfo.freeBytes;

  final DownloadQueue queue;
  final TrackStore store;
  final CoverStore? covers;
  final Duration poll;
  final Future<int?> Function() _getFreeBytes;
  final Set<String> Function()? activeTracks;

  final Map<String, Track> _tracks = {};
  final Map<String, int> _bytes = {};
  final Set<String> _playlists = {};

  bool _allowMobile = false;
  int _reserveLimitBytes = 10 * 1024 * 1024 * 1024;
  int? _freeBytes;
  int _downloadBytes = 0;
  int _reserveBytes = 0;
  Timer? _timer;
  bool _ticking = false;
  bool _disposed = false;

  @override
  int get downloadBytes => _downloadBytes;

  @override
  int get reserveBytes => _reserveBytes;

  Future<void> _updateUsage() async {
    try {
      final usage = await store.usage();
      _downloadBytes = usage.downloadBytes;
      _reserveBytes = usage.reserveBytes;
    } catch (_) {}
  }

  @override
  bool get allowMobile => _allowMobile;

  @override
  int get reserveLimitBytes => _reserveLimitBytes;

  @override
  int? get freeBytes => _freeBytes;

  @override
  QueueHold get hold => queue.hold;

  @override
  DownloadStatus? statusOf(String trackId) {
    if (_bytes.containsKey(trackId)) return DownloadStatus.done;
    final status = queue.statusOf(trackId);
    if (status == DownloadStatus.done) {
      return DownloadStatus.downloading;
    }
    if (status != null) return status;
    if (_tracks.containsKey(trackId)) return DownloadStatus.waiting;
    return null;
  }

  @override
  List<DownloadedTrack> get items => [
    for (final entry in _tracks.entries)
      DownloadedTrack(
        track: entry.value,
        status: statusOf(entry.key) ?? DownloadStatus.waiting,
        bytes: _bytes[entry.key],
      ),
  ];

  @override
  ({int done, int total}) get progress {
    var done = 0;
    for (final id in _tracks.keys) {
      if (statusOf(id) == DownloadStatus.done) {
        done++;
      }
    }
    return (done: done, total: _tracks.length);
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _allowMobile = await queue.allowMobile();
    _reserveLimitBytes = await store.reserveLimitBytes();
    try {
      _freeBytes = await _getFreeBytes();
    } catch (_) {}

    final savedPlaylists =
        prefs.getStringList('downloads_${store.namespace}_playlists') ?? [];
    _playlists.addAll(savedPlaylists);

    final rawTracks = prefs.getString('downloads_${store.namespace}_tracks');
    if (rawTracks != null) {
      try {
        final decoded = jsonDecode(rawTracks) as Map<String, dynamic>;
        for (final entry in decoded.entries) {
          _tracks[entry.key] = Track.fromJson(
            entry.value as Map<String, dynamic>,
          );
        }
      } catch (_) {}
    }

    for (final id in _tracks.keys) {
      final file = await store.fileFor(id);
      if (file != null) {
        _bytes[id] = await file.length();
      }
    }

    await queue.tick();

    for (final id in _tracks.keys) {
      if (queue.statusOf(id) == DownloadStatus.done && _bytes[id] == null) {
        final file = await store.fileFor(id);
        if (file != null) {
          _bytes[id] = await file.length();
        }
      }
    }

    // Without awaiting: without network each cover would await timeout, and
    // "Downloaded" on cold start would open with delay.
    unawaited(_keepMissingCovers());

    await _updateUsage();
    notifyListeners();
    _startPolling();
  }

  bool _hasUnfinished() {
    for (final id in _tracks.keys) {
      final status = statusOf(id);
      if (status != DownloadStatus.done && status != DownloadStatus.failed) {
        return true;
      }
    }
    return false;
  }

  void _startPolling() {
    if (_disposed) return;
    if (_timer != null) return;
    if (!_hasUnfinished()) return;
    _timer = Timer.periodic(poll, (_) => unawaited(_tick()));
  }

  Future<void> _tick() async {
    if (_disposed || _ticking) return;
    _ticking = true;
    try {
      await queue.tick();
      if (_disposed) return;
      for (final id in _tracks.keys) {
        if (_disposed) return;
        if (queue.statusOf(id) == DownloadStatus.done && _bytes[id] == null) {
          final file = await store.fileFor(id);
          if (_disposed) return;
          if (file != null) {
            _bytes[id] = await file.length();
          }
        }
      }
      try {
        _freeBytes = await _getFreeBytes();
      } catch (_) {}
      if (_disposed) return;
      await _updateUsage();
      if (_disposed) return;
      notifyListeners();
    } catch (_) {
    } finally {
      _ticking = false;
    }
    if (_disposed) return;
    if (!_hasUnfinished()) {
      _timer?.cancel();
      _timer = null;
    }
  }

  /// Covers of downloaded tracks that did not finish before network disconnection.
  Future<void> _keepMissingCovers() async {
    final coverStore = covers;
    if (coverStore == null) return;
    final urls = {
      for (final entry in _tracks.entries)
        if (_bytes.containsKey(entry.key)) entry.value.artworkUrl,
    };
    for (final url in urls) {
      if (_disposed) return;
      if (url.isNotEmpty && coverStore.fileFor(url) == null) {
        await coverStore.keep(url);
      }
    }
  }

  Future<void> _saveTracks() async {
    final prefs = await SharedPreferences.getInstance();
    final data = {
      for (final entry in _tracks.entries) entry.key: entry.value.toJson(),
    };
    await prefs.setString(
      'downloads_${store.namespace}_tracks',
      jsonEncode(data),
    );
  }

  @override
  Future<void> download(List<Track> tracks, {String? playlist}) async {
    if (playlist != null) {
      _playlists.add(playlist);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        'downloads_${store.namespace}_playlists',
        _playlists.toList(),
      );
    }
    for (final track in tracks) {
      _tracks[track.id] = track;
    }
    await _saveTracks();
    await queue.add([for (final t in tracks) t.id]);
    // Tracks are queued first, cover follows, one per album.
    final coverStore = covers;
    if (coverStore != null) {
      for (final url in {for (final t in tracks) t.artworkUrl}) {
        if (url.isNotEmpty) await coverStore.keep(url);
      }
    }
    for (final t in tracks) {
      if (queue.statusOf(t.id) == DownloadStatus.done && _bytes[t.id] == null) {
        final file = await store.fileFor(t.id);
        if (file != null) {
          _bytes[t.id] = await file.length();
        }
      }
    }
    await _updateUsage();
    notifyListeners();
    _startPolling();
  }

  @override
  Future<void> remove(List<String> trackIds, {String? playlist}) async {
    await queue.remove(trackIds);
    final droppedCovers = <String>{};
    for (final id in trackIds) {
      final track = _tracks[id];
      if (track != null && track.artworkUrl.isNotEmpty) {
        droppedCovers.add(track.artworkUrl);
      }
      _tracks.remove(id);
      _bytes.remove(id);
    }
    if (playlist != null) {
      // Playlist removed from device is not automatically downloaded further (FT-540).
      _playlists.remove(playlist);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        'downloads_${store.namespace}_playlists',
        _playlists.toList(),
      );
    }
    await _saveTracks();
    final coverStore = covers;
    if (coverStore != null && droppedCovers.isNotEmpty) {
      final remainingCovers = <String>{};
      for (final t in _tracks.values) {
        if (t.artworkUrl.isNotEmpty) {
          remainingCovers.add(t.artworkUrl);
        }
      }
      for (final cover in droppedCovers) {
        if (!remainingCovers.contains(cover)) {
          await coverStore.drop(cover);
        }
      }
    }
    await _updateUsage();
    notifyListeners();
    if (!_hasUnfinished()) {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  Future<void> clearReserve() async {
    final keep = activeTracks?.call() ?? const <String>{};
    await store.clearReserve(keep: keep);
    await _updateUsage();
    notifyListeners();
  }

  @override
  Future<void> removeAll() async {
    _playlists.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('downloads_${store.namespace}_playlists', []);
    await remove(_tracks.keys.toList());
  }

  @override
  Future<void> setAllowMobile(bool value) async {
    await queue.setAllowMobile(value);
    _allowMobile = value;
    notifyListeners();
    _startPolling();
  }

  @override
  Future<void> setReserveLimit(int bytes) async {
    await store.setReserveLimitBytes(bytes);
    _reserveLimitBytes = bytes;
    notifyListeners();
  }

  @override
  Future<void> playlistLoaded(String playlistId, List<Track> tracks) async {
    if (!_playlists.contains(playlistId)) return;
    final newTracks = tracks.where((t) => !_tracks.containsKey(t.id)).toList();
    if (newTracks.isNotEmpty) {
      await download(newTracks, playlist: playlistId);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}

class DownloadStateMark extends StatelessWidget {
  const DownloadStateMark(this.mark, {super.key, this.size = 20});

  final DownloadMark mark;
  final double size;

  @override
  Widget build(BuildContext context) {
    return switch (mark) {
      DownloadMark.none => Icon(
        Icons.arrow_downward,
        key: const Key('download-state-none'),
        size: size,
        color: ApertonoColors.textSecondary,
      ),
      DownloadMark.progress => SizedBox.square(
        dimension: size,
        child: const CircularProgressIndicator(
          key: Key('download-state-progress'),
          strokeWidth: 2,
        ),
      ),
      DownloadMark.done => Icon(
        Icons.check,
        key: const Key('download-state-done'),
        size: size,
        color: ApertonoColors.accent,
      ),
    };
  }
}

/// "Download" button (FT-540, FT-795): "Download all" — not downloaded yet,
/// "Downloading N of M" — in progress (with words), downloaded — only badge
/// with long press tooltip ("Downloaded to device"). Tapping in-progress
/// or downloaded does not re-download, but opens "Delete from device" sheet.
class DownloadAllButton extends StatelessWidget {
  const DownloadAllButton({
    super.key,
    required this.downloads,
    required this.tracks,
    this.playlist,
  });

  final DownloadsPort downloads;
  final List<Track> tracks;
  final String? playlist;

  @override
  Widget build(BuildContext context) {
    final ids = [for (final track in tracks) track.id];
    return ListenableBuilder(
      listenable: downloads,
      builder: (context, _) {
        final text = l10n(context);
        final mark = downloads.markOf(ids);
        if (mark == DownloadMark.done) {
          return IconButton(
            tooltip: text.downloadsOnPhone,
            icon: DownloadStateMark(mark),
            onPressed: () => _removeFromPhone(context, ids),
          );
        }
        return TextButton.icon(
          icon: DownloadStateMark(mark),
          label: Text(
            switch (mark) {
              DownloadMark.none => text.downloadsDownloadAll,
              DownloadMark.progress => text.downloadsDownloading(
                _done(ids),
                ids.length,
              ),
              DownloadMark.done => text.downloadsOnPhone,
            },
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onPressed: mark == DownloadMark.none
              ? () => downloads.download(tracks, playlist: playlist)
              : () => _removeFromPhone(context, ids),
        );
      },
    );
  }

  int _done(List<String> ids) => [
    for (final id in ids)
      if (downloads.statusOf(id) == DownloadStatus.done) id,
  ].length;

  /// "12 songs · 180 MB on device" — how much space will be freed.
  String _onPhone(List<String> ids, AppLocalizations text) {
    final wanted = ids.toSet();
    var songs = 0;
    var bytes = 0;
    for (final item in downloads.items) {
      if (!wanted.contains(item.track.id) || item.bytes == null) continue;
      songs++;
      bytes += item.bytes!;
    }
    final mb = (bytes / (1024 * 1024)).round();
    return text.downloadsOnPhoneDetail(text.downloadsSongs(songs), mb);
  }

  /// Sheet: how much space is on device and one "Delete from device" row.
  Future<void> _removeFromPhone(BuildContext context, List<String> ids) async {
    final text = l10n(context);
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      useRootNavigator: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _onPhone(ids, text),
                key: const Key('download-on-phone'),
                style: ApertonoText.trackArtist,
              ),
              ListTile(
                minTileHeight: 48,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  text.downloadsRemoveFromPhone,
                  style: ApertonoText.trackTitle,
                ),
                onTap: () => Navigator.pop(context, true),
              ),
            ],
          ),
        ),
      ),
    );
    if (confirmed != true) return;
    await downloads.remove(ids, playlist: playlist);
  }
}
