import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/book_client.dart';
import 'package:music_stream/book_playback.dart';
import 'package:music_stream/book_progress.dart';
import 'package:music_stream/player.dart';
import 'package:music_stream/playback.dart';

import 'fake_server.dart';
import 'fakes.dart';

class _MemoryBox implements BookProgressBox {
  String? data;
  @override
  Future<String?> read() async => data;
  @override
  Future<void> write(String value) async => data = value;
}

void main() {
  const bookId = '0b0f6a52-7f3e-4d7a-9a51-3c2f1e8d7a10';

  final sampleBook = ShelfBook(
    id: bookId,
    title: 'Мастер и Маргарита',
    author: 'Михаил Булгаков',
    narrator: 'Александр Клюквин',
    year: 2011,
    sizeBytes: 52428800,
    parts: 3,
    shelvedAt: DateTime.parse('2026-10-12T10:00:00.000Z'),
  );

  test('BookPlayback.tracksFor creates queue with required fields', () {
    final tracks = BookPlayback.tracksFor(sampleBook);
    expect(tracks.length, 3);
    expect(tracks[0].id, 'book:$bookId:1');
    expect(tracks[1].id, 'book:$bookId:2');
    expect(tracks[2].id, 'book:$bookId:3');
    for (final track in tracks) {
      expect(track.title, 'Мастер и Маргарита');
      expect(track.artist, 'Михаил Булгаков');
      expect(track.durationMs, 0);
      expect(track.artworkUrl, '');
    }
  });

  test(
    'BookPlayback forwards regular playback tracks into the inner port',
    () async {
      final inner = FakePlayback([
        'https://apertono.test/v1/stream/regular-token',
      ]);
      final client = BookClient(
        (_, _, {body, query}) async => const BookReply(200, {}),
      );
      final playback = BookPlayback(
        inner,
        client: client,
        baseUrl: 'https://apertono.test',
      );

      final url = await playback.start('regular-track-1');
      expect(inner.started, ['regular-track-1']);
      expect(url, 'https://apertono.test/v1/stream/regular-token');

      await playback.failed(url);
      expect(inner.failedUrls, [url]);
    },
  );

  test('BookPlayback fetches book part token via BookClient.play', () async {
    final inner = FakePlayback();
    final calls = <String>[];
    final client = BookClient((method, path, {body, query}) async {
      calls.add('$method $path: $body');
      if (method == 'POST' && path == '/v1/books/$bookId/play') {
        return const BookReply(200, {'token': 'book-tok-2', 'state': 'ready'});
      }
      return const BookReply(404, {'status': 'not_found'});
    });
    final playback = BookPlayback(
      inner,
      client: client,
      baseUrl: 'https://apertono.test',
    );

    final url = await playback.start('book:$bookId:2');
    expect(url, 'https://apertono.test/v1/stream/book-tok-2');
    expect(calls, ['POST /v1/books/$bookId/play: {part: 2}']);
    expect(inner.started, isEmpty);

    // Book part URL failure does not leak into internal port
    await playback.failed(url);
    expect(inner.failedUrls, isEmpty);
  });

  test('BookPlayback maps BookClient errors to PlaybackFailed', () async {
    final inner = FakePlayback();
    for (final (status, reason, expected) in [
      (401, 'signed_out', PlayFailure.noAccess),
      (404, 'not_on_shelf', PlayFailure.unknownTrack),
      (503, 'unavailable', PlayFailure.noSource),
    ]) {
      final client = BookClient(
        (_, _, {body, query}) async => BookReply(status, {'status': reason}),
      );
      final playback = BookPlayback(
        inner,
        client: client,
        baseUrl: 'https://apertono.test',
      );
      expect(
        () => playback.start('book:$bookId:1'),
        throwsA(
          isA<PlaybackFailed>().having((e) => e.reason, 'reason', expected),
        ),
      );
    }
  });

  test('listen starts from saved position in BookProgressStore', () async {
    final box = _MemoryBox();
    final progress = BookProgressStore(box);
    await progress.report(bookId, 2, 45000, force: true);

    final inner = FakePlayback();
    final client = BookClient((_, path, {body, query}) async {
      return const BookReply(200, {'token': 'part-token', 'state': 'ready'});
    });
    final playback = BookPlayback(
      inner,
      client: client,
      baseUrl: 'https://apertono.test',
    );

    final audio = FakeAudio();
    final player = Player(playback: playback, audio: audio);

    await playback.listen(player, progress, sampleBook);

    expect(player.current?.id, 'book:$bookId:2');
    expect(
      audio.played,
      contains((
        'https://apertono.test/v1/stream/part-token',
        // bookResume rewinds 3 s back: user remembers where they were.
        const Duration(milliseconds: 42000),
      )),
    );
  });

  test('remember stores book position and calls BookClient.put', () async {
    final box = _MemoryBox();
    final progress = BookProgressStore(box);

    Map<String, dynamic>? lastPutBatch;
    final client = BookClient((method, path, {body, query}) async {
      if (method == 'POST' && path == '/v1/books/positions') {
        lastPutBatch = body as Map<String, dynamic>?;
        return const BookReply(200, {'positions': {}});
      }
      return const BookReply(200, {'token': 'tok', 'state': 'ready'});
    });
    final playback = BookPlayback(
      FakePlayback(),
      client: client,
      baseUrl: 'https://apertono.test',
    );

    final player = Player(playback: playback, audio: FakeAudio());
    await player.playQueue(BookPlayback.tracksFor(sampleBook), start: 0);

    final reported = playback.remember(
      player,
      progress,
      const Duration(seconds: 15),
      force: true,
    );
    expect(reported, isTrue);

    final pos = progress.of(bookId);
    expect(pos?.part, 1);
    expect(pos?.positionMs, 15000);
    final items = lastPutBatch?['items'] as List?;
    expect((items?.single as Map)['book_id'], bookId);
    expect((items?.single as Map)['position_ms'], 15000);
  });

  test('ServerApi.bookSend performs authorized request', () async {
    final server = FakeServer();
    server.on(
      'GET /v1/books/shelf',
      (_) => answer(200, {
        'books': [
          {
            'id': bookId,
            'title': 'Мастер и Маргарита',
            'author': 'Михаил Булгаков',
            'narrator': '',
            'year': 2011,
            'size_bytes': 52428800,
            'parts': 3,
            'shelved_at': '2026-10-12T10:00:00.000Z',
          },
        ],
      }),
    );

    final api = server.api();
    final reply = await api.bookSend('GET', '/v1/books/shelf');
    expect(reply.status, 200);
    final json = reply.json as Map<String, dynamic>;
    expect(json['books'], isNotEmpty);
    expect(server.calls('GET /v1/books/shelf'), isNotEmpty);
  });
}
