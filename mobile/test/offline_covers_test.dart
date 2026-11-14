import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/auth/token_provider.dart';
import 'package:music_stream/models/track.dart';
import 'package:music_stream/offline/cover_store.dart';
import 'package:music_stream/offline/download_queue.dart';
import 'package:music_stream/offline/downloads.dart';
import 'package:music_stream/offline/track_store.dart';
import 'package:music_stream/screens/parts.dart';
import 'package:music_stream/server_api.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fake_server.dart';
import 'fakes.dart';
import 'offline_downloads_test.dart' show QueueServer, Transfer, gib;

/// Downloaded covers visible offline (FT-534).
///
/// Songs in Downloads play in subway and plane (P6), while cover art
/// previously came only via `Image.network` — offline showed placeholder box with
/// artist letters instead: in mini player, player screen, lists.
const coverA = '/v1/covers/aaaaaaaa-0000-4000-8000-000000000534';
const coverB = '/v1/covers/bbbbbbbb-0000-4000-8000-000000000534';

/// Real 1x1 JPEG: `Image.file` must parse it.
final jpeg = Uint8List.fromList([
  0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, //
  0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xD9,
]);

Track song(int n, String cover) => Track(
  id: '00000000-0000-4000-8000-00000000053$n',
  title: 'Song $n',
  artist: 'Band',
  durationMs: 200000,
  artworkUrl: cover,
);

void main() {
  late Directory root;
  late List<String> fetched;
  late CoverStore covers;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('offline_covers_test');
    fetched = [];
    covers = CoverStore(
      root: root,
      fetch: (path) async {
        fetched.add(path);
        return jpeg;
      },
    );
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  group('on-device cover art store', () {
    test('cover is saved once per album', () async {
      await covers.keep(coverA);
      await covers.keep(coverA);
      expect(fetched, [coverA], reason: 'same cover downloaded twice');
      final file = covers.fileFor(coverA);
      expect(file, isNotNull);
      expect(file!.readAsBytesSync(), jpeg);
      expect(covers.fileFor(coverB), isNull);
    });

    test('no cover and offline does not break', () async {
      await covers.keep('');
      expect(fetched, isEmpty, reason: 'track without cover skips download');
      final offline = CoverStore(root: root, fetch: (_) async => null);
      await offline.keep(coverB);
      expect(offline.fileFor(coverB), isNull);
    });

    test('deleted cover is removed from disk', () async {
      await covers.keep(coverA);
      final file = covers.fileFor(coverA)!;
      await covers.drop(coverA);
      expect(covers.fileFor(coverA), isNull);
      expect(file.existsSync(), isFalse);
    });

    test('filename does not contain album id', () async {
      await covers.keep(coverA);
      final names = root
          .listSync(recursive: true)
          .whereType<File>()
          .map((f) => f.path)
          .join(' ');
      expect(names, isNot(contains('aaaaaaaa-0000-4000-8000-000000000534')));
    });
  });

  group('Cover', () {
    Future<void> show(WidgetTester tester, {CoverStore? store}) async {
      final cover = Cover(
        server: Rig().server.api(),
        path: coverA,
        artist: 'Band',
        size: 48,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: store == null ? cover : CoverFiles(store: store, child: cover),
        ),
      );
    }

    testWidgets('downloaded cover renders directly from file, offline', (
      tester,
    ) async {
      await tester.runAsync(() => covers.keep(coverA));
      await show(tester, store: covers);
      final image = tester.widget<Image>(find.byType(Image));
      expect(
        image.image,
        isA<FileImage>(),
        reason: 'downloaded cover still hits network',
      );
    });

    testWidgets('not downloaded — from server as before', (tester) async {
      await show(tester, store: covers);
      expect(
        tester.widget<Image>(find.byType(Image)).image,
        isA<NetworkImage>(),
      );
      await show(tester);
      expect(
        tester.widget<Image>(find.byType(Image)).image,
        isA<NetworkImage>(),
      );
    });
  });

  group('«Downloads» bundle cover art', () {
    const base = 'https://music.example';
    const account = 'account/https%3A%2F%2Fmusic.example/42';
    late TrackStore store;
    late QueueServer server;

    Future<Downloads> open() async {
      final queue = DownloadQueue(
        server: ServerApi(
          base,
          tokens: TokenProvider(
            EmptySessionStore()..cachedToken = 'secret-session-token-01234',
            server: Uri.parse(base),
          ),
          client: server.client,
        ),
        store: store,
        transfer: Transfer(),
        isMetered: () async => false,
      );
      final downloads = Downloads(
        queue: queue,
        store: store,
        covers: covers,
        poll: const Duration(milliseconds: 10),
      );
      await downloads.load();
      return downloads;
    }

    setUpAll(sqfliteFfiInit);

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      store = await TrackStore.open(
        root: Directory('${root.path}/tracks'),
        namespace: account,
        databaseFactory: databaseFactoryFfi,
        now: DateTime.now,
        freeBytes: () async => 50 * gib,
      );
      server = QueueServer();
    });

    tearDown(() => store.close());

    test('download album — cover saved to phone, once per album', () async {
      final downloads = await open();
      await downloads.download([
        song(1, coverA),
        song(2, coverA),
        song(3, coverB),
      ]);
      expect(covers.fileFor(coverA), isNotNull, reason: 'cover was not saved');
      expect(covers.fileFor(coverB), isNotNull);
      expect(fetched..sort(), [coverA, coverB]);
      downloads.dispose();
    });

    test(
      'delete download — cover is removed when no longer needed by any track',
      () async {
        final downloads = await open();
        await downloads.download([
          song(1, coverA),
          song(2, coverA),
          song(3, coverB),
        ]);
        await downloads.remove([song(1, coverA).id]);
        expect(
          covers.fileFor(coverA),
          isNotNull,
          reason: 'song 2 still needs cover',
        );
        await downloads.remove([song(2, coverA).id, song(3, coverB).id]);
        expect(
          covers.fileFor(coverA),
          isNull,
          reason: 'cover remained on phone',
        );
        expect(covers.fileFor(coverB), isNull);
        downloads.dispose();
      },
    );
  });
}
