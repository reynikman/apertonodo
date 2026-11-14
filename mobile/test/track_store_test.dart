import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/offline/track_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Audio files on device (FT-523, P-A60, rules 5, 7, 10).
///
/// Downloaded tracks persist until user deletes them. Playback cache limited
/// to configured quota, least recently played evicted first. Currently playing
/// and upcoming queued tracks never evicted. Incomplete download hidden from player.
/// Separate account on same device cannot access downloads.
const account = 'account/https%3A%2F%2Fmusic.example.org/42';
const other = 'account/https%3A%2F%2Fmusic.example.org/43';
const gib = 1024 * 1024 * 1024;

late Directory root;
late DateTime clock;
var free = 50 * gib;

Future<TrackStore> open([String namespace = account]) => TrackStore.open(
  root: root,
  namespace: namespace,
  databaseFactory: databaseFactoryFfi,
  now: () => clock,
  freeBytes: () async => free,
);

/// Write "downloaded" file simulating downloader: to `.part`, then
/// `commit`.
Future<File> put(
  TrackStore store,
  String id, {
  Hold hold = Hold.reserve,
  int size = 1000,
  String format = 'opus',
}) async {
  final part = store.partFile(id, format: format);
  await part.parent.create(recursive: true);
  await part.writeAsBytes(List.filled(size, 7));
  return store.commit(id, format: format, hold: hold);
}

void tick() => clock = clock.add(const Duration(minutes: 1));

List<String> filesUnder(Directory dir) => [
  for (final entity in dir.listSync(recursive: true))
    if (entity is File) entity.path,
];

void main() {
  sqfliteFfiInit();

  setUp(() async {
    root = await Directory.systemTemp.createTemp('track_store_test');
    clock = DateTime.utc(2026, 10, 2, 12);
    free = 50 * gib;
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  test('partial file hidden from player, complete is visible', () async {
    final store = await open();
    final part = store.partFile('t1', format: 'opus');
    await part.parent.create(recursive: true);
    await part.writeAsBytes([1, 2, 3]);
    expect(await store.fileFor('t1'), isNull);

    final ready = await store.commit('t1', format: 'opus', hold: Hold.download);
    expect(part.existsSync(), isFalse);
    expect(ready.existsSync(), isTrue);
    expect(
      ready.path.endsWith('.opus'),
      isTrue,
      reason: 'player detects format by file extension',
    );
    expect((await store.fileFor('t1'))!.path, ready.path);
    expect(ready.path.startsWith(root.path), isTrue);
    await store.close();
  });

  test('no leftovers remain after crash during download', () async {
    var store = await open();
    final ready = await put(store, 't1');
    final part = store.partFile('t2', format: 'opus');
    await part.parent.create(recursive: true);
    await part.writeAsBytes([1, 2, 3]);
    await store.close();
    await ready.delete(); // the file dropped out of the books

    store = await open();
    expect(
      part.existsSync(),
      isFalse,
      reason: '.part file removed after restart',
    );
    expect(await store.fileFor('t1'), isNull, reason: 'missing file dropped');
    expect((await store.usage()).reserveBytes, 0);
    await store.close();
  });

  test('cache: oldest unplayed tracks evicted first', () async {
    final store = await open();
    await store.setReserveLimitBytes(3000);
    for (final id in ['a', 'b', 'c']) {
      await put(store, id);
      tick();
    }
    await store.markPlayed('a'); // a played again — now it is fresh
    tick();
    await put(store, 'd');

    expect(await store.evict(), ['b']);
    expect(await store.fileFor('b'), isNull);
    for (final id in ['a', 'c', 'd']) {
      expect(await store.fileFor(id), isNotNull, reason: id);
    }
    expect((await store.usage()).reserveBytes, 3000);
    await store.close();
  });

  test('downloaded tracks not evicted, excluded from cache', () async {
    final store = await open();
    await store.setReserveLimitBytes(0);
    await put(store, 'kept', hold: Hold.download, size: 5000);
    await put(store, 'heard', size: 1000);

    expect(await store.evict(), ['heard']);
    expect(await store.fileFor('kept'), isNotNull);
    final usage = await store.usage();
    expect(usage.downloadBytes, 5000);
    expect(usage.reserveBytes, 0);
    await store.close();
  });

  test(
    'playing and upcoming queue tracks not evicted even with zero cache',
    () async {
      final store = await open();
      await store.setReserveLimitBytes(0);
      for (final id in ['now', 'next1', 'next2', 'old']) {
        await put(store, id);
        tick();
      }
      expect(await store.evict(keep: {'now', 'next1', 'next2'}), ['old']);
      for (final id in ['now', 'next1', 'next2']) {
        expect(await store.fileFor(id), isNotNull, reason: id);
      }
      // Track finished playing and left queue — with 0 cache quota it is not retained.
      expect(await store.evict(keep: {'next1', 'next2'}), ['now']);
      await store.close();
    },
  );

  test('downloading cached track marks it as downloaded', () async {
    final store = await open();
    await store.setReserveLimitBytes(0);
    await put(store, 't1');
    await store.promote('t1');
    expect(await store.evict(), isEmpty);
    expect((await store.usage()).downloadBytes, 1000);
    await store.close();
  });

  test('delete removes file from disk', () async {
    final store = await open();
    final file = await put(store, 't1', hold: Hold.download);
    await store.remove('t1');
    expect(file.existsSync(), isFalse);
    expect(await store.fileFor('t1'), isNull);
    expect((await store.usage()).downloadBytes, 0);
    await store.close();
  });

  test('other account cannot see downloads, files remain on logout', () async {
    var mine = await open();
    await put(mine, 't1', hold: Hold.download);
    await mine.close();

    final theirs = await open(other);
    expect(await theirs.fileFor('t1'), isNull);
    expect((await theirs.usage()).downloadBytes, 0);
    await theirs.close();

    mine = await open();
    expect(
      await mine.fileFor('t1'),
      isNotNull,
      reason: 'login again keeps downloaded tracks',
    );
    await mine.close();
  });

  test('paths contain no server url, account id, or song id', () async {
    final store = await open();
    await put(store, '../../escape', hold: Hold.download);
    await put(store, 'Slipknot - Duality');
    for (final path in filesUnder(root)) {
      final relative = path.substring(root.path.length);
      expect(relative, isNot(contains('apertonodo')));
      expect(relative, isNot(contains('%2F')));
      expect(relative, isNot(contains('Slipknot')));
      expect(relative, isNot(contains('escape')));
    }
    final escaped = (await store.fileFor('../../escape'))!.absolute.path;
    expect(
      Uri.file(escaped).normalizePath().toFilePath().startsWith(root.path),
      isTrue,
      reason: 'song id cannot traverse outside store folder',
    );
    await store.close();
  });

  test(
    'cache default 10 GB until set; setting persists across restarts',
    () async {
      var store = await open();
      expect(await store.reserveLimitBytes(), 10 * gib);
      await store.setReserveLimitBytes(3 * gib);
      await store.close();
      store = await open();
      expect(await store.reserveLimitBytes(), 3 * gib);
      await store.close();
    },
  );

  test('under 1 GB free space pauses download', () async {
    final store = await open();
    free = gib - 1;
    expect(await store.roomForDownload(), isFalse);
    free = gib;
    expect(await store.roomForDownload(), isTrue);
    await store.close();
  });

  test('files stored in app private storage, not public storage', () {
    final code = File('lib/offline/track_store.dart').readAsStringSync();
    expect(code, contains('getApplicationSupportDirectory'));
    expect(code, isNot(contains('getExternalStorage')));
    expect(code, isNot(contains('getDownloadsDirectory')));
  });
}
