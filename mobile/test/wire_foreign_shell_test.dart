import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_stream/foreign/foreign_library.dart';
import 'package:music_stream/foreign/foreign_playback.dart';
import 'package:music_stream/foreign/foreign_shell.dart';
import 'package:music_stream/l10n/app_localizations.dart';
import 'package:music_stream/player.dart';
import 'package:music_stream/subsonic_client.dart';

import 'fakes.dart';

/// FT-779: Apertono logged into Navidrome or Jellyfin — dedicated lightweight
/// shell: search, library (artists -> albums -> tracks), favorites, and
/// same player. Responses recorded from real Navidrome 0.64.2 (FT-648).
http.Response _reply(String name) {
  final record =
      jsonDecode(
            File(
              'test/fixtures/navidrome_0_64_2/$name.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final type = (record['content_type'] as String? ?? '').split(';').first;
  return http.Response.bytes(
    utf8.encode(jsonEncode(record['json'])),
    record['status'] as int,
    headers: {if (type.isNotEmpty) 'content-type': type},
  );
}

const _byMethod = {
  'search3': 'search_tone',
  'getArtists': 'artists',
  'getArtist': 'artist',
  'getAlbum': 'album',
  'getStarred2': 'starred_one',
  'star': 'star',
  'unstar': 'unstar',
};

const longId = '2llbCRtEv5j7BosspiA3xR';

void main() {
  late List<Uri> asked;
  late FakeAudio audio;
  late Player player;
  late int left;

  Future<void> open(WidgetTester tester) async {
    asked = [];
    left = 0;
    final library = SubsonicLibrary(
      SubsonicClient(
        base: Uri.parse('http://music.test:4533'),
        auth: const SubsonicAuth.password('tester', 'correct horse'),
        client: MockClient((request) async {
          asked.add(request.url);
          final method = request.url.pathSegments.last.replaceAll('.view', '');
          return _reply(_byMethod[method] ?? 'unknown_method');
        }),
      ),
    );
    audio = FakeAudio();
    player = Player(playback: ForeignPlayback(library), audio: audio);
    addTearDown(player.dispose);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ru'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ForeignShell(
          library: library,
          player: player,
          onLeave: () async => left++,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('search: found track plays from foreign server', (tester) async {
    await open(tester);
    await tester.enterText(
      find.byKey(const Key('foreign-search-field')),
      'tone',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Test Tone Long').first);
    await tester.pump();
    await tester.pump();
    final url = Uri.parse(audio.played.last.$1);
    expect(url.host, 'music.test');
    expect(url.path, '/rest/stream.view');
    expect(url.queryParameters['id'], longId);
  });

  testWidgets('mini-player opens full player screen', (tester) async {
    await open(tester);
    await tester.enterText(
      find.byKey(const Key('foreign-search-field')),
      'tone',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Test Tone Long').first);
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const Key('mini-player')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const Key('player-screen')), findsOneWidget);
  });

  testWidgets('library: artist -> album -> tracks', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('foreign-tab-library')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apertono').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Test Tones').first);
    await tester.pumpAndSettle();
    expect(find.text('Test Tone Long'), findsWidgets);
    expect(find.text('Test Tone Short'), findsWidgets);
  });

  testWidgets('favorites: heart track, unstar removes', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('foreign-tab-favorites')));
    await tester.pumpAndSettle();
    expect(find.text('Test Tone Long'), findsWidgets);
    await tester.tap(find.byKey(const Key('foreign-like-$longId')));
    await tester.pumpAndSettle();
    final unstar = asked.where((u) => u.path == '/rest/unstar.view');
    expect(unstar.map((u) => u.queryParameters['id']), [longId]);
  });

  testWidgets('logout returns to login; own server not contacted', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('foreign-leave')));
    await tester.pumpAndSettle();
    expect(left, 1);
    expect(asked.every((u) => u.host == 'music.test'), isTrue);
  });
}
