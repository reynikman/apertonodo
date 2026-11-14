import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/podcast_client.dart';
import 'package:music_stream/podcast_library.dart';
import 'package:music_stream/screens/podcast_home_view.dart';

/// Lead check FT-664: podcasts section — subscriptions and search screen over model from FT-663.

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
    return Future.value(true);
  }

  @override
  Future<List<PodcastEpisode>> episodes(
    String feedUrl, {
    int limit = 50,
    int offset = 0,
  }) {
    calls.add('episodes $feedUrl');
    return Future.value(const []);
  }
}

/// Model exposing whether anyone is listening to it.
class _Library extends PodcastLibrary {
  _Library(super.source);
  bool get listened => hasListeners;
}

/// Model requiring more than 3 chars: screen must trust rejection, not count chars itself.
class _Strict extends PodcastLibrary {
  _Strict(super.source);
  String _asked = '';

  @override
  String get query => _asked;

  @override
  PodcastLoad get searchState => PodcastLoad.idle;

  @override
  Future<void> search(String text) async {
    _asked = text.trim();
    notifyListeners();
  }
}

const _a = 'https://a.example/feed.xml';
const _b = 'https://b.example/feed.xml';
const _c = 'https://c.example/feed.xml';

PodcastSubscription _sub(
  String url, {
  String? title = 'Show',
  String author = '',
  int episodes = 3,
  DateTime? newest,
}) => PodcastSubscription(
  feedUrl: url,
  title: title,
  author: author,
  image: null,
  episodes: episodes,
  newestAt: newest,
  addedAt: null,
);

FoundPodcast _found(String url, {String title = 'Show', String author = ''}) =>
    FoundPodcast(
      feedUrl: url,
      title: title,
      author: author,
      image: null,
      episodes: null,
    );

PodcastException _fail(PodcastFailure reason) => PodcastException(reason);

/// Words intentionally neither Russian nor English: whatever screen shows besides them is its own.
final _texts = PodcastHomeTexts(
  searchHint: 't-hint',
  clearSearch: 't-clear',
  subscriptionsEmpty: 't-subs-empty',
  subscriptionsFailed: 't-subs-failed',
  refreshFailed: 't-refresh-failed',
  searchEmpty: 't-search-empty',
  searchFailed: 't-search-failed',
  searchUnavailable: 't-search-unavailable',
  offline: 't-offline',
  signedOut: 't-signed-out',
  retry: 't-retry',
  subscribe: 't-subscribe',
  unsubscribe: 't-unsubscribe',
  untitled: 't-untitled',
  limit: 't-limit',
  badUrl: 't-bad-url',
  actionFailed: 't-action-failed',
  episodeCount: (count) => 't-episodes-$count',
);

Finder _key(String name) => find.byKey(Key(name));

class _Shown {
  _Shown(this.source, this.library);
  final _Source source;
  final PodcastLibrary library;
  bool get listened => (library as _Library).listened;
  final opened = <(String, String)>[];
}

Widget _app(_Shown shown, {PodcastLibrary? library}) => MaterialApp(
  home: Scaffold(
    body: PodcastHomeView(
      library: library ?? shown.library,
      texts: _texts,
      onOpenFeed: (url, title) => shown.opened.add((url, title)),
    ),
  ),
);

Future<_Shown> _show(
  WidgetTester tester, {
  _Source? source,
  double width = 400,
  bool settle = true,
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  source ??= _Source();
  final shown = _Shown(source, _Library(source));
  addTearDown(shown.library.dispose);
  await tester.pumpWidget(_app(shown));
  if (settle) await tester.pump();
  return shown;
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(_key('podcast-search-field'), text);
  await tester.pump();
}

/// Type words and await server response.
Future<void> _search(WidgetTester tester, String text) async {
  await _type(tester, text);
  await tester.pump(podcastSearchDelay);
  await tester.pump();
}

IconButton _toggle(WidgetTester tester, int index) =>
    tester.widget<IconButton>(_key('podcast-found-toggle-$index'));

String _message(WidgetTester tester) => tester
    .widget<Text>(
      find.descendant(of: _key('podcast-message'), matching: find.byType(Text)),
    )
    .data!;

String _actionMessage(WidgetTester tester) => tester
    .widget<Text>(
      find.descendant(
        of: _key('podcast-action-message'),
        matching: find.byType(Text),
      ),
    )
    .data!;

bool _live(WidgetTester tester, String key) =>
    tester.widget<Semantics>(_key(key)).properties.liveRegion == true;

void main() {
  test('search debounce — 400 ms', () {
    expect(podcastSearchDelay, const Duration(milliseconds: 400));
  });

  group('subscriptions', () {
    testWidgets('screen queries subscriptions, spinner while waiting', (
      tester,
    ) async {
      final source = _Source()..subsHold = Completer();
      final shown = await _show(tester, source: source, settle: false);
      expect(source.calls, ['subscriptions']);
      expect(_key('podcast-loading'), findsOneWidget);
      expect(_key('podcast-message'), findsNothing);
      source.subsHold!.complete([_sub(_a, title: 'Alpha')]);
      await tester.pump();
      expect(_key('podcast-loading'), findsNothing);
      expect(find.text('Alpha'), findsOneWidget);
      expect(shown.library.subscriptionsState, PodcastLoad.ready);
    });

    testWidgets('subscriptions already loaded — server not queried again', (
      tester,
    ) async {
      final source = _Source()..subs = [_sub(_a, title: 'Alpha')];
      final library = PodcastLibrary(source);
      addTearDown(library.dispose);
      await library.loadSubscriptions();
      source.calls.clear();
      final shown = _Shown(source, library);
      await tester.pumpWidget(_app(shown));
      await tester.pump();
      expect(source.calls, isEmpty);
      expect(find.text('Alpha'), findsOneWidget);
    });

    testWidgets('no subscriptions — message shown, no retry button', (
      tester,
    ) async {
      await _show(tester);
      expect(_message(tester), 't-subs-empty');
      expect(_live(tester, 'podcast-message'), isTrue);
      expect(_key('podcast-retry'), findsNothing);
    });

    testWidgets('row: title, author, and episode count', (tester) async {
      final source = _Source()
        ..subs = [_sub(_a, title: 'Alpha', author: 'Ann', episodes: 12)];
      await _show(tester, source: source);
      expect(
        find.descendant(
          of: _key('podcast-sub-0'),
          matching: find.text('Alpha'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: _key('podcast-sub-0'),
          matching: find.text('Ann · t-episodes-12'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('no author — episode count only, without separator dot', (
      tester,
    ) async {
      final source = _Source()..subs = [_sub(_a, title: 'Alpha', episodes: 0)];
      await _show(tester, source: source);
      expect(find.text('t-episodes-0'), findsOneWidget);
    });

    testWidgets('feed without title (not crawled yet) — placeholder', (
      tester,
    ) async {
      final source = _Source()
        ..subs = [
          _sub(_a, title: null, newest: DateTime.utc(2026, 5)),
          _sub(_b, title: ''),
        ];
      final shown = await _show(tester, source: source);
      expect(find.text('t-untitled'), findsNWidgets(2));
      await tester.tap(_key('podcast-sub-0'));
      expect(shown.opened, [(_a, 't-untitled')]);
    });

    testWidgets('row order matches model', (tester) async {
      final source = _Source()
        ..subs = [
          _sub(_a, title: 'Old', newest: DateTime.utc(2026, 1)),
          _sub(_b, title: 'New', newest: DateTime.utc(2026, 6)),
        ];
      await _show(tester, source: source);
      expect(
        find.descendant(of: _key('podcast-sub-0'), matching: find.text('New')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: _key('podcast-sub-1'), matching: find.text('Old')),
        findsOneWidget,
      );
    });

    testWidgets('tapping row opens feed', (tester) async {
      final source = _Source()
        ..subs = [
          _sub(_a, title: 'Alpha', newest: DateTime.utc(2026, 6)),
          _sub(_b, title: 'Beta', newest: DateTime.utc(2026, 1)),
        ];
      final shown = await _show(tester, source: source);
      await tester.tap(_key('podcast-sub-1'));
      expect(shown.opened, [(_b, 'Beta')]);
      // Screen does not open feed directly or query server for episodes — left to wiring.
      expect(source.calls, ['subscriptions']);
    });

    testWidgets('row height at least 48 dp', (tester) async {
      final source = _Source()..subs = [_sub(_a, title: 'Alpha')];
      await _show(tester, source: source);
      expect(
        tester.getSize(_key('podcast-sub-0')).height,
        greaterThanOrEqualTo(48),
      );
    });

    testWidgets('long title on narrow screen does not break layout', (
      tester,
    ) async {
      final source = _Source()
        ..subs = [_sub(_a, title: 'Long ' * 60, author: 'Author ' * 40)];
      await _show(tester, source: source, width: 320);
      expect(tester.takeException(), isNull);
      expect(tester.getSize(_key('podcast-sub-0')).height, lessThan(120));
    });

    testWidgets('500 subscriptions: subscription rows built on scroll', (
      tester,
    ) async {
      final source = _Source()
        ..subs = [
          for (var i = 0; i < 500; i++)
            _sub('https://f$i.example/feed.xml', title: 'Show $i'),
        ];
      await _show(tester, source: source);
      expect(find.byType(ListTile).evaluate().length, lessThan(40));
      expect(_key('podcast-sub-0'), findsOneWidget);
      expect(_key('podcast-sub-499'), findsNothing);
    });

    testWidgets('subscriptions list has own scroll pos', (tester) async {
      final source = _Source()..subs = [_sub(_a)];
      await _show(tester, source: source);
      final list = tester.widget<ListView>(find.byType(ListView));
      expect(list.key, const PageStorageKey('podcast-subs'));
    });

    for (final (reason, text) in [
      (PodcastFailure.offline, 't-offline'),
      (PodcastFailure.signedOut, 't-signed-out'),
      (PodcastFailure.unavailable, 't-subs-failed'),
      (PodcastFailure.broken, 't-subs-failed'),
    ]) {
      testWidgets('list failed to load (${reason.name}) — text and retry', (
        tester,
      ) async {
        final source = _Source()..subsError = _fail(reason);
        await _show(tester, source: source);
        expect(_message(tester), text);
        expect(_live(tester, 'podcast-message'), isTrue);
        expect(_key('podcast-retry'), findsOneWidget);
        expect(find.text('t-retry'), findsOneWidget);
        expect(
          tester.getSize(_key('podcast-retry')).height,
          greaterThanOrEqualTo(48),
        );
      });
    }

    testWidgets('retry queries server again and displays podcast list', (
      tester,
    ) async {
      final source = _Source()..subsError = _fail(PodcastFailure.offline);
      await _show(tester, source: source);
      source
        ..subsError = null
        ..subs = [_sub(_a, title: 'Alpha')]
        ..calls.clear();
      await tester.tap(_key('podcast-retry'));
      await tester.pump();
      expect(source.calls, ['subscriptions']);
      expect(find.text('Alpha'), findsOneWidget);
      expect(_key('podcast-message'), findsNothing);
    });

    testWidgets('refresh with list shown: bar shown, list stays', (
      tester,
    ) async {
      final source = _Source()..subs = [_sub(_a, title: 'Alpha')];
      final shown = await _show(tester, source: source);
      expect(_key('podcast-refreshing'), findsNothing);
      source.subsHold = Completer();
      unawaited(shown.library.loadSubscriptions());
      await tester.pump();
      expect(_key('podcast-refreshing'), findsOneWidget);
      expect(_key('podcast-loading'), findsNothing);
      expect(find.text('Alpha'), findsOneWidget);
      source.subsHold!.complete([_sub(_a, title: 'Alpha')]);
      await tester.pump();
      expect(_key('podcast-refreshing'), findsNothing);
    });

    for (final (reason, text) in [
      (PodcastFailure.offline, 't-offline'),
      (PodcastFailure.unavailable, 't-refresh-failed'),
    ]) {
      testWidgets(
        'update failed (${reason.name}): list stays, error message above list',
        (tester) async {
          final source = _Source()..subs = [_sub(_a, title: 'Alpha')];
          final shown = await _show(tester, source: source);
          source.subsError = _fail(reason);
          await shown.library.loadSubscriptions();
          await tester.pump();
          expect(find.text('Alpha'), findsOneWidget);
          expect(_message(tester), text);
          expect(_live(tester, 'podcast-message'), isTrue);
          expect(_key('podcast-retry'), findsNothing);
        },
      );
    }
  });

  group('search field', () {
    testWidgets('hint from screen text, no clear icon', (tester) async {
      await _show(tester);
      expect(find.text('t-hint'), findsOneWidget);
      expect(_key('podcast-search-clear'), findsNothing);
    });

    testWidgets('one char — still subscriptions, server not queried', (
      tester,
    ) async {
      final source = _Source()..subs = [_sub(_a, title: 'Alpha')];
      await _show(tester, source: source);
      source.calls.clear();
      await _type(tester, 'a');
      await tester.pump(podcastSearchDelay * 2);
      expect(source.calls, isEmpty);
      expect(find.text('Alpha'), findsOneWidget);
      expect(_key('podcast-search-clear'), findsOneWidget);
    });

    testWidgets('spaces do not count as chars', (tester) async {
      final source = _Source()..subs = [_sub(_a, title: 'Alpha')];
      await _show(tester, source: source);
      source.calls.clear();
      await _type(tester, '  a   ');
      // Immediately after typing, before debounce: no spinner, subscriptions intact.
      expect(_key('podcast-search-loading'), findsNothing);
      expect(find.text('Alpha'), findsOneWidget);
      await tester.pump(podcastSearchDelay * 2);
      expect(source.calls, isEmpty);
      expect(find.text('Alpha'), findsOneWidget);
    });

    testWidgets('one emoji is one char: subscriptions, not spinner', (
      tester,
    ) async {
      final source = _Source()..subs = [_sub(_a, title: 'Alpha')];
      await _show(tester, source: source);
      source.calls.clear();
      await _type(tester, String.fromCharCode(0x1F600));
      await tester.pump(podcastSearchDelay * 2);
      await tester.pump();
      expect(source.calls, isEmpty);
      expect(_key('podcast-search-loading'), findsNothing);
      expect(find.text('Alpha'), findsOneWidget);
    });

    testWidgets('two chars: spinner now, server only after debounce', (
      tester,
    ) async {
      final source = _Source()
        ..subs = [_sub(_a, title: 'Alpha')]
        ..finds = {
          'ab': [_found(_b, title: 'Found')],
        };
      await _show(tester, source: source);
      source.calls.clear();
      await _type(tester, 'ab');
      expect(_key('podcast-search-loading'), findsOneWidget);
      expect(find.text('Alpha'), findsNothing);
      await tester.pump(podcastSearchDelay - const Duration(milliseconds: 1));
      expect(source.calls, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      expect(source.calls, ['search ab $podcastSearchLimit']);
      await tester.pump();
      expect(_key('podcast-search-loading'), findsNothing);
      expect(find.text('Found'), findsOneWidget);
    });

    testWidgets('fast typing — single server request for latest text', (
      tester,
    ) async {
      final source = _Source();
      await _show(tester, source: source);
      source.calls.clear();
      await _type(tester, 'ab');
      await tester.pump(const Duration(milliseconds: 300));
      await _type(tester, 'abc');
      await tester.pump(const Duration(milliseconds: 300));
      await _type(tester, 'abcd');
      expect(source.calls, isEmpty);
      await tester.pump(podcastSearchDelay);
      expect(source.calls, ['search abcd $podcastSearchLimit']);
    });

    testWidgets('keyboard search is immediate, no second request sent', (
      tester,
    ) async {
      final source = _Source()
        ..finds = {
          'abc': [_found(_b, title: 'Found')],
        };
      await _show(tester, source: source);
      source.calls.clear();
      await _type(tester, 'abc');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      expect(source.calls, ['search abc $podcastSearchLimit']);
      expect(find.text('Found'), findsOneWidget);
      await tester.pump(podcastSearchDelay * 2);
      expect(source.calls, ['search abc $podcastSearchLimit']);
    });

    testWidgets('query changed — old results replaced by spinner', (
      tester,
    ) async {
      final source = _Source()
        ..finds = {
          'abc': [_found(_b, title: 'Found')],
        };
      await _show(tester, source: source);
      await _search(tester, 'abc');
      expect(find.text('Found'), findsOneWidget);
      await _type(tester, 'abcd');
      expect(find.text('Found'), findsNothing);
      expect(_key('podcast-search-loading'), findsOneWidget);
      await tester.pump(podcastSearchDelay);
      await tester.pump();
    });

    testWidgets(
      'cleared to one char — subscriptions now, late request cancelled',
      (tester) async {
        final source = _Source()
          ..subs = [_sub(_a, title: 'Alpha')]
          ..finds = {
            'abc': [_found(_b, title: 'Found')],
          };
        final shown = await _show(tester, source: source);
        await _search(tester, 'abc');
        await _type(tester, 'abcd');
        source.calls.clear();
        await _type(tester, 'a');
        expect(find.text('Alpha'), findsOneWidget);
        expect(find.text('Found'), findsNothing);
        expect(shown.library.found, isEmpty);
        expect(shown.library.searchState, PodcastLoad.idle);
        await tester.pump(podcastSearchDelay * 2);
        expect(source.calls, isEmpty);
      },
    );

    testWidgets('clear button: field empty, in-flight query cancelled', (
      tester,
    ) async {
      final source = _Source()..subs = [_sub(_a, title: 'Alpha')];
      final shown = await _show(tester, source: source);
      source.calls.clear();
      await _type(tester, 'abc');
      expect(
        tester.widget<IconButton>(_key('podcast-search-clear')).tooltip,
        't-clear',
      );
      await tester.tap(_key('podcast-search-clear'));
      await tester.pump();
      expect(
        tester.widget<TextField>(_key('podcast-search-field')).controller!.text,
        '',
      );
      expect(_key('podcast-search-clear'), findsNothing);
      expect(find.text('Alpha'), findsOneWidget);
      await tester.pump(podcastSearchDelay * 2);
      expect(source.calls, isEmpty);
      expect(shown.library.query, '');
    });

    testWidgets(
      'returned to screen with active search — query and results kept',
      (tester) async {
        final source = _Source()
          ..finds = {
            'abc': [_found(_b, title: 'Found')],
          };
        final library = PodcastLibrary(source);
        addTearDown(library.dispose);
        await library.search('abc');
        source.calls.clear();
        final shown = _Shown(source, library);
        await tester.pumpWidget(_app(shown));
        await tester.pump();
        expect(
          tester
              .widget<TextField>(_key('podcast-search-field'))
              .controller!
              .text,
          'abc',
        );
        expect(find.text('Found'), findsOneWidget);
        expect(source.calls, ['subscriptions']);
      },
    );

    testWidgets('field does not autocorrect or suggest', (tester) async {
      await _show(tester);
      final field = tester.widget<TextField>(_key('podcast-search-field'));
      expect(field.autocorrect, isFalse);
      expect(field.enableSuggestions, isFalse);
      expect(field.textInputAction, TextInputAction.search);
    });
  });

  group('search results', () {
    testWidgets('row: title and author', (tester) async {
      final source = _Source()
        ..finds = {
          'abc': [
            _found(_a, title: 'First', author: 'Ann'),
            _found(_b, title: 'Second'),
          ],
        };
      await _show(tester, source: source);
      await _search(tester, 'abc');
      expect(
        find.descendant(
          of: _key('podcast-found-0'),
          matching: find.text('First'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: _key('podcast-found-0'),
          matching: find.text('Ann'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: _key('podcast-found-1'),
          matching: find.text('Second'),
        ),
        findsOneWidget,
      );
      expect(
        tester.getSize(_key('podcast-found-0')).height,
        greaterThanOrEqualTo(48),
      );
      expect(
        tester.getSize(_key('podcast-found-1')).height,
        greaterThanOrEqualTo(48),
        reason: 'row without author',
      );
      final list = tester.widget<ListView>(find.byType(ListView));
      expect(list.key, const PageStorageKey('podcast-found abc'));
    });

    testWidgets('long text on narrow screen does not break layout', (
      tester,
    ) async {
      final source = _Source()
        ..finds = {
          'abc': [_found(_a, title: 'Long ' * 60, author: 'Author ' * 40)],
        };
      await _show(tester, source: source, width: 320);
      await _search(tester, 'abc');
      expect(tester.takeException(), isNull);
      expect(_key('podcast-found-toggle-0'), findsOneWidget);
      expect(tester.getSize(_key('podcast-found-0')).height, lessThan(120));
    });

    testWidgets('nothing found — message shown, without any retry button', (
      tester,
    ) async {
      await _show(tester);
      await _search(tester, 'abc');
      expect(_message(tester), 't-search-empty');
      expect(_live(tester, 'podcast-message'), isTrue);
      expect(_key('podcast-retry'), findsNothing);
    });

    for (final (reason, text) in [
      (PodcastFailure.offline, 't-offline'),
      (PodcastFailure.signedOut, 't-signed-out'),
      (PodcastFailure.searchUnavailable, 't-search-unavailable'),
      (PodcastFailure.unavailable, 't-search-failed'),
      (PodcastFailure.broken, 't-search-failed'),
    ]) {
      testWidgets('search failed (${reason.name}) — message and retry', (
        tester,
      ) async {
        final source = _Source();
        await _show(tester, source: source);
        source.searchError = _fail(reason);
        await _search(tester, 'abc');
        expect(_message(tester), text);
        expect(_live(tester, 'podcast-message'), isTrue);
        expect(_key('podcast-retry'), findsOneWidget);
      });
    }

    testWidgets('retry queries same text immediately', (tester) async {
      final source = _Source();
      await _show(tester, source: source);
      source.searchError = _fail(PodcastFailure.offline);
      await _search(tester, ' abc ');
      source
        ..searchError = null
        ..finds = {
          'abc': [_found(_a, title: 'Found')],
        }
        ..calls.clear();
      await tester.tap(_key('podcast-retry'));
      await tester.pump();
      expect(source.calls, ['search abc $podcastSearchLimit']);
      expect(find.text('Found'), findsOneWidget);
    });

    testWidgets('"subscribe" button: tooltip, request, then "unsubscribe"', (
      tester,
    ) async {
      final source = _Source()
        ..finds = {
          'abc': [_found(_a, title: 'Found')],
        };
      await _show(tester, source: source);
      await _search(tester, 'abc');
      expect(_toggle(tester, 0).tooltip, 't-subscribe');
      expect(_toggle(tester, 0).isSelected, isFalse);
      source
        ..subs = [_sub(_a, title: 'Found')]
        ..calls.clear();
      await tester.tap(_key('podcast-found-toggle-0'));
      await tester.pump();
      await tester.pump();
      expect(source.calls, ['subscribe $_a', 'subscriptions']);
      expect(_toggle(tester, 0).tooltip, 't-unsubscribe');
      expect(_toggle(tester, 0).isSelected, isTrue);
      expect(_key('podcast-action-message'), findsNothing);
    });

    testWidgets('button disabled while subscribing', (tester) async {
      final source = _Source()
        ..finds = {
          'abc': [_found(_a), _found(_b)],
        };
      await _show(tester, source: source);
      await _search(tester, 'abc');
      source
        ..subscribeHold = Completer()
        ..calls.clear();
      await tester.tap(_key('podcast-found-toggle-0'));
      await tester.pump();
      expect(_toggle(tester, 0).onPressed, isNull);
      expect(_toggle(tester, 1).onPressed, isNotNull);
      await tester.tap(_key('podcast-found-toggle-0'), warnIfMissed: false);
      await tester.pump();
      expect(source.calls, ['subscribe $_a']);
      source.subscribeHold!.complete(PodcastSubscribed(_a, isNew: true));
      await tester.pump();
      await tester.pump();
      expect(_toggle(tester, 0).onPressed, isNotNull);
    });

    testWidgets('subscribed feed: button unsubscribes', (tester) async {
      final source = _Source()
        ..subs = [_sub(_a, title: 'Mine')]
        ..finds = {
          'abc': [_found(_a, title: 'Mine')],
        };
      final shown = await _show(tester, source: source);
      await _search(tester, 'abc');
      expect(_toggle(tester, 0).tooltip, 't-unsubscribe');
      source.calls.clear();
      await tester.tap(_key('podcast-found-toggle-0'));
      await tester.pump();
      expect(source.calls, ['unsubscribe $_a']);
      expect(_toggle(tester, 0).tooltip, 't-subscribe');
      expect(shown.library.isSubscribed(_a), isFalse);
    });

    testWidgets(
      'server saved feed with different url — still considered subscribed',
      (tester) async {
        final source = _Source()
          ..finds = {
            'abc': [_found(_a, title: 'Found')],
          };
        await _show(tester, source: source);
        await _search(tester, 'abc');
        source
          ..storedAs = _c
          ..subs = [_sub(_c, title: 'Found')];
        await tester.tap(_key('podcast-found-toggle-0'));
        await tester.pump();
        await tester.pump();
        expect(_toggle(tester, 0).tooltip, 't-unsubscribe');
      },
    );

    for (final (reason, text) in [
      (PodcastFailure.limit, 't-limit'),
      (PodcastFailure.badUrl, 't-bad-url'),
      (PodcastFailure.offline, 't-offline'),
      (PodcastFailure.signedOut, 't-signed-out'),
      (PodcastFailure.unavailable, 't-action-failed'),
      (PodcastFailure.broken, 't-action-failed'),
    ]) {
      testWidgets('subscribe failed (${reason.name}) — message above results', (
        tester,
      ) async {
        final source = _Source()
          ..finds = {
            'abc': [_found(_a, title: 'Found')],
          };
        await _show(tester, source: source);
        await _search(tester, 'abc');
        source.subscribeError = _fail(reason);
        await tester.tap(_key('podcast-found-toggle-0'));
        await tester.pump();
        await tester.pump();
        expect(_actionMessage(tester), text);
        expect(_live(tester, 'podcast-action-message'), isTrue);
        // Results remain, button switches back to "subscribe".
        expect(find.text('Found'), findsOneWidget);
        expect(_toggle(tester, 0).tooltip, 't-subscribe');
        expect(_toggle(tester, 0).onPressed, isNotNull);
      });
    }

    testWidgets('unsubscribe failed — message, feed stays subscribed', (
      tester,
    ) async {
      final source = _Source()
        ..subs = [_sub(_a)]
        ..finds = {
          'abc': [_found(_a)],
        };
      await _show(tester, source: source);
      await _search(tester, 'abc');
      source.unsubscribeError = _fail(PodcastFailure.offline);
      await tester.tap(_key('podcast-found-toggle-0'));
      await tester.pump();
      await tester.pump();
      expect(_actionMessage(tester), 't-offline');
      expect(_toggle(tester, 0).tooltip, 't-unsubscribe');
    });

    testWidgets('failure message clears on retry', (tester) async {
      final source = _Source()
        ..finds = {
          'abc': [_found(_a)],
        };
      await _show(tester, source: source);
      await _search(tester, 'abc');
      source.subscribeError = _fail(PodcastFailure.limit);
      await tester.tap(_key('podcast-found-toggle-0'));
      await tester.pump();
      await tester.pump();
      expect(_key('podcast-action-message'), findsOneWidget);
      source
        ..subscribeError = null
        ..subscribeHold = Completer();
      await tester.tap(_key('podcast-found-toggle-0'));
      await tester.pump();
      expect(_key('podcast-action-message'), findsNothing);
      source.subscribeHold!.complete(PodcastSubscribed(_a, isNew: true));
      await tester.pump();
      await tester.pump();
    });

    testWidgets('failure message clears away as user types query further', (
      tester,
    ) async {
      final source = _Source()
        ..finds = {
          'abc': [_found(_a)],
        };
      await _show(tester, source: source);
      await _search(tester, 'abc');
      source.subscribeError = _fail(PodcastFailure.limit);
      await tester.tap(_key('podcast-found-toggle-0'));
      await tester.pump();
      await tester.pump();
      expect(_key('podcast-action-message'), findsOneWidget);
      await _type(tester, 'abcd');
      expect(_key('podcast-action-message'), findsNothing);
      await tester.pump(podcastSearchDelay);
      await tester.pump();
    });

    testWidgets('tap row: subscribed opens, unsubscribed does not', (
      tester,
    ) async {
      final source = _Source()
        ..subs = [_sub(_a, title: 'Mine')]
        ..finds = {
          'abc': [_found(_a, title: 'Mine'), _found(_b, title: 'Other')],
        };
      final shown = await _show(tester, source: source);
      await _search(tester, 'abc');
      await tester.tap(find.text('Other'));
      expect(shown.opened, isEmpty);
      await tester.tap(find.text('Mine'));
      expect(shown.opened, [(_a, 'Mine')]);
    });
  });

  group('screen lifecycle', () {
    testWidgets(
      'account logout: previous user search queries do not remain behind',
      (tester) async {
        final source = _Source()
          ..subs = [_sub(_a, title: 'Alpha')]
          ..finds = {
            'abc': [_found(_b, title: 'Found')],
          };
        final shown = await _show(tester, source: source);
        await _search(tester, 'abc');
        source.subscribeError = _fail(PodcastFailure.limit);
        await tester.tap(_key('podcast-found-toggle-0'));
        await tester.pump();
        await tester.pump();
        source.calls.clear();
        shown.library.clear();
        await tester.pump();
        expect(
          tester
              .widget<TextField>(_key('podcast-search-field'))
              .controller!
              .text,
          '',
        );
        expect(find.text('Found'), findsNothing);
        expect(find.text('Alpha'), findsNothing);
        expect(_key('podcast-action-message'), findsNothing);
        expect(_key('podcast-search-loading'), findsNothing);
        expect(
          _key('podcast-message'),
          findsNothing,
          reason: 'not "no subscriptions"',
        );
        // After unmount screen does not query server.
        await tester.pump(podcastSearchDelay * 2);
        expect(source.calls, isEmpty);
      },
    );

    testWidgets('screen closed mid-typing — no request sent to server', (
      tester,
    ) async {
      final source = _Source();
      await _show(tester, source: source);
      source.calls.clear();
      await _type(tester, 'abc');
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump(podcastSearchDelay * 2);
      expect(source.calls, isEmpty);
    });

    testWidgets('screen closed — model lives on without querying', (
      tester,
    ) async {
      final source = _Source()..subs = [_sub(_a)];
      final shown = await _show(tester, source: source);
      expect(shown.listened, isTrue);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      expect(shown.listened, isFalse, reason: 'listener removed');
      await shown.library.loadSubscriptions();
      await shown.library.search('abc');
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('screen closed during subscribe — response breaks nothing', (
      tester,
    ) async {
      final source = _Source()
        ..finds = {
          'abc': [_found(_a)],
        };
      await _show(tester, source: source);
      await _search(tester, 'abc');
      source.subscribeHold = Completer();
      await tester.tap(_key('podcast-found-toggle-0'));
      await tester.pump();
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      source.subscribeHold!.completeError(_fail(PodcastFailure.limit));
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'model rejected query that screen accepted — shows subscriptions list',
      (tester) async {
        final source = _Source()..subs = [_sub(_a, title: 'Alpha')];
        final library = _Strict(source);
        addTearDown(library.dispose);
        final shown = _Shown(source, library);
        await tester.pumpWidget(_app(shown));
        await tester.pump();
        await _type(tester, 'abc');
        await tester.pump(podcastSearchDelay * 2);
        await tester.pump();
        expect(_key('podcast-search-loading'), findsNothing);
        expect(find.text('Alpha'), findsOneWidget, reason: 'not empty screen');
      },
    );

    testWidgets('each search query has own scroll pos', (tester) async {
      final source = _Source()
        ..finds = {
          'abc': [for (var i = 0; i < 30; i++) _found('$_a?$i', title: 'A$i')],
          'xyz': [for (var i = 0; i < 30; i++) _found('$_b?$i', title: 'X$i')],
        };
      await _show(tester, source: source);
      await _search(tester, 'abc');
      final list = tester.state<ScrollableState>(find.byType(Scrollable).last);
      list.position.jumpTo(list.position.maxScrollExtent);
      await tester.pump();
      expect(find.text('A0'), findsNothing);
      await _search(tester, 'xyz');
      expect(find.text('X0'), findsOneWidget, reason: 'new results at top');
    });

    testWidgets('previous model failure not shown over new results', (
      tester,
    ) async {
      final source = _Source()
        ..finds = {
          'abc': [_found(_a)],
        };
      final shown = await _show(tester, source: source);
      await _search(tester, 'abc');
      source.subscribeHold = Completer();
      await tester.tap(_key('podcast-found-toggle-0'));
      await tester.pump();
      final other = _Source()
        ..finds = {
          'abc': [_found(_b, title: 'Other')],
        };
      final next = PodcastLibrary(other);
      addTearDown(next.dispose);
      await next.search('abc');
      await tester.pumpWidget(_app(shown, library: next));
      await tester.pump();
      expect(find.text('Other'), findsOneWidget);
      source.subscribeHold!.completeError(_fail(PodcastFailure.limit));
      await tester.pump();
      await tester.pump();
      expect(_key('podcast-action-message'), findsNothing);
      expect(find.text('Other'), findsOneWidget);
    });

    testWidgets('given new model — listens to it, detached from old', (
      tester,
    ) async {
      final source = _Source()..subs = [_sub(_a, title: 'Alpha')];
      final shown = await _show(tester, source: source);
      await _type(tester, 'abc');
      final other = _Source()..subs = [_sub(_b, title: 'Beta')];
      final next = PodcastLibrary(other);
      addTearDown(next.dispose);
      source.calls.clear();
      await tester.pumpWidget(_app(shown, library: next));
      await tester.pump();
      expect(other.calls, ['subscriptions']);
      expect(shown.listened, isFalse, reason: 'detached from old');
      expect(
        tester.widget<TextField>(_key('podcast-search-field')).controller!.text,
        '',
      );
      expect(find.text('Beta'), findsOneWidget);
      expect(find.text('Alpha'), findsNothing);
      // Text typed with previous model not sent to server — neither old nor new.
      await tester.pump(podcastSearchDelay * 2);
      expect(source.calls, isEmpty);
      expect(other.calls, ['subscriptions']);
      // Previous model mutates — screen does not repaint with its data.
      source.subs = [_sub(_c, title: 'Gamma')];
      await shown.library.loadSubscriptions();
      await tester.pump();
      expect(find.text('Gamma'), findsNothing);
      other.subs = [_sub(_c, title: 'Delta')];
      await next.loadSubscriptions();
      await tester.pump();
      expect(find.text('Delta'), findsOneWidget);
    });

    testWidgets(
      'other model with active search — its own query, without stale error',
      (tester) async {
        final source = _Source()
          ..finds = {
            'abc': [_found(_a, title: 'Found')],
          };
        final shown = await _show(tester, source: source);
        await _search(tester, 'abc');
        source.subscribeError = _fail(PodcastFailure.limit);
        await tester.tap(_key('podcast-found-toggle-0'));
        await tester.pump();
        await tester.pump();
        expect(_key('podcast-action-message'), findsOneWidget);
        final other = _Source()
          ..finds = {
            'xyz': [_found(_b, title: 'Theirs')],
          };
        final next = PodcastLibrary(other);
        addTearDown(next.dispose);
        await next.search('xyz');
        await tester.pumpWidget(_app(shown, library: next));
        await tester.pump();
        expect(
          tester
              .widget<TextField>(_key('podcast-search-field'))
              .controller!
              .text,
          'xyz',
        );
        expect(find.text('Theirs'), findsOneWidget);
        expect(find.text('Found'), findsNothing);
        expect(_key('podcast-action-message'), findsNothing);
      },
    );

    testWidgets(
      'subscriptions finished mid-typing — typed search text is not erased',
      (tester) async {
        final source = _Source()..subsHold = Completer();
        await _show(tester, source: source, settle: false);
        await _type(tester, 'ab');
        source.subsHold!.complete([_sub(_a, title: 'Alpha')]);
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          tester
              .widget<TextField>(_key('podcast-search-field'))
              .controller!
              .text,
          'ab',
        );
        expect(_key('podcast-search-loading'), findsOneWidget);
        await tester.pump(podcastSearchDelay);
        expect(source.calls, [
          'subscriptions',
          'search ab $podcastSearchLimit',
        ]);
        await tester.pump();
      },
    );

    testWidgets('screen opened over another listening to same model — '
        'rendering does not crash', (tester) async {
      final source = _Source();
      final shown = _Shown(source, _Library(source));
      addTearDown(shown.library.dispose);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: Scaffold(
            body: ListenableBuilder(
              listenable: shown.library,
              builder: (context, child) =>
                  Text('below-${shown.library.subscriptionsState.name}'),
            ),
          ),
        ),
      );
      navigator.currentState!.push(
        MaterialPageRoute<void>(builder: (context) => _app(shown)),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        source.calls.where((call) => call.startsWith('subscriptions')),
        hasLength(1),
      );
    });

    testWidgets('no hardcoded strings: all text from words and data', (
      tester,
    ) async {
      final source = _Source()
        ..subs = [_sub(_a, title: 'Alpha', author: 'Ann')]
        ..finds = {
          'abc': [_found(_b, title: 'Found', author: 'Bob')],
        };
      await _show(tester, source: source);
      final seen = <String>{};
      void collect() {
        for (final element in find.byType(Text).evaluate()) {
          final data = (element.widget as Text).data;
          if (data != null) seen.add(data);
        }
        for (final element in find.byType(IconButton).evaluate()) {
          final tip = (element.widget as IconButton).tooltip;
          if (tip != null) seen.add(tip);
        }
      }

      collect();
      await _search(tester, 'abc');
      collect();
      source.subscribeError = _fail(PodcastFailure.broken);
      await tester.tap(_key('podcast-found-toggle-0'));
      await tester.pump();
      await tester.pump();
      collect();
      source.searchError = _fail(PodcastFailure.broken);
      await _search(tester, 'abcd');
      collect();
      const data = {'Alpha', 'Found', 'Bob', 'abc', 'abcd'};
      for (final text in seen) {
        final own =
            data.contains(text) ||
            text.startsWith('t-') ||
            text == 'Ann · t-episodes-3';
        expect(own, isTrue, reason: 'unexpected on screen: «$text»');
      }
      expect(seen, contains('t-hint'));
    });
  });
}
