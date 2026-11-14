import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import 'book_client.dart';
import 'book_position.dart';
import 'book_progress.dart';
import 'book_sync.dart';
import 'models/track.dart';
import 'player.dart';
import 'playback.dart';

/// Storage of book positions on the phone (FT-773).
class PrefsBookProgressBox implements BookProgressBox {
  PrefsBookProgressBox([this.namespace]);

  static const key = 'book_progress';
  final String? namespace;
  String? _memory;

  String get _own => namespace == null ? key : '${key}_$namespace';

  @override
  Future<String?> read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_own);
    } catch (_) {
      return _memory;
    }
  }

  @override
  Future<void> write(String data) async {
    _memory = data;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_own, data);
    } catch (_) {}
  }
}

/// Mark for syncing book positions with the server (FT-773).
class PrefsBookMarkBox implements BookProgressBox {
  PrefsBookMarkBox([this.namespace]);

  static const key = 'book_sync_mark';
  final String? namespace;
  String? _memory;

  String get _own => namespace == null ? key : '${key}_$namespace';

  @override
  Future<String?> read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_own);
    } catch (_) {
      return _memory;
    }
  }

  @override
  Future<void> write(String data) async {
    _memory = data;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_own, data);
    } catch (_) {}
  }
}

/// Adapter of `BookClient` to the sync port `BookSyncPort`.
class BookClientSyncPort implements BookSyncPort {
  BookClientSyncPort(this.client);

  final BookClient client;

  @override
  Future<Map<String, BookPosition>> put(Map<String, BookPosition> batch) =>
      client.put(batch);

  @override
  Future<BookSyncPage> changes(int after) async {
    final res = await client.changes(after);
    return BookSyncPage(res.items, res.mark);
  }
}

/// Audiobooks playback in the music player (FT-773).
///
/// Book track id has the form `book:<bookId>:<part>`. Track start request
/// asks the server for the book part token and serves the stream from it.
class BookPlayback implements PlaybackPort {
  BookPlayback(this.inner, {this.client, this.baseUrl = ''});

  final PlaybackPort? inner;
  final BookClient? client;
  final String baseUrl;

  final _urls = <String>{};
  DateTime? _lastPut;
  Future<void>? _restored;

  static bool isBook(String trackId) => trackId.startsWith('book:');

  static String idFor(String bookId, int part) => 'book:$bookId:$part';

  static (String, int)? parseId(String trackId) {
    if (!isBook(trackId)) return null;
    final parts = trackId.split(':');
    if (parts.length != 3) return null;
    final part = int.tryParse(parts[2]);
    if (part == null || part < 1) return null;
    return (parts[1], part);
  }

  static Track trackFor(ShelfBook book, int part) => Track(
    id: idFor(book.id, part),
    title: book.title,
    artist: book.author,
    durationMs: 0,
    artworkUrl: '',
  );

  static List<Track> tracksFor(ShelfBook book) => [
    for (var p = 1; p <= book.parts; p++) trackFor(book, p),
  ];

  Future<void> ready(BookProgressStore progress) =>
      _restored ??= progress.restore();

  /// "Listen": from where left off, or the first part from start.
  Future<void> listen(
    Player player,
    BookProgressStore progress,
    ShelfBook book,
  ) async {
    final tracks = tracksFor(book);
    if (tracks.isEmpty) return;
    await ready(progress);
    final resume = bookResume(progress.of(book.id), partCount: book.parts);
    final startIndex = (resume.part - 1).clamp(0, tracks.length - 1);
    final from = Duration(milliseconds: resume.positionMs);
    await player.playQueue(tracks, start: startIndex, from: from);
  }

  /// Remember position of playing book. `false` — currently playing is not a book part.
  bool remember(
    Player player,
    BookProgressStore progress,
    Duration position, {
    bool force = false,
  }) {
    final current = player.current;
    if (current == null || !isBook(current.id)) return false;
    final parsed = parseId(current.id);
    if (parsed == null) return false;
    final (bookId, part) = parsed;
    progress
        .report(bookId, part, position.inMilliseconds, force: force)
        .ignore();

    final now = DateTime.now();
    if (force ||
        _lastPut == null ||
        now.difference(_lastPut!) >= const Duration(seconds: 5)) {
      _lastPut = now;
      _syncPosition(progress, bookId);
    }
    return true;
  }

  void _syncPosition(BookProgressStore progress, String bookId) {
    final client = this.client;
    if (client == null) return;
    final pos = progress.of(bookId);
    if (pos == null) return;
    client.put({bookId: pos}).then((remote) {
      progress.ack(bookId, pos).ignore();
      progress.applyRemote(remote).ignore();
    }).ignore();
  }

  @override
  Future<String> start(String trackId, {bool prepare = false}) async {
    if (!isBook(trackId)) {
      final port = inner;
      if (port == null) {
        throw const PlaybackFailed(PlayFailure.unknownTrack);
      }
      return port.start(trackId, prepare: prepare);
    }

    final parsed = parseId(trackId);
    if (parsed == null) {
      throw const PlaybackFailed(PlayFailure.unknownTrack);
    }

    final client = this.client;
    if (client == null) {
      throw const PlaybackFailed(PlayFailure.unknownTrack);
    }

    final (bookId, part) = parsed;
    final BookPlay play;
    try {
      play = await client.play(bookId, part);
    } on BookException catch (e) {
      throw switch (e.reason) {
        BookFailure.signedOut => const PlaybackFailed(PlayFailure.noAccess),
        BookFailure.notOnShelf => const PlaybackFailed(
          PlayFailure.unknownTrack,
        ),
        BookFailure.unavailable || BookFailure.searchUnavailable =>
          const PlaybackFailed(PlayFailure.noSource),
        _ => const PlaybackFailed(PlayFailure.noAnswer),
      };
    } catch (_) {
      throw const PlaybackFailed(PlayFailure.noAnswer);
    }

    final url = '$baseUrl/v1/stream/${play.token}';
    _urls.add(url);
    return url;
  }

  @override
  Future<bool> isLocal(String trackId) async {
    if (isBook(trackId)) return false;
    return inner?.isLocal(trackId) ?? false;
  }

  @override
  Future<void> failed(String url) async {
    if (_urls.contains(url)) {
      return;
    }
    await inner?.failed(url);
  }
}
