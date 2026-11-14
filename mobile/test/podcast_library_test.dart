import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/podcast_client.dart';
import 'package:music_stream/podcast_library.dart';

/// Lead check FT-663: podcasts section — screen models (subscriptions, search, episodes).

class _Source implements PodcastSource {
  final calls = <String>[];

  List<PodcastSubscription> subs = const [];
  Object? subsError;
  Completer<List<PodcastSubscription>>? subsHold;

  Map<String, List<FoundPodcast>> finds = {};
  Object? searchError;
  final searchHolds = <String, Completer<List<FoundPodcast>>>{};

  String? storedAs;
  Object? subscribeError;
  Completer<PodcastSubscribed>? subscribeHold;

  Object? unsubscribeError;
  Completer<bool>? unsubscribeHold;

  Map<String, List<PodcastEpisode>> feeds = {};
  Object? episodesError;
  final episodeHolds = <String, Completer<List<PodcastEpisode>>>{};

  @override
  Future<List<PodcastSubscription>> subscriptions() {
    calls.add('subscriptions');
    if (subsError != null) return Future.error(subsError!);
    return subsHold?.future ?? Future.value(subs);
  }

  @override
  Future<List<FoundPodcast>> search(String query, {int limit = 20}) {
    calls.add('search $query $limit');
    if (searchError != null) return Future.error(searchError!);
    return searchHolds[query]?.future ?? Future.value(finds[query] ?? const []);
  }

  @override
  Future<PodcastSubscribed> subscribe(String feedUrl) {
    calls.add('subscribe $feedUrl');
    if (subscribeError != null) return Future.error(subscribeError!);
    return subscribeHold?.future ??
        Future.value(PodcastSubscribed(storedAs ?? feedUrl, isNew: true));
  }

  @override
  Future<bool> unsubscribe(String feedUrl) {
    calls.add('unsubscribe $feedUrl');
    if (unsubscribeError != null) return Future.error(unsubscribeError!);
    return unsubscribeHold?.future ?? Future.value(true);
  }

  @override
  Future<List<PodcastEpisode>> episodes(
    String feedUrl, {
    int limit = 50,
    int offset = 0,
  }) {
    calls.add('episodes $feedUrl $limit $offset');
    if (episodesError != null) return Future.error(episodesError!);
    final hold = episodeHolds['$feedUrl $offset'];
    if (hold != null) return hold.future;
    final all = feeds[feedUrl] ?? const <PodcastEpisode>[];
    final from = offset > all.length ? all.length : offset;
    final to = from + limit > all.length ? all.length : from + limit;
    return Future.value(all.sublist(from, to));
  }
}

const _a = 'https://a.example/feed.xml';
const _b = 'https://b.example/feed.xml';
const _c = 'https://c.example/feed.xml';

PodcastSubscription _sub(String url, {String? title, DateTime? newest}) =>
    PodcastSubscription(
      feedUrl: url,
      title: title,
      author: '',
      image: null,
      episodes: 3,
      newestAt: newest,
      addedAt: null,
    );

FoundPodcast _found(String url, [String title = 'Show']) => FoundPodcast(
  feedUrl: url,
  title: title,
  author: '',
  image: null,
  episodes: null,
);

PodcastEpisode _episode(String guid) => PodcastEpisode(
  guid: guid,
  title: 'E $guid',
  description: '',
  audioUrl: 'https://a.example/$guid.mp3',
  audioType: null,
  audioBytes: null,
  durationMs: null,
  published: null,
  image: null,
  season: null,
  number: null,
  explicit: false,
);

List<PodcastEpisode> _many(int count, [String prefix = 'g']) => [
  for (var i = 0; i < count; i++) _episode('$prefix$i'),
];

const _offline = PodcastException(PodcastFailure.offline);

void main() {
  late _Source source;
  late PodcastLibrary library;
  late List<String> seen;

  setUp(() {
    source = _Source();
    library = PodcastLibrary(source);
    seen = [];
    library.addListener(
      () => seen.add(
        '${library.subscriptionsState.name}/${library.searchState.name}/'
        '${library.episodesState.name}',
      ),
    );
  });

  test('thresholds and page sizes match contract', () {
    expect(podcastSearchMinChars, 2);
    expect(podcastSearchLimit, 30);
    expect(podcastEpisodePage, 50);
  });

  test('initially all empty and nothing requested', () {
    expect(library.subscriptionsState, PodcastLoad.idle);
    expect(library.searchState, PodcastLoad.idle);
    expect(library.episodesState, PodcastLoad.idle);
    expect(library.subscriptions, isEmpty);
    expect(library.found, isEmpty);
    expect(library.episodes, isEmpty);
    expect(library.query, '');
    expect(library.feedUrl, isNull);
    expect(library.hasMore, isFalse);
    expect(library.loadingMore, isFalse);
    expect(library.moreFailed, isFalse);
    expect(source.calls, isEmpty);
  });

  group('subscriptions', () {
    test('loading: loading, then ready', () async {
      source.subs = [_sub(_a, title: 'A')];
      await library.loadSubscriptions();
      expect(seen, ['loading/idle/idle', 'ready/idle/idle']);
      expect(library.subscriptions.single.feedUrl, _a);
      expect(library.subscriptionsFailure, isNull);
      expect(library.isSubscribed(_a), isTrue);
      expect(library.isSubscribed(_b), isFalse);
    });

    test('empty list — empty', () async {
      await library.loadSubscriptions();
      expect(library.subscriptionsState, PodcastLoad.empty);
    });

    test(
      'order: newer episode first, undated last, then sorted by title name',
      () async {
        source.subs = [
          _sub('https://z.example/1', title: 'beta'),
          _sub('https://z.example/2', title: 'Old', newest: DateTime.utc(2024)),
          _sub('https://z.example/3', title: 'Alpha'),
          _sub('https://z.example/4', title: 'New', newest: DateTime.utc(2026)),
          _sub('https://z.example/5'),
          _sub('https://z.example/0'),
        ];
        await library.loadSubscriptions();
        expect(
          [for (final s in library.subscriptions) s.feedUrl.split('/').last],
          ['4', '2', '0', '5', '3', '1'],
        );
      },
    );

    test('same date — case-insensitive by name', () async {
      final day = DateTime.utc(2026, 5);
      source.subs = [
        _sub(_a, title: 'B', newest: day),
        _sub(_b, title: 'a', newest: day),
      ];
      await library.loadSubscriptions();
      expect([for (final s in library.subscriptions) s.title], ['a', 'B']);
    });

    test(
      'feed removed on another phone — marked as unsubscribed after reload',
      () async {
        source.subs = [_sub(_a), _sub(_b)];
        await library.loadSubscriptions();
        expect(library.isSubscribed(_b), isTrue);
        source.subs = [_sub(_a)];
        await library.loadSubscriptions();
        expect(library.isSubscribed(_a), isTrue);
        expect(library.isSubscribed(_b), isFalse);
      },
    );

    test('duplicate feed — deduplicated, keeps first', () async {
      source.subs = [_sub(_a, title: 'first'), _sub(_a, title: 'second')];
      await library.loadSubscriptions();
      expect(library.subscriptions.single.title, 'first');
    });

    test('list is unmodifiable from outside', () async {
      source.subs = [_sub(_a)];
      await library.loadSubscriptions();
      expect(() => library.subscriptions.clear(), throwsUnsupportedError);
    });

    test('failure: failed with reason, old list stays', () async {
      source.subs = [_sub(_a)];
      await library.loadSubscriptions();
      source.subsError = _offline;
      await library.loadSubscriptions();
      expect(library.subscriptionsState, PodcastLoad.failed);
      expect(library.subscriptionsFailure, PodcastFailure.offline);
      expect(library.subscriptions.single.feedUrl, _a);
      expect(library.isSubscribed(_a), isTrue);
    });

    test('foreign exception — broken, leaks nothing', () async {
      source.subsError = StateError('boom');
      await library.loadSubscriptions();
      expect(library.subscriptionsFailure, PodcastFailure.broken);
    });

    test('successful load clears previous error', () async {
      source.subsError = _offline;
      await library.loadSubscriptions();
      source.subsError = null;
      await library.loadSubscriptions();
      expect(library.subscriptionsFailure, isNull);
      expect(library.subscriptionsState, PodcastLoad.empty);
    });

    test('two loads at once: only latest applies', () async {
      final first = Completer<List<PodcastSubscription>>();
      source.subsHold = first;
      final one = library.loadSubscriptions();
      source.subsHold = null;
      source.subs = [_sub(_b)];
      await library.loadSubscriptions();
      first.complete([_sub(_a)]);
      await one;
      expect(library.subscriptions.single.feedUrl, _b);
      expect(library.isSubscribed(_a), isFalse);
    });

    test('late failure from old load breaks nothing', () async {
      final first = Completer<List<PodcastSubscription>>();
      source.subsHold = first;
      final one = library.loadSubscriptions();
      source.subsHold = null;
      source.subs = [_sub(_b)];
      await library.loadSubscriptions();
      first.completeError(_offline);
      await one;
      expect(library.subscriptionsState, PodcastLoad.ready);
      expect(library.subscriptionsFailure, isNull);
    });
  });

  group('search', () {
    test('query matches: loading, then ready', () async {
      source.finds['rock'] = [_found(_a), _found(_b)];
      await library.search('rock');
      expect(seen, ['idle/loading/idle', 'idle/ready/idle']);
      expect([for (final f in library.found) f.feedUrl], [_a, _b]);
      expect(library.query, 'rock');
      expect(source.calls, ['search rock 30']);
    });

    test('leading/trailing spaces trimmed', () async {
      await library.search('  rock  ');
      expect(source.calls, ['search rock 30']);
      expect(library.query, 'rock');
    });

    test('nothing found — empty', () async {
      await library.search('zz');
      expect(library.searchState, PodcastLoad.empty);
      expect(library.found, isEmpty);
    });

    test(
      'under 2 chars — server not queried, previous search results cleared',
      () async {
        source.finds['rock'] = [_found(_a)];
        await library.search('rock');
        source.calls.clear();
        for (final short in ['', ' ', 'r', ' r ']) {
          await library.search(short);
          expect(library.searchState, PodcastLoad.idle, reason: '"$short"');
          expect(library.found, isEmpty);
        }
        expect(source.calls, isEmpty);
        expect(library.query, 'r');
      },
    );

    test('exactly two chars triggers search', () async {
      await library.search('ab');
      expect(source.calls, ['search ab 30']);
    });

    test('duplicate feed in results — deduplicated', () async {
      source.finds['rock'] = [_found(_a, 'one'), _found(_a, 'two'), _found(_b)];
      await library.search('rock');
      expect([for (final f in library.found) f.title], ['one', 'Show']);
    });

    test('failure: failed with reason, old results cleared', () async {
      source.finds['rock'] = [_found(_a)];
      await library.search('rock');
      source.searchError = const PodcastException(
        PodcastFailure.searchUnavailable,
      );
      await library.search('jazz');
      expect(library.searchState, PodcastLoad.failed);
      expect(library.searchFailure, PodcastFailure.searchUnavailable);
      expect(library.found, isEmpty);
    });

    test('new search clears previous error', () async {
      source.searchError = _offline;
      await library.search('rock');
      source.searchError = null;
      await library.search('jazz');
      expect(library.searchFailure, isNull);
      source.searchError = _offline;
      await library.search('rock');
      await library.search('r');
      expect(library.searchFailure, isNull);
    });

    test('fast typing: response for latest query shown', () async {
      final slow = Completer<List<FoundPodcast>>();
      source.searchHolds['ro'] = slow;
      source.finds['rock'] = [_found(_b)];
      final one = library.search('ro');
      await library.search('rock');
      slow.complete([_found(_a)]);
      await one;
      expect(library.found.single.feedUrl, _b);
      expect(library.query, 'rock');
      expect(library.searchState, PodcastLoad.ready);
    });

    test(
      'query cleared during active search: late response is discarded here',
      () async {
        final slow = Completer<List<FoundPodcast>>();
        source.searchHolds['rock'] = slow;
        final one = library.search('rock');
        await library.search('');
        slow.complete([_found(_a)]);
        await one;
        expect(library.found, isEmpty);
        expect(library.searchState, PodcastLoad.idle);
      },
    );

    test('late failure from old search breaks nothing', () async {
      final slow = Completer<List<FoundPodcast>>();
      source.searchHolds['ro'] = slow;
      source.finds['rock'] = [_found(_b)];
      final one = library.search('ro');
      await library.search('rock');
      slow.completeError(_offline);
      await one;
      expect(library.searchState, PodcastLoad.ready);
      expect(library.searchFailure, isNull);
    });

    test('search results unmodifiable from outside', () async {
      source.finds['rock'] = [_found(_a)];
      await library.search('rock');
      expect(() => library.found.clear(), throwsUnsupportedError);
    });
  });

  group('subscribe', () {
    test('success: null, marked subscribed, list reloaded', () async {
      source.subs = [_sub(_a)];
      expect(await library.subscribe(_a), isNull);
      expect(library.isSubscribed(_a), isTrue);
      expect(library.isBusy(_a), isFalse);
      expect(source.calls, ['subscribe $_a', 'subscriptions']);
      expect(library.subscriptions.single.feedUrl, _a);
    });

    test('in progress — busy, repeat tap ignores server', () async {
      final hold = Completer<PodcastSubscribed>();
      source.subscribeHold = hold;
      final one = library.subscribe(_a);
      expect(library.isBusy(_a), isTrue);
      expect(library.isBusy(_b), isFalse);
      expect(await library.subscribe(_a), isNull);
      expect(source.calls, ['subscribe $_a']);
      hold.complete(const PodcastSubscribed(_a, isNew: true));
      await one;
      expect(library.isBusy(_a), isFalse);
    });

    test('listeners notified on start and finish', () async {
      final hold = Completer<PodcastSubscribed>();
      source.subscribeHold = hold;
      final one = library.subscribe(_a);
      expect(seen, hasLength(1));
      hold.complete(const PodcastSubscribed(_a, isNew: true));
      await one;
      expect(seen.length, greaterThanOrEqualTo(3));
    });

    test('already subscribed — server not queried', () async {
      source.subs = [_sub(_a)];
      await library.loadSubscriptions();
      source.calls.clear();
      expect(await library.subscribe(_a), isNull);
      expect(source.calls, isEmpty);
    });

    test('failure: returns reason, unsubscribed, busy cleared', () async {
      for (final reason in [
        PodcastFailure.limit,
        PodcastFailure.badUrl,
        PodcastFailure.offline,
      ]) {
        source.subscribeError = PodcastException(reason);
        expect(await library.subscribe(_a), reason);
        expect(library.isSubscribed(_a), isFalse);
        expect(library.isBusy(_a), isFalse);
      }
      expect(source.calls.where((c) => c == 'subscriptions'), isEmpty);
    });

    test('foreign exception — broken', () async {
      source.subscribeError = StateError('boom');
      expect(await library.subscribe(_a), PodcastFailure.broken);
    });

    test('can retry after failure', () async {
      source.subscribeError = _offline;
      await library.subscribe(_a);
      source.subscribeError = null;
      source.subs = [_sub(_a)];
      expect(await library.subscribe(_a), isNull);
      expect(library.isSubscribed(_a), isTrue);
    });

    test(
      'server saved feed with different url: both considered subscribed',
      () async {
        source.storedAs = _b;
        source.subs = [_sub(_b)];
        expect(await library.subscribe(_a), isNull);
        expect(library.isSubscribed(_a), isTrue);
        expect(library.isSubscribed(_b), isTrue);
        await library.loadSubscriptions();
        expect(library.isSubscribed(_a), isTrue, reason: 'after reload');
        source.calls.clear();
        expect(await library.subscribe(_a), isNull);
        expect(source.calls, isEmpty, reason: 'does not subscribe twice');
      },
    );

    test(
      'different url and list not reloaded — both still subscribed',
      () async {
        source.storedAs = _b;
        source.subsError = _offline;
        expect(await library.subscribe(_a), isNull);
        expect(library.isSubscribed(_a), isTrue);
        expect(library.isSubscribed(_b), isTrue);
      },
    );

    test('list not reloaded — subscription still succeeded', () async {
      source.subsError = _offline;
      expect(await library.subscribe(_a), isNull);
      expect(library.isSubscribed(_a), isTrue);
      expect(library.subscriptionsState, PodcastLoad.failed);
    });

    test('two different feeds subscribe independently', () async {
      final hold = Completer<PodcastSubscribed>();
      source.subscribeHold = hold;
      final one = library.subscribe(_a);
      source.subscribeHold = null;
      source.subs = [_sub(_a), _sub(_b)];
      expect(await library.subscribe(_b), isNull);
      expect(library.isBusy(_a), isTrue);
      expect(library.isSubscribed(_b), isTrue);
      hold.complete(const PodcastSubscribed(_a, isNew: true));
      await one;
      expect(library.isSubscribed(_a), isTrue);
    });
  });

  group('unsubscribe', () {
    setUp(() async {
      source.subs = [_sub(_a, title: 'A'), _sub(_b, title: 'B')];
      await library.loadSubscriptions();
      source.calls.clear();
      seen.clear();
    });

    test('success: null, feed removed without reload', () async {
      expect(await library.unsubscribe(_a), isNull);
      expect(library.isSubscribed(_a), isFalse);
      expect(library.isBusy(_a), isFalse);
      expect(library.subscriptions.single.feedUrl, _b);
      expect(library.subscriptionsState, PodcastLoad.ready);
      expect(source.calls, ['unsubscribe $_a']);
    });

    test('list after unsubscribe unmodifiable from outside', () async {
      source.subs = [_sub(_a), _sub(_b)];
      await library.loadSubscriptions();
      await library.unsubscribe(_a);
      expect(() => library.subscriptions.clear(), throwsUnsupportedError);
    });

    test('last subscription removed — empty', () async {
      await library.unsubscribe(_a);
      await library.unsubscribe(_b);
      expect(library.subscriptionsState, PodcastLoad.empty);
      expect(library.subscriptions, isEmpty);
    });

    test('server responded "not found" — also success', () async {
      source.unsubscribeHold = Completer<bool>()..complete(false);
      expect(await library.unsubscribe(_a), isNull);
      expect(library.isSubscribed(_a), isFalse);
    });

    test('notSubscribed rejection — also success', () async {
      source.unsubscribeError = const PodcastException(
        PodcastFailure.notSubscribed,
      );
      expect(await library.unsubscribe(_a), isNull);
      expect(library.isSubscribed(_a), isFalse);
      expect(library.subscriptions.single.feedUrl, _b);
    });

    test('failure: reason returned, feed remains', () async {
      source.unsubscribeError = _offline;
      expect(await library.unsubscribe(_a), PodcastFailure.offline);
      expect(library.isSubscribed(_a), isTrue);
      expect(library.isBusy(_a), isFalse);
      expect(library.subscriptions, hasLength(2));
    });

    test('foreign exception — broken', () async {
      source.unsubscribeError = StateError('boom');
      expect(await library.unsubscribe(_a), PodcastFailure.broken);
    });

    test('in progress — busy, repeat tap ignores server', () async {
      final hold = Completer<bool>();
      source.unsubscribeHold = hold;
      final one = library.unsubscribe(_a);
      expect(library.isBusy(_a), isTrue);
      expect(seen, hasLength(1));
      expect(await library.unsubscribe(_a), isNull);
      expect(source.calls, ['unsubscribe $_a']);
      hold.complete(true);
      await one;
      expect(library.isBusy(_a), isFalse);
    });

    test('subscribing in progress — unsubscribe blocked', () async {
      final hold = Completer<PodcastSubscribed>();
      source.subscribeHold = hold;
      final one = library.subscribe(_c);
      expect(await library.unsubscribe(_c), isNull);
      expect(source.calls, ['subscribe $_c']);
      hold.complete(const PodcastSubscribed(_c, isNew: true));
      await one;
    });

    test(
      'late list response does not restore previously unsubscribed podcast',
      () async {
        final hold = Completer<List<PodcastSubscription>>();
        source.subsHold = hold;
        final loading = library.loadSubscriptions();
        await library.unsubscribe(_a);
        hold.complete([_sub(_a), _sub(_b)]);
        await loading;
        expect(library.isSubscribed(_a), isFalse);
        expect(library.subscriptions.single.feedUrl, _b);
        expect(library.subscriptionsState, PodcastLoad.ready);
      },
    );

    test('list failed to load — unsubscribe leaves it unloaded', () async {
      // Otherwise "failed to load" would become "no subscriptions" until app restart.
      final fresh = PodcastLibrary(source);
      source.subsError = _offline;
      await fresh.loadSubscriptions();
      expect(fresh.subscriptionsState, PodcastLoad.failed);
      expect(await fresh.unsubscribe(_a), isNull);
      expect(fresh.subscriptionsState, PodcastLoad.failed);
      expect(fresh.subscriptionsFailure, PodcastFailure.offline);
    });

    test('list in transit — unsubscribe does not mark loaded', () async {
      final fresh = PodcastLibrary(source);
      final hold = Completer<List<PodcastSubscription>>();
      source.subsHold = hold;
      final loading = fresh.loadSubscriptions();
      expect(await fresh.unsubscribe(_a), isNull);
      expect(fresh.subscriptionsState, PodcastLoad.loading);
      hold.complete([_sub(_b)]);
      await loading;
      expect(fresh.subscriptionsState, PodcastLoad.ready);
    });

    test(
      'feed used two urls — neither remains subscribed after unsubscribing',
      () async {
        const one = 'https://one.example/feed';
        const two = 'https://two.example/feed';
        final fresh = PodcastLibrary(source);
        source.storedAs = _c;
        source.subsError = _offline;
        await fresh.subscribe(one);
        // Second URL of same feed only resolved by server — subscribing to it succeeds again.
        await fresh.subscribe(two);
        expect(fresh.isSubscribed(one), isTrue);
        expect(fresh.isSubscribed(two), isTrue);
        expect(await fresh.unsubscribe(one), isNull);
        expect(fresh.isSubscribed(one), isFalse);
        expect(fresh.isSubscribed(_c), isFalse);
        expect(fresh.isSubscribed(two), isFalse);
      },
    );

    test('subscriptions never opened — state remains idle', () async {
      final fresh = PodcastLibrary(source);
      await fresh.unsubscribe(_a);
      expect(fresh.subscriptionsState, PodcastLoad.idle);
    });

    test('feed with different url: that url sent to server', () async {
      source.storedAs = _c;
      source.subs = [_sub(_b), _sub(_c)];
      await library.unsubscribe(_a);
      await library.subscribe('https://typed.example/feed');
      source.calls.clear();
      expect(await library.unsubscribe('https://typed.example/feed'), isNull);
      expect(source.calls, ['unsubscribe $_c']);
      expect(library.isSubscribed(_c), isFalse);
      expect(library.isSubscribed('https://typed.example/feed'), isFalse);
      expect(library.subscriptions.single.feedUrl, _b);
    });
  });

  group('feed episodes', () {
    test('open: loading, then ready', () async {
      source.feeds[_a] = _many(3);
      await library.openFeed(_a);
      expect(seen, ['idle/idle/loading', 'idle/idle/ready']);
      expect(library.feedUrl, _a);
      expect([for (final e in library.episodes) e.guid], ['g0', 'g1', 'g2']);
      expect(source.calls, ['episodes $_a 50 0']);
    });

    test('incomplete page is not end; end is empty page', () async {
      // Client drops malformed episodes and duplicates: 49 out of 50 sent may arrive.
      source.feeds[_a] = [..._many(49), ..._many(1), ..._many(30, 'n')];
      source.episodeHolds['$_a 0'] = Completer<List<PodcastEpisode>>()
        ..complete(_many(49));
      await library.openFeed(_a);
      expect(library.episodes, hasLength(49));
      expect(library.hasMore, isTrue);
      await library.loadMore();
      expect(source.calls.last, 'episodes $_a 50 50');
      expect(library.episodes, hasLength(79));
      expect(library.hasMore, isTrue);
      await library.loadMore();
      expect(source.calls.last, 'episodes $_a 50 100');
      expect(library.episodes, hasLength(79));
      expect(library.hasMore, isFalse);
      expect(library.episodesState, PodcastLoad.ready);
    });

    test('no episodes — empty', () async {
      await library.openFeed(_a);
      expect(library.episodesState, PodcastLoad.empty);
      expect(library.hasMore, isFalse);
    });

    test('full page — more available', () async {
      source.feeds[_a] = _many(50);
      await library.openFeed(_a);
      expect(library.hasMore, isTrue);
      expect(library.episodes, hasLength(50));
    });

    test('failure: failed with reason', () async {
      source.episodesError = const PodcastException(
        PodcastFailure.notSubscribed,
      );
      await library.openFeed(_a);
      expect(library.episodesState, PodcastLoad.failed);
      expect(library.episodesFailure, PodcastFailure.notSubscribed);
      expect(library.feedUrl, _a);
      source.episodesError = StateError('boom');
      await library.openFeed(_a);
      expect(library.episodesFailure, PodcastFailure.broken);
    });

    test('other feed: previous episodes cleared immediately', () async {
      source.feeds[_a] = _many(50);
      await library.openFeed(_a);
      final hold = Completer<List<PodcastEpisode>>();
      source.episodeHolds['$_b 0'] = hold;
      final opening = library.openFeed(_b);
      expect(library.feedUrl, _b);
      expect(library.episodes, isEmpty);
      expect(library.hasMore, isFalse);
      expect(library.episodesState, PodcastLoad.loading);
      hold.complete(_many(1, 'b'));
      await opening;
      expect(library.episodes.single.guid, 'b0');
    });

    test('late response from old feed discarded', () async {
      final slow = Completer<List<PodcastEpisode>>();
      source.episodeHolds['$_a 0'] = slow;
      source.feeds[_b] = _many(1, 'b');
      final one = library.openFeed(_a);
      await library.openFeed(_b);
      slow.complete(_many(2));
      await one;
      expect(library.feedUrl, _b);
      expect(library.episodes.single.guid, 'b0');
    });

    test('late failure from old feed breaks nothing', () async {
      final slow = Completer<List<PodcastEpisode>>();
      source.episodeHolds['$_a 0'] = slow;
      source.feeds[_b] = _many(1, 'b');
      final one = library.openFeed(_a);
      await library.openFeed(_b);
      slow.completeError(_offline);
      await one;
      expect(library.episodesState, PodcastLoad.ready);
      expect(library.episodesFailure, isNull);
    });

    test('duplicate episode — deduplicated', () async {
      source.feeds[_a] = [_episode('x'), _episode('x'), _episode('y')];
      await library.openFeed(_a);
      expect([for (final e in library.episodes) e.guid], ['x', 'y']);
    });

    test('episodes unmodifiable from outside', () async {
      source.feeds[_a] = _many(2);
      await library.openFeed(_a);
      expect(() => library.episodes.clear(), throwsUnsupportedError);
    });

    test('close: all cleared, late response discarded', () async {
      final slow = Completer<List<PodcastEpisode>>();
      source.episodeHolds['$_a 0'] = slow;
      final one = library.openFeed(_a);
      library.closeFeed();
      expect(library.feedUrl, isNull);
      expect(library.episodesState, PodcastLoad.idle);
      slow.complete(_many(2));
      await one;
      expect(library.episodes, isEmpty);
      expect(library.episodesState, PodcastLoad.idle);
    });

    test('closing with nothing open does not notify listeners', () {
      library.closeFeed();
      expect(seen, isEmpty);
    });
  });

  group('next page', () {
    setUp(() async {
      source.feeds[_a] = _many(120);
      await library.openFeed(_a);
      source.calls.clear();
      seen.clear();
    });

    test('appends episodes, requests with offset', () async {
      await library.loadMore();
      expect(source.calls, ['episodes $_a 50 50']);
      expect(library.episodes, hasLength(100));
      expect(library.episodes[50].guid, 'g50');
      expect(library.hasMore, isTrue);
      expect(library.episodesState, PodcastLoad.ready);
      await library.loadMore();
      expect(source.calls.last, 'episodes $_a 50 100');
      expect(library.episodes, hasLength(120));
      expect(library.hasMore, isTrue, reason: 'end is only empty page');
      await library.loadMore();
      expect(source.calls.last, 'episodes $_a 50 150');
      expect(library.episodes, hasLength(120));
      expect(library.hasMore, isFalse);
      await library.loadMore();
      expect(source.calls, hasLength(3), reason: 'stop querying further');
    });

    test('in progress: loadingMore, second call ignored', () async {
      final hold = Completer<List<PodcastEpisode>>();
      source.episodeHolds['$_a 50'] = hold;
      final one = library.loadMore();
      expect(library.loadingMore, isTrue);
      expect(seen, hasLength(1));
      await library.loadMore();
      expect(source.calls, hasLength(1));
      hold.complete(_many(5, 'n'));
      await one;
      expect(library.loadingMore, isFalse);
      expect(library.episodes, hasLength(55));
      expect(library.hasMore, isTrue);
      expect(seen, hasLength(2));
    });

    test('already displayed episode not duplicated', () async {
      final hold = Completer<List<PodcastEpisode>>()
        ..complete([_episode('g49'), _episode('new'), _episode('new')]);
      source.episodeHolds['$_a 50'] = hold;
      await library.loadMore();
      expect(library.episodes, hasLength(51));
      expect(library.episodes.last.guid, 'new');
    });

    test('offset counted by requested, not displayed', () async {
      source.episodeHolds['$_a 50'] = Completer<List<PodcastEpisode>>()
        ..complete([for (var i = 0; i < 50; i++) _episode('g${i + 25}')]);
      await library.loadMore();
      expect(library.episodes, hasLength(75));
      expect(library.hasMore, isTrue);
      await library.loadMore();
      expect(source.calls.last, 'episodes $_a 50 100');
    });

    test('failure: keeps shown, moreFailed, can retry', () async {
      source.episodesError = _offline;
      await library.loadMore();
      expect(library.moreFailed, isTrue);
      expect(library.loadingMore, isFalse);
      expect(library.hasMore, isTrue);
      expect(library.episodes, hasLength(50));
      expect(library.episodesState, PodcastLoad.ready);
      expect(library.episodesFailure, isNull);
      source.episodesError = null;
      await library.loadMore();
      expect(library.moreFailed, isFalse);
      expect(source.calls.last, 'episodes $_a 50 50');
      expect(library.episodes, hasLength(100));
    });

    test(
      'opened another feed: late page response is not appended to list now',
      () async {
        final hold = Completer<List<PodcastEpisode>>();
        source.episodeHolds['$_a 50'] = hold;
        source.feeds[_b] = _many(50, 'b');
        final one = library.loadMore();
        await library.openFeed(_b);
        expect(library.loadingMore, isFalse);
        hold.complete(_many(5, 'n'));
        await one;
        expect(library.episodes, hasLength(50));
        expect(library.episodes.first.guid, 'b0');
        expect(library.hasMore, isTrue);
        await library.loadMore();
        expect(source.calls.last, 'episodes $_b 50 50');
      },
    );

    test(
      'reopened same feed: late page response is not appended to feed list',
      () async {
        final hold = Completer<List<PodcastEpisode>>();
        source.episodeHolds['$_a 50'] = hold;
        final one = library.loadMore();
        await library.openFeed(_a);
        hold.complete(_many(5, 'n'));
        await one;
        expect(library.episodes, hasLength(50));
        expect(library.loadingMore, isFalse);
      },
    );

    test('closed feed: late page failure changes nothing', () async {
      final hold = Completer<List<PodcastEpisode>>();
      source.episodeHolds['$_a 50'] = hold;
      final one = library.loadMore();
      library.closeFeed();
      hold.completeError(_offline);
      await one;
      expect(library.moreFailed, isFalse);
      expect(library.loadingMore, isFalse);
    });

    test(
      'no open feed, while loading, or failed — does not query server page',
      () async {
        library.closeFeed();
        await library.loadMore();
        final hold = Completer<List<PodcastEpisode>>();
        source.episodeHolds['$_b 0'] = hold;
        final opening = library.openFeed(_b);
        await library.loadMore();
        hold.completeError(_offline);
        await opening;
        await library.loadMore();
        expect(source.calls, ['episodes $_b 50 0']);
      },
    );
  });

  group('feed: subtle corner cases', () {
    test('reopened — previous failure reason cleared', () async {
      source.episodesError = _offline;
      await library.openFeed(_a);
      expect(library.episodesFailure, PodcastFailure.offline);
      source.episodesError = null;
      source.episodeHolds['$_a 0'] = Completer<List<PodcastEpisode>>();
      unawaited(library.openFeed(_a));
      expect(library.episodesState, PodcastLoad.loading);
      expect(library.episodesFailure, isNull);
    });

    test(
      'opened other feed — previous load-more error is cleared immediately',
      () async {
        source.feeds[_a] = _many(120);
        await library.openFeed(_a);
        source.episodesError = _offline;
        await library.loadMore();
        expect(library.moreFailed, isTrue);
        source.episodesError = null;
        source.episodeHolds['$_b 0'] = Completer<List<PodcastEpisode>>();
        unawaited(library.openFeed(_b));
        expect(library.moreFailed, isFalse);
      },
    );

    test('page 1 duplicates do not shift window further', () async {
      source.feeds[_a] = [
        ..._many(40),
        ..._many(10),
        for (var i = 0; i < 100; i++) _episode('n$i'),
      ];
      await library.openFeed(_a);
      expect(library.episodes, hasLength(40));
      await library.loadMore();
      expect(source.calls.last, 'episodes $_a 50 50');
      await library.loadMore();
      expect(source.calls.last, 'episodes $_a 50 100');
      expect(library.episodes, hasLength(140));
    });

    test('appended list also unmodifiable from outside', () async {
      source.feeds[_a] = _many(120);
      await library.openFeed(_a);
      await library.loadMore();
      expect(() => library.episodes.clear(), throwsUnsupportedError);
    });

    test('closed feed — no episodes remain', () async {
      source.feeds[_a] = _many(3);
      await library.openFeed(_a);
      library.closeFeed();
      expect(library.episodes, isEmpty);
      expect(library.feedUrl, isNull);
      expect(library.episodesState, PodcastLoad.idle);
    });
  });

  group('logout: other user traces', () {
    test('previous user list error cleared', () async {
      source.subsError = _offline;
      await library.loadSubscriptions();
      library.clear();
      expect(library.subscriptionsFailure, isNull);
    });

    test('previous user alias not passed to new user', () async {
      source.storedAs = _c;
      await library.subscribe(_a);
      library.clear();
      source.subs = [_sub(_c)];
      await library.loadSubscriptions();
      expect(library.isSubscribed(_c), isTrue);
      expect(library.isSubscribed(_a), isFalse);
    });
  });

  test('load-more after dispose does not query server', () async {
    source.feeds[_a] = _many(120);
    await library.openFeed(_a);
    source.calls.clear();
    library.dispose();
    await library.loadMore();
    expect(source.calls, isEmpty);
  });

  group('account logout', () {
    test('clear: nothing remains from previous user', () async {
      source.subs = [_sub(_a)];
      source.finds['rock'] = [_found(_b)];
      source.feeds[_a] = _many(50);
      source.storedAs = _a;
      await library.subscribe(_c);
      await library.search('rock');
      await library.openFeed(_a);
      seen.clear();
      library.clear();
      expect(seen, ['idle/idle/idle']);
      expect(library.subscriptions, isEmpty);
      expect(library.isSubscribed(_a), isFalse);
      expect(library.isSubscribed(_c), isFalse, reason: 'and alias forgotten');
      expect(library.found, isEmpty);
      expect(library.query, '');
      expect(library.feedUrl, isNull);
      expect(library.episodes, isEmpty);
      expect(library.hasMore, isFalse);
      expect(library.subscriptionsFailure, isNull);
    });

    test('late responses after clear are discarded', () async {
      final subs = Completer<List<PodcastSubscription>>();
      final find = Completer<List<FoundPodcast>>();
      final feed = Completer<List<PodcastEpisode>>();
      source.subsHold = subs;
      source.searchHolds['rock'] = find;
      source.episodeHolds['$_a 0'] = feed;
      final waits = [
        library.loadSubscriptions(),
        library.search('rock'),
        library.openFeed(_a),
      ];
      library.clear();
      subs.complete([_sub(_a)]);
      find.complete([_found(_b)]);
      feed.complete(_many(3));
      await Future.wait(waits);
      expect(library.subscriptions, isEmpty);
      expect(library.isSubscribed(_a), isFalse);
      expect(library.found, isEmpty);
      expect(library.episodes, isEmpty);
      expect(library.subscriptionsState, PodcastLoad.idle);
      expect(library.searchState, PodcastLoad.idle);
      expect(library.episodesState, PodcastLoad.idle);
    });

    test(
      'late subscribe after clear does not affect newly logged-in user now',
      () async {
        final hold = Completer<PodcastSubscribed>();
        source.subscribeHold = hold;
        final one = library.subscribe(_a);
        library.clear();
        expect(library.isBusy(_a), isFalse);
        hold.complete(const PodcastSubscribed(_a, isNew: true));
        expect(await one, isNull);
        expect(library.isSubscribed(_a), isFalse);
        expect(source.calls, ['subscribe $_a'], reason: 'list not reloaded');
      },
    );

    test(
      'late subscribe error after clear does not affect newly logged-in user',
      () async {
        final hold = Completer<PodcastSubscribed>();
        source.subscribeHold = hold;
        final one = library.subscribe(_a);
        library.clear();
        seen.clear();
        hold.completeError(_offline);
        expect(await one, isNull);
        expect(seen, isEmpty);
        expect(library.isBusy(_a), isFalse);
      },
    );

    test('late unsubscribe after clear touches nothing', () async {
      source.subs = [_sub(_a)];
      await library.loadSubscriptions();
      final hold = Completer<bool>();
      source.unsubscribeHold = hold;
      final one = library.unsubscribe(_a);
      library.clear();
      source.subsHold = null;
      await library.loadSubscriptions();
      hold.complete(true);
      await one;
      expect(library.isSubscribed(_a), isTrue, reason: 'this is already new');
      expect(library.isBusy(_a), isFalse);
    });
  });

  group('after dispose', () {
    test('no server calls, no notifications, no crashes', () async {
      library.dispose();
      await library.loadSubscriptions();
      await library.search('rock');
      expect(await library.subscribe(_a), isNull);
      expect(await library.unsubscribe(_a), isNull);
      await library.openFeed(_a);
      await library.loadMore();
      library.closeFeed();
      library.clear();
      expect(source.calls, isEmpty);
      expect(seen, isEmpty);
    });

    test('late responses after dispose do not crash', () async {
      source.feeds[_a] = _many(50);
      await library.openFeed(_a);
      final holds = [
        source.subsHold = Completer<List<PodcastSubscription>>(),
        source.searchHolds['rock'] = Completer<List<FoundPodcast>>(),
        source.subscribeHold = Completer<PodcastSubscribed>(),
        source.unsubscribeHold = Completer<bool>(),
        source.episodeHolds['$_a 50'] = Completer<List<PodcastEpisode>>(),
      ];
      final waits = [
        library.loadSubscriptions(),
        library.search('rock'),
        library.subscribe(_b),
        library.unsubscribe(_c),
        library.loadMore(),
      ];
      seen.clear();
      library.dispose();
      (holds[0] as Completer<List<PodcastSubscription>>).complete([_sub(_a)]);
      (holds[1] as Completer<List<FoundPodcast>>).completeError(_offline);
      (holds[2] as Completer<PodcastSubscribed>).completeError(_offline);
      (holds[3] as Completer<bool>).complete(true);
      (holds[4] as Completer<List<PodcastEpisode>>).complete(_many(2, 'n'));
      await Future.wait(waits);
      expect(seen, isEmpty);
    });
  });

  test('titles and urls do not leak into toString', () {
    expect(library.toString(), isNot(contains('example')));
  });

  test('2000 episodes in pages — under two seconds', () async {
    source.feeds[_a] = _many(2000);
    final watch = Stopwatch()..start();
    await library.openFeed(_a);
    while (library.hasMore) {
      await library.loadMore();
    }
    expect(library.episodes, hasLength(2000));
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
  });
}
