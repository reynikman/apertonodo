import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/l10n/l10n.dart';
import 'package:music_stream/models/track.dart';
import 'package:music_stream/playback.dart';
import 'package:music_stream/screens/catalog_screens.dart';
import 'package:music_stream/screens/known_as.dart';
import 'package:music_stream/screens/parts.dart';
import 'package:music_stream/screens/player_screen.dart';
import 'package:music_stream/screens/swipe_row.dart';
import 'package:music_stream/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('1. KnownAs (alternate names)', () {
    test('ArtistAlias.listFrom filters empty names and garbage', () {
      final aliases = ArtistAlias.listFrom([
        {'name': '  '},
        {'name': ''},
        {'name': 123},
        null,
        'string',
        {'locale': 'ru'},
        {'name': 'Valid', 'locale': 456},
        {'name': 'Other', 'locale': '  '},
        {'name': 'Proper', 'locale': 'ru'},
      ]);

      expect(aliases, [
        const ArtistAlias('Valid', null),
        const ArtistAlias('Other', null),
        const ArtistAlias('Proper', 'ru'),
      ]);
    });

    test('ArtistAlias.listFrom safely handles non-lists', () {
      expect(ArtistAlias.listFrom(null), isEmpty);
      expect(ArtistAlias.listFrom('not-a-list'), isEmpty);
      expect(ArtistAlias.listFrom(42), isEmpty);
      expect(ArtistAlias.listFrom({'name': 'Metallica'}), isEmpty);
    });

    testWidgets('KnownAs ignores alias identical to artist name', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: apertonoTheme(),
          home: const Scaffold(
            body: KnownAs(
              name: 'Metallica',
              aliases: [
                ArtistAlias('metallica'),
                ArtistAlias(' Metallica '),
                ArtistAlias('METALLICA'),
                ArtistAlias('   '),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('known-as-names')), findsNothing);
    });

    testWidgets('KnownAs does not crash on garbage server response', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final page = sample('catalog-artist-lastfm');
      final artist = page['artist'] as Map<String, dynamic>;
      artist['aliases'] = 'invalid_format';

      final rig = Rig();
      rig.server.on('GET /v1/artist', (_) => answer(200, page));
      await rig.screen(
        tester,
        (services) => ArtistScreen(services: services, name: 'Metallica'),
      );

      expect(find.byKey(const Key('known-as-names')), findsNothing);
    });
  });

  group('2. Preparing audio and buffering', () {
    testWidgets('before first sound, Preparing Audio visible on player', (
      tester,
    ) async {
      final rig = Rig();
      await rig.start(tester);
      await tester.pumpAndSettle();
      await typeSearch(tester, 'metallica');
      await tester.tap(find.text('Nothing Else Matters'));
      await tester.pump();

      // Open full player screen
      await tester.tap(find.byKey(const Key('mini-player')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // Before first audio buffer (AudioPhase.playing has not occurred yet)
      // PlayerScreen displays preparation status
      expect(find.byType(PlayerScreen), findsOneWidget);
      expect(find.byKey(const Key('player-wait')), findsOneWidget);
    });

    testWidgets(
      'during track, player and mini-player do not show Preparing Audio on brief buffering',
      (tester) async {
        final rig = Rig();
        await rig.start(tester);
        await tester.pumpAndSettle();
        await typeSearch(tester, 'metallica');
        await tester.tap(find.text('Nothing Else Matters'));
        await tester.pump();
        rig.audio.emit(AudioPhase.playing);
        await tester.pump();

        // Open player screen
        await tester.tap(find.byKey(const Key('mini-player')));
        await tester.pumpAndSettle();

        // Brief buffering mid-track
        rig.audio.emit(AudioPhase.buffering);
        await tester.pump();
        await tester.pump();

        // No waiting counter on player screen
        expect(find.byKey(const Key('player-wait')), findsNothing);
      },
    );
  });

  group('3. Swipe right', () {
    const playableTrack = Track(
      id: 'track-1',
      title: 'Playable',
      artist: 'Band',
      durationMs: 1000,
      artworkUrl: '',
    );
    const unplayableTrack = Track(
      id: 'track-2',
      title: 'Unplayable',
      artist: 'Band',
      durationMs: 1000,
      artworkUrl: '',
      playable: false,
    );
    const missingTrack = Track(
      id: 'track-3',
      title: 'Missing',
      artist: 'Band',
      durationMs: 1000,
      artworkUrl: '',
      missing: true,
    );

    testWidgets('unavailable or missing track has no SwipeRow', (tester) async {
      final server = FakeServer();
      final services = Services(
        server: server.api(),
        search: server.catalog().search,
        play: (_, _) {},
        prepare: (_) {},
        playNext: (_) {},
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: apertonoTheme(),
          home: Scaffold(
            body: Column(
              children: [
                TrackTile(
                  track: unplayableTrack,
                  onTap: () {},
                  services: services,
                ),
                TrackTile(
                  track: missingTrack,
                  onTap: () {},
                  services: services,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SwipeRow), findsNothing);
    });

    testWidgets('no SwipeRow without playNext', (tester) async {
      final server = FakeServer();
      final services = Services(
        server: server.api(),
        search: server.catalog().search,
        play: (_, _) {},
        prepare: (_) {},
        playNext: null,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: apertonoTheme(),
          home: Scaffold(
            body: TrackTile(
              track: playableTrack,
              onTap: () {},
              services: services,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SwipeRow), findsNothing);
    });

    testWidgets('SwipeRow contains Semantics action for TalkBack', (
      tester,
    ) async {
      final sem = tester.ensureSemantics();
      final server = FakeServer();
      var called = false;
      final services = Services(
        server: server.api(),
        search: server.catalog().search,
        play: (_, _) {},
        prepare: (_) {},
        playNext: (_) => called = true,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: apertonoTheme(),
          home: Scaffold(
            body: TrackTile(
              track: playableTrack,
              onTap: () {},
              services: services,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final node = tester.getSemantics(find.byType(SwipeRow));
      expect(
        node,
        isSemantics(
          customActions: const [
            CustomSemanticsAction(label: 'Играть следующей'),
          ],
        ),
      );
      node.owner!.performAction(
        node.id,
        SemanticsAction.customAction,
        CustomSemanticsAction.getIdentifier(
          const CustomSemanticsAction(label: 'Играть следующей'),
        ),
      );
      await tester.pump();
      expect(called, isTrue);
      sem.dispose();
    });
  });

  group('4. Playlist duplicates', () {
    const found = '11111111-1111-1111-1111-111111111111';

    testWidgets('server error reading playlist notifies user', (tester) async {
      final rig = Rig();
      rig.server.on(
        'GET /v1/playlists/*',
        (_) => answer(500, {'error': 'down'}),
      );
      await rig.start(tester);
      await typeSearch(tester, 'metallica');
      await tapAndSettle(tester, find.byTooltip('Ещё').first);
      await tapAndSettle(tester, find.text('Добавить в плейлист'));
      await tapAndSettle(tester, find.text('В дорогу'));

      expect(find.text('Сервер не ответил'), findsOneWidget);
      expect(rig.server.calls('POST /v1/playlists/*/tracks'), isEmpty);
    });

    testWidgets('single duplicate track hides Only New button', (tester) async {
      final rig = Rig();
      rig.server.on('GET /v1/playlists/*', (_) {
        final body = sample('library-playlist');
        final tracks = body['tracks'] as List;
        (tracks.first as Map<String, dynamic>)['id'] = found;
        return answer(200, body);
      });
      await rig.start(tester);
      await typeSearch(tester, 'metallica');
      await tapAndSettle(tester, find.byTooltip('Ещё').first);
      await tapAndSettle(tester, find.text('Добавить в плейлист'));
      await tapAndSettle(tester, find.text('В дорогу'));

      expect(find.text('Добавить все'), findsOneWidget);
      expect(find.text('Только новые'), findsNothing);
      expect(find.text('Отмена'), findsOneWidget);
    });

    testWidgets('plural forms in Russian and English (1, 2, 5, 21)', (
      tester,
    ) async {
      late AppLocalizations ruText;
      late AppLocalizations enText;

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ru'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              ruText = l10n(context);
              return const SizedBox();
            },
          ),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              enText = l10n(context);
              return const SizedBox();
            },
          ),
        ),
      );

      // Russian language
      expect(ruText.partsDuplicatesTitle(1), '1 песня уже есть в плейлисте');
      expect(ruText.partsDuplicatesTitle(2), '2 песни уже есть в плейлисте');
      expect(ruText.partsDuplicatesTitle(5), '5 песен уже есть в плейлисте');
      expect(ruText.partsDuplicatesTitle(21), '21 песня уже есть в плейлисте');

      // English language
      expect(
        enText.partsDuplicatesTitle(1),
        '1 song is already in the playlist',
      );
      expect(
        enText.partsDuplicatesTitle(2),
        '2 songs are already in the playlist',
      );
      expect(
        enText.partsDuplicatesTitle(5),
        '5 songs are already in the playlist',
      );
      expect(
        enText.partsDuplicatesTitle(21),
        '21 songs are already in the playlist',
      );
    });
  });
}
