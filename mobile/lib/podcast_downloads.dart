// FT-710: Podcast episode to phone (Р-A108, Пк-5).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'offline/download_queue.dart';
import 'offline/track_store.dart';

enum EpisodeDownloadState { none, downloading, onPhone, failed }

enum EpisodeDownloadResult { started, alreadyThere, noRoom, metered, badUrl }

abstract class EpisodeStore {
  File partFile(String id, {required String format});

  Future<File> commit(String id, {required String format, required Hold hold});

  Future<File?> fileFor(String id);

  Future<void> remove(String id);

  Future<bool> roomForDownload();
}

/// Downloaded episode with human description (FT-803): file itself is stored under
/// a number without words, title and podcast are remembered separately by the phone.
class DownloadedEpisode {
  const DownloadedEpisode({
    required this.id,
    required this.feedUrl,
    required this.guid,
    required this.enclosureUrl,
    required this.title,
    required this.show,
    this.durationMs,
    this.image,
  });

  final String id;
  final String feedUrl;
  final String guid;
  final String enclosureUrl;
  final String title;
  final String show;
  final int? durationMs;
  final String? image;

  Map<String, Object?> toJson() => {
    'feedUrl': feedUrl,
    'guid': guid,
    'enclosureUrl': enclosureUrl,
    'title': title,
    'show': show,
    'durationMs': durationMs,
    'image': image,
  };

  static DownloadedEpisode? fromJson(Object? json) {
    if (json is! Map) return null;
    final feedUrl = json['feedUrl'];
    final guid = json['guid'];
    final enclosureUrl = json['enclosureUrl'];
    final title = json['title'];
    final show = json['show'];
    if (feedUrl is! String ||
        guid is! String ||
        enclosureUrl is! String ||
        title is! String ||
        show is! String) {
      return null;
    }
    final durationMs = json['durationMs'];
    final image = json['image'];
    return DownloadedEpisode(
      id: PodcastDownloads.idFor(feedUrl, guid),
      feedUrl: feedUrl,
      guid: guid,
      enclosureUrl: enclosureUrl,
      title: title,
      show: show,
      durationMs: durationMs is int ? durationMs : null,
      image: image is String ? image : null,
    );
  }
}

class PodcastDownloads extends ChangeNotifier {
  PodcastDownloads({
    required this.store,
    required this.transfer,
    required this.isMetered,
    required this.allowMobile,
    this.prefs,
    this.namespace = '',
  });

  final SharedPreferences? prefs;
  final String namespace;

  /// Descriptions in download order (Map preserves insertion order).
  final Map<String, DownloadedEpisode> _described = {};

  String get _prefsKey => 'podcast_downloads_${namespace}_episodes';

  /// Remember what episode this is. Titles live only on the phone.
  void describe({
    required String feedUrl,
    required String guid,
    required String enclosureUrl,
    required String title,
    required String show,
    int? durationMs,
    String? image,
  }) {
    final id = idFor(feedUrl, guid);
    _described.remove(id);
    _described[id] = DownloadedEpisode(
      id: id,
      feedUrl: feedUrl,
      guid: guid,
      enclosureUrl: enclosureUrl,
      title: title,
      show: show,
      durationMs: durationMs,
      image: image,
    );
    _save();
  }

  /// Only episodes on the phone that have a description.
  List<DownloadedEpisode> get episodes => [
    for (final e in _described.values)
      if (_states[e.id] == EpisodeDownloadState.onPhone) e,
  ];

  void _save() {
    final box = prefs;
    if (box == null) return;
    final json = jsonEncode([for (final e in _described.values) e.toJson()]);
    box.setString(_prefsKey, json).ignore();
  }

  /// After restart: descriptions from disk; no file means no description.
  Future<void> restore() async {
    final box = prefs;
    if (box == null) return;
    final raw = box.getString(_prefsKey);
    if (raw == null) return;
    List<Object?> list;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      list = decoded;
    } catch (_) {
      return;
    }
    var dropped = false;
    for (final item in list) {
      final e = DownloadedEpisode.fromJson(item);
      if (e == null) {
        dropped = true;
        continue;
      }
      File? file;
      try {
        file = await store.fileFor(e.id);
      } catch (_) {
        file = null;
      }
      if (_disposed) return;
      if (file == null) {
        dropped = true;
        continue;
      }
      _described[e.id] = e;
      _states[e.id] = EpisodeDownloadState.onPhone;
    }
    if (dropped) _save();
    _notify();
  }

  final EpisodeStore store;
  final FileTransfer transfer;
  final Future<bool> Function() isMetered;
  final Future<bool> Function() allowMobile;

  final Map<String, EpisodeDownloadState> _states = {};
  final Map<String, Object> _activeJobs = {};
  bool _disposed = false;

  static const _supportedFormats = ['m4a', 'ogg', 'opus', 'aac', 'mp3'];

  static String idFor(String feedUrl, String guid) =>
      'podcast:${sha256.convert(utf8.encode('$feedUrl\n$guid'))}';

  static String formatOf(Uri uri) {
    final path = uri.path.toLowerCase();
    for (final ext in _supportedFormats) {
      if (path.endsWith('.$ext')) {
        return ext;
      }
    }
    return 'mp3';
  }

  final Map<String, (String feedUrl, String guid, String enclosureUrl)>
  _episodes = {};

  void registerEpisode({
    required String feedUrl,
    required String guid,
    required String enclosureUrl,
  }) {
    final id = idFor(feedUrl, guid);
    _episodes[id] = (feedUrl, guid, enclosureUrl);
  }

  EpisodeDownloadState stateOf(String feedUrl, [String? guid]) {
    final id = guid == null ? feedUrl : idFor(feedUrl, guid);
    return _states[id] ?? EpisodeDownloadState.none;
  }

  /// Same as [describe], for an episode already known by number
  /// ([registerEpisode]): player tile only knows the track.
  void describeTrack(
    String trackId, {
    required String title,
    required String show,
    int? durationMs,
    String? image,
  }) {
    final ep = _episodes[trackId];
    if (ep == null) return;
    describe(
      feedUrl: ep.$1,
      guid: ep.$2,
      enclosureUrl: ep.$3,
      title: title,
      show: show,
      durationMs: durationMs,
      image: image,
    );
  }

  Future<EpisodeDownloadResult> downloadEpisode(String trackId) async {
    final ep = _episodes[trackId];
    if (ep == null) return EpisodeDownloadResult.badUrl;
    return download(feedUrl: ep.$1, guid: ep.$2, enclosureUrl: ep.$3);
  }

  Future<File?> fileFor(String feedUrl, String guid) =>
      store.fileFor(idFor(feedUrl, guid));

  Future<EpisodeDownloadResult> download({
    required String feedUrl,
    required String guid,
    required String enclosureUrl,
  }) async {
    final uri = Uri.tryParse(enclosureUrl);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return EpisodeDownloadResult.badUrl;
    }

    final id = idFor(feedUrl, guid);
    if (_states[id] == EpisodeDownloadState.downloading ||
        _states[id] == EpisodeDownloadState.onPhone) {
      return EpisodeDownloadResult.alreadyThere;
    }

    final previousState = _states[id] ?? EpisodeDownloadState.none;
    final token = Object();
    _activeJobs[id] = token;
    _states[id] = EpisodeDownloadState.downloading;
    _notify();

    final existing = await store.fileFor(id);
    if (_activeJobs[id] != token) {
      return EpisodeDownloadResult.alreadyThere;
    }
    if (existing != null) {
      _activeJobs.remove(id);
      _states[id] = EpisodeDownloadState.onPhone;
      _notify();
      return EpisodeDownloadResult.alreadyThere;
    }

    final mobile = await allowMobile();
    if (_activeJobs[id] != token) {
      return EpisodeDownloadResult.alreadyThere;
    }
    final metered = await isMetered();
    if (_activeJobs[id] != token) {
      return EpisodeDownloadResult.alreadyThere;
    }
    if (!mobile && metered) {
      _release(id, token, previousState);
      return EpisodeDownloadResult.metered;
    }

    final hasRoom = await store.roomForDownload();
    if (_activeJobs[id] != token) {
      return EpisodeDownloadResult.alreadyThere;
    }
    if (!hasRoom) {
      _release(id, token, previousState);
      return EpisodeDownloadResult.noRoom;
    }

    final format = formatOf(uri);
    final part = store.partFile(id, format: format);
    final job = TransferJob(
      trackId: id,
      url: uri,
      headers: const {},
      file: part,
      expectedBytes: 0,
      unmeteredOnly: !mobile,
    );

    unawaited(_runFetch(id, token, job, format));

    return EpisodeDownloadResult.started;
  }

  void _release(String id, Object token, EpisodeDownloadState previousState) {
    if (_activeJobs[id] == token) {
      _activeJobs.remove(id);
      if (previousState == EpisodeDownloadState.none) {
        _states.remove(id);
      } else {
        _states[id] = previousState;
      }
      _notify();
    }
  }

  Future<void> _runFetch(
    String id,
    Object token,
    TransferJob job,
    String format,
  ) async {
    bool ok = false;
    try {
      ok = await transfer.fetch(job);
    } catch (_) {
      ok = false;
    }

    if (_disposed) {
      try {
        if (await job.file.exists()) {
          await job.file.delete();
        }
      } catch (_) {}
      return;
    }

    if (_activeJobs[id] != token) {
      if (!_activeJobs.containsKey(id)) {
        try {
          if (await job.file.exists()) {
            await job.file.delete();
          }
        } catch (_) {}
      }
      return;
    }

    var success = false;
    if (ok) {
      try {
        if (await job.file.exists() && await job.file.length() > 0) {
          success = true;
        }
      } catch (_) {
        success = false;
      }
    }

    if (success) {
      try {
        await store.commit(id, format: format, hold: Hold.download);
        if (_disposed) return;
        if (_activeJobs[id] != token) {
          if (!_activeJobs.containsKey(id)) {
            try {
              await store.remove(id);
            } catch (_) {}
          }
          return;
        }
        _activeJobs.remove(id);
        _states[id] = EpisodeDownloadState.onPhone;
        _notify();
      } catch (_) {
        if (_disposed || _activeJobs[id] != token) {
          return;
        }
        _activeJobs.remove(id);
        try {
          if (await job.file.exists()) {
            await job.file.delete();
          }
        } catch (_) {}
        _states[id] = EpisodeDownloadState.failed;
        _notify();
      }
    } else {
      if (_disposed || _activeJobs[id] != token) {
        return;
      }
      _activeJobs.remove(id);
      try {
        if (await job.file.exists()) {
          await job.file.delete();
        }
      } catch (_) {}
      _states[id] = EpisodeDownloadState.failed;
      _notify();
    }
  }

  Future<void> remove(String feedUrl, String guid) async {
    final id = idFor(feedUrl, guid);
    final wasDownloading = _activeJobs.containsKey(id);
    if (wasDownloading) {
      _activeJobs.remove(id);
      try {
        await transfer.cancel(id);
      } catch (_) {}
    }

    for (final ext in _supportedFormats) {
      final part = store.partFile(id, format: ext);
      try {
        if (await part.exists()) {
          await part.delete();
        }
      } catch (_) {}
    }

    bool hadFile = false;
    try {
      hadFile = await store.fileFor(id) != null;
      await store.remove(id);
    } catch (_) {}

    final oldState = _states[id] ?? EpisodeDownloadState.none;
    _states.remove(id);
    if (_described.remove(id) != null) {
      _save();
      _notify();
    }

    final changed =
        wasDownloading || hadFile || oldState != EpisodeDownloadState.none;
    if (changed) {
      _notify();
    }
  }

  Future<void> refresh(Iterable<(String, String)> episodes) async {
    var changed = false;
    for (final (feedUrl, guid) in episodes) {
      final id = idFor(feedUrl, guid);
      if (_states[id] == EpisodeDownloadState.downloading ||
          _activeJobs.containsKey(id)) {
        continue;
      }
      if (_disposed) return;
      // Reconciliation is best-effort: store is closed on sign-out,
      // and screen calls it unawaited — exception would be unhandled
      // (FT-733 review).
      final File? file;
      try {
        file = await store.fileFor(id);
      } catch (_) {
        return;
      }
      if (_disposed) return;
      if (_states[id] == EpisodeDownloadState.downloading ||
          _activeJobs.containsKey(id)) {
        continue;
      }
      final current = _states[id] ?? EpisodeDownloadState.none;
      if (file != null) {
        if (current != EpisodeDownloadState.onPhone) {
          _states[id] = EpisodeDownloadState.onPhone;
          changed = true;
        }
      } else {
        if (current == EpisodeDownloadState.onPhone) {
          _states.remove(id);
          changed = true;
        }
      }
    }
    if (changed) {
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
