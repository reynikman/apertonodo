// FT-662 (P-A93, block B-5): podcasts — app communication with server.
//
// Server serves podcasts via seven endpoints (FT-661). Here — client implementation
// on device: parse responses into models, map server errors into reasons
// displayable on screen, provide real port for progress sync (FT-659).
// No network in module: request sent via `PodcastSend`, wired by lead.
//
// Contract `lib/podcast_client.dart`:
// - `PodcastReply(status, json)`; `typedef PodcastSend = Future<PodcastReply>
//   Function(String method, String path, {Map<String, String>? query,
//   Object? body})`;
// - `enum PodcastFailure { offline, unavailable, searchUnavailable, badUrl,
//   limit, notSubscribed, signedOut, broken }`; `PodcastException(reason)`;
// - `FoundPodcast`, `PodcastSubscription`, `PodcastEpisode` with
//   `static T? fromJson(Object?)`; `PodcastSubscribed(feedUrl, isNew:)`;
// - `podcastHttpUrl(Object?) -> String?`;
// - `PodcastClient(send) implements PodcastSyncPort`: `search`,
//   `subscriptions`, `subscribe`, `unsubscribe`, `episodes`, `put`, `changes`.
//
// Guarded:
// - foreign server does not crash app: malformed response yields skipped
//   row or `broken`, never unexpected exception type;
// - audio and image URLs — http(s) only, no credentials: `file:` and
//   `content:` never reach player;
// - invisible and bidi override characters in titles stripped from screen;
// - `toString()` of models and exceptions excludes URLs and titles.
//
// What test does not prove: real network and server not used.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/podcast_client.dart';
import 'package:music_stream/podcast_progress.dart';
import 'package:music_stream/podcast_sync.dart';

const feed = 'https://feeds.example.org/secret-show.xml';
const stamp = '2026-10-01T11:00:00.000Z';

class Call {
  final String method;
  final String path;
  final Map<String, String>? query;
  final Object? body;
  Call(this.method, this.path, this.query, this.body);
}

class Wire {
  final List<Call> calls = [];
  PodcastReply reply = const PodcastReply(200, <String, Object?>{});
  Object? error;

  Future<PodcastReply> send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
  }) async {
    calls.add(Call(method, path, query, body));
    if (error != null) throw error!;
    return reply;
  }

  void answer(Object? json, [int status = 200]) {
    reply = PodcastReply(status, json);
  }
}

Map<String, Object?> episode([Map<String, Object?> over = const {}]) => {
  'guid': 'guid-1',
  'title': 'Secret Episode',
  'description': 'About secrets',
  'audio_url': 'https://cdn.example.org/1.mp3',
  'audio_type': 'audio/mpeg',
  'audio_bytes': 1000,
  'duration_ms': 600000,
  'published': '2026-09-03T10:00:00.000Z',
  'image': 'https://img.example.org/e.jpg',
  'season': 2,
  'number': 7,
  'explicit': true,
  ...over,
};

Map<String, Object?> subscription([Map<String, Object?> over = const {}]) => {
  'feed_url': feed,
  'title': 'Secret Show',
  'author': 'Secret Author',
  'image': 'https://img.example.org/s.jpg',
  'episodes': 3,
  'newest_at': '2026-09-03T10:00:00.000Z',
  'added_at': '2026-10-01T09:00:00.000Z',
  ...over,
};

Map<String, Object?> found([Map<String, Object?> over = const {}]) => {
  'feed_url': feed,
  'title': 'Secret Show',
  'author': 'Secret Author',
  'image': 'https://img.example.org/s.jpg',
  'episodes': 42,
  ...over,
};

EpisodeProgress progress([int ms = 60000]) => EpisodeProgress(
  positionMs: ms,
  done: false,
  updatedAt: DateTime.parse(stamp),
);

Matcher fails(PodcastFailure reason) =>
    throwsA(isA<PodcastException>().having((e) => e.reason, 'reason', reason));

final List<Object?> garbage = [
  null,
  5,
  'x',
  true,
  <Object?>[],
  <String, Object?>{},
  <String, Object?>{'podcasts': 5, 'episodes': 'x', 'items': null},
];

void main() {
  late Wire wire;
  late PodcastClient client;

  setUp(() {
    wire = Wire();
    client = PodcastClient(wire.send);
  });

  group('address', () {
    test('only http and https', () {
      expect(podcastHttpUrl('https://a.example.org/x.mp3'), isNotNull);
      expect(podcastHttpUrl('http://a.example.org/x.mp3'), isNotNull);
      for (final bad in <Object?>[
        null,
        5,
        '',
        'file:///sdcard/x.mp3',
        'content://media/1',
        'javascript:alert(1)',
        'ftp://a.example.org/x',
        'https:///x.mp3',
        'https://',
        '/x.mp3',
        'a.example.org/x.mp3',
        'https://user:pass@a.example.org/x.mp3',
        'https://user@a.example.org/x.mp3',
        ' https://a.example.org/x.mp3',
        'https://a.example.org/x.mp3 ',
        'https://a.example.org/x y.mp3',
        'https://a.example.org/x\n.mp3',
        'https://a.example.org/x\t.mp3',
        'https://a.example.org/${String.fromCharCode(0)}',
        'https://a.example.org/${'a' * 2048}',
      ]) {
        expect(podcastHttpUrl(bad), isNull, reason: '$bad');
      }
    });

    test('URL returns as received', () {
      const url = 'https://A.example.org:8443/x%20y.mp3?a=1&b=2';
      expect(podcastHttpUrl(url), url);
      expect(podcastHttpUrl('https://a.example.org/${'a' * 2020}'), isNotNull);
    });
  });

  group('episode', () {
    test('parsed completely', () {
      final e = PodcastEpisode.fromJson(episode())!;
      expect(e.guid, 'guid-1');
      expect(e.title, 'Secret Episode');
      expect(e.description, 'About secrets');
      expect(e.audioUrl, 'https://cdn.example.org/1.mp3');
      expect(e.audioType, 'audio/mpeg');
      expect(e.audioBytes, 1000);
      expect(e.durationMs, 600000);
      expect(e.published, DateTime.utc(2026, 9, 3, 10));
      expect(e.published!.isUtc, isTrue);
      expect(e.image, 'https://img.example.org/e.jpg');
      expect(e.season, 2);
      expect(e.number, 7);
      expect(e.explicit, isTrue);
    });

    test('optional fields may be absent', () {
      final e = PodcastEpisode.fromJson({
        'guid': 'g',
        'audio_url': 'https://cdn.example.org/1.mp3',
      })!;
      expect(e.title, '');
      expect(e.description, '');
      expect(e.audioType, isNull);
      expect(e.audioBytes, isNull);
      expect(e.durationMs, isNull);
      expect(e.published, isNull);
      expect(e.image, isNull);
      expect(e.season, isNull);
      expect(e.number, isNull);
      expect(e.explicit, isFalse);
    });

    test('no episode without number or audio', () {
      for (final over in <Map<String, Object?>>[
        {'guid': null},
        {'guid': ''},
        {'guid': 5},
        {'guid': 'g' * 2049},
        {'audio_url': null},
        {'audio_url': 'file:///sdcard/secret.mp3'},
        {'audio_url': 'content://media/1'},
        {'audio_url': 5},
      ]) {
        expect(PodcastEpisode.fromJson(episode(over)), isNull, reason: '$over');
      }
      for (final bad in garbage) {
        expect(PodcastEpisode.fromJson(bad), isNull);
      }
    });

    test('episode number not cleaned: key for resume position', () {
      final guid = ' guid\twith${String.fromCharCode(0xa0)}spaces ';
      expect(PodcastEpisode.fromJson(episode({'guid': guid}))!.guid, guid);
    });

    test('malformed fields become empty, not breaking parsing', () {
      final e = PodcastEpisode.fromJson(
        episode({
          'title': 5,
          'description': <Object?>[],
          'audio_type': 7,
          'audio_bytes': -1,
          'duration_ms': 'long',
          'published': 'yesterday',
          'image': 'file:///x.jpg',
          'season': 1.5,
          'number': -3,
          'explicit': 'yes',
        }),
      )!;
      expect(e.title, '');
      expect(e.description, '');
      expect(e.audioType, isNull);
      expect(e.audioBytes, isNull);
      expect(e.durationMs, isNull);
      expect(e.published, isNull);
      expect(e.image, isNull);
      expect(e.season, isNull);
      expect(e.number, isNull);
      expect(e.explicit, isFalse);
    });

    test('zero duration — unknown', () {
      expect(
        PodcastEpisode.fromJson(episode({'duration_ms': 0}))!.durationMs,
        isNull,
      );
    });

    test('time without Z not treated as local', () {
      expect(
        PodcastEpisode.fromJson(
          episode({'published': '2026-09-03T10:00:00.000'}),
        )!.published,
        isNull,
      );
    });

    test('long texts are truncated', () {
      final e = PodcastEpisode.fromJson(
        episode({'title': 'т' * 600, 'description': 'о' * 5000}),
      )!;
      expect(e.title.length, 500);
      expect(e.description.length, 4000);
    });

    test('surrogate pair character not split in half', () {
      final e = PodcastEpisode.fromJson(episode({'title': '🎧' * 600}))!;
      expect(e.title.runes.length, 500);
      expect(e.title.length, 1000);
      expect(e.title, '🎧' * 500);
    });

    test('invisible and bidi-override chars filtered out', () {
      final nasty = [
        0x00,
        0x07,
        0x0a,
        0x1b,
        0x7f,
        0x85,
        0x200e,
        0x200f,
        0x202a,
        0x202e,
        0x2066,
        0x2069,
      ];
      for (final code in nasty) {
        final raw = 'Secret${String.fromCharCode(code)}Episode';
        final e = PodcastEpisode.fromJson(
          episode({'title': raw, 'description': raw}),
        )!;
        expect(e.title, 'Secret Episode', reason: code.toRadixString(16));
        expect(e.description, 'Secret Episode');
      }
      final e = PodcastEpisode.fromJson(episode({'title': ' \n\t '}))!;
      expect(e.title, '');
    });

    test('lone surrogate replaced: screen crashes from it', () {
      // Flutter does not render string with lone surrogate: "string is not well-formed UTF-16".
      final high = String.fromCharCode(0xd83d);
      final low = String.fromCharCode(0xdc00);
      final mark = String.fromCharCode(0xfffd);
      final e = PodcastEpisode.fromJson(
        episode({
          'title': 'Secret${high}Episode$low',
          'description': '$low🎧$high',
        }),
      )!;
      expect(e.title, 'Secret${mark}Episode$mark');
      expect(e.description, '$mark🎧$mark');
      final cut = PodcastEpisode.fromJson(
        episode({'title': '${'🎧' * 499}$high$high'}),
      )!;
      expect(cut.title, '${'🎧' * 499}$mark', reason: 'cut is intact');
    });

    test('regular characters are not touched', () {
      const title = 'Ёлка — «выпуск» №5 🎧 日本語';
      expect(PodcastEpisode.fromJson(episode({'title': title}))!.title, title);
    });
  });

  group('subscription and search hit', () {
    test('subscription parsed completely', () {
      final s = PodcastSubscription.fromJson(subscription())!;
      expect(s.feedUrl, feed);
      expect(s.title, 'Secret Show');
      expect(s.author, 'Secret Author');
      expect(s.image, 'https://img.example.org/s.jpg');
      expect(s.episodes, 3);
      expect(s.newestAt, DateTime.utc(2026, 9, 3, 10));
      expect(s.addedAt, DateTime.utc(2026, 10, 1, 9));
    });

    test('feed not yet fetched: no title', () {
      final s = PodcastSubscription.fromJson(
        subscription({
          'title': null,
          'author': '',
          'image': null,
          'episodes': 0,
          'newest_at': null,
        }),
      )!;
      expect(s.title, isNull);
      expect(s.author, '');
      expect(s.image, isNull);
      expect(s.episodes, 0);
      expect(s.newestAt, isNull);
    });

    test('subscription without valid URL cannot exist', () {
      for (final bad in <Object?>[null, '', 5, 'file:///x', 'not a url']) {
        expect(
          PodcastSubscription.fromJson(subscription({'feed_url': bad})),
          isNull,
        );
      }
      for (final bad in garbage) {
        expect(PodcastSubscription.fromJson(bad), isNull);
      }
    });

    test('subscription image — also http(s) only', () {
      for (final bad in <Object?>['file:///x.jpg', 'content://media/1', 5]) {
        expect(
          PodcastSubscription.fromJson(subscription({'image': bad}))!.image,
          isNull,
        );
      }
    });

    test('malformed episode count — zero', () {
      for (final bad in <Object?>[null, -1, 'x', 1.5]) {
        expect(
          PodcastSubscription.fromJson(
            subscription({'episodes': bad}),
          )!.episodes,
          0,
        );
      }
    });

    test('search hit parsed completely', () {
      final f = FoundPodcast.fromJson(found())!;
      expect(f.feedUrl, feed);
      expect(f.title, 'Secret Show');
      expect(f.author, 'Secret Author');
      expect(f.image, 'https://img.example.org/s.jpg');
      expect(f.episodes, 42);
    });

    test('search hit requires URL and title', () {
      expect(FoundPodcast.fromJson(found({'feed_url': 'x'})), isNull);
      expect(FoundPodcast.fromJson(found({'title': null})), isNull);
      expect(FoundPodcast.fromJson(found({'title': '  '})), isNull);
      for (final bad in garbage) {
        expect(FoundPodcast.fromJson(bad), isNull);
      }
      final f = FoundPodcast.fromJson({'feed_url': feed, 'title': 'T'})!;
      expect(f.author, '');
      expect(f.image, isNull);
      expect(f.episodes, isNull);
    });

    test('no bidi override in subscription or hit title', () {
      final raw = 'Secret${String.fromCharCode(0x202e)}Show';
      expect(
        PodcastSubscription.fromJson(subscription({'title': raw}))!.title,
        'Secret Show',
      );
      expect(
        FoundPodcast.fromJson(found({'title': raw}))!.title,
        'Secret Show',
      );
      expect(
        FoundPodcast.fromJson(found({'author': raw}))!.author,
        'Secret Show',
      );
    });
  });

  group('search', () {
    test('queries server and parses response', () async {
      wire.answer({
        'podcasts': [
          found(),
          found({'feed_url': 'https://b.example.org/f', 'title': 'Other'}),
        ],
      });
      final result = await client.search('  secret show ');
      expect(result.map((f) => f.title), ['Secret Show', 'Other']);
      final call = wire.calls.single;
      expect(call.method, 'GET');
      expect(call.path, '/v1/podcasts/search');
      expect(call.query, {'q': 'secret show', 'limit': '20'});
      expect(call.body, isNull);
    });

    test('short query not sent to server', () async {
      for (final q in ['', ' ', 'a', ' a ']) {
        expect(await client.search(q), isEmpty);
      }
      expect(wire.calls, isEmpty);
    });

    test('limit and query length are bounded', () async {
      wire.answer({'podcasts': <Object?>[]});
      await client.search('secret', limit: 500);
      await client.search('secret', limit: 0);
      await client.search('s' * 300, limit: 7);
      expect(wire.calls[0].query!['limit'], '50');
      expect(wire.calls[1].query!['limit'], '1');
      expect(wire.calls[2].query, {'q': 's' * 200, 'limit': '7'});
    });

    test('malformed rows skipped, duplicates collapsed', () async {
      wire.answer({
        'podcasts': [
          null,
          5,
          found({'feed_url': 'file:///x'}),
          found(),
          found({'title': 'Duplicate'}),
        ],
      });
      final result = await client.search('secret');
      expect(result.map((f) => f.title), ['Secret Show']);
    });

    test('directory unreachable — distinct reason', () async {
      wire.answer({'status': 'podcast_search_unavailable'}, 503);
      await expectLater(
        client.search('secret'),
        fails(PodcastFailure.searchUnavailable),
      );
      wire.answer({'status': 'library_unavailable'}, 503);
      await expectLater(
        client.search('secret'),
        fails(PodcastFailure.unavailable),
      );
    });

    test('list is unmodifiable', () async {
      wire.answer({
        'podcasts': [found()],
      });
      final result = await client.search('secret');
      expect(() => result.add(result.first), throwsUnsupportedError);
    });
  });

  group('subscriptions', () {
    test('list', () async {
      wire.answer({
        'podcasts': [
          subscription(),
          'x',
          subscription({'feed_url': 'nope'}),
          subscription({'title': 'Duplicate'}),
        ],
      });
      final result = await client.subscriptions();
      expect(result.map((s) => s.title), ['Secret Show']);
      final call = wire.calls.single;
      expect((call.method, call.path), ('GET', '/v1/podcasts'));
      expect(call.query, isNull);
      expect(call.body, isNull);
      expect(() => result.clear(), throwsUnsupportedError);
    });

    test('subscribe: new and existing', () async {
      wire.answer({'result': 'new', 'feed_url': feed});
      final first = await client.subscribe(' HTTPS://Feeds.example.org/x ');
      expect((first.feedUrl, first.isNew), (feed, true));
      final call = wire.calls.single;
      expect((call.method, call.path), ('POST', '/v1/podcasts/subscribe'));
      expect(call.body, {'feed_url': ' HTTPS://Feeds.example.org/x '});
      expect(call.query, isNull);

      wire.answer({'result': 'exists', 'feed_url': feed});
      final second = await client.subscribe(feed);
      expect((second.feedUrl, second.isNew), (feed, false));
    });

    test('subscribe: server errors', () async {
      wire.answer({'status': 'bad_url'}, 422);
      await expectLater(client.subscribe('x'), fails(PodcastFailure.badUrl));
      wire.answer({'status': 'limit'}, 409);
      await expectLater(client.subscribe(feed), fails(PodcastFailure.limit));
      wire.answer({'status': 'invalid_request'}, 400);
      await expectLater(client.subscribe(feed), fails(PodcastFailure.broken));
    });

    test('subscribe: unrecognized reply — broken', () async {
      for (final bad in <Object?>[
        ...garbage,
        {'result': 'new'},
        {'result': 'new', 'feed_url': 'file:///x'},
        {'result': 'maybe', 'feed_url': feed},
        {'feed_url': feed},
      ]) {
        wire.answer(bad);
        await expectLater(
          client.subscribe(feed),
          fails(PodcastFailure.broken),
          reason: '$bad',
        );
      }
    });

    test('unsubscribe', () async {
      wire.answer({'removed': true});
      expect(await client.unsubscribe(feed), isTrue);
      final call = wire.calls.single;
      expect((call.method, call.path), ('POST', '/v1/podcasts/unsubscribe'));
      expect(call.body, {'feed_url': feed});
      wire.answer({'removed': false});
      expect(await client.unsubscribe(feed), isFalse);
      for (final bad in <Object?>[
        ...garbage,
        {'removed': 'yes'},
        {'removed': 1},
      ]) {
        wire.answer(bad);
        await expectLater(
          client.unsubscribe(feed),
          fails(PodcastFailure.broken),
        );
      }
    });
  });

  group('episodes', () {
    test('episodes page', () async {
      wire.answer({
        'episodes': [
          episode(),
          episode({'guid': 'guid-2', 'title': 'Second'}),
          episode({'guid': 'guid-1', 'title': 'Duplicate'}),
          episode({'audio_url': 'file:///x.mp3', 'guid': 'guid-3'}),
          7,
        ],
      });
      final result = await client.episodes(feed);
      expect(result.map((e) => e.title), ['Secret Episode', 'Second']);
      final call = wire.calls.single;
      expect((call.method, call.path), ('GET', '/v1/podcasts/episodes'));
      expect(call.query, {'feed_url': feed, 'limit': '50', 'offset': '0'});
      expect(call.body, isNull);
      expect(() => result.clear(), throwsUnsupportedError);
    });

    test('«from first» requests order=oldest (FT-732)', () async {
      wire.answer({'episodes': <Object?>[]});
      await client.episodes(feed, oldestFirst: true);
      expect(wire.calls.single.query, {
        'feed_url': feed,
        'limit': '50',
        'offset': '0',
        'order': 'oldest',
      });
    });

    test('limit and offset are clamped', () async {
      wire.answer({'episodes': <Object?>[]});
      await client.episodes(feed, limit: 1000, offset: -5);
      await client.episodes(feed, limit: 0, offset: 150);
      expect(wire.calls[0].query, {
        'feed_url': feed,
        'limit': '200',
        'offset': '0',
      });
      expect(wire.calls[1].query, {
        'feed_url': feed,
        'limit': '1',
        'offset': '150',
      });
    });

    test('not subscribed — distinct reason', () async {
      wire.answer({'status': 'not_subscribed'}, 404);
      await expectLater(
        client.episodes(feed),
        fails(PodcastFailure.notSubscribed),
      );
      wire.answer({'detail': 'Not Found'}, 404);
      await expectLater(
        client.episodes(feed),
        fails(PodcastFailure.unavailable),
        reason: 'legacy server without podcasts — not «not subscribed»',
      );
    });

    test('excessively long response is truncated', () async {
      wire.answer({
        'episodes': [
          for (var n = 0; n < 2500; n++) episode({'guid': 'g$n'}),
        ],
      });
      expect((await client.episodes(feed)).length, 2000);
    });
  });

  group('new episodes (FT-752)', () {
    test('feed, its title and episode; bad rows skipped', () async {
      wire.answer({
        'episodes': [
          {'feed_url': feed, 'feed_title': 'Шоу', ...episode()},
          {
            'feed_url': feed,
            ...episode({'guid': 'guid-2', 'title': 'Без названия ленты'}),
          },
          {
            'feed_url': '',
            'feed_title': 'Пусто',
            ...episode({'guid': 'guid-4'}),
          },
          {
            'feed_title': 'Без ленты',
            ...episode({'guid': 'guid-3'}),
          },
          {'feed_url': feed, 'feed_title': 'Шоу', 'guid': 'x'},
          7,
        ],
      });
      final result = await client.newEpisodes();
      final call = wire.calls.single;
      expect((call.method, call.path), ('GET', '/v1/podcasts/new'));
      expect(result.map((e) => (e.feedUrl, e.feedTitle, e.episode.guid)), [
        (feed, 'Шоу', episode()['guid']),
        (feed, '', 'guid-2'),
      ]);
    });

    test('second look: episode repeat — one row; feed URL not http — '
        'skipped; feed title sanitized', () async {
      wire.answer({
        'episodes': [
          {'feed_url': feed, 'feed_title': 'Шоу\u202e', ...episode()},
          {'feed_url': feed, 'feed_title': 'Шоу', ...episode()},
          {'feed_url': 'ftp://x/feed', 'feed_title': 'Не http', ...episode()},
        ],
      });
      final result = await client.newEpisodes();
      expect(result.map((e) => (e.feedUrl, e.feedTitle)), [(feed, 'Шоу')]);
    });

    test('malformed response — rejected', () async {
      wire.answer({'items': <Object?>[]});
      await expectLater(client.newEpisodes(), fails(PodcastFailure.broken));
    });
  });

  group('resume (FT-756)', () {
    test(
      'feed, title, position, and episode; malformed lines skipped properly',
      () async {
        wire.answer({
          'episodes': [
            {
              'feed_url': feed,
              'feed_title': 'Шоу',
              'position_ms': 125000,
              ...episode(),
            },
            {
              'feed_url': feed,
              'position_ms': 5000,
              ...episode({'guid': 'guid-2'}),
            },
            {
              'feed_url': feed,
              'feed_title': 'Без места',
              ...episode({'guid': 'guid-3'}),
            },
            {
              'feed_url': feed,
              'feed_title': 'Место не число',
              'position_ms': '5000',
              ...episode({'guid': 'guid-4'}),
            },
            {
              'feed_url': feed,
              'feed_title': 'Место меньше нуля',
              'position_ms': -1,
              ...episode({'guid': 'guid-5'}),
            },
            {
              'feed_url': 'ftp://x/feed',
              'feed_title': 'Не http',
              'position_ms': 1000,
              ...episode({'guid': 'guid-6'}),
            },
            {'feed_url': feed, 'position_ms': 1000, 'guid': 'x'},
            7,
          ],
        });
        final result = await client.continueEpisodes();
        final call = wire.calls.single;
        expect((call.method, call.path), ('GET', '/v1/podcasts/continue'));
        expect(
          result.map(
            (e) => (e.feedUrl, e.feedTitle, e.positionMs, e.episode.guid),
          ),
          [
            (feed, 'Шоу', 125000, episode()['guid']),
            (feed, '', 5000, 'guid-2'),
          ],
        );
      },
    );

    test(
      'duplicate episode — one line, first; feed title trimmed properly here',
      () async {
        wire.answer({
          'episodes': [
            {
              'feed_url': feed,
              'feed_title': 'Шоу\u202e',
              'position_ms': 9000,
              ...episode(),
            },
            {
              'feed_url': feed,
              'feed_title': 'Шоу',
              'position_ms': 1000,
              ...episode(),
            },
          ],
        });
        final result = await client.continueEpisodes();
        expect(result.map((e) => (e.feedUrl, e.feedTitle, e.positionMs)), [
          (feed, 'Шоу', 9000),
        ]);
      },
    );

    test('malformed response — rejection', () async {
      wire.answer({'items': <Object?>[]});
      await expectLater(
        client.continueEpisodes(),
        fails(PodcastFailure.broken),
      );
    });
  });

  group('common failures', () {
    final asks = <String, Future<Object?> Function(PodcastClient)>{
      'search': (c) => c.search('secret'),
      'subscriptions': (c) => c.subscriptions(),
      'subscribe': (c) => c.subscribe(feed),
      'unsubscribe': (c) => c.unsubscribe(feed),
      'episodes': (c) => c.episodes(feed),
      'put': (c) => c.put({podcastEpisodeKey(feed, 'g'): progress()}),
      'changes': (c) => c.changes(0),
    };

    for (final entry in asks.entries) {
      test('${entry.key}: no network', () async {
        for (final error in <Object>[
          const SocketException('feeds.example.org'),
          TimeoutException('secret'),
          StateError('secret'),
          'secret',
        ]) {
          wire.error = error;
          await expectLater(entry.value(client), fails(PodcastFailure.offline));
        }
      });

      test('${entry.key}: transport reason passes through as is', () async {
        wire.error = const PodcastException(PodcastFailure.signedOut);
        await expectLater(entry.value(client), fails(PodcastFailure.signedOut));
      });

      test('${entry.key}: statuses', () async {
        final expected = <int, PodcastFailure>{
          401: PodcastFailure.signedOut,
          400: PodcastFailure.broken,
          403: PodcastFailure.unavailable,
          404: PodcastFailure.unavailable,
          409: PodcastFailure.unavailable,
          422: PodcastFailure.broken,
          429: PodcastFailure.unavailable,
          500: PodcastFailure.unavailable,
          502: PodcastFailure.unavailable,
          503: PodcastFailure.unavailable,
          201: PodcastFailure.unavailable,
          204: PodcastFailure.unavailable,
          302: PodcastFailure.unavailable,
        };
        for (final status in expected.entries) {
          for (final body in <Object?>[null, 'x', <String, Object?>{}]) {
            wire.answer(body, status.key);
            await expectLater(
              entry.value(client),
              fails(status.value),
              reason: '${status.key} $body',
            );
          }
        }
      });

      test('${entry.key}: garbage on 200 — broken, not crash', () async {
        for (final bad in garbage) {
          wire.answer(bad);
          await expectLater(
            entry.value(client),
            fails(PodcastFailure.broken),
            reason: '$bad',
          );
        }
      });
    }
  });

  group('playback position', () {
    test('this is FT-659 sync port', () {
      expect(client, isA<PodcastSyncPort>());
    });

    test('batch send and server response', () async {
      final mine = {
        podcastEpisodeKey(feed, 'g1'): progress(1000),
        podcastEpisodeKey(feed, 'g2'): progress(2000),
      };
      wire.answer({
        'items': [
          {
            'feed_url': feed,
            'guid': 'g1',
            'position_ms': 9000,
            'done': true,
            'updated_at': '2026-10-02T00:00:00.000Z',
          },
          'x',
        ],
      });
      final kept = await client.put(mine);
      expect(kept.keys, [podcastEpisodeKey(feed, 'g1')]);
      expect(kept.values.single.positionMs, 9000);
      expect(kept.values.single.done, isTrue);
      final call = wire.calls.single;
      expect((call.method, call.path), ('POST', '/v1/podcasts/progress'));
      expect(call.query, isNull);
      expect(call.body, podcastToWire(mine));
    });

    test('empty batch not sent to server', () async {
      expect(await client.put({}), isEmpty);
      expect(wire.calls, isEmpty);
    });

    test('changes after mark', () async {
      wire.answer({
        'items': [
          {
            'feed_url': feed,
            'guid': 'g1',
            'position_ms': 5,
            'done': false,
            'updated_at': stamp,
          },
        ],
        'mark': 17,
      });
      final page = await client.changes(12);
      expect(page.mark, 17);
      expect(page.items.keys, [podcastEpisodeKey(feed, 'g1')]);
      final call = wire.calls.single;
      expect((call.method, call.path), ('GET', '/v1/podcasts/progress'));
      expect(call.query, {'after': '12'});
      expect(call.body, isNull);
    });

    test('empty page with same mark — valid response', () async {
      wire.answer({'items': <Object?>[], 'mark': 12});
      final page = await client.changes(12);
      expect(page.items, isEmpty);
      expect(page.mark, 12);
    });

    test('mark present without list — broken', () async {
      for (final bad in <Object?>[
        {'mark': 15},
        {'mark': 15, 'items': 'x'},
        {'mark': 15, 'items': <String, Object?>{}},
      ]) {
        wire.answer(bad);
        await expectLater(client.changes(12), fails(PodcastFailure.broken));
      }
    });

    test('negative mark sent as zero', () async {
      wire.answer({'items': <Object?>[], 'mark': 0});
      await client.changes(-4);
      expect(wire.calls.single.query, {'after': '0'});
    });

    test('mark backward or non-numeric — broken', () async {
      for (final mark in <Object?>[null, 'x', 1.5, -1, 11]) {
        wire.answer({'items': <Object?>[], 'mark': mark});
        await expectLater(
          client.changes(12),
          fails(PodcastFailure.broken),
          reason: '$mark',
        );
      }
    });

    test('FT-659 sync works via this port', () async {
      final store = PodcastProgressStore(_Box());
      await store.report(
        podcastEpisodeKey(feed, 'g1'),
        60000,
        durationMs: 3600000,
        force: true,
      );
      final sync = PodcastSync(store, client, _Box());

      wire.error = const SocketException('down');
      expect(await sync.run(), PodcastSyncResult.failed);
      expect(store.pending(), isNotEmpty, reason: 'record waits offline');

      wire.error = null;
      wire.answer({'items': <Object?>[], 'mark': 3});
      expect(await sync.run(), PodcastSyncResult.done);
      expect(store.pending(), isEmpty);
      expect(wire.calls.map((c) => c.method), containsAll(['POST', 'GET']));
    });
  });

  group('no extraneous text', () {
    test('models and exception do not print data', () {
      final texts = [
        PodcastEpisode.fromJson(episode())!.toString(),
        PodcastSubscription.fromJson(subscription())!.toString(),
        FoundPodcast.fromJson(found())!.toString(),
        const PodcastSubscribed(feed, isNew: true).toString(),
        const PodcastException(PodcastFailure.badUrl).toString(),
      ];
      for (final text in texts) {
        final low = text.toLowerCase();
        expect(low, isNot(contains('secret')));
        expect(low, isNot(contains('example.org')));
        expect(low, isNot(contains('guid')));
      }
      expect(
        const PodcastException(PodcastFailure.badUrl).toString(),
        contains('badUrl'),
      );
    });

    test('failure reason omits transport error text', () async {
      wire.error = const SocketException('feeds.example.org secret');
      try {
        await client.subscribe(feed);
        fail('should throw');
      } on PodcastException catch (e) {
        expect(e.toString(), isNot(contains('example.org')));
        expect(e.toString(), isNot(contains('secret')));
      }
    });
  });
}

class _Box implements PodcastProgressBox {
  String? data;
  @override
  Future<String?> read() async => data;
  @override
  Future<void> write(String value) async => data = value;
}
