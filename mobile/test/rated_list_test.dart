// FT-642 (P-A94, P-A95, feature B5, step P5b): "Rated" screen and "Disliked" list.
//
// Server provides both lists since FT-629 (`GET /v1/ratings`), stars and dislike button in app since
// FT-638. Here — list: `RatedList` (pages, "N stars and above" threshold, failures, retries) and `RatedView` (body
// of screen, wired into "My Music" by lead).
//
// Guarded:
// - first page is 100 tracks, next requested with offset 100 only if more items exist;
// - "N stars and above" threshold re-fetches list; stale response from previous threshold does not overwrite;
// - ratings in response immediately update store — no secondary request needed;
// - failure described with text and retryable via button: same page, visible rows persist;
// - row does not disappear when rating removed on same screen — accidental click can be undone;
// - malformed server response does not crash screen;
// - Russian and English, 320 dp width;
//
// What test does not prove: real request (provided by `RatedPort` written by lead over
// `server_api.dart`), opening screen from "My Music", starting track on tap — B5 wiring.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/l10n/l10n.dart';
import 'package:music_stream/models/track.dart';
import 'package:music_stream/rated_list.dart';
import 'package:music_stream/ratings.dart';
import 'package:music_stream/screens/rated_view.dart';
import 'package:music_stream/screens/rating_controls.dart';

typedef _Ask = ({int minStars, bool disliked, int limit, int offset});

String _id(int n) => 'track-$n';

Map<String, Object?> _row(int n, {int stars = 4, bool disliked = false}) => {
  'id': _id(n),
  'title': 'Песня $n',
  'artist': 'Исполнитель $n',
  'duration_ms': 200000,
  'artwork_url': '',
  'stars': disliked ? 0 : stars,
  'disliked': disliked,
};

RatedPage _page(
  Iterable<int> numbers, {
  required int total,
  int stars = 4,
  bool disliked = false,
}) => RatedPage.fromJson({
  'tracks': [
    for (final n in numbers) _row(n, stars: stars, disliked: disliked),
  ],
  'total': total,
});

Iterable<int> _range(int from, int to) sync* {
  for (var n = from; n < to; n++) {
    yield n;
  }
}

class _ListPort implements RatedPort {
  final asks = <_Ask>[];
  final gates = <Completer<void>>[];
  bool hold = false;
  bool fail = false;
  RatedPage Function(_Ask ask) answer = (_) => _page(const [], total: 0);

  @override
  Future<RatedPage> list({
    required int minStars,
    required bool disliked,
    required int limit,
    required int offset,
  }) async {
    final ask = (
      minStars: minStars,
      disliked: disliked,
      limit: limit,
      offset: offset,
    );
    asks.add(ask);
    final failing = fail;
    final page = answer(ask);
    if (hold) {
      final gate = Completer<void>();
      gates.add(gate);
      await gate.future;
    }
    if (failing) throw StateError('нет сети');
    return page;
  }
}

class _RatingsPort implements RatingsPort {
  final asked = <List<String>>[];
  final sets = <({String id, int? stars, bool? disliked})>[];
  Completer<void>? gate;
  bool fail = false;

  @override
  Future<Map<String, Rating>> of(List<String> trackIds) async {
    asked.add(List.of(trackIds));
    return {};
  }

  @override
  Future<Rating> set(String trackId, {int? stars, bool? disliked}) async {
    sets.add((id: trackId, stars: stars, disliked: disliked));
    if (gate != null) await gate!.future;
    if (fail) throw StateError('нет сети');
    return Rating(stars: stars ?? 0, disliked: disliked ?? false);
  }
}

/// 120 tracks on server: pages split by offset and limit.
RatedPage Function(_Ask) _server(
  int count, {
  int stars = 4,
  bool disliked = false,
}) => (ask) {
  final end = ask.offset + ask.limit < count ? ask.offset + ask.limit : count;
  return _page(
    _range(ask.offset < count ? ask.offset : count, end),
    total: count,
    stars: stars,
    disliked: disliked,
  );
};

Widget _app(Widget child, {Locale locale = const Locale('ru')}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

Finder _rowOf(int n) => find.byKey(Key('rated-row-${_id(n)}'));
Finder _filter(int n) => find.byKey(Key('rated-filter-$n'));
final _retry = find.byKey(const Key('rated-retry'));

void main() {
  group('server response', () {
    test('page: songs in order, ratings, total count', () {
      final page = RatedPage.fromJson({
        'tracks': [_row(1, stars: 5), _row(2, stars: 3)],
        'total': 240,
      });
      expect(page.tracks.map((t) => t.id), [_id(1), _id(2)]);
      expect(page.tracks.first.title, 'Песня 1');
      expect(page.tracks.first.artist, 'Исполнитель 1');
      expect(page.ratings, {
        _id(1): const Rating(stars: 5),
        _id(2): const Rating(stars: 3),
      });
      expect(page.total, 240);
    });

    test('disliked row - badge without stars', () {
      final page = RatedPage.fromJson({
        'tracks': [_row(1, disliked: true)],
        'total': 1,
      });
      expect(page.ratings[_id(1)], const Rating(disliked: true));
    });

    test('malformed response - empty page, no exceptions', () {
      for (final Object? bad in [
        null,
        'строка',
        7,
        <Object?>[],
        <String, Object?>{},
        {'tracks': 'не список', 'total': 3},
        {'tracks': null},
      ]) {
        final page = RatedPage.fromJson(bad);
        expect(page.tracks, isEmpty, reason: '$bad');
        expect(page.ratings, isEmpty, reason: '$bad');
        expect(page.total, 0, reason: '$bad');
      }
    });

    test('malformed row skipped, others remain', () {
      final noTitle = _row(3)..remove('title');
      final noId = _row(4)..remove('id');
      final emptyId = _row(5)..['id'] = '';
      final noRating = _row(6)..['stars'] = 0;
      final page = RatedPage.fromJson({
        'tracks': [
          _row(1),
          'не объект',
          noTitle,
          noId,
          emptyId,
          noRating,
          null,
          _row(2),
        ],
        'total': 8,
      });
      expect(page.tracks.map((t) => t.id), [_id(1), _id(2)]);
      expect(page.ratings.keys, [_id(1), _id(2)]);
    });

    test('song duplicated in response - single row, first', () {
      final page = RatedPage.fromJson({
        'tracks': [_row(1, stars: 5), _row(1, stars: 2), _row(2)],
        'total': 3,
      });
      expect(page.tracks.map((t) => t.id), [_id(1), _id(2)]);
      expect(page.ratings[_id(1)], const Rating(stars: 5));
    });

    test('invalid total count - uses received count', () {
      for (final Object? total in [null, '9', 1.5, -4, 1]) {
        final page = RatedPage.fromJson({
          'tracks': [_row(1), _row(2)],
          'total': total,
        });
        expect(page.total, 2, reason: '$total');
      }
    });
  });

  group('storage accepts ratings from list', () {
    test('rating visible immediately, one notify, no 2nd request', () async {
      final port = _RatingsPort();
      final store = RatingsStore(port);
      var notified = 0;
      store.addListener(() => notified++);

      store.adopt({
        _id(1): const Rating(stars: 5),
        _id(2): const Rating(disliked: true),
      });
      expect(store.ratingOf(_id(1)), const Rating(stars: 5));
      expect(store.ratingOf(_id(2)), const Rating(disliked: true));
      expect(notified, 1);

      await store.load([_id(1), _id(2), _id(3)]);
      expect(port.asked, [
        [_id(3)],
      ]);
    });

    test('same rating a second time - no notification', () {
      final store = RatingsStore(_RatingsPort());
      store.adopt({_id(1): const Rating(stars: 5)});
      var notified = 0;
      store.addListener(() => notified++);
      store.adopt({_id(1): const Rating(stars: 5)});
      store.adopt({});
      expect(notified, 0);
    });

    test('fresh list updates known rating', () {
      final store = RatingsStore(_RatingsPort());
      store.adopt({_id(1): const Rating(stars: 5)});
      store.adopt({_id(1): const Rating(stars: 2)});
      expect(store.ratingOf(_id(1)), const Rating(stars: 2));
    });

    test('tap failure reverts rating from list', () async {
      final port = _RatingsPort();
      final store = RatingsStore(port);
      store.adopt({_id(1): const Rating(stars: 5)});
      port.fail = true;
      expect(await store.setStars(_id(1), 2), isFalse);
      expect(store.ratingOf(_id(1)), const Rating(stars: 5));
    });

    test('in-flight tap does not overwrite list', () async {
      final port = _RatingsPort()..gate = Completer<void>();
      final store = RatingsStore(port);
      final saved = store.setStars(_id(1), 5);
      await pumpEventQueue();

      store.adopt({_id(1): const Rating(stars: 2)});
      expect(store.ratingOf(_id(1)), const Rating(stars: 5));

      port.gate!.complete();
      expect(await saved, isTrue);
      expect(store.ratingOf(_id(1)), const Rating(stars: 5));
    });

    test('rating set after snapshot is not overwritten by old list', () async {
      // List requested, user rated track and received response before
      // page snapshot taken before rating arrived.
      final store = RatingsStore(_RatingsPort());
      store.adopt({
        _id(1): const Rating(stars: 3),
        _id(2): const Rating(stars: 3),
      });
      final asked = store.clock;
      expect(await store.setStars(_id(1), 5), isTrue);

      store.adopt({
        _id(1): const Rating(stars: 3),
        _id(2): const Rating(stars: 4),
      }, since: asked);
      expect(store.ratingOf(_id(1)), const Rating(stars: 5));
      expect(store.ratingOf(_id(2)), const Rating(stars: 4));

      // List requested after rating action is fresher.
      store.adopt({_id(1): const Rating(stars: 2)}, since: store.clock);
      expect(store.ratingOf(_id(1)), const Rating(stars: 2));
    });

    test('unsaved tap after snapshot still counts', () async {
      final port = _RatingsPort();
      final store = RatingsStore(port);
      store.adopt({_id(1): const Rating(stars: 3)});
      final asked = store.clock;
      port.fail = true;
      expect(await store.setStars(_id(1), 5), isFalse);
      expect(store.clock, greaterThan(asked));
    });

    test('after close - quiet', () {
      final store = RatingsStore(_RatingsPort());
      var notified = 0;
      store.addListener(() => notified++);
      store.dispose();
      store.adopt({_id(1): const Rating(stars: 5)});
      expect(notified, 0);
    });
  });

  group('rated list', () {
    late _ListPort port;
    late _RatingsPort ratings;
    late RatingsStore store;

    setUp(() {
      port = _ListPort();
      ratings = _RatingsPort();
      store = RatingsStore(ratings);
    });

    test('empty and idle before first request', () {
      final list = RatedList(port, store);
      expect(list.tracks, isEmpty);
      expect(list.total, 0);
      expect(list.minStars, 1);
      expect(list.loading, isFalse);
      expect(list.failed, isFalse);
      expect(list.hasMore, isFalse);
      expect(list.disliked, isFalse);
      expect(port.asks, isEmpty);
    });

    test('page 1: 100 songs from 1 star, from beginning', () async {
      port.answer = _server(120);
      final list = RatedList(port, store);
      await list.load();
      expect(port.asks, [
        (minStars: 1, disliked: false, limit: 100, offset: 0),
      ]);
      expect(list.tracks, hasLength(100));
      expect(list.tracks.first.id, _id(0));
      expect(list.total, 120);
      expect(list.hasMore, isTrue);
      expect(list.loading, isFalse);
      expect(list.failed, isFalse);
    });

    test('while requesting - \'loading\', listeners notified', () async {
      port
        ..hold = true
        ..answer = _server(3);
      final list = RatedList(port, store);
      final states = <bool>[];
      list.addListener(() => states.add(list.loading));

      final loading = list.load();
      await pumpEventQueue();
      expect(list.loading, isTrue);
      expect(states, [true]);

      port.gates.single.complete();
      await loading;
      expect(list.loading, isFalse);
      expect(states, [true, false]);
      expect(list.tracks, hasLength(3));
    });

    test('response ratings known to store without 2nd request', () async {
      port.answer = _server(3, stars: 5);
      final list = RatedList(port, store);
      await list.load();
      expect(store.ratingOf(_id(0)), const Rating(stars: 5));
      await store.load([_id(0), _id(1), _id(2)]);
      expect(ratings.asked, isEmpty);
    });

    test('song list cannot be modified from outside', () async {
      port.answer = _server(3);
      final list = RatedList(port, store);
      await list.load();
      expect(() => list.tracks.clear(), throwsUnsupportedError);
    });

    test('next page: offset 100, rows appended', () async {
      port.answer = _server(120);
      final list = RatedList(port, store);
      await list.load();
      await list.loadMore();
      expect(port.asks.last, (
        minStars: 1,
        disliked: false,
        limit: 100,
        offset: 100,
      ));
      expect(list.tracks, hasLength(120));
      expect(list.tracks.last.id, _id(119));
      expect(list.hasMore, isFalse);
      expect(store.ratingOf(_id(119)), const Rating(stars: 4));
    });

    test('all shown - next page is not requested', () async {
      port.answer = _server(100);
      final list = RatedList(port, store);
      await list.load();
      expect(list.hasMore, isFalse);
      await list.loadMore();
      expect(port.asks, hasLength(1));
    });

    test('cannot request next page without first page', () async {
      port.answer = _server(120);
      final list = RatedList(port, store);
      await list.loadMore();
      expect(port.asks, isEmpty);
    });

    test('two \'load more\' at once - single request', () async {
      port.answer = _server(300);
      final list = RatedList(port, store);
      await list.load();
      port.hold = true;
      final first = list.loadMore();
      final second = list.loadMore();
      await pumpEventQueue();
      expect(port.asks, hasLength(2));
      port.gates.single.complete();
      await Future.wait([first, second]);
      expect(list.tracks, hasLength(200));
    });

    test('third page - offset 200', () async {
      port.answer = _server(250);
      final list = RatedList(port, store);
      await list.load();
      await list.loadMore();
      await list.loadMore();
      expect(port.asks.map((a) => a.offset), [0, 100, 200]);
      expect(list.tracks, hasLength(250));
      expect(list.hasMore, isFalse);
    });

    test('already shown song is not added as second row', () async {
      // Between pages user rated another track — server list shifted.
      port.answer = (ask) => ask.offset == 0
          ? _page(_range(0, 100), total: 150)
          : _page(_range(99, 150), total: 150);
      final list = RatedList(port, store);
      await list.load();
      await list.loadMore();
      final ids = list.tracks.map((t) => t.id).toList();
      expect(ids.toSet(), hasLength(ids.length));
      expect(ids, hasLength(150));
    });

    test('malformed row in page does not break offset', () async {
      // Offset calculated by count requested, not count rendered.
      RatedPage broken(_Ask ask, int total) => RatedPage.fromJson({
        'tracks': [
          for (final n in _range(ask.offset, ask.offset + 100))
            if (n == 7) (_row(n)..remove('title')) else _row(n),
        ],
        'total': total,
      });
      port.answer = (ask) => broken(ask, 250);
      final list = RatedList(port, store);
      await list.load();
      expect(list.tracks, hasLength(99));
      await list.loadMore();
      expect(port.asks.last.offset, 100);
      expect(list.tracks, hasLength(199));
    });

    test('page with malformed row was last - no \'more\'', () async {
      port.answer = (ask) => RatedPage.fromJson({
        'tracks': [
          for (final n in _range(0, 100))
            if (n == 7) (_row(n)..remove('title')) else _row(n),
        ],
        'total': 100,
      });
      final list = RatedList(port, store);
      await list.load();
      expect(list.tracks, hasLength(99));
      expect(list.hasMore, isFalse);
    });

    test('empty page - end, even if total promised more', () async {
      port.answer = (ask) => ask.offset == 0
          ? _page(_range(0, 100), total: 500)
          : _page(const [], total: 500);
      final list = RatedList(port, store);
      await list.load();
      await list.loadMore();
      expect(list.hasMore, isFalse);
      await list.loadMore();
      expect(port.asks, hasLength(2));
    });

    test('threshold: new request, old rows cleared right away', () async {
      port.answer = _server(120);
      final list = RatedList(port, store);
      await list.load();
      await list.loadMore();

      port
        ..hold = true
        ..answer = _server(7, stars: 5);
      final changing = list.setMinStars(4);
      await pumpEventQueue();
      expect(list.minStars, 4);
      expect(list.tracks, isEmpty);
      expect(list.hasMore, isFalse);
      expect(list.loading, isTrue);
      expect(port.asks.last, (
        minStars: 4,
        disliked: false,
        limit: 100,
        offset: 0,
      ));

      port.gates.single.complete();
      await changing;
      expect(list.tracks, hasLength(7));
      expect(list.total, 7);
    });

    test('after threshold change \'more\' recalculates offset', () async {
      port.answer = _server(250);
      final list = RatedList(port, store);
      await list.load();
      await list.loadMore();
      await list.setMinStars(3);
      await list.loadMore();
      expect(port.asks.last, (
        minStars: 3,
        disliked: false,
        limit: 100,
        offset: 100,
      ));
    });

    test('same threshold - no request; out of 1..5 - error', () async {
      port.answer = _server(3);
      final list = RatedList(port, store);
      await list.load();
      await list.setMinStars(1);
      expect(port.asks, hasLength(1));
      expect(() => list.setMinStars(0), throwsArgumentError);
      expect(() => list.setMinStars(6), throwsArgumentError);
      expect(port.asks, hasLength(1));
      expect(list.minStars, 1);
    });

    test('late response from old threshold does not corrupt', () async {
      port
        ..hold = true
        ..answer = (ask) => ask.minStars == 1
            ? _page(_range(0, 50), total: 50, stars: 2)
            : _page(_range(500, 503), total: 3, stars: 5);
      final list = RatedList(port, store);
      final old = list.load();
      await pumpEventQueue();
      final fresh = list.setMinStars(5);
      await pumpEventQueue();

      port.gates[1].complete();
      await fresh;
      expect(list.tracks.map((t) => t.id), [_id(500), _id(501), _id(502)]);

      port.gates[0].complete();
      await old;
      expect(list.tracks.map((t) => t.id), [_id(500), _id(501), _id(502)]);
      expect(list.total, 3);
      expect(list.loading, isFalse);
    });

    test('late failure of old request does not report failure', () async {
      port
        ..hold = true
        ..fail = true
        ..answer = _server(3);
      final list = RatedList(port, store);
      final old = list.load();
      await pumpEventQueue();
      port.fail = false;
      final fresh = list.setMinStars(5);
      await pumpEventQueue();

      port.gates[1].complete();
      await fresh;
      port.gates[0].complete();
      await old;
      expect(list.failed, isFalse);
      expect(list.loading, isFalse);
      expect(list.tracks, hasLength(3));
    });

    test('late \'more\' response after threshold not appended', () async {
      port.answer = _server(250, stars: 2);
      final list = RatedList(port, store);
      await list.load();
      port.hold = true;
      final more = list.loadMore();
      await pumpEventQueue();
      port.answer = _server(2, stars: 5);
      final fresh = list.setMinStars(5);
      await pumpEventQueue();
      port.gates[1].complete();
      await fresh;
      port.gates[0].complete();
      await more;
      expect(list.tracks, hasLength(2));
      expect(list.total, 2);
    });

    test('page 1 failure: reported without exception; retry fixes', () async {
      port.fail = true;
      final list = RatedList(port, store);
      await list.load();
      expect(list.failed, isTrue);
      expect(list.loading, isFalse);
      expect(list.tracks, isEmpty);

      port
        ..fail = false
        ..answer = _server(3);
      await list.retry();
      expect(port.asks.last.offset, 0);
      expect(list.failed, isFalse);
      expect(list.tracks, hasLength(3));
    });

    test('\'more\' failure: rows kept, retry requests same page', () async {
      port.answer = _server(250);
      final list = RatedList(port, store);
      await list.load();
      port.fail = true;
      await list.loadMore();
      expect(list.failed, isTrue);
      expect(list.tracks, hasLength(100));
      expect(list.hasMore, isTrue);

      port.fail = false;
      await list.retry();
      expect(port.asks.map((a) => a.offset), [0, 100, 100]);
      expect(list.failed, isFalse);
      expect(list.tracks, hasLength(200));
    });

    test('retry without failure does nothing', () async {
      port.answer = _server(250);
      final list = RatedList(port, store);
      await list.retry();
      await list.load();
      await list.retry();
      expect(port.asks, hasLength(1));
    });

    test('refresh failure does not clear existing rows', () async {
      port.answer = _server(3);
      final list = RatedList(port, store);
      await list.load();
      port.fail = true;
      await list.load();
      expect(list.failed, isTrue);
      expect(list.tracks, hasLength(3));
      expect(list.total, 3);
    });

    test('retry failed refresh - starts from beginning', () async {
      port.answer = _server(250);
      final list = RatedList(port, store);
      await list.load();
      await list.loadMore();
      port.fail = true;
      await list.load();
      expect(list.tracks, hasLength(200));

      port.fail = false;
      await list.retry();
      expect(port.asks.last.offset, 0);
      expect(list.failed, isFalse);
      expect(list.tracks, hasLength(100));
    });

    test('refresh after \'more\' - starts over, list replaced', () async {
      port.answer = _server(250);
      final list = RatedList(port, store);
      await list.load();
      await list.loadMore();
      port.answer = _server(2);
      await list.load();
      expect(port.asks.last.offset, 0);
      expect(list.tracks, hasLength(2));
      expect(list.hasMore, isFalse);
    });

    test('rating changed on this screen - row remains', () async {
      port.answer = _server(3);
      final list = RatedList(port, store);
      await list.load();
      await store.setStars(_id(1), 0);
      await store.setDisliked(_id(2), true);
      expect(list.tracks.map((t) => t.id), [_id(0), _id(1), _id(2)]);
      expect(list.total, 3);
    });

    test('late response after close does not crash anything', () async {
      port
        ..hold = true
        ..answer = _server(3);
      final list = RatedList(port, store);
      var notified = 0;
      list.addListener(() => notified++);
      final loading = list.load();
      await pumpEventQueue();
      final before = notified;
      list.dispose();
      port.gates.single.complete();
      await loading;
      expect(notified, before);
    });

    test('page requested before tap does not overwrite fresh rating', () async {
      port
        ..hold = true
        ..answer = _server(3, stars: 3);
      final list = RatedList(port, store);
      final loading = list.load();
      await pumpEventQueue();
      expect(await store.setStars(_id(1), 5), isTrue);

      port.gates.single.complete();
      await loading;
      expect(store.ratingOf(_id(1)), const Rating(stars: 5));
      expect(store.ratingOf(_id(0)), const Rating(stars: 3));
    });

    test('no requests sent after close', () async {
      port.answer = _server(250);
      final list = RatedList(port, store);
      await list.load();
      list.dispose();
      await list.loadMore();
      await list.load();
      await list.retry();
      expect(port.asks, hasLength(1));
    });

    test('late failure after close does not crash anything', () async {
      port
        ..hold = true
        ..fail = true;
      final list = RatedList(port, store);
      final loading = list.load();
      await pumpEventQueue();
      list.dispose();
      port.gates.single.complete();
      await loading;
    });
  });

  group('disliked list', () {
    test('requests flagged; has no threshold', () async {
      final port = _ListPort()..answer = _server(3, disliked: true);
      final store = RatingsStore(_RatingsPort());
      final list = RatedList(port, store, disliked: true);
      await list.load();
      expect(port.asks.single.disliked, isTrue);
      expect(port.asks.single.offset, 0);
      expect(port.asks.single.limit, 100);
      expect(store.ratingOf(_id(0)), const Rating(disliked: true));

      await list.setMinStars(4);
      expect(port.asks, hasLength(1));
      expect(list.tracks, hasLength(3));
    });
  });

  group('screen', () {
    late _ListPort port;
    late _RatingsPort ratings;
    late RatingsStore store;
    late List<Track> opened;

    setUp(() {
      port = _ListPort();
      ratings = _RatingsPort();
      store = RatingsStore(ratings);
      opened = [];
    });

    Future<RatedList> show(
      WidgetTester tester, {
      bool disliked = false,
      Locale locale = const Locale('ru'),
      bool settle = true,
    }) async {
      final list = RatedList(port, store, disliked: disliked);
      addTearDown(list.dispose);
      await tester.pumpWidget(
        _app(
          RatedView(list: list, store: store, onOpen: opened.add),
          locale: locale,
        ),
      );
      unawaited(list.load());
      if (settle) await tester.pumpAndSettle();
      return list;
    }

    testWidgets('spinner shown while page 1 is loading, no rows', (
      tester,
    ) async {
      port
        ..hold = true
        ..answer = _server(3);
      await show(tester, settle: false);
      await tester.pump();
      expect(find.byKey(const Key('rated-loading')), findsOneWidget);
      expect(_rowOf(0), findsNothing);

      port.gates.single.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('rated-loading')), findsNothing);
      expect(_rowOf(0), findsOneWidget);
    });

    testWidgets('row: title, artist, star count', (tester) async {
      port.answer = _server(3, stars: 5);
      await show(tester);
      expect(find.text('Песня 1'), findsOneWidget);
      expect(find.text('Исполнитель 1'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(Key('rated-stars-${_id(1)}'))).data,
        '5',
      );
    });

    testWidgets('tapping row opens this song', (tester) async {
      port.answer = _server(3);
      await show(tester);
      await tester.tap(_rowOf(1));
      expect(opened.map((t) => t.id), [_id(1)]);
    });

    testWidgets('star count in row follows storage', (tester) async {
      port.answer = _server(3, stars: 5);
      await show(tester);
      await store.setStars(_id(1), 2);
      await tester.pump();
      expect(
        tester.widget<Text>(find.byKey(Key('rated-stars-${_id(1)}'))).data,
        '2',
      );
      expect(_rowOf(1), findsOneWidget);
    });

    testWidgets('row read aloud as single node with rating', (tester) async {
      final handle = tester.ensureSemantics();
      port.answer = _server(2, stars: 5);
      await show(tester);
      // Row is single node: track, artist, and rating announced continuously.
      final label = tester.getSemantics(_rowOf(1)).label;
      expect(label, contains('Песня 1'));
      expect(label, contains('Исполнитель 1'));
      expect(label, contains('5 из 5'));
      expect(label, isNot(contains('Песня 0')));
      handle.dispose();
    });

    testWidgets('empty - explained in text, in RU and EN', (tester) async {
      await show(tester);
      expect(find.text('Оценённых песен пока нет'), findsOneWidget);
      expect(find.byKey(const Key('rated-empty')), findsOneWidget);

      await show(tester, locale: const Locale('en'));
      expect(find.text('No rated songs yet'), findsOneWidget);
    });

    testWidgets('empty disliked list has own wording', (tester) async {
      await show(tester, disliked: true);
      expect(find.text('Песен с пометкой «Не нравится» нет'), findsOneWidget);
      await show(tester, disliked: true, locale: const Locale('en'));
      expect(find.text('No disliked songs'), findsOneWidget);
    });

    testWidgets('failure: message and Retry button to re-fetch', (
      tester,
    ) async {
      port.fail = true;
      await show(tester);
      expect(find.text('Не удалось загрузить список'), findsOneWidget);
      expect(find.text('Повторить'), findsOneWidget);
      expect(find.byKey(const Key('rated-empty')), findsNothing);

      port
        ..fail = false
        ..answer = _server(2);
      await tester.tap(_retry);
      await tester.pumpAndSettle();
      expect(port.asks, hasLength(2));
      expect(_rowOf(0), findsOneWidget);
      expect(_retry, findsNothing);
    });

    testWidgets('failure in English', (tester) async {
      port.fail = true;
      await show(tester, locale: const Locale('en'));
      expect(find.text("Couldn't load the list"), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('threshold: 5 buttons, current selected', (tester) async {
      port.answer = _server(3);
      await show(tester);
      for (var n = 1; n <= 5; n++) {
        expect(_filter(n), findsOneWidget);
        expect(
          tester.widget<ChoiceChip>(_filter(n)).selected,
          n == 1,
          reason: 'threshold $n',
        );
        expect(
          find.descendant(of: _filter(n), matching: find.text('От $n')),
          findsOneWidget,
        );
      }
    });

    testWidgets('threshold in English', (tester) async {
      await show(tester, locale: const Locale('en'));
      expect(
        find.descendant(of: _filter(4), matching: find.text('4 and up')),
        findsOneWidget,
      );
    });

    testWidgets('tapping threshold re-fetches list', (tester) async {
      port.answer = (ask) => ask.minStars == 4
          ? _page(_range(50, 52), total: 2, stars: 5)
          : _page(_range(0, 3), total: 3, stars: 2);
      final list = await show(tester);
      await tester.tap(_filter(4));
      await tester.pumpAndSettle();
      expect(list.minStars, 4);
      expect(port.asks.last.minStars, 4);
      expect(tester.widget<ChoiceChip>(_filter(4)).selected, isTrue);
      expect(tester.widget<ChoiceChip>(_filter(1)).selected, isFalse);
      expect(_rowOf(50), findsOneWidget);
      expect(_rowOf(0), findsNothing);
    });

    testWidgets('threshold stays visible when empty or on failure', (
      tester,
    ) async {
      await show(tester);
      expect(_filter(3), findsOneWidget);
      port.fail = true;
      await tester.tap(_filter(3));
      await tester.pumpAndSettle();
      expect(_retry, findsOneWidget);
      expect(_filter(3), findsOneWidget);
    });

    testWidgets('threshold button at least 48 dp', (tester) async {
      await show(tester);
      for (var n = 1; n <= 5; n++) {
        expect(tester.getSize(_filter(n)).height, greaterThanOrEqualTo(48));
      }
    });

    testWidgets('disliked list has no threshold', (tester) async {
      port.answer = _server(2, disliked: true);
      await show(tester, disliked: true);
      expect(_filter(1), findsNothing);
      expect(find.byType(ChoiceChip), findsNothing);
    });

    testWidgets('dislike: flag can be toggled, row stays in place', (
      tester,
    ) async {
      port.answer = _server(2, disliked: true);
      await show(tester, disliked: true);
      expect(find.byType(RatingDislike), findsNWidgets(2));
      expect(find.byIcon(Icons.thumb_down), findsNWidgets(2));

      final button = find.descendant(
        of: find.byType(RatingDislike).first,
        matching: find.byKey(const Key('rating-dislike')),
      );
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(ratings.sets.single, (id: _id(0), stars: null, disliked: false));
      expect(_rowOf(0), findsOneWidget);
      expect(find.byIcon(Icons.thumb_down), findsOneWidget);

      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(ratings.sets.last, (id: _id(0), stars: null, disliked: true));
      expect(find.byIcon(Icons.thumb_down), findsNWidgets(2));
    });

    testWidgets('no dislike button in rated list', (tester) async {
      port.answer = _server(2);
      await show(tester);
      expect(find.byType(RatingDislike), findsNothing);
    });

    testWidgets('scrolled to end - requests next page', (tester) async {
      port.answer = _server(120);
      final list = await show(tester);
      expect(port.asks, hasLength(1));

      await tester.drag(find.byType(Scrollable).last, const Offset(0, -20000));
      await tester.pumpAndSettle();
      expect(port.asks.map((a) => a.offset), [0, 100]);
      expect(list.tracks, hasLength(120));

      await tester.drag(find.byType(Scrollable).last, const Offset(0, -20000));
      await tester.pumpAndSettle();
      expect(_rowOf(119), findsOneWidget);
      expect(port.asks, hasLength(2));
    });

    testWidgets('not scrolled - page 2 not requested', (tester) async {
      port.answer = _server(120);
      await show(tester);
      await tester.drag(find.byType(Scrollable).last, const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(port.asks, hasLength(1));
    });

    testWidgets('\'more\' error: rows kept, retry shown', (tester) async {
      port.answer = _server(120);
      final list = await show(tester);
      port.fail = true;
      await tester.drag(find.byType(Scrollable).last, const Offset(0, -20000));
      await tester.pumpAndSettle();
      expect(list.tracks, hasLength(100));
      expect(_rowOf(99), findsOneWidget);
      expect(_retry, findsOneWidget);
      // Failure does not trigger infinite request loop.
      expect(port.asks, hasLength(2));

      port.fail = false;
      await tester.ensureVisible(_retry);
      await tester.pumpAndSettle();
      await tester.tap(_retry);
      await tester.pumpAndSettle();
      expect(port.asks.map((a) => a.offset), [0, 100, 100]);
      expect(list.tracks, hasLength(120));
      expect(_retry, findsNothing);
    });

    testWidgets('320 dp: long title does not break row', (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final long = _row(1)
        ..['title'] = 'Очень длинное название песни ' * 6
        ..['artist'] = 'Очень длинное имя исполнителя ' * 6;
      port.answer = (_) => RatedPage.fromJson({
        'tracks': [long],
        'total': 1,
      });
      await show(tester);
      expect(tester.takeException(), isNull);
      expect(_rowOf(1), findsOneWidget);

      port.answer = (_) => RatedPage.fromJson({
        'tracks': [long..['disliked'] = true],
        'total': 1,
      });
      await show(tester, disliked: true);
      expect(tester.takeException(), isNull);
      expect(find.byType(RatingDislike), findsOneWidget);
    });

    testWidgets('row height at least 48 dp', (tester) async {
      port.answer = _server(2);
      await show(tester);
      expect(tester.getSize(_rowOf(0)).height, greaterThanOrEqualTo(48));
    });
  });
}
