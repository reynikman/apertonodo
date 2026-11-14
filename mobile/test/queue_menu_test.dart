// Lead check FT-561 (P-A74 "now"): song menu — "Play next",
// "Add to queue end", "Go to artist". Queue is same as player queue
// (`Player.queue`); queued next track (FT-550) becomes newly inserted track.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/models/track.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/player.dart';
import 'package:music_stream/screens/parts.dart';
import 'package:music_stream/theme.dart';

import 'fake_server.dart';
import 'fakes.dart';

Track song(int n, {bool playable = true}) => Track(
  id: '00000000-0000-4000-8000-00000000006$n',
  title: 'Song $n',
  artist: 'Band $n',
  durationMs: 200000,
  artworkUrl: '',
  playable: playable,
);

final album = [song(1), song(2), song(3)];

List<String> ids(List<Track> tracks) => [for (final t in tracks) t.id];

class Bench {
  Bench() {
    player = Player(playback: playback, audio: audio);
  }

  final playback = FakePlayback(['u1', 'u2', 'u3', 'u4', 'u5', 'u6']);
  final audio = FakeAudio();
  late final Player player;

  Future<void> playing() {
    audio.emit(AudioPhase.playing);
    return settle();
  }

  Future<void> album1() async {
    await player.playQueue(album);
    await playing();
  }
}

void main() {
  group('player queue', () {
    test('\'Play next\' right after current, current plays', () async {
      final b = Bench();
      await b.album1();
      await b.player.playNext(song(9));
      await settle();
      expect(ids(b.player.queue), ids([song(1), song(9), song(2), song(3)]));
      expect(b.player.current?.id, song(1).id);
      expect(b.player.phase, AudioPhase.playing);
    });

    test('after \'Play next\', finished track advances to inserted', () async {
      final b = Bench();
      await b.album1();
      await b.player.playNext(song(9));
      await settle();
      // Previously queued next was second album track — now replaced by inserted track.
      if (b.audio.queuedNow != null) {
        b.audio.advance();
      } else {
        b.audio.finish();
      }
      await settle();
      expect(b.player.current?.id, song(9).id);
    });

    test('two \'Play next\' in a row - last tapped plays first', () async {
      final b = Bench();
      await b.album1();
      await b.player.playNext(song(8));
      await b.player.playNext(song(9));
      expect(
        ids(b.player.queue),
        ids([song(1), song(9), song(8), song(2), song(3)]),
      );
    });

    test('\'Add to queue\' - at end, current and next unchanged', () async {
      final b = Bench();
      await b.album1();
      await b.player.enqueue(song(9));
      expect(ids(b.player.queue), ids([...album, song(9)]));
      expect(b.player.current?.id, song(1).id);
      await b.player.next();
      expect(b.player.current?.id, song(2).id);
    });

    test(
      'in shuffled queue, \'Play next\' inserts next in play order',
      () async {
        final b = Bench();
        await b.album1();
        b.player.toggleShuffle();
        await settle();
        await b.player.playNext(song(9));
        final order = ids(b.player.queue);
        expect(order[b.player.queueIndex], b.player.current?.id);
        expect(order[b.player.queueIndex + 1], song(9).id);
        expect(order.length, 4);
      },
    );

    test('nothing playing - both commands start playback', () async {
      final b = Bench();
      await b.player.playNext(song(9));
      await settle();
      expect(b.player.current?.id, song(9).id);

      final c = Bench();
      await c.player.enqueue(song(8));
      await settle();
      expect(c.player.current?.id, song(8).id);
    });
  });

  group('song menu', () {
    late List<String> next;
    late List<String> end;
    late List<String> artists;

    Future<void> pump(
      WidgetTester tester,
      Track track, {
      bool wired = true,
    }) async {
      next = [];
      end = [];
      artists = [];
      final server = FakeServer();
      final services = Services(
        server: server.api(),
        search: server.catalog().search,
        play: (_, _) {},
        prepare: (_) {},
        playNext: wired ? (t) => next.add(t.id) : null,
        enqueue: wired ? (t) => end.add(t.id) : null,
        openArtist: wired ? artists.add : null,
      );
      final hearts = Hearts(services.server)..show([track]);
      addTearDown(hearts.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: apertonoTheme(),
          home: Scaffold(
            body: TrackTile(
              track: track,
              onTap: () {},
              services: services,
              hearts: hearts,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> choose(WidgetTester tester, String item) async {
      await tester.tap(find.byTooltip('Ещё'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(item));
      await tester.pumpAndSettle();
    }

    testWidgets('\'Play next\' and \'Add to queue\' use this song', (
      tester,
    ) async {
      await pump(tester, song(4));
      await choose(tester, 'Играть следующей');
      expect(next, [song(4).id]);
      await choose(tester, 'В конец очереди');
      expect(end, [song(4).id]);
    });

    testWidgets('\'Go to artist\' opens song artist page', (tester) async {
      await pump(tester, song(5));
      await choose(tester, 'К исполнителю');
      expect(artists, ['Band 5']);
    });

    testWidgets('cannot queue unplayable track, can go to artist', (
      tester,
    ) async {
      await pump(tester, song(6, playable: false));
      await tester.tap(find.byTooltip('Ещё'));
      await tester.pumpAndSettle();
      expect(find.text('Играть следующей'), findsNothing);
      expect(find.text('В конец очереди'), findsNothing);
      expect(find.text('К исполнителю'), findsOneWidget);
    });

    testWidgets('no player or pages (shell) - no menu items', (tester) async {
      await pump(tester, song(4), wired: false);
      await tester.tap(find.byTooltip('Ещё'));
      await tester.pumpAndSettle();
      expect(find.text('Играть следующей'), findsNothing);
      expect(find.text('В конец очереди'), findsNothing);
      expect(find.text('К исполнителю'), findsNothing);
      expect(find.text('Добавить в плейлист'), findsOneWidget);
    });
  });
}
