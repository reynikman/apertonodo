// FT-638 (P-A94, P-A95, feature B5): ratings in app — five stars and "dislike".
//
// Server supports this since FT-629 (`POST /v1/ratings`, `POST /v1/ratings/of`). Here — client half:
// `RatingsStore` (what app knows about ratings) and two widgets wired by lead into player and
// track menu.
//
// Guarded:
// - screen ratings queried in single request, only those unknown to app, up to
//   500 tracks per request;
// - star illuminates immediately before server responds; failure reverts to previous rating with message;
// - repeated tap on the same star clears the rating;
// - stars and "dislike" are mutually exclusive;
// - rapid taps: last one wins, stale response or failure of previous tap does not corrupt it;
// - stars announced by screen reader ("4 of 5", rated or unrated), touch target at least 48 dp;
// - Russian and English.
//
// What test does not prove: real server requests (provided by `RatingsPort` written by lead
// over `server_api.dart`) and widget placements in player and track menu — B5 wiring. "Dislike" in beta
// is a flag: no automated queue purging yet, smart queues not implemented.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/l10n/l10n.dart';
import 'package:music_stream/ratings.dart';
import 'package:music_stream/screens/rating_controls.dart';

const _song = '33333333-3333-3333-3333-333333333333';
const _other = '44444444-4444-4444-4444-444444444444';

typedef _Call = ({String id, int? stars, bool? disliked});

class _Port implements RatingsPort {
  final asked = <List<String>>[];
  final sets = <_Call>[];
  Map<String, Rating> known = {};
  bool failOf = false;
  bool failSet = false;
  Completer<void>? holdOf;

  /// Dedicated lock per `set` call: responses can be released in any order.
  final holds = <Completer<void>>[];
  bool hold = false;
  Rating? answer;

  @override
  Future<Map<String, Rating>> of(List<String> trackIds) async {
    asked.add(List.of(trackIds));
    final result = {
      for (final id in trackIds)
        if (known.containsKey(id)) id: known[id]!,
    };
    if (holdOf != null) await holdOf!.future;
    if (failOf) throw StateError('нет сети');
    return result;
  }

  @override
  Future<Rating> set(String trackId, {int? stars, bool? disliked}) async {
    sets.add((id: trackId, stars: stars, disliked: disliked));
    final fail = failSet;
    final reply =
        answer ?? Rating(stars: stars ?? 0, disliked: disliked ?? false);
    if (hold) {
      final gate = Completer<void>();
      holds.add(gate);
      await gate.future;
    }
    if (fail) throw StateError('нет сети');
    return reply;
  }
}

Widget _app(Widget child, {Locale locale = const Locale('ru')}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

Finder _star(int n) => find.byKey(Key('rating-star-$n'));
final _dislike = find.byKey(const Key('rating-dislike'));

int _lit(WidgetTester tester) => tester
    .widgetList<Icon>(
      find.descendant(
        of: find.byType(RatingStars),
        matching: find.byType(Icon),
      ),
    )
    .where((icon) => icon.icon == Icons.star)
    .length;

void main() {
  group('server response', () {
    test('rating', () {
      final r = Rating.fromJson({'stars': 4, 'disliked': false});
      expect((r.stars, r.disliked), (4, false));
      expect(r.isNone, isFalse);
    });

    test('dislike', () {
      final r = Rating.fromJson({'stars': 0, 'disliked': true});
      expect((r.stars, r.disliked, r.isNone), (0, true, false));
    });

    test('malformed response - no rating, no exceptions', () {
      for (final json in <Map<String, Object?>>[
        {},
        {'stars': '5'},
        {'stars': 9},
        {'stars': -1},
        {'stars': 2.5},
        {'disliked': 'yes'},
        {'stars': null, 'disliked': null},
      ]) {
        final r = Rating.fromJson(json);
        expect(
          (r.stars, r.disliked, r.isNone),
          (0, false, true),
          reason: '$json',
        );
      }
    });

    test(
      'stars and dislike are mutually exclusive: dislike always takes priority',
      () {
        final r = Rating.fromJson({'stars': 3, 'disliked': true});
        expect((r.stars, r.disliked), (0, true));
      },
    );

    test('equality by value', () {
      expect(const Rating(stars: 3), const Rating(stars: 3));
      expect(const Rating(stars: 3) == const Rating(stars: 4), isFalse);
      expect(Rating.none, const Rating());
    });
  });

  group('what the app knows about ratings', () {
    test('screen fetches ratings in single request', () async {
      final port = _Port()..known = {_song: const Rating(stars: 4)};
      final store = RatingsStore(port);
      expect(store.ratingOf(_song), Rating.none);
      await store.load([_song, _other]);
      expect(port.asked, [
        [_song, _other],
      ]);
      expect(store.ratingOf(_song), const Rating(stars: 4));
      expect(store.ratingOf(_other), Rating.none);
      store.dispose();
    });

    test('known not re-fetched, duplicates in list queried once', () async {
      final port = _Port();
      final store = RatingsStore(port);
      await store.load([_song, _song]);
      await store.load([_song, _other, _other]);
      await store.load([_other, _song]);
      await store.load([]);
      expect(port.asked, [
        [_song],
        [_other],
      ]);
      store.dispose();
    });

    test('over 500 songs - split into requests of at most 500', () async {
      final port = _Port();
      final store = RatingsStore(port);
      final ids = [for (var i = 0; i < 1201; i++) 'id-$i'];
      port.known = {'id-1200': const Rating(disliked: true)};
      await store.load(ids);
      expect(port.asked.map((batch) => batch.length), [500, 500, 201]);
      expect(port.asked.expand((batch) => batch).toList(), ids);
      expect(store.ratingOf('id-1200'), const Rating(disliked: true));
      store.dispose();
    });

    test('request error does not crash screen, retried later', () async {
      final port = _Port()..failOf = true;
      final store = RatingsStore(port);
      await store.load([_song]);
      expect(store.ratingOf(_song), Rating.none);
      port
        ..failOf = false
        ..known = {_song: const Rating(stars: 2)};
      await store.load([_song]);
      expect(port.asked.length, 2);
      expect(store.ratingOf(_song), const Rating(stars: 2));
      store.dispose();
    });

    test('listeners notified of loaded ratings', () async {
      final port = _Port()..known = {_song: const Rating(stars: 4)};
      final store = RatingsStore(port);
      var told = 0;
      store.addListener(() => told++);
      await store.load([_song]);
      expect(told, greaterThan(0));
      store.dispose();
    });
  });

  group('set rating', () {
    test('star lights up immediately without waiting for server', () async {
      final port = _Port()..hold = true;
      final store = RatingsStore(port);
      var told = 0;
      store.addListener(() => told++);
      final saving = store.setStars(_song, 4);
      expect(store.ratingOf(_song), const Rating(stars: 4));
      expect(told, 1);
      await Future<void>.delayed(Duration.zero);
      expect(port.sets, [(id: _song, stars: 4, disliked: null)]);
      port.holds.single.complete();
      expect(await saving, isTrue);
      expect(store.ratingOf(_song), const Rating(stars: 4));
      store.dispose();
    });

    test('same star second tap clears rating', () async {
      final port = _Port();
      final store = RatingsStore(port);
      await store.setStars(_song, 3);
      expect(await store.setStars(_song, 3), isTrue);
      expect(store.ratingOf(_song), Rating.none);
      expect(port.sets.last, (id: _song, stars: 0, disliked: null));
      await store.setStars(_song, 3);
      await store.setStars(_song, 5);
      expect(store.ratingOf(_song), const Rating(stars: 5));
      expect(port.sets.last, (id: _song, stars: 5, disliked: null));
      store.dispose();
    });

    test('zero stars clears rating, outside 0..5 causes error', () async {
      final port = _Port();
      final store = RatingsStore(port);
      await store.setStars(_song, 3);
      await store.setStars(_song, 0);
      expect(store.ratingOf(_song), Rating.none);
      expect(() => store.setStars(_song, 6), throwsArgumentError);
      expect(() => store.setStars(_song, -1), throwsArgumentError);
      expect(port.sets.length, 2);
      store.dispose();
    });

    test('dislike clears stars, star clears dislike', () async {
      final port = _Port();
      final store = RatingsStore(port);
      await store.setStars(_song, 5);
      expect(await store.setDisliked(_song, true), isTrue);
      expect(store.ratingOf(_song), const Rating(disliked: true));
      expect(port.sets.last, (id: _song, stars: null, disliked: true));
      await store.setStars(_song, 2);
      expect(store.ratingOf(_song), const Rating(stars: 2));
      await store.setDisliked(_song, true);
      await store.setDisliked(_song, false);
      expect(store.ratingOf(_song), Rating.none);
      expect(port.sets.last, (id: _song, stars: null, disliked: false));
      store.dispose();
    });

    test('failure reverts to previous rating', () async {
      final port = _Port();
      final store = RatingsStore(port);
      await store.setStars(_song, 2);
      port.failSet = true;
      var told = 0;
      store.addListener(() => told++);
      expect(await store.setStars(_song, 5), isFalse);
      expect(store.ratingOf(_song), const Rating(stars: 2));
      expect(told, 2, reason: 'lit up first, then reverted');
      expect(await store.setDisliked(_song, true), isFalse);
      expect(store.ratingOf(_song), const Rating(stars: 2));
      store.dispose();
    });

    test('state taken from server response', () async {
      final port = _Port()..answer = const Rating(stars: 3);
      final store = RatingsStore(port);
      await store.setStars(_song, 4);
      expect(store.ratingOf(_song), const Rating(stars: 3));
      store.dispose();
    });

    test('rating one song does not affect another', () async {
      final port = _Port();
      final store = RatingsStore(port);
      await store.setStars(_song, 4);
      await store.setDisliked(_other, true);
      expect(store.ratingOf(_song), const Rating(stars: 4));
      expect(store.ratingOf(_other), const Rating(disliked: true));
      store.dispose();
    });

    test('screen no longer queries rated song', () async {
      final port = _Port();
      final store = RatingsStore(port);
      await store.setStars(_song, 4);
      await store.load([_song]);
      expect(port.asked, isEmpty);
      store.dispose();
    });
  });

  group('rapid taps', () {
    test('song requests sent in order of taps', () async {
      final port = _Port()..hold = true;
      final store = RatingsStore(port);
      final first = store.setStars(_song, 4);
      final second = store.setStars(_song, 2);
      await Future<void>.delayed(Duration.zero);
      const why = 'два запроса разом сервер вправе принять в любом порядке';
      expect(port.sets.map((c) => c.stars), [4], reason: why);
      expect(store.ratingOf(_song), const Rating(stars: 2));
      port.holds[0].complete();
      expect(await first, isTrue);
      expect(store.ratingOf(_song), const Rating(stars: 2));
      await Future<void>.delayed(Duration.zero);
      expect(port.sets.map((c) => c.stars), [4, 2]);
      port.holds[1].complete();
      expect(await second, isTrue);
      expect(store.ratingOf(_song), const Rating(stars: 2));
      store.dispose();
    });

    test('failure of earlier tap does not roll back newer', () async {
      final port = _Port()
        ..hold = true
        ..failSet = true;
      final store = RatingsStore(port);
      final first = store.setStars(_song, 4);
      await Future<void>.delayed(Duration.zero);
      port.failSet = false;
      final second = store.setStars(_song, 2);
      port.holds[0].complete();
      expect(await first, isFalse);
      expect(store.ratingOf(_song), const Rating(stars: 2));
      expect(store.failedOf(_song), isFalse, reason: 'last still in flight');
      await Future<void>.delayed(Duration.zero);
      port.holds[1].complete();
      expect(await second, isTrue);
      expect(store.ratingOf(_song), const Rating(stars: 2));
      expect(store.failedOf(_song), isFalse);
      store.dispose();
    });

    test('last tap failure reverts to server confirmed state', () async {
      final port = _Port();
      final store = RatingsStore(port);
      await store.setStars(_song, 1);
      port.hold = true;
      final first = store.setStars(_song, 4);
      final second = store.setStars(_song, 2);
      await Future<void>.delayed(Duration.zero);
      port.failSet = true;
      port.holds[0].complete();
      expect(await first, isTrue);
      await Future<void>.delayed(Duration.zero);
      port.holds[1].complete();
      expect(await second, isFalse);
      expect(
        store.ratingOf(_song),
        const Rating(stars: 4),
        reason: 'server saved 4, but not 2',
      );
      expect(store.failedOf(_song), isTrue);
      store.dispose();
    });

    test('both taps failed - reverts to confirmed', () async {
      final port = _Port();
      final store = RatingsStore(port);
      await store.setStars(_song, 1);
      port
        ..hold = true
        ..failSet = true;
      final first = store.setStars(_song, 4);
      final second = store.setStars(_song, 2);
      await Future<void>.delayed(Duration.zero);
      port.holds[0].complete();
      expect(await first, isFalse);
      await Future<void>.delayed(Duration.zero);
      port.holds[1].complete();
      expect(await second, isFalse);
      expect(store.ratingOf(_song), const Rating(stars: 1));
      store.dispose();
    });

    test('queues for different songs run independently', () async {
      final port = _Port()..hold = true;
      final store = RatingsStore(port);
      final first = store.setStars(_song, 4);
      final second = store.setStars(_other, 2);
      await Future<void>.delayed(Duration.zero);
      expect(port.sets.map((c) => c.id), [_song, _other]);
      port.holds[1].complete();
      expect(await second, isTrue);
      port.holds[0].complete();
      await first;
      store.dispose();
    });

    test('tap failed during load - reverts to server rating', () async {
      final port = _Port()
        ..holdOf = Completer<void>()
        ..known = {_song: const Rating(stars: 4)}
        ..failSet = true;
      final store = RatingsStore(port);
      final loading = store.load([_song]);
      expect(await store.setStars(_song, 2), isFalse);
      expect(store.ratingOf(_song), Rating.none, reason: 'server is silent');
      var heard = 0;
      store.addListener(() => heard++);
      port.holdOf!.complete();
      await loading;
      expect(
        store.ratingOf(_song),
        const Rating(stars: 4),
        reason: 'server has 4 - screen must not show \'no rating\'',
      );
      expect(heard, 1);
      store.dispose();
    });

    test(
      'load returned while tap in-flight and tap failed - server rating kept',
      () async {
        final port = _Port()
          ..holdOf = Completer<void>()
          ..known = {_song: const Rating(stars: 4)}
          ..hold = true
          ..failSet = true;
        final store = RatingsStore(port);
        final loading = store.load([_song]);
        final saving = store.setStars(_song, 2);
        await Future<void>.delayed(Duration.zero);
        port.holdOf!.complete();
        await loading;
        expect(store.ratingOf(_song), const Rating(stars: 2));
        port.holds.single.complete();
        expect(await saving, isFalse);
        expect(store.ratingOf(_song), const Rating(stars: 4));
        store.dispose();
      },
    );

    test('late load response does not overwrite freshly set rating', () async {
      final port = _Port()
        ..holdOf = Completer<void>()
        ..known = {_song: const Rating(stars: 1)};
      final store = RatingsStore(port);
      final loading = store.load([_song, _other]);
      await store.setStars(_song, 5);
      port.known[_other] = const Rating(stars: 3);
      port.holdOf!.complete();
      await loading;
      expect(store.ratingOf(_song), const Rating(stars: 5));
      store.dispose();
    });

    test('response after screen close crashes nothing', () async {
      final port = _Port()..hold = true;
      final store = RatingsStore(port);
      final saving = store.setStars(_song, 4);
      await Future<void>.delayed(Duration.zero);
      store.dispose();
      port.holds.single.complete();
      expect(await saving, isTrue, reason: 'server saved rating');
    });
  });

  group('five stars', () {
    testWidgets('tap sets rating and lights stars', (tester) async {
      final port = _Port();
      final store = RatingsStore(port);
      await tester.pumpWidget(_app(RatingStars(store: store, trackId: _song)));
      for (var n = 1; n <= 5; n++) {
        expect(_star(n), findsOneWidget);
      }
      expect(_lit(tester), 0);

      await tester.tap(_star(4));
      await tester.pump();
      expect(_lit(tester), 4);
      expect(port.sets, [(id: _song, stars: 4, disliked: null)]);

      await tester.tap(_star(4));
      await tester.pump();
      expect(_lit(tester), 0);
      store.dispose();
    });

    testWidgets('shows known rating and listens to changes', (tester) async {
      final port = _Port()..known = {_song: const Rating(stars: 3)};
      final store = RatingsStore(port);
      await tester.pumpWidget(_app(RatingStars(store: store, trackId: _song)));
      expect(_lit(tester), 0);
      await store.load([_song]);
      await tester.pump();
      expect(_lit(tester), 3);
      await store.setDisliked(_song, true);
      await tester.pump();
      expect(_lit(tester), 0);
      store.dispose();
    });

    testWidgets('other song\'s star does not light up', (tester) async {
      final port = _Port();
      final store = RatingsStore(port);
      await store.setStars(_other, 5);
      await tester.pumpWidget(_app(RatingStars(store: store, trackId: _song)));
      expect(_lit(tester), 0);
      store.dispose();
    });

    testWidgets('error explained, clears on success', (tester) async {
      final port = _Port()..failSet = true;
      final store = RatingsStore(port);
      await tester.pumpWidget(_app(RatingStars(store: store, trackId: _song)));
      expect(find.text('Не удалось сохранить оценку'), findsNothing);
      await tester.tap(_star(5));
      await tester.pump();
      await tester.pump();
      expect(_lit(tester), 0);
      expect(find.text('Не удалось сохранить оценку'), findsOneWidget);

      port.failSet = false;
      await tester.tap(_star(5));
      await tester.pump();
      await tester.pump();
      expect(_lit(tester), 5);
      expect(find.text('Не удалось сохранить оценку'), findsNothing);
      store.dispose();
    });

    testWidgets('dislike error is also explained', (tester) async {
      final port = _Port()..failSet = true;
      final store = RatingsStore(port);
      await tester.pumpWidget(
        _app(
          Row(
            children: [
              RatingStars(store: store, trackId: _song),
              RatingDislike(store: store, trackId: _song),
            ],
          ),
        ),
      );
      await tester.tap(_dislike);
      await tester.pump();
      await tester.pump();
      expect(find.text('Не удалось сохранить оценку'), findsOneWidget);
      store.dispose();
    });

    testWidgets('error on one song not shown on another', (tester) async {
      final port = _Port()..failSet = true;
      final store = RatingsStore(port);
      await tester.pumpWidget(_app(RatingStars(store: store, trackId: _song)));
      await tester.tap(_star(5));
      await tester.pump();
      await tester.pump();
      expect(find.text('Не удалось сохранить оценку'), findsOneWidget);
      // List row recycled for another track.
      await tester.pumpWidget(_app(RatingStars(store: store, trackId: _other)));
      expect(find.text('Не удалось сохранить оценку'), findsNothing);
      store.dispose();
    });

    testWidgets('each star at least 48 dp and screen-readable', (tester) async {
      final handle = tester.ensureSemantics();
      final port = _Port();
      final store = RatingsStore(port);
      await store.setStars(_song, 2);
      await tester.pumpWidget(_app(RatingStars(store: store, trackId: _song)));
      for (var n = 1; n <= 5; n++) {
        final size = tester.getSize(_star(n));
        expect(size.width, greaterThanOrEqualTo(48));
        expect(size.height, greaterThanOrEqualTo(48));
        expect(
          tester.getSemantics(find.bySemanticsLabel('$n из 5')),
          isSemantics(
            isButton: true,
            isSelected: n == 2,
            hasSelectedState: true,
          ),
          reason: 'star $n',
        );
      }
      handle.dispose();
      store.dispose();
    });

    testWidgets('five stars fit on narrow phone', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = RatingsStore(_Port());
      await tester.pumpWidget(
        _app(
          Row(
            children: [
              RatingStars(store: store, trackId: _song),
              RatingDislike(store: store, trackId: _song),
            ],
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      store.dispose();
    });
  });

  group('dislike', () {
    testWidgets('tapping sets and unsets', (tester) async {
      final handle = tester.ensureSemantics();
      final port = _Port();
      final store = RatingsStore(port);
      await tester.pumpWidget(
        _app(RatingDislike(store: store, trackId: _song)),
      );
      final size = tester.getSize(_dislike);
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
      expect(
        tester.getSemantics(find.bySemanticsLabel('Не нравится')),
        isSemantics(isButton: true, isSelected: false, hasSelectedState: true),
      );

      await tester.tap(_dislike);
      await tester.pump();
      expect(port.sets, [(id: _song, stars: null, disliked: true)]);
      expect(find.byIcon(Icons.thumb_down), findsOneWidget);
      expect(
        tester.getSemantics(find.bySemanticsLabel('Не нравится')),
        isSemantics(isButton: true, isSelected: true, hasSelectedState: true),
      );

      await tester.tap(_dislike);
      await tester.pump();
      expect(port.sets.last, (id: _song, stars: null, disliked: false));
      expect(find.byIcon(Icons.thumb_down), findsNothing);
      expect(find.byIcon(Icons.thumb_down_off_alt), findsOneWidget);
      handle.dispose();
      store.dispose();
    });

    testWidgets('star turns off dislike', (tester) async {
      final port = _Port();
      final store = RatingsStore(port);
      await tester.pumpWidget(
        _app(
          Column(
            children: [
              RatingStars(store: store, trackId: _song),
              RatingDislike(store: store, trackId: _song),
            ],
          ),
        ),
      );
      await tester.tap(_dislike);
      await tester.pump();
      expect(find.byIcon(Icons.thumb_down), findsOneWidget);
      await tester.tap(_star(3));
      await tester.pump();
      expect(find.byIcon(Icons.thumb_down), findsNothing);
      expect(_lit(tester), 3);
      store.dispose();
    });

    testWidgets('error restores button state', (tester) async {
      final port = _Port()..failSet = true;
      final store = RatingsStore(port);
      await tester.pumpWidget(
        _app(RatingDislike(store: store, trackId: _song)),
      );
      await tester.tap(_dislike);
      await tester.pump();
      await tester.pump();
      expect(find.byIcon(Icons.thumb_down), findsNothing);
      store.dispose();
    });
  });

  testWidgets('English', (tester) async {
    final handle = tester.ensureSemantics();
    final port = _Port()..failSet = true;
    final store = RatingsStore(port);
    await tester.pumpWidget(
      _app(
        Column(
          children: [
            RatingStars(store: store, trackId: _song),
            RatingDislike(store: store, trackId: _song),
          ],
        ),
        locale: const Locale('en'),
      ),
    );
    expect(find.bySemanticsLabel('4 of 5'), findsOneWidget);
    expect(find.bySemanticsLabel('Dislike'), findsOneWidget);
    await tester.tap(_star(1));
    await tester.pump();
    await tester.pump();
    expect(find.text("Couldn't save the rating"), findsOneWidget);
    handle.dispose();
    store.dispose();
  });
}
