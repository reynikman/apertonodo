import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_stream/app.dart';
import 'package:music_stream/catalog.dart';
import 'package:music_stream/device_library.dart';
import 'package:music_stream/models/track.dart';
import 'package:music_stream/loudness.dart';
import 'package:music_stream/opened_audio.dart';
import 'package:music_stream/prefetch_policy.dart';
import 'package:music_stream/quality_prefs.dart';
import 'package:music_stream/track_formats.dart';
import 'package:music_stream/screens/parts.dart';
import 'package:music_stream/server_api.dart';

import 'fakes.dart';

const base = 'http://apertono.test';

/// Server response sample is a contract, not a test invention.
///
/// Shared `contracts/` at root, single copy. Until 20.09.2026 byte-for-byte
/// copies were nearby (`mobile/test/contracts/`): branches of phases F, F2 and H were
/// not yet merged then, and there was nowhere to take samples from. Now merged, and
/// copies drifted from original on very first response edit — exactly
/// why fixtures were made shared in the first place.
Map<String, dynamic> sample(String name) {
  final file = File('../contracts/$name.response.json');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

/// Track shaped like first track of fixture [name]: same fields, custom values.
Map<String, dynamic> songLike(
  String name,
  String id,
  String title, {
  bool playable = true,
}) {
  final first = (sample(name)['tracks'] as List<dynamic>).first;
  return {
    ...first as Map<String, dynamic>,
    'id': id,
    'title': title,
    'playable': playable,
  };
}

/// Album from fixture F with different tracks.
Map<String, dynamic> albumOf(
  List<String> titles, {
  Set<String> dead = const {},
}) {
  return sample('catalog-album')
    ..['tracks'] = [
      for (var i = 0; i < titles.length; i++)
        {
          ...songLike(
            'catalog-album',
            songId(titles[i]),
            titles[i],
            playable: !dead.contains(titles[i]),
          ),
          'position': i + 1,
        },
    ];
}

/// Playlist from fixture H with different tracks.
Map<String, dynamic> playlistOf(
  List<String> titles, {
  Set<String> dead = const {},
}) {
  return sample('library-playlist')
    ..['tracks'] = [
      for (final title in titles)
        songLike(
          'library-playlist',
          songId(title),
          title,
          playable: !dead.contains(title),
        ),
    ];
}

/// Stable track id derived from title — so test has something consistent to verify.
String songId(String title) {
  final n = title.codeUnits.fold(0, (sum, unit) => (sum * 31 + unit) % 1000000);
  return 'a0000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';
}

http.Response answer(int status, Object body) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    status,
    headers: {'content-type': 'application/json'},
  );
}

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

/// "GET /v1/albums/*": method and path, id wildcarded.
String routeOf(http.BaseRequest request) {
  final path = request.url.pathSegments
      .map((part) => _uuid.hasMatch(part) ? '*' : part)
      .join('/');
  return '${request.method} /$path';
}

/// Server backed by fixtures: each path answers with its fixture, test can
/// override responses via [on]. All requests are recorded.
class FakeServer {
  FakeServer() {
    final liked = sample('library-favorites-contains')['track_ids'] as List;
    this.liked.addAll(liked.cast<String>());
  }

  final requests = <http.Request>[];
  late final tokens = tokensFor(base);

  /// Paths unknown to server: test must keep them empty.
  final unknown = <String>[];

  /// What is favorited — `favorites/contains` response for queried ids.
  final liked = <String>{};

  late final Map<String, http.Response Function(http.Request)> _routes = {
    'GET /v1/search': (_) => answer(200, sample('search')),
    'GET /v1/suggest': (_) => answer(200, sample('suggest')),
    'GET /v1/genres': (_) => answer(200, sample('catalog-genres')),
    // FT-800: configured by default, "Browse" tiles are active.
    'GET /v1/features': (_) => answer(200, {'books': true, 'podcasts': true}),
    'GET /v1/letters': (_) => answer(200, sample('catalog-letters')),
    // Fixture contains one artist out of 5834; server serves nothing further.
    'GET /v1/artists': (request) => request.url.queryParameters['offset'] == '0'
        ? answer(200, sample('catalog-artists'))
        : answer(200, {'artists': const [], 'total': 5834}),
    'GET /v1/artist': (_) => answer(200, sample('catalog-artist-lastfm')),
    'GET /v1/albums/*': (_) => answer(200, sample('catalog-album')),
    'GET /v1/favorites': (_) => answer(200, sample('library-favorites')),
    'POST /v1/favorites': (request) {
      liked.add(bodyOf(request)['track_id'] as String);
      return answer(200, {'status': 'ok'});
    },
    'POST /v1/favorites/remove': (request) {
      liked.remove(bodyOf(request)['track_id']);
      return answer(200, {'status': 'ok'});
    },
    'POST /v1/favorites/contains': (request) => answer(200, {
      'track_ids': [
        for (final id in bodyOf(request)['track_ids'] as List)
          if (liked.contains(id)) id,
      ],
    }),
    // Queue queries "disliked" for tracks queued automatically (P-A95).
    'POST /v1/ratings/of': (_) => answer(200, {'ratings': {}}),
    // FT-843: the player asks for lyrics once per song; no answer keeps the button ordinary.
    'GET /v1/lyrics/*': (_) => answer(404, const {}),
    'GET /v1/history': (_) => answer(200, sample('library-history')),
    'POST /v1/history': (_) => answer(200, sample('library-history-add')),
    // History pause state: history screen queries it on open.
    'GET /v1/history/pause': (_) => answer(200, {'paused': false}),
    // Scrobbling services (FT-631, FT-645): nothing connected by default.
    'GET /v1/scrobble': (_) => answer(200, {'listenbrainz': 'off'}),
    'GET /v1/scrobble/lastfm': (_) => answer(200, {'lastfm': 'off'}),
    'POST /v1/scrobble/listenbrainz': (_) =>
        answer(200, {'listenbrainz': 'on'}),
    'GET /v1/playlists': (_) => answer(200, sample('library-playlists')),
    'POST /v1/playlists': (request) => answer(201, {
      'id': '0a0a0a0a-0000-4000-8000-000000000001',
      'name': bodyOf(request)['name'],
      'tracks': 0,
    }),
    'GET /v1/playlists/*': (_) => answer(200, sample('library-playlist')),
    'POST /v1/playlists/*/rename': (_) => answer(200, {'status': 'ok'}),
    'POST /v1/playlists/*/delete': (_) => answer(200, {'status': 'ok'}),
    'POST /v1/playlists/*/tracks': (_) => answer(200, {'status': 'ok'}),
    'POST /v1/playlists/*/tracks/remove': (_) => answer(200, {'status': 'ok'}),
    'POST /v1/playlists/*/order': (_) => answer(200, {'status': 'ok'}),
    // Feed (FT-580): subscriptions and empty feed suggestions. Empty by default;
    // test configures responses via [on].
    'GET /v1/news/follows': (_) => answer(200, {'artists': const []}),
    'POST /v1/news/follows': (_) => answer(200, {'status': 'ok'}),
    'POST /v1/news/follows/remove': (_) => answer(200, {'status': 'ok'}),
    'GET /v1/news/suggestions': (_) =>
        answer(200, {'source': 'popular', 'artists': const []}),
    // Episode progress positions (FT-735): app syncs them at startup.
    'GET /v1/podcasts/progress': (request) => answer(200, {
      'items': const [],
      'mark': int.parse(request.url.queryParameters['after'] ?? '0'),
    }),
    'POST /v1/podcasts/progress': (_) => answer(200, {'items': const []}),
    // Books (FT-773): shelf, search, parts, positions.
    'GET /v1/books/shelf': (_) => answer(200, {'books': const []}),
    'POST /v1/books/shelf': (request) => answer(200, {
      'state': 'ok',
      'book': {
        'id': '0b000000-0000-4000-8000-000000000001',
        'title': 'Книга',
        'parts': 1,
      },
    }),
    'POST /v1/books/shelf/*/remove': (_) => answer(200, {'status': 'ok'}),
    'GET /v1/books/search': (_) => answer(200, {'books': const []}),
    'GET /v1/books/*': (_) => answer(200, {
      'book': {
        'id': '0b000000-0000-4000-8000-000000000001',
        'title': 'Книга',
        'parts': 1,
      },
      'parts': const [],
    }),
    'POST /v1/books/*/play': (_) =>
        answer(200, {'token': 'play-token', 'state': 'ready'}),
    'GET /v1/books/positions': (request) => answer(200, {
      'items': const [],
      'mark': int.parse(request.url.queryParameters['after'] ?? '0'),
    }),
    'POST /v1/books/positions': (_) => answer(200, {'items': const []}),
  };

  void on(String route, http.Response Function(http.Request) respond) {
    _routes[route] = respond;
  }

  /// Response to [route] arrives when test completes returned [Completer]:
  /// "server responded later than human took action".
  Completer<http.Response> later(String route) {
    final reply = Completer<http.Response>();
    _later[route] = reply;
    return reply;
  }

  final _later = <String, Completer<http.Response>>{};

  /// Path fails with code [status] and body `{"status": name}` — like real server,
  /// — until test calls the returned fix function.
  void Function() fail(String route, int status, String name) {
    final normal = _routes[route]!;
    var failing = true;
    _routes[route] = (request) =>
        failing ? answer(status, {'status': name}) : normal(request);
    return () => failing = false;
  }

  late final client = MockClient((request) async {
    requests.add(request);
    final held = _later.remove(routeOf(request));
    if (held != null) return held.future;
    final respond = _routes[routeOf(request)];
    if (respond == null) {
      unknown.add(routeOf(request));
      return answer(599, const {});
    }
    return respond(request);
  });

  ServerApi api() => ServerApi(base, client: client, tokens: tokens);

  HttpCatalog catalog() => HttpCatalog(base, client: client, tokens: tokens);

  List<http.Request> calls(String route) => [
    for (final request in requests)
      if (routeOf(request) == route) request,
  ];

  List<Map<String, dynamic>> bodies(String route) => [
    for (final request in calls(route)) bodyOf(request),
  ];
}

Map<String, dynamic> bodyOf(http.Request request) =>
    jsonDecode(request.body) as Map<String, dynamic>;

/// Full app, as built, but with mocked server and player.
class Rig {
  Rig({
    FakeServer? server,
    QualityPrefs? quality,
    this.formats,
    this.prefetch,
    this.loudness,
    this.opened,
    this.deviceMedia,
    this.account = false,
  }) : server = server ?? FakeServer(),
       playback = FakePlayback(),
       audio = FakeAudio(),
       quality = quality ?? QualityPrefs();

  final FakeServer server;
  final FakePlayback playback;
  final FakeAudio audio;

  /// Audio quality in player menu (FT-633).
  final QualityPrefs quality;

  /// File formats for player badge (FT-633).
  final TrackFormats? formats;

  /// Preload next track (FT-692).
  final PrefetchPolicy? prefetch;

  /// ReplayGain volume normalization (FT-765).
  final LoudnessGate? loudness;

  /// "Open with" (FT-767).
  final OpenedAudioChannel? opened;

  /// Local audio files on phone (FT-783).
  final DeviceMediaPort? deviceMedia;

  /// Whether to show account button: general settings behind it (FT-804).
  final bool account;

  /// What screen without menu ([screen]) queued: list and starting index.
  final played = <(List<Track>, int)>[];

  /// What screen without menu requested to preload (track IDs).
  final prepared = <String>[];

  Future<void> start(WidgetTester tester) async {
    addTearDown(audio.close);
    addTearDown(() => expect(server.unknown, isEmpty));
    await tester.pumpWidget(
      MusicApp(
        catalogSource: server.catalog(),
        playback: playback,
        audio: audio,
        server: server.api(),
        quality: quality,
        formats: formats,
        prefetch: prefetch,
        loudness: loudness,
        opened: opened,
        deviceMedia: deviceMedia,
        onAccountAction: account ? (_) async {} : null,
      ),
    );
  }

  /// Screen standalone, without menu: for failure checks and edge cases.
  Future<Services> screen(
    WidgetTester tester,
    Widget Function(Services services) build,
  ) async {
    addTearDown(() => expect(server.unknown, isEmpty));
    final services = Services(
      server: server.api(),
      search: server.catalog().search,
      play: (tracks, index) => played.add((tracks, index)),
      prepare: (track) => prepared.add(track.id),
    );
    await tester.pumpWidget(MaterialApp(home: build(services)));
    await tester.pumpAndSettle();
    return services;
  }
}

/// Search is third tab (FT-472). Without server tabs are absent, search is already on
/// screen; if nested search open (top artist track) — type into it.
Future<void> typeSearch(WidgetTester tester, String query) async {
  final field = find.byKey(const Key('search-field')).hitTestable();
  if (field.evaluate().isEmpty) {
    await openTab(tester, 'search');
  }
  await tester.enterText(field, query);
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pumpAndSettle();
}

Future<void> tapAndSettle(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// Bottom bar tab: `home`, `browse`, `search`, `library`. No labels on
/// bar (Figma export, FT-471), so tests tap by key, not label.
Future<void> openTab(WidgetTester tester, String name) =>
    tapAndSettle(tester, find.byKey(Key('tab-$name')));

/// "Audio quality" lives in general settings — account menu (FT-804), not in
/// player menu. Open player collapses first.
Future<void> openSoundQuality(WidgetTester tester) async {
  final close = find.byKey(const Key('player-close'));
  if (close.evaluate().isNotEmpty) await tapAndSettle(tester, close);
  await openTab(tester, 'library');
  await tapAndSettle(tester, find.byKey(const Key('account-button')));
  await tapAndSettle(tester, find.byKey(const Key('sound-quality')));
}

/// Text color as painted: dimmed is semi-transparent.
double alphaOf(WidgetTester tester, String text) {
  final paragraph = tester.renderObject<RenderParagraph>(find.text(text).first);
  return paragraph.text.style!.color!.a;
}

/// Browse → genre → "Кино" → "Группа крови", via menu, as a human would.
Future<void> openAlbum(WidgetTester tester, Rig rig) async {
  rig.server.on('GET /v1/artist', (_) => answer(200, sample('catalog-artist')));
  await rig.start(tester);
  await openTab(tester, 'browse');
  await tapAndSettle(tester, find.text('Рок'));
  await tapAndSettle(tester, find.text('Кино'));
  await tester.ensureVisible(find.text('Группа крови'));
  await tapAndSettle(tester, find.text('Группа крови'));
}
