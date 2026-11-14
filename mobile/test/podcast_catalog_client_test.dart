// FT-703: podcast categories and trending — client side (server FT-688).
//
// Contract `lib/podcast_catalog_client.dart`:
// - `PodcastCategory(id:, ru:, en:)`, `title(languageCode)`, `static fromJson`;
// - `PodcastCatalogClient(PodcastSend)`: `categories()`, `top({category, country})`;
// - failures — same `PodcastException(PodcastFailure.…)`, as `PodcastClient`.
//
// Guarded: malformed response — skipped row or `broken`; duplicates not
// repeated; country sent to server strictly as two lowercase letters;
// `toString()` contains no titles or URLs.
//
// What test does not prove: real server and network not used.

import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/podcast_catalog_client.dart';
import 'package:music_stream/podcast_client.dart';

class Call {
  final String method;
  final String path;
  final Map<String, String>? query;
  Call(this.method, this.path, this.query);
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
    calls.add(Call(method, path, query));
    final e = error;
    if (e != null) throw e;
    return reply;
  }
}

Map<String, Object?> podcast(String n) => {
  'feed_url': 'https://feeds.example.org/$n.xml',
  'title': 'Show $n',
  'author': 'Author $n',
  'image': 'https://img.example.org/$n.jpg',
  'episodes': 10,
};

const science = {'id': 1533, 'ru': 'Наука', 'en': 'Science'};
const history = {'id': 1487, 'ru': 'История', 'en': 'History'};

Future<PodcastFailure> failureOf(Future<Object?> Function() run) async {
  try {
    await run();
  } on PodcastException catch (e) {
    return e.reason;
  }
  fail('ожидался PodcastException');
}

void main() {
  late Wire wire;
  late PodcastCatalogClient client;

  setUp(() {
    wire = Wire();
    client = PodcastCatalogClient(wire.send);
  });

  group('categories', () {
    test('asks GET /v1/podcasts/categories without query', () async {
      wire.reply = const PodcastReply(200, {
        'categories': [science, history],
      });
      final got = await client.categories();
      expect(wire.calls.single.method, 'GET');
      expect(wire.calls.single.path, '/v1/podcasts/categories');
      expect(wire.calls.single.query, isNull);
      expect(got.map((c) => c.id), [1533, 1487]);
      expect(got.first.ru, 'Наука');
      expect(got.first.en, 'Science');
    });

    test('title follows the phone language', () {
      final c = PodcastCategory.fromJson(science)!;
      expect(c.title('ru'), 'Наука');
      expect(c.title('en'), 'Science');
      expect(c.title('de'), 'Science');
    });

    test('bad rows are skipped, not fatal', () async {
      wire.reply = const PodcastReply(200, {
        'categories': [
          science,
          'junk',
          {'id': '7', 'ru': 'Строка', 'en': 'String'},
          {'id': 0, 'ru': 'Ноль', 'en': 'Zero'},
          {'id': -3, 'ru': 'Минус', 'en': 'Minus'},
          {'id': 9, 'ru': 'Без английского'},
          {'id': 10, 'en': 'No Russian'},
          {'id': 11, 'ru': '', 'en': 'Empty'},
          history,
        ],
      });
      final got = await client.categories();
      expect(got.map((c) => c.id), [1533, 1487]);
    });

    test('repeated id is kept once', () async {
      wire.reply = const PodcastReply(200, {
        'categories': [science, science, history],
      });
      expect((await client.categories()).map((c) => c.id), [1533, 1487]);
    });

    test('no more than podcastMaxCategories', () async {
      wire.reply = PodcastReply(200, {
        'categories': [
          for (var i = 1; i <= 80; i++) {'id': i, 'ru': 'Р$i', 'en': 'E$i'},
        ],
      });
      expect((await client.categories()).length, podcastMaxCategories);
    });

    test('invisible and bidi marks never reach the screen', () async {
      wire.reply = const PodcastReply(200, {
        'categories': [
          {'id': 5, 'ru': 'На\u202Eука\u200F', 'en': 'Sci\u0000ence'},
        ],
      });
      final c = (await client.categories()).single;
      for (final text in [c.ru, c.en]) {
        expect(
          text.runes.where(
            (r) => r < 0x20 || r == 0x200F || (r >= 0x202A && r <= 0x202E),
          ),
          isEmpty,
        );
      }
      expect(c.ru, 'На ука');
      expect(c.en, 'Sci ence');
    });

    test('result cannot be changed by the screen', () async {
      wire.reply = const PodcastReply(200, {
        'categories': [science],
      });
      final got = await client.categories();
      expect(
        () => got.add(PodcastCategory.fromJson(history)!),
        throwsUnsupportedError,
      );
    });

    test('broken body shapes are broken', () async {
      for (final body in <Object?>[
        null,
        'x',
        <Object?>[],
        <String, Object?>{},
        {'categories': 'x'},
      ]) {
        wire.reply = PodcastReply(200, body);
        expect(
          await failureOf(client.categories),
          PodcastFailure.broken,
          reason: '$body',
        );
      }
    });

    test('toString carries no names', () {
      final c = PodcastCategory.fromJson(science)!;
      expect(c.toString(), isNot(contains('Наука')));
      expect(c.toString(), isNot(contains('Science')));
    });
  });

  group('top', () {
    test('without arguments asks top with no query', () async {
      wire.reply = PodcastReply(200, {
        'podcasts': [podcast('a'), podcast('b')],
      });
      final got = await client.top();
      expect(wire.calls.single.path, '/v1/podcasts/top');
      expect(wire.calls.single.query, isNull);
      expect(got.map((p) => p.title), ['Show a', 'Show b']);
      expect(got.first.feedUrl, 'https://feeds.example.org/a.xml');
      expect(got.first.author, 'Author a');
      expect(got.first.image, 'https://img.example.org/a.jpg');
      expect(got.first.episodes, 10);
    });

    test('category and country go to the server', () async {
      wire.reply = const PodcastReply(200, {'podcasts': []});
      await client.top(category: 1487, country: 'ru');
      expect(wire.calls.single.query, {'category': '1487', 'country': 'ru'});
    });

    test('country is sent only as two lowercase letters', () async {
      wire.reply = const PodcastReply(200, {'podcasts': []});
      for (final bad in ['RU', 'rus', 'r', '', 'r1', 'ру', 'ru&x=1']) {
        wire.calls.clear();
        await client.top(country: bad);
        expect(wire.calls.single.query, isNull, reason: bad);
      }
    });

    test('category that is not positive is not sent', () async {
      wire.reply = const PodcastReply(200, {'podcasts': []});
      await client.top(category: 0);
      await client.top(category: -5);
      expect(wire.calls.map((c) => c.query), [null, null]);
    });

    test('bad rows are skipped and repeats kept once', () async {
      wire.reply = PodcastReply(200, {
        'podcasts': [
          podcast('a'),
          'junk',
          {'feed_url': 'file:///etc/passwd', 'title': 'Bad'},
          {'feed_url': 'https://feeds.example.org/x.xml'},
          podcast('a'),
          podcast('b'),
        ],
      });
      expect((await client.top()).map((p) => p.title), ['Show a', 'Show b']);
    });

    test('broken body shapes are broken', () async {
      for (final body in <Object?>[
        null,
        <Object?>[],
        <String, Object?>{},
        {'podcasts': 'x'},
      ]) {
        wire.reply = PodcastReply(200, body);
        expect(
          await failureOf(client.top),
          PodcastFailure.broken,
          reason: '$body',
        );
      }
    });

    test('result cannot be changed by the screen', () async {
      wire.reply = PodcastReply(200, {
        'podcasts': [podcast('a')],
      });
      final got = await client.top();
      expect(() => got.clear(), throwsUnsupportedError);
    });
  });

  group('failures', () {
    final calls = <String, Future<Object?> Function(PodcastCatalogClient)>{
      'categories': (c) => c.categories(),
      'top': (c) => c.top(),
    };

    calls.forEach((name, run) {
      test('$name: transport error is offline', () async {
        wire.error = StateError('socket');
        expect(await failureOf(() => run(client)), PodcastFailure.offline);
      });

      test('$name: PodcastException from transport passes through', () async {
        wire.error = const PodcastException(PodcastFailure.signedOut);
        expect(await failureOf(() => run(client)), PodcastFailure.signedOut);
      });

      test('$name: 401 is signedOut', () async {
        wire.reply = const PodcastReply(401, {'status': 'unauthorized'});
        expect(await failureOf(() => run(client)), PodcastFailure.signedOut);
      });

      test('$name: 400 is broken', () async {
        wire.reply = const PodcastReply(400, {'status': 'invalid_request'});
        expect(await failureOf(() => run(client)), PodcastFailure.broken);
      });

      test(
        '$name: 503 podcast_search_unavailable is searchUnavailable',
        () async {
          wire.reply = const PodcastReply(503, {
            'status': 'podcast_search_unavailable',
          });
          expect(
            await failureOf(() => run(client)),
            PodcastFailure.searchUnavailable,
          );
        },
      );

      test('$name: other 503 is unavailable', () async {
        wire.reply = const PodcastReply(503, {'status': 'down'});
        expect(await failureOf(() => run(client)), PodcastFailure.unavailable);
      });

      test('$name: 404 and 500 are unavailable', () async {
        for (final s in [404, 500, 502]) {
          wire.reply = PodcastReply(s, const {'status': 'x'});
          expect(
            await failureOf(() => run(client)),
            PodcastFailure.unavailable,
            reason: '$s',
          );
        }
      });
    });
  });
}
