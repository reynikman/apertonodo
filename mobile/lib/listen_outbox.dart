import 'dart:async';
import 'dart:convert';
import 'dart:math';

/// Single playback run of a song: each has its own number (contract D1, FT-640).
class Listen {
  const Listen({
    required this.id,
    required this.trackId,
    required this.startedAt,
  });

  final String id;
  final String trackId;
  final DateTime startedAt;
}

/// Report "played for this much during this run"; accumulated number.
class ListenReport {
  const ListenReport({
    required this.listenId,
    required this.trackId,
    required this.startedAt,
    required this.listenedMs,
  });

  final String listenId;
  final String trackId;
  final DateTime startedAt;
  final int listenedMs;

  Map<String, Object?> toJson() => {
    'listen_id': listenId,
    'track_id': trackId,
    'started_at': startedAt.toUtc().toIso8601String(),
    'listened_ms': listenedMs,
  };

  /// Buffer line. Anything malformed -> `null`, without exceptions: corrupted line
  /// must not crash restoration of the entire buffer.
  static ListenReport? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['listen_id'];
    final track = json['track_id'];
    final started = json['started_at'];
    final ms = json['listened_ms'];
    if (id is! String || id.isEmpty) return null;
    if (track is! String || track.isEmpty) return null;
    if (started is! String) return null;
    final at = DateTime.tryParse(started);
    // Time without timezone is local time, while buffer stores UTC only.
    if (at == null || !at.isUtc) return null;
    if (ms is! int || ms <= 0) return null;
    return ListenReport(
      listenId: id,
      trackId: track,
      startedAt: at,
      listenedMs: ms,
    );
  }
}

/// What server responded: accepted (including "not recorded"); failed for now
/// (no network, 5xx, 429); will never accept such request.
enum ListenSent { accepted, retry, rejected }

/// Server request; real implementation is wired by lead.
abstract interface class ListenPort {
  Future<ListenSent> send(ListenReport report);
}

/// Phone storage slot for single line; real storage is wired by lead.
abstract interface class ListenBox {
  Future<String?> read();
  Future<void> write(String value);
}

/// Random version 4 UUID in lowercase. Package `uuid` not needed:
/// `pubspec.yaml` is shared.
String newListenId([Random? random]) {
  final r = random ?? Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

/// Outbox buffer of playback reports: report first hits the phone and leaves
/// from there once server accepted it. Song is recorded offline too.
class ListenOutbox {
  ListenOutbox({
    required this._port,
    required this._box,
    DateTime Function()? now,
    String Function()? newId,
  }) : _now = now ?? (() => DateTime.now().toUtc()),
       _newId = newId ?? newListenId;

  static const maxPending = 200;
  static const maxAge = Duration(days: 14);

  final ListenPort _port;
  final ListenBox _box;
  final DateTime Function() _now;
  final String Function() _newId;

  List<ListenReport> _items = [];
  Future<void>? _flushing;
  Future<void> _writes = Future.value();

  /// Increments on clear: response or read started earlier changes nothing.
  int _epoch = 0;

  /// Which clear epoch the run was started in. Song playing at the moment of
  /// "do not record" is no longer reported after clear.
  final Expando<int> _born = Expando();

  /// Last write to phone failed: stale buffer is stored there.
  bool _unsaved = false;

  int get pending => _items.length;

  /// New playback run of a song. During "do not record" pause — `null`, nothing is created.
  Listen? begin(String trackId, {required bool paused}) {
    if (paused) return null;
    final listen = Listen(
      id: _newId(),
      trackId: trackId,
      startedAt: _now().toUtc(),
    );
    _born[listen] = _epoch;
    return listen;
  }

  /// [listenedMs] — total time played in this run. First to the device,
  /// then to the server: the app might be killed during the request.
  Future<void> report(Listen listen, int listenedMs) async {
    if (listenedMs <= 0) return;
    if ((_born[listen] ?? _epoch) != _epoch) return;
    final i = _items.indexWhere((e) => e.listenId == listen.id);
    // Buffer unchanged, but report is a reason to retry: network might have
    // returned.
    if (i >= 0 && _items[i].listenedMs >= listenedMs) return flush();
    final entry = ListenReport(
      listenId: listen.id,
      trackId: listen.trackId,
      startedAt: listen.startedAt,
      listenedMs: listenedMs,
    );
    if (i >= 0) {
      _items[i] = entry;
    } else {
      _items.add(entry);
    }
    _prune();
    await _save();
    await flush();
  }

  /// One flush at a time: second call awaits the same one.
  Future<void> flush() => _flushing ??= _drain();

  Future<void> _drain() async {
    // First await — ensures `_flushing` is set before `finally`.
    await Future<void>.value();
    try {
      while (true) {
        if (_prune() || _unsaved) await _save();
        if (_items.isEmpty) return;
        final item = _items.first;
        final epoch = _epoch;
        ListenSent? answer;
        try {
          answer = await _port.send(item);
        } catch (_) {
          answer = null;
        }
        if (epoch != _epoch) continue;
        if (answer == null || answer == ListenSent.retry) return;
        if (answer == ListenSent.accepted) {
          final now = _items.where((e) => e.listenId == item.listenId);
          // Report that grew during sending stays and is sent again.
          if (now.isNotEmpty && now.first.listenedMs > item.listenedMs) {
            continue;
          }
        }
        _items.removeWhere((e) => e.listenId == item.listenId);
        await _save();
      }
    } finally {
      _flushing = null;
    }
  }

  /// Reads buffer on app launch. Does not send anything itself.
  Future<void> restore() async {
    final epoch = _epoch;
    final loaded = <ListenReport>[];
    try {
      final raw = await _box.read();
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final row in decoded) {
            final item = ListenReport.fromJson(row);
            if (item != null) loaded.add(item);
          }
        }
      }
    } catch (_) {
      // Corrupted buffer or read failure — buffer is empty.
    }
    if (epoch != _epoch || loaded.isEmpty) return;
    // Read items are placed before what arrived during reading; for the same
    // run id the largest number remains.
    final merged = <String, ListenReport>{};
    for (final e in [...loaded, ..._items]) {
      final known = merged[e.listenId];
      if (known == null || e.listenedMs > known.listenedMs) {
        merged[e.listenId] = e;
      }
    }
    _items = merged.values.toList();
    _prune();
    await _save();
  }

  /// "Do not record" or logout: clear buffer in memory and on device.
  Future<void> clear() async {
    _epoch++;
    _items = [];
    await _save();
  }

  /// Discards expired and over-limit items (oldest first). `true` if
  /// anything was discarded.
  bool _prune() {
    final before = _items.length;
    final cutoff = _now().toUtc().subtract(maxAge);
    _items = _items.where((e) => !e.startedAt.isBefore(cutoff)).toList();
    if (_items.length > maxPending) {
      _items = _items.sublist(_items.length - maxPending);
    }
    return _items.length != before;
  }

  /// Writes go sequentially, and each writes buffer as it was at its start.
  Future<void> _save() => _writes = _writes.then((_) async {
    try {
      await _box.write(jsonEncode(_items.map((e) => e.toJson()).toList()));
      _unsaved = false;
    } catch (_) {
      // Write failure does not hinder sending; next flush will retry writing.
      _unsaved = true;
    }
  });
}
