import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:music_stream/offline/track_store.dart';
import 'package:music_stream/server_api.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum DownloadStatus { waiting, preparing, downloading, done, failed }

enum QueueHold { none, metered, noRoom }

class TransferJob {
  const TransferJob({
    required this.trackId,
    required this.url,
    required this.headers,
    required this.file,
    required this.expectedBytes,
    required this.unmeteredOnly,
  });

  final String trackId;
  final Uri url;
  final Map<String, String> headers;
  final File file;
  final int expectedBytes;
  final bool unmeteredOnly;
}

abstract class FileTransfer {
  Future<bool> fetch(TransferJob job);
  Future<void> cancel(String trackId);
}

/// Download queue to device (FT-526, Р-A60).
class DownloadQueue {
  DownloadQueue({
    required this.server,
    required this.store,
    required this.transfer,
    required this.isMetered,
  });

  final ServerApi server;
  final TrackStore store;
  final FileTransfer transfer;
  final Future<bool> Function() isMetered;

  final List<String> _items = [];
  final Map<String, DownloadStatus> _statuses = {};
  QueueHold _hold = QueueHold.none;
  bool _loaded = false;
  static bool _askedPermissions = false;

  QueueHold get hold => _hold;

  DownloadStatus? statusOf(String id) => _statuses[id];

  ({int done, int total}) get progress {
    final done = _items
        .where((id) => _statuses[id] == DownloadStatus.done)
        .length;
    return (done: done, total: _items.length);
  }

  Future<bool> allowMobile() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('download_queue_${store.namespace}_allow_mobile') ??
        false;
  }

  Future<void> setAllowMobile(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(
      'download_queue_${store.namespace}_allow_mobile',
      value,
    );
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    final saved =
        prefs.getStringList('download_queue_${store.namespace}_items') ?? [];
    for (final id in saved) {
      if (!_items.contains(id)) {
        _items.add(id);
      }
      final file = await store.fileFor(id);
      if (file != null) {
        _statuses[id] = DownloadStatus.done;
      } else {
        _statuses.putIfAbsent(id, () => DownloadStatus.waiting);
      }
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'download_queue_${store.namespace}_items',
      _items,
    );
  }

  Future<void> _askNotificationPermission() async {
    if (_askedPermissions) return;
    _askedPermissions = true;
    try {
      final permissions = FileDownloader().permissions;
      final status = await permissions.status(PermissionType.notifications);
      if (status != PermissionStatus.granted) {
        await permissions.request(PermissionType.notifications);
      }
    } catch (_) {
      // Denial or missing platform channel in tests does not prevent downloading.
    }
  }

  Future<void> add(List<String> ids) async {
    await _ensureLoaded();
    await _askNotificationPermission();
    final toRequest = <String>[];
    for (final id in ids) {
      if (!_items.contains(id)) {
        _items.add(id);
      }
      final existingFile = await store.fileFor(id);
      if (existingFile != null) {
        await store.promote(id);
        _statuses[id] = DownloadStatus.done;
      } else {
        _statuses[id] = DownloadStatus.waiting;
        toRequest.add(id);
      }
    }
    await _save();
    if (toRequest.isNotEmpty) {
      try {
        await server.requestDownloads(toRequest);
      } catch (_) {}
    }
  }

  Future<void> remove(List<String> ids) async {
    await _ensureLoaded();
    for (final id in ids) {
      await transfer.cancel(id);
      await store.remove(id);
      for (final format in const ['opus', 'mp3', 'flac', 'm4a', 'aac', 'ogg']) {
        final part = store.partFile(id, format: format);
        if (await part.exists()) {
          await part.delete();
        }
      }
      _items.remove(id);
      _statuses.remove(id);
    }
    await _save();
    try {
      await server.removeDownloads(ids);
    } catch (_) {}
  }

  Future<void> tick() async {
    await _ensureLoaded();

    final List<Map<String, dynamic>> serverItems;
    try {
      serverItems = await server.downloads();
    } catch (_) {
      return;
    }

    final byId = <String, Map<String, dynamic>>{};
    for (final item in serverItems) {
      final id = item['track_id']?.toString();
      if (id != null) {
        byId[id] = item;
      }
    }

    final readyToFetch = <(String id, String format, int bytes)>[];

    for (final id in _items) {
      if (_statuses[id] == DownloadStatus.done) {
        continue;
      }
      final item = byId[id];
      if (item == null) {
        _statuses[id] = DownloadStatus.preparing;
        continue;
      }
      final state = item['state'] as String?;
      if (state == 'failed') {
        _statuses[id] = DownloadStatus.failed;
      } else if (state == 'ready') {
        final format = (item['format'] as String?) ?? 'opus';
        final bytes = (item['bytes'] as int?) ?? 0;
        readyToFetch.add((id, format, bytes));
      } else {
        _statuses[id] = DownloadStatus.preparing;
      }
    }

    if (readyToFetch.isEmpty) {
      return;
    }

    final allowMobile = await this.allowMobile();
    final metered = await isMetered();
    if (!allowMobile && metered) {
      _hold = QueueHold.metered;
      return;
    }

    if (!await store.roomForDownload()) {
      _hold = QueueHold.noRoom;
      return;
    }

    _hold = QueueHold.none;

    // All ready tracks go to system download at once: that way group notification
    // counts "3 of 12" rather than "0 of 1" for each single track.
    final fetches = <Future<void>>[];
    for (final (id, format, bytes) in readyToFetch) {
      if (!await store.roomForDownload()) {
        _hold = QueueHold.noRoom;
        break;
      }

      final part = store.partFile(id, format: format);
      final uri = Uri.parse(server.url('/v1/downloads/$id/file'));
      final headers = server.tokens.headersFor(uri);

      _statuses[id] = DownloadStatus.downloading;

      final job = TransferJob(
        trackId: id,
        url: uri,
        headers: headers,
        file: part,
        expectedBytes: bytes,
        unmeteredOnly: !allowMobile,
      );

      fetches.add(_fetch(job, format));
    }
    await Future.wait(fetches);
  }

  Future<void> _fetch(TransferJob job, String format) async {
    final id = job.trackId;
    final part = job.file;
    final success = await transfer.fetch(job);
    if (success &&
        await part.exists() &&
        await part.length() == job.expectedBytes) {
      await store.commit(id, format: format, hold: Hold.download);
      _statuses[id] = DownloadStatus.done;
      try {
        await server.removeDownloads([id]);
      } catch (_) {}
    } else {
      if (await part.exists()) {
        await part.delete();
      }
      _statuses[id] = DownloadStatus.waiting;
    }
  }
}
