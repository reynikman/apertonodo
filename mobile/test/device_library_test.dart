import 'dart:async';
import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/device_library.dart';

/// Lead check FT-652: device audio — list model (contract D3, items 3 and 6).

class _Port implements DeviceMediaPort {
  _Port({
    this.now = DeviceAccess.granted,
    DeviceAccess? asked,
    this.list = const [],
  }) : asked = asked ?? now;
  DeviceAccess now;
  DeviceAccess asked;
  List<DeviceSong> list;
  Object? accessError;
  Object? songsError;
  Completer<List<DeviceSong>>? hold;
  Completer<DeviceAccess>? holdAccess;
  final calls = <String>[];

  @override
  Future<DeviceAccess> access() {
    calls.add('access');
    if (accessError != null) throw accessError!;
    return holdAccess?.future ?? Future.value(now);
  }

  @override
  Future<DeviceAccess> request() async {
    calls.add('request');
    if (accessError != null) throw accessError!;
    return now = asked;
  }

  @override
  Future<List<DeviceSong>> songs() {
    calls.add('songs');
    if (songsError != null) return Future.error(songsError!);
    return hold?.future ?? Future.value(list);
  }
}

const _music = '/storage/emulated/0/Music';

DeviceSong _song(
  String uri, {
  String title = '',
  String artist = '',
  String album = '',
  String albumId = '',
  int ms = 200000,
  int? track,
  String? path,
}) => DeviceSong(
  uri: uri,
  title: title,
  artist: artist,
  album: album,
  albumId: albumId,
  durationMs: ms,
  track: track,
  path: path ?? '$_music/$uri.mp3',
);

Future<DeviceLibrary> _open(List<DeviceSong> list) async {
  final library = DeviceLibrary(_Port(list: list));
  await library.open();
  return library;
}

/// Port list that fails during traversal.
class _Broken extends ListBase<DeviceSong> {
  @override
  int get length => 1;
  @override
  set length(int value) {}
  @override
  DeviceSong operator [](int index) => throw StateError('x');
  @override
  void operator []=(int index, DeviceSong value) {}
}

void main() {
  group('what qualifies as music', () {
    test('under 30 seconds is ringtone or notification, not music', () {
      expect(deviceMusicMinMs, 30000);
      expect(isDeviceMusic(_song('a', ms: 29999)), isFalse);
      expect(isDeviceMusic(_song('a', ms: 1)), isFalse);
      expect(isDeviceMusic(_song('a', ms: 30000)), isTrue);
    });

    test('unknown duration (zero or negative) is retained', () {
      expect(isDeviceMusic(_song('a', ms: 0)), isTrue);
      expect(isDeviceMusic(_song('a', ms: -1)), isTrue);
    });

    test('without Android URI: not a song', () {
      expect(isDeviceMusic(_song('')), isFalse);
    });

    test('system folders ignored, case insensitive', () {
      for (final folder in [
        'Ringtones',
        'ringtones',
        'Notifications',
        'Alarms',
        'Recordings',
        'Call Recordings',
        'Voice Recorder',
        'WhatsApp Voice Notes',
        'Music/Recordings/2026',
        'Android/data/com.app/files',
        'Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Audio',
        'android/obb/x',
      ]) {
        expect(
          isDeviceMusic(_song('a', path: '/storage/emulated/0/$folder/a.mp3')),
          isFalse,
          reason: folder,
        );
      }
    });

    test('similar folder and file names are not hidden', () {
      for (final path in [
        '$_music/Ringtones.mp3',
        '$_music/Alarms',
        '$_music/My Ringtones Collection/a.mp3',
        '$_music/Android/a.mp3',
        '/storage/emulated/0/Android/a.mp3',
        '/storage/emulated/0/Android Music/data/a.mp3',
        '/storage/1A2B-3C4D/Music/a.flac',
        '',
      ]) {
        expect(isDeviceMusic(_song('a', path: path)), isTrue, reason: path);
      }
    });
  });

  group('row normalization', () {
    test('<unknown> from Android and spaces cleared to empty', () {
      final song = tidyDeviceSong(
        _song('u', title: ' Song ', artist: '<unknown>', album: ' <Unknown> '),
      );
      expect(song.title, 'Song');
      expect(song.artist, '');
      expect(song.album, '');
    });

    test('missing title uses filename without extension', () {
      expect(
        tidyDeviceSong(_song('u', path: '$_music/01 - Intro.final.mp3')).title,
        '01 - Intro.final',
      );
      expect(
        tidyDeviceSong(
          _song('u', title: '<unknown>', path: '$_music/track'),
        ).title,
        'track',
      );
      expect(
        tidyDeviceSong(_song('u', path: '$_music/.hidden')).title,
        '.hidden',
      );
      expect(tidyDeviceSong(_song('u', title: '  ', path: '')).title, '');
    });

    test(
      'track number zero or negative cleared; negative duration is zero',
      () {
        expect(tidyDeviceSong(_song('u', track: 0)).track, isNull);
        expect(tidyDeviceSong(_song('u', track: -3)).track, isNull);
        expect(tidyDeviceSong(_song('u', track: 1004)).track, 1004);
        expect(tidyDeviceSong(_song('u', ms: -5)).durationMs, 0);
      },
    );

    test('uri, path, and album id are preserved unchanged', () {
      final song = tidyDeviceSong(
        _song(' content://media/1 ', albumId: ' 7 ', path: ' /a/b.mp3 '),
      );
      expect(song.uri, ' content://media/1 ');
      expect(song.albumId, ' 7 ');
      expect(song.path, ' /a/b.mp3 ');
    });

    test('row string representation omits titles and path', () {
      expect(
        _song(
          'content://media/1',
          title: 'Secret',
          path: '/a/Secret.mp3',
        ).toString(),
        'DeviceSong',
      );
    });
  });

  group('permission', () {
    test('before open: nothing requested or read', () {
      final port = _Port();
      final library = DeviceLibrary(port);
      expect(library.state, DeviceLibraryState.idle);
      expect(library.songs, isEmpty);
      expect(port.calls, isEmpty);
    });

    test('opening does not prompt system dialog', () async {
      final port = _Port(now: DeviceAccess.denied, asked: DeviceAccess.granted);
      final library = DeviceLibrary(port);
      await library.open();
      expect(library.state, DeviceLibraryState.noAccess);
      expect(port.calls, ['access']);
    });

    test('grant permission: requested, received, loaded', () async {
      final port = _Port(
        now: DeviceAccess.denied,
        asked: DeviceAccess.granted,
        list: [_song('a', title: 'A')],
      );
      final library = DeviceLibrary(port);
      await library.open();
      await library.ask();
      expect(library.state, DeviceLibraryState.ready);
      expect(library.songs.single.title, 'A');
      expect(port.calls, ['access', 'request', 'songs']);
    });

    test(
      'denied and permanently denied are distinct: library not read',
      () async {
        for (final (access, state) in [
          (DeviceAccess.denied, DeviceLibraryState.noAccess),
          (DeviceAccess.deniedForever, DeviceLibraryState.deniedForever),
        ]) {
          final port = _Port(
            now: DeviceAccess.denied,
            asked: access,
            list: [_song('a')],
          );
          final library = DeviceLibrary(port);
          await library.ask();
          expect(library.state, state);
          expect(library.songs, isEmpty);
          expect(port.calls, ['request']);
        }
      },
    );

    test(
      'permission revoked in settings: existing library list cleared',
      () async {
        final port = _Port(
          list: [_song('a', artist: 'X', album: 'Y')],
        );
        final library = DeviceLibrary(port);
        await library.open();
        expect(library.songs, hasLength(1));
        port.now = DeviceAccess.denied;
        await library.refresh();
        expect(library.state, DeviceLibraryState.noAccess);
        expect(library.songs, isEmpty);
        expect(library.albums, isEmpty);
        expect(library.artists, isEmpty);
        expect(library.folders, isEmpty);
      },
    );
  });

  group('states', () {
    test('empty and all filtered out resolve to empty state', () async {
      expect((await _open([])).state, DeviceLibraryState.empty);
      expect(
        (await _open([_song('a', ms: 2000)])).state,
        DeviceLibraryState.empty,
      );
    });

    test('while reading is loading, listeners notified at each step', () async {
      final port = _Port(list: [_song('a')])..hold = Completer();
      final library = DeviceLibrary(port);
      final states = <DeviceLibraryState>[];
      library.addListener(() => states.add(library.state));
      final opening = library.open();
      await pumpEventQueue();
      expect(library.state, DeviceLibraryState.loading);
      port.hold!.complete([_song('a')]);
      await opening;
      expect(states, [DeviceLibraryState.loading, DeviceLibraryState.ready]);
    });

    test(
      'read failure and prompt failure report error without throwing',
      () async {
        final reading = DeviceLibrary(_Port()..songsError = StateError('x'));
        await reading.open();
        expect(reading.state, DeviceLibraryState.failed);
        final asking = DeviceLibrary(_Port()..accessError = StateError('x'));
        await asking.open();
        expect(asking.state, DeviceLibraryState.failed);
        await asking.ask();
        expect(asking.state, DeviceLibraryState.failed);
      },
    );

    test('refresh error does not clear currently displayed list', () async {
      final port = _Port(list: [_song('a', title: 'A')]);
      final library = DeviceLibrary(port);
      await library.open();
      port.songsError = StateError('x');
      await library.refresh();
      expect(library.state, DeviceLibraryState.failed);
      expect(library.songs.single.title, 'A');
      port.songsError = null;
      await library.refresh();
      expect(library.state, DeviceLibraryState.ready);
    });

    test(
      'refresh with identical count still notifies: contents changed',
      () async {
        final port = _Port(list: [_song('a', title: 'A')]);
        final library = DeviceLibrary(port);
        await library.open();
        port.list = [_song('b', title: 'B')];
        var calls = 0;
        library.addListener(() => calls++);
        await library.refresh();
        expect(library.songs.single.title, 'B');
        expect(calls, 2);
      },
    );

    test(
      'concurrent reads: latest wins, delayed first does not overwrite',
      () async {
        final first = Completer<List<DeviceSong>>();
        final port = _Port()..hold = first;
        final library = DeviceLibrary(port);
        final one = library.open();
        await pumpEventQueue();
        port.hold = null;
        port.list = [_song('new', title: 'New')];
        await library.refresh();
        first.complete([_song('old', title: 'Old')]);
        await one;
        expect(library.songs.single.title, 'New');
        expect(library.state, DeviceLibraryState.ready);
      },
    );

    test('delayed failure of first read does not corrupt fresh list', () async {
      final first = Completer<List<DeviceSong>>();
      final port = _Port()..hold = first;
      final library = DeviceLibrary(port);
      final one = library.open();
      await pumpEventQueue();
      port.hold = null;
      port.list = [_song('new')];
      await library.refresh();
      first.completeError(StateError('x'));
      await one;
      expect(library.state, DeviceLibraryState.ready);
    });

    test(
      'delayed permission answer from first open does not erase list',
      () async {
        final first = Completer<DeviceAccess>();
        final port = _Port(list: [_song('new')])..holdAccess = first;
        final library = DeviceLibrary(port);
        final one = library.open();
        await pumpEventQueue();
        port.holdAccess = null;
        await library.refresh();
        expect(library.state, DeviceLibraryState.ready);
        first.complete(DeviceAccess.denied);
        await one;
        expect(library.state, DeviceLibraryState.ready);
        expect(library.songs, hasLength(1));
      },
    );

    test('after dispose: no reads, no notifications, no crashes', () async {
      final port = _Port()..hold = Completer();
      final library = DeviceLibrary(port);
      final opening = library.open();
      await pumpEventQueue();
      library.dispose();
      port.hold!.complete([_song('a')]);
      await opening;
      expect(library.songs, isEmpty);
      final calls = port.calls.length;
      await library.open();
      await library.ask();
      await library.refresh();
      expect(port.calls, hasLength(calls));
    });
  });

  group('song list', () {
    test(
      'case-insensitive title sort; identical by casing then by URI',
      () async {
        final library = await _open([
          _song('3', title: 'beta'),
          _song('5', title: 'Alpha'),
          _song('0', title: 'alpha'),
          _song('1', title: 'Яблоко'),
          _song('2', title: 'Alpha'),
          _song('4', title: 'Zeta'),
        ]);
        expect(
          [for (final s in library.songs) '${s.title}/${s.uri}'],
          ['Alpha/2', 'Alpha/5', 'alpha/0', 'beta/3', 'Zeta/4', 'Яблоко/1'],
        );
      },
    );

    test('duplicate entries deduplicated, first occurrence wins', () async {
      final library = await _open([
        _song('a', title: 'First'),
        _song('a', title: 'Second'),
        _song('b', title: 'B'),
      ]);
      expect(library.songs.map((s) => s.title), ['B', 'First']);
    });

    test('list contains normalized rows, non-music filtered out', () async {
      final library = await _open([
        _song('a', artist: '<unknown>', path: '$_music/Song A.flac'),
        _song('r', title: 'Ring', path: '/storage/emulated/0/Ringtones/r.ogg'),
        _song('s', title: 'Short', ms: 4000),
      ]);
      expect(library.songs.single.title, 'Song A');
      expect(library.songs.single.artist, '');
    });

    test('returned lists cannot be modified externally', () async {
      final library = await _open([
        _song('a', title: 'A', artist: 'X', album: 'Y'),
      ]);
      expect(() => library.songs.add(_song('z')), throwsUnsupportedError);
      expect(() => library.albums.clear(), throwsUnsupportedError);
      expect(() => library.albums.single.songs.clear(), throwsUnsupportedError);
      expect(
        () => library.artists.single.songs.clear(),
        throwsUnsupportedError,
      );
      expect(
        () => library.folders.single.songs.clear(),
        throwsUnsupportedError,
      );
    });
  });

  group('albums', () {
    test(
      'Android album id grouping prevents merging distinct artists',
      () async {
        final library = await _open([
          _song(
            '1',
            title: 'A',
            artist: 'X',
            album: 'Greatest Hits',
            albumId: '10',
          ),
          _song(
            '2',
            title: 'B',
            artist: 'Y',
            album: 'Greatest Hits',
            albumId: '20',
          ),
          _song(
            '3',
            title: 'C',
            artist: 'X',
            album: 'Greatest Hits',
            albumId: '10',
          ),
        ]);
        expect(library.albums, hasLength(2));
        expect(library.albums.map((a) => a.artist).toSet(), {'X', 'Y'});
        expect(
          library.albums
              .firstWhere((a) => a.artist == 'X')
              .songs
              .map((s) => s.title),
          ['A', 'C'],
        );
      },
    );

    test('without album id: grouped by case-insensitive name', () async {
      final library = await _open([
        _song('1', title: 'A', album: 'Live'),
        _song('2', title: 'B', album: 'live'),
        _song('3', title: 'C', album: 'Other'),
      ]);
      expect(library.albums.map((a) => a.name), ['Live', 'Other']);
      expect(library.albums.first.songs, hasLength(2));
    });

    test('songs without album are excluded from albums', () async {
      final library = await _open([
        _song('1', title: 'A', album: '<unknown>', albumId: '5'),
        _song('2', title: 'B'),
      ]);
      expect(library.albums, isEmpty);
      expect(library.songs, hasLength(2));
    });

    test(
      'in album: sorted by track number; untracked at end by title',
      () async {
        final library = await _open([
          _song('1', title: 'Zeta', album: 'L', track: 2),
          _song('2', title: 'Beta', album: 'L'),
          _song('3', title: 'Alpha', album: 'L', track: 1002),
          _song('4', title: 'Omega', album: 'L', track: 1),
          _song('5', title: 'Alpha', album: 'L'),
          _song('6', title: 'Same', album: 'L', track: 2),
        ]);
        expect(library.albums.single.songs.map((s) => s.uri), [
          '4',
          '6',
          '1',
          '3',
          '5',
          '2',
        ]);
      },
    );

    test('album artist: shared artist set, mixed clears to empty', () async {
      final library = await _open([
        _song('1', title: 'A', artist: 'Queen', album: 'One', albumId: '1'),
        _song('2', title: 'B', artist: 'QUEEN', album: 'One', albumId: '1'),
        _song('3', title: 'A', artist: 'X', album: 'Mix', albumId: '2'),
        _song('4', title: 'B', artist: 'Y', album: 'Mix', albumId: '2'),
        _song('5', title: 'A', artist: '', album: 'Mix2', albumId: '3'),
        _song('6', title: 'B', artist: 'Y', album: 'Mix2', albumId: '3'),
      ]);
      expect(
        {for (final a in library.albums) a.name: a.artist},
        {'One': 'Queen', 'Mix': '', 'Mix2': ''},
      );
    });

    test('albums sorted by title', () async {
      final library = await _open([
        _song('1', album: 'beta', albumId: '1'),
        _song('2', album: 'Alpha', albumId: '2'),
        _song('3', album: 'Гамма', albumId: '3'),
      ]);
      expect(library.albums.map((a) => a.name), ['Alpha', 'beta', 'Гамма']);
    });
  });

  group('artists', () {
    test(
      'case-insensitive artist sort without empties; songs by title',
      () async {
        final library = await _open([
          _song('1', title: 'B', artist: 'queen'),
          _song('2', title: 'A', artist: 'Queen'),
          _song('3', title: 'C', artist: 'ABBA'),
          _song('4', title: 'D', artist: '<unknown>'),
          _song('5', title: 'E'),
        ]);
        expect(library.artists.map((a) => a.name), ['ABBA', 'Queen']);
        expect(library.artists.last.songs.map((s) => s.title), ['A', 'B']);
      },
    );

    test(
      'album count: distinct albums counted, songs without album not',
      () async {
        final library = await _open([
          _song('1', title: 'A', artist: 'X', album: 'One', albumId: '1'),
          _song('2', title: 'B', artist: 'X', album: 'One', albumId: '1'),
          _song('3', title: 'C', artist: 'X', album: 'Two', albumId: '2'),
          _song('4', title: 'D', artist: 'X', album: 'One', albumId: '9'),
          _song('5', title: 'E', artist: 'X'),
          _song('6', title: 'F', artist: 'Y'),
        ]);
        expect(library.artists.first.albumCount, 3);
        expect(library.artists.last.albumCount, 0);
      },
    );
  });

  group('folders', () {
    test(
      'folder is directory; name is last segment; same name by path',
      () async {
        final library = await _open([
          _song('1', title: 'A', path: '$_music/Rock/a.mp3'),
          _song('2', title: 'B', path: '$_music/Rock/b.mp3'),
          _song('3', title: 'C', path: '/storage/1A2B-3C4D/Rock/c.mp3'),
          _song('4', title: 'D', path: '$_music/d.mp3'),
          _song('5', title: 'E', path: ''),
          _song('6', title: 'F', path: 'f.mp3'),
          _song('7', title: 'G', path: '/g.mp3'),
        ]);
        expect(
          [
            for (final f in library.folders)
              '${f.name}|${f.path}|${f.songs.length}',
          ],
          [
            'Music|$_music|1',
            'Rock|/storage/1A2B-3C4D/Rock|1',
            'Rock|$_music/Rock|2',
          ],
        );
      },
    );

    test(
      'folder casing preserved: on memory card these are distinct',
      () async {
        final library = await _open([
          _song('1', path: '$_music/rock/a.mp3'),
          _song('2', path: '$_music/Rock/b.mp3'),
        ]);
        expect(library.folders, hasLength(2));
      },
    );
  });

  test('twenty thousand songs parsed quickly', () async {
    final list = [
      for (var i = 0; i < 20000; i++)
        _song(
          'content://media/external/audio/media/$i',
          title: 'Song ${i * 7919 % 20000}',
          artist: 'Artist ${i % 900}',
          album: 'Album ${i % 2500}',
          albumId: '${i % 2500}',
          track: i % 14 + 1,
          path: '$_music/Artist ${i % 900}/Album ${i % 2500}/$i.mp3',
        ),
    ];
    final watch = Stopwatch()..start();
    final library = await _open(list);
    expect(watch.elapsedMilliseconds, lessThan(3000));
    expect(library.songs, hasLength(20000));
    expect(library.albums, hasLength(2500));
    expect(library.artists, hasLength(900));
  });
  group('second review pass', () {
    test(
      'yo collated beside ye instead of after ya across all entities',
      () async {
        final library = await _open([
          _song('1', title: 'Яблоко', album: 'Яма', artist: 'Яна'),
          _song('2', title: 'Ёлка', album: 'Ёж', artist: 'Ёлка'),
          _song('3', title: 'Арбуз', album: 'Атом', artist: 'Аня'),
          _song('4', title: 'Жук', album: 'Жар', artist: 'Жанна'),
        ]);
        expect(
          [for (final s in library.songs) s.title],
          ['Арбуз', 'Ёлка', 'Жук', 'Яблоко'],
        );
        expect(
          [for (final a in library.albums) a.name],
          ['Атом', 'Ёж', 'Жар', 'Яма'],
        );
        expect(
          [for (final a in library.artists) a.name],
          ['Аня', 'Ёлка', 'Жанна', 'Яна'],
        );
      },
    );

    test('file in root storage or sdcard has no parent folder', () async {
      final library = await _open([
        _song('1', path: '/storage/emulated/0/a.mp3'),
        _song('2', path: '/storage/1A2B-3C4D/b.mp3'),
        _song('3', path: '/sdcard/c.mp3'),
        _song('4', path: '/storage/emulated/0/Music/d.mp3'),
      ]);
      expect(library.songs, hasLength(4));
      expect(
        [for (final f in library.folders) f.path],
        ['/storage/emulated/0/Music'],
      );
    });

    test('title from filename trims leading and trailing spaces', () {
      expect(
        tidyDeviceSong(_song('1', path: '$_music/ Song .mp3')).title,
        'Song',
      );
    });

    test(
      'port list parsing failure reports failure rather than hanging',
      () async {
        final port = _Port(list: [_song('a', title: 'A')]);
        final library = DeviceLibrary(port);
        await library.open();
        port.list = _Broken();
        await library.refresh();
        expect(library.state, DeviceLibraryState.failed);
        expect(library.songs, hasLength(1));
      },
    );
  });
}
