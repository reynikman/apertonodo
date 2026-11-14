import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/app.dart';

import 'fake_server.dart';

/// P-A95: disliked track excluded from auto queue, but manual
/// playback allowed. Album queue: A, B (disliked), C.
void main() {
  const a = 'aaaaaaaa-0000-4000-8000-000000000001';
  const b = 'aaaaaaaa-0000-4000-8000-000000000002';
  const c = 'aaaaaaaa-0000-4000-8000-000000000003';

  late Rig rig;
  late List<String> upcoming;

  Future<void> openAlbum(WidgetTester tester) async {
    rig = Rig();
    upcoming = [];
    rig.server.on('GET /v1/albums/*', (_) {
      final album = sample('catalog-album');
      album['tracks'] = [
        songLike('catalog-album', a, 'Song A'),
        songLike('catalog-album', b, 'Song B'),
        songLike('catalog-album', c, 'Song C'),
      ];
      return answer(200, album);
    });
    rig.server.on('POST /v1/ratings/of', (request) {
      final asked = bodyOf(request)['track_ids'] as List;
      return answer(200, {
        'ratings': {
          if (asked.contains(b)) b: {'stars': 0, 'disliked': true},
        },
      });
    });
    rig.server.on(
      'GET /v1/artist',
      (_) => answer(200, sample('catalog-artist')),
    );
    addTearDown(rig.audio.close);
    await tester.pumpWidget(
      MusicApp(
        catalogSource: rig.server.catalog(),
        playback: rig.playback,
        audio: rig.audio,
        server: rig.server.api(),
        upcoming: (ids) => upcoming = ids,
      ),
    );
    await tester.pumpAndSettle();
    await openTab(tester, 'browse');
    await tapAndSettle(tester, find.text('Рок'));
    await tapAndSettle(tester, find.text('Кино'));
    await tester.ensureVisible(find.text('Группа крови'));
    await tapAndSettle(tester, find.text('Группа крови'));
  }

  /// Play runs spinner, pumpAndSettle will not wait: pump several frames
  /// to deliver dislike response.
  Future<void> settleQueue(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('from start: disliked track removed from queue', (tester) async {
    await openAlbum(tester);

    await tester.tap(find.text('Song A'));
    await settleQueue(tester);

    expect(rig.playback.started.first, a);
    expect(upcoming, [c]);
    final asked = rig.server.bodies('POST /v1/ratings/of').single;
    expect(asked['track_ids'], [b, c], reason: 'skip querying selected track');
  });

  testWidgets('disliked track tapped directly plays, queue continues', (
    tester,
  ) async {
    await openAlbum(tester);

    await tester.tap(find.text('Song B'));
    await settleQueue(tester);

    expect(rig.playback.started.first, b);
    expect(upcoming, [c]);
  });

  testWidgets('ratings fetch failed: queue preserved, Play works', (
    tester,
  ) async {
    await openAlbum(tester);
    rig.server.on('POST /v1/ratings/of', (_) => answer(500, {}));

    await tester.tap(find.text('Song A'));
    await settleQueue(tester);

    expect(rig.playback.started.first, a);
    expect(upcoming, [b, c]);
  });
}
