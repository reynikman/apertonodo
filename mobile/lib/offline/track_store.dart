import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqlite;

import '../device_info.dart';

enum Hold { download, reserve }

class StoreUsage {
  const StoreUsage({required this.downloadBytes, required this.reserveBytes});

  final int downloadBytes;
  final int reserveBytes;
}

/// Accounting is shared across device, files and track access are separate per account.
class TrackStore {
  TrackStore._(
    this._root,
    this._namespace,
    this._db,
    this._now,
    this._freeBytes,
  );

  static const _gib = 1024 * 1024 * 1024;
  final Directory _root;
  final String _namespace;
  String get namespace => _namespace;
  Directory get accountDirectory => Directory('${_root.path}/$_namespace');
  final sqlite.Database _db;
  final DateTime Function() _now;
  final Future<int?> Function() _freeBytes;

  static Future<TrackStore> open({
    required Directory root,
    required String namespace,
    required sqlite.DatabaseFactory databaseFactory,
    required DateTime Function() now,
    required Future<int?> Function() freeBytes,
  }) async {
    final account = _hash(namespace);
    final directory = Directory('${root.path}/$account');
    await directory.create(recursive: true);
    final db = await databaseFactory.openDatabase(
      '${root.path}/tracks.sqlite',
      options: sqlite.OpenDatabaseOptions(
        version: 1,
        singleInstance: false,
        onCreate: (db, _) async {
          await db.execute('''CREATE TABLE tracks (
            namespace TEXT NOT NULL, id TEXT NOT NULL, format TEXT NOT NULL,
            bytes INTEGER NOT NULL, hold INTEGER NOT NULL, used INTEGER NOT NULL,
            PRIMARY KEY (namespace, id))''');
          await db.execute('CREATE INDEX tracks_lru ON tracks (hold, used)');
          await db.execute('''CREATE TABLE settings (
            key TEXT PRIMARY KEY, value INTEGER NOT NULL)''');
        },
      ),
    );
    final store = TrackStore._(root, account, db, now, freeBytes);
    try {
      await db.transaction((tx) async {
        // Do not touch unfinished download of another open account.
        await for (final entity in directory.list(followLinks: false)) {
          if (entity is File && entity.path.endsWith('.part')) {
            await entity.delete();
          }
        }
        for (final row in await tx.query('tracks')) {
          if (!await store._rowFile(row).exists()) {
            await tx.delete(
              'tracks',
              where: 'namespace = ? AND id = ?',
              whereArgs: [row['namespace'], row['id']],
            );
          }
        }
      });
      return store;
    } catch (_) {
      await db.close();
      rethrow;
    }
  }

  static Future<TrackStore> forAccount(String namespace) async {
    final support = await getApplicationSupportDirectory();
    return open(
      root: Directory('${support.path}/music'),
      namespace: namespace,
      databaseFactory: sqlite.databaseFactory,
      now: DateTime.now,
      freeBytes: DeviceInfo.freeBytes,
    );
  }

  static String _hash(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  File _file(String namespace, String id, String format) {
    // Losslessly compressed by server (Р-A60); MP3, AAC and Vorbis arrive as is.
    if (!const {'opus', 'mp3', 'flac', 'm4a', 'aac', 'ogg'}.contains(format)) {
      throw ArgumentError.value(format, 'format', 'Unsupported audio format');
    }
    return File('${_root.path}/$namespace/${_hash(id)}.$format');
  }

  File _rowFile(Map<String, Object?> row) => _file(
    row['namespace'] as String,
    row['id'] as String,
    row['format'] as String,
  );

  Future<List<Map<String, Object?>>> _rows(
    sqlite.DatabaseExecutor db,
    String id,
  ) => db.query(
    'tracks',
    where: 'namespace = ? AND id = ?',
    whereArgs: [_namespace, id],
  );

  File partFile(String id, {required String format}) =>
      File('${_file(_namespace, id, format).path}.part');

  Future<File> commit(
    String id, {
    required String format,
    required Hold hold,
  }) async {
    final part = partFile(id, format: format);
    final ready = _file(_namespace, id, format);
    final old = await _db.transaction((tx) async {
      final previous = await _rows(tx, id);
      await tx.insert('tracks', {
        'namespace': _namespace,
        'id': id,
        'format': format,
        'bytes': await part.length(),
        'hold': hold.index,
        'used': _now().microsecondsSinceEpoch,
      }, conflictAlgorithm: sqlite.ConflictAlgorithm.replace);
      await part.rename(ready.path);
      return previous.isEmpty ? null : _rowFile(previous.single);
    });
    // Failure to delete old format does not rollback accounting of already prepared file.
    if (old != null && old.path != ready.path && await old.exists()) {
      await old.delete();
    }
    return ready;
  }

  Future<File?> fileFor(String id) => _db.transaction((tx) async {
    final rows = await _rows(tx, id);
    if (rows.isEmpty) return null;
    final file = _rowFile(rows.single);
    return await file.exists() ? file : null;
  });

  Future<void> markPlayed(String id) async {
    await _db.update(
      'tracks',
      {'used': _now().microsecondsSinceEpoch},
      where: 'namespace = ? AND id = ?',
      whereArgs: [_namespace, id],
    );
  }

  Future<void> promote(String id) async {
    await _db.update(
      'tracks',
      {'hold': Hold.download.index},
      where: 'namespace = ? AND id = ?',
      whereArgs: [_namespace, id],
    );
  }

  Future<void> _remove(
    sqlite.DatabaseExecutor db,
    Map<String, Object?> row,
  ) async {
    final file = _rowFile(row);
    if (await file.exists()) await file.delete();
    await db.delete(
      'tracks',
      where: 'namespace = ? AND id = ?',
      whereArgs: [row['namespace'], row['id']],
    );
  }

  Future<void> remove(String id) => _db.transaction((tx) async {
    for (final row in await _rows(tx, id)) {
      await _remove(tx, row);
    }
  });

  Future<List<String>> evict({Set<String> keep = const {}}) => _db.transaction((
    tx,
  ) async {
    final rows = await tx.query(
      'tracks',
      where: 'hold = ?',
      whereArgs: [Hold.reserve.index],
      orderBy: 'used, namespace, id',
    );
    var bytes = rows.fold<int>(0, (sum, row) => sum + (row['bytes'] as int));
    final limit = await _limit(tx);
    final removed = <String>[];
    for (final row in rows) {
      if (bytes <= limit) break;
      if (row['namespace'] == _namespace && keep.contains(row['id'])) continue;
      await _remove(tx, row);
      bytes -= row['bytes'] as int;
      removed.add(row['id'] as String);
    }
    return removed;
  });

  Future<List<String>> clearReserve({Set<String> keep = const {}}) =>
      _db.transaction((tx) async {
        final rows = await tx.query(
          'tracks',
          where: 'hold = ? AND namespace = ?',
          whereArgs: [Hold.reserve.index, _namespace],
          orderBy: 'used, id',
        );
        final removed = <String>[];
        for (final row in rows) {
          if (keep.contains(row['id'])) continue;
          await _remove(tx, row);
          removed.add(row['id'] as String);
        }
        return removed;
      });

  Future<int> _limit(sqlite.DatabaseExecutor db) async {
    final rows = await db.query(
      'settings',
      where: 'key = ?',
      whereArgs: ['reserve_limit'],
    );
    return rows.isEmpty ? 10 * _gib : rows.single['value'] as int;
  }

  Future<int> reserveLimitBytes() => _limit(_db);

  Future<void> setReserveLimitBytes(int bytes) async {
    if (bytes < 0) {
      throw ArgumentError.value(bytes, 'bytes', 'Must be nonnegative');
    }
    await _db.insert('settings', {
      'key': 'reserve_limit',
      'value': bytes,
    }, conflictAlgorithm: sqlite.ConflictAlgorithm.replace);
  }

  Future<bool> roomForDownload() async {
    final free = await _freeBytes();
    return free == null || free >= _gib;
  }

  Future<StoreUsage> usage() async {
    final rows = await _db.rawQuery(
      '''SELECT hold, SUM(bytes) AS total FROM tracks
         WHERE namespace = ? GROUP BY hold''',
      [_namespace],
    );
    var download = 0;
    var reserve = 0;
    for (final row in rows) {
      if (row['hold'] == Hold.download.index) {
        download = row['total'] as int;
      } else {
        reserve = row['total'] as int;
      }
    }
    return StoreUsage(downloadBytes: download, reserveBytes: reserve);
  }

  Future<void> close() => _db.close();
}
