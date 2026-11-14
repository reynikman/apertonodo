import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/podcast_client.dart';
import 'package:music_stream/podcast_library.dart';
import 'package:music_stream/screens/podcast_feed_view.dart';

/// Lead check FT-666: podcasts section — episode feed screen over model from FT-663.

/// First page queries. Short feed is fully visible, so screen immediately asks for
/// second: model discovers end of feed only via empty page (FT-663).
Iterable<String> _opened(_Source source) =>
    source.calls.where((call) => call.endsWith(' 0'));

class _Source implements PodcastSource {
  final calls = <String>[];
  Map<String, List<PodcastEpisode>> feeds = {};
  Object? episodesError;
  final holds = <String, Completer<List<PodcastEpisode>>>{};

  @override
  Future<List<PodcastEpisode>> episodes(
    String feedUrl, {
    int limit = 50,
    int offset = 0,
  }) {
    calls.add('episodes $feedUrl $limit $offset');
    if (episodesError != null) return Future.error(episodesError!);
    final hold = holds['$feedUrl $offset'];
    if (hold != null) return hold.future;
    final all = feeds[feedUrl] ?? const <PodcastEpisode>[];
    final from = offset > all.length ? all.length : offset;
    final to = from + limit > all.length ? all.length : from + limit;
    return Future.value(all.sublist(from, to));
  }

  @override
  Future<List<FoundPodcast>> search(String query, {int limit = 20}) =>
      Future.value(const []);

  @override
  Future<List<PodcastSubscription>> subscriptions() => Future.value(const []);

  @override
  Future<PodcastSubscribed> subscribe(String feedUrl) =>
      Future.value(PodcastSubscribed(feedUrl, isNew: true));

  @override
  Future<bool> unsubscribe(String feedUrl) => Future.value(true);
}

/// Model exposing whether anyone is listening to it.
class _Library extends PodcastLibrary {
  _Library(super.source);
  bool get listened => hasListeners;
}

const _a = 'https://a.example/feed.xml';
const _b = 'https://b.example/feed.xml';

PodcastEpisode _episode(
  String guid, {
  String? title,
  DateTime? published,
  int? durationMs,
}) => PodcastEpisode(
  guid: guid,
  title: title ?? 'E $guid',
  audioUrl: 'https://a.example/$guid.mp3',
  published: published,
  durationMs: durationMs,
);

List<PodcastEpisode> _many(int count, [String prefix = 'g']) => [
  for (var i = 0; i < count; i++) _episode('$prefix$i'),
];

PodcastException _fail(PodcastFailure reason) => PodcastException(reason);

/// Words intentionally neither Russian nor English: whatever screen shows besides them is its own.
final _texts = PodcastFeedTexts(
  empty: 't-empty',
  failed: 't-failed',
  notSubscribed: 't-not-subscribed',
  offline: 't-offline',
  signedOut: 't-signed-out',
  retry: 't-retry',
  moreFailed: 't-more-failed',
  untitled: 't-untitled',
  finished: 't-finished',
  date: (published) => 't-date-${published.year}-${published.month}',
  duration: (milliseconds) => 't-len-$milliseconds',
);

Finder _key(String name) => find.byKey(Key(name));

class _Shown {
  _Shown(this.source, this.library);
  final _Source source;
  final _Library library;
  final played = <String>[];
  Map<String, double> heard = {};
}

Widget _app(
  _Shown shown, {
  PodcastLibrary? library,
  String feedUrl = _a,
  bool progress = true,
}) => MaterialApp(
  home: Scaffold(
    body: PodcastFeedView(
      library: library ?? shown.library,
      feedUrl: feedUrl,
      texts: _texts,
      onPlay: (episode) => shown.played.add(episode.guid),
      progress: progress ? (episode) => shown.heard[episode.guid] : null,
    ),
  ),
);

Future<_Shown> _show(
  WidgetTester tester, {
  _Source? source,
  double width = 400,
  bool settle = true,
  bool progress = true,
  Map<String, double> heard = const {},
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  source ??= _Source();
  final shown = _Shown(source, _Library(source))..heard = heard;
  addTearDown(shown.library.dispose);
  await tester.pumpWidget(_app(shown, progress: progress));
  if (settle) await tester.pump();
  return shown;
}

String _message(WidgetTester tester, [String key = 'podcast-feed-message']) =>
    tester
        .widget<Text>(
          find.descendant(of: _key(key), matching: find.byType(Text)),
        )
        .data!;

bool _live(WidgetTester tester, String key) =>
    tester.widget<Semantics>(_key(key)).properties.liveRegion == true;

/// Scroll to the very end of list.
Future<void> _toEnd(WidgetTester tester) async {
  final list = tester.state<ScrollableState>(find.byType(Scrollable).first);
  list.position.jumpTo(list.position.maxScrollExtent);
  await tester.pump();
  await tester.pump();
}

void main() {
  test('next page requested ten rows before end', () {
    expect(podcastFeedAhead, 10);
  });

  group('opening', () {
    testWidgets('screen opens feed, spinner while waiting', (tester) async {
      final source = _Source()..holds['$_a 0'] = Completer();
      final shown = await _show(tester, source: source, settle: false);
      expect(source.calls, ['episodes $_a $podcastEpisodePage 0']);
      expect(_key('podcast-feed-loading'), findsOneWidget);
      source.holds['$_a 0']!.complete([_episode('one', title: 'First')]);
      await tester.pump();
      expect(_key('podcast-feed-loading'), findsNothing);
      expect(find.text('First'), findsOneWidget);
      expect(shown.library.feedUrl, _a);
    });

    testWidgets('feed open in model — server not queried again', (
      tester,
    ) async {
      final source = _Source()..feeds[_a] = [_episode('one', title: 'First')];
      final library = _Library(source);
      addTearDown(library.dispose);
      await library.openFeed(_a);
      source.calls.clear();
      await tester.pumpWidget(_app(_Shown(source, library)));
      await tester.pump();
      expect(_opened(source), isEmpty);
      expect(find.text('First'), findsOneWidget);
    });

    testWidgets('different feed open in model — opens this one', (
      tester,
    ) async {
      final source = _Source()
        ..feeds[_a] = [_episode('one', title: 'Mine')]
        ..feeds[_b] = [_episode('two', title: 'Other')];
      final library = _Library(source);
      addTearDown(library.dispose);
      await library.openFeed(_b);
      await tester.pumpWidget(_app(_Shown(source, library)));
      expect(
        find.text('Other'),
        findsNothing,
        reason: 'other episodes not shown even for a frame',
      );
      await tester.pump();
      expect(find.text('Mine'), findsOneWidget);
      expect(find.text('Other'), findsNothing);
    });

    testWidgets('no episodes — message shown, no retry', (tester) async {
      await _show(tester);
      expect(_message(tester), 't-empty');
      expect(_live(tester, 'podcast-feed-message'), isTrue);
      expect(_key('podcast-feed-retry'), findsNothing);
    });

    for (final (reason, text) in [
      (PodcastFailure.offline, 't-offline'),
      (PodcastFailure.signedOut, 't-signed-out'),
      (PodcastFailure.notSubscribed, 't-not-subscribed'),
      (PodcastFailure.unavailable, 't-failed'),
      (PodcastFailure.broken, 't-failed'),
    ]) {
      testWidgets('feed failed to open (${reason.name}) — message and retry', (
        tester,
      ) async {
        final source = _Source()..episodesError = _fail(reason);
        await _show(tester, source: source);
        expect(_message(tester), text);
        expect(_live(tester, 'podcast-feed-message'), isTrue);
        expect(find.text('t-retry'), findsOneWidget);
        expect(
          tester.getSize(_key('podcast-feed-retry')).height,
          greaterThanOrEqualTo(48),
        );
      });
    }

    testWidgets('retry opens feed again', (tester) async {
      final source = _Source()..episodesError = _fail(PodcastFailure.offline);
      await _show(tester, source: source);
      source
        ..episodesError = null
        ..feeds[_a] = [_episode('one', title: 'First')]
        ..calls.clear();
      await tester.tap(_key('podcast-feed-retry'));
      await tester.pump();
      expect(_opened(source), ['episodes $_a $podcastEpisodePage 0']);
      expect(find.text('First'), findsOneWidget);
      expect(_key('podcast-feed-message'), findsNothing);
    });
  });

  group('episode row', () {
    testWidgets('title, date and duration', (tester) async {
      final source = _Source()
        ..feeds[_a] = [
          _episode(
            'one',
            title: 'First',
            published: DateTime.utc(2026, 5, 4),
            durationMs: 90000,
          ),
        ];
      await _show(tester, source: source);
      expect(
        find.descendant(
          of: _key('podcast-episode-0'),
          matching: find.text('First'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: _key('podcast-episode-0'),
          matching: find.text('t-date-2026-5 · t-len-90000'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('missing date or duration — shows available info', (
      tester,
    ) async {
      final source = _Source()
        ..feeds[_a] = [
          _episode('one', published: DateTime.utc(2026, 5, 4)),
          _episode('two', durationMs: 1000),
          _episode('three', durationMs: 0),
          _episode('four'),
        ];
      await _show(tester, source: source);
      expect(find.text('t-date-2026-5'), findsOneWidget);
      expect(find.text('t-len-1000'), findsOneWidget);
      expect(find.textContaining('t-len-0'), findsNothing);
      expect(find.textContaining(' · '), findsNothing);
    });

    testWidgets('untitled episode — placeholder', (tester) async {
      final source = _Source()..feeds[_a] = [_episode('one', title: '')];
      await _show(tester, source: source);
      expect(find.text('t-untitled'), findsOneWidget);
    });

    testWidgets('tap plays this episode', (tester) async {
      final source = _Source()..feeds[_a] = _many(3);
      final shown = await _show(tester, source: source);
      await tester.tap(_key('podcast-episode-1'));
      expect(shown.played, ['g1']);
    });

    testWidgets('row at least 48 dp, long title does not break layout', (
      tester,
    ) async {
      final source = _Source()
        ..feeds[_a] = [
          _episode('one', title: 'A'),
          _episode('two', title: 'Long ' * 80, durationMs: 5),
        ];
      await _show(tester, source: source, width: 320);
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(_key('podcast-episode-0')).height,
        greaterThanOrEqualTo(48),
      );
      expect(tester.getSize(_key('podcast-episode-1')).height, lessThan(140));
    });

    testWidgets('not started — no bar, no checkmark', (tester) async {
      final source = _Source()..feeds[_a] = _many(1);
      await _show(tester, source: source);
      expect(_key('podcast-episode-progress-0'), findsNothing);
      expect(_key('podcast-episode-done-0'), findsNothing);
    });

    testWidgets('started — progress bar with fraction', (tester) async {
      final source = _Source()..feeds[_a] = _many(2);
      await _show(tester, source: source, heard: {'g1': 0.25});
      expect(_key('podcast-episode-progress-0'), findsNothing);
      final bar = tester.widget<LinearProgressIndicator>(
        _key('podcast-episode-progress-1'),
      );
      expect(bar.value, 0.25);
      expect(_key('podcast-episode-done-1'), findsNothing);
    });

    testWidgets('nearly finished — still progress bar, not checkmark', (
      tester,
    ) async {
      final source = _Source()..feeds[_a] = _many(1);
      await _show(tester, source: source, heard: {'g0': 0.99});
      final bar = tester.widget<LinearProgressIndicator>(
        _key('podcast-episode-progress-0'),
      );
      expect(bar.value, 0.99);
      expect(_key('podcast-episode-done-0'), findsNothing);
    });

    testWidgets('finished, episode has date — label present, no bar', (
      tester,
    ) async {
      final source = _Source()
        ..feeds[_a] = [
          _episode('one', published: DateTime.utc(2026, 9, 1), durationMs: 5),
        ];
      await _show(tester, source: source, heard: {'one': 1.0});
      expect(_key('podcast-episode-done-0'), findsOneWidget);
      expect(_key('podcast-episode-progress-0'), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('fraction below zero displayed as zero', (tester) async {
      final source = _Source()..feeds[_a] = _many(1);
      await _show(tester, source: source, heard: {'g0': -3});
      final bar = tester.widget<LinearProgressIndicator>(
        _key('podcast-episode-progress-0'),
      );
      expect(bar.value, 0);
    });

    for (final value in [1.0, 1.7]) {
      testWidgets('finished ($value) — checkmark with label, no bar', (
        tester,
      ) async {
        final source = _Source()..feeds[_a] = _many(1);
        await _show(tester, source: source, heard: {'g0': value});
        expect(_key('podcast-episode-progress-0'), findsNothing);
        final icon = tester.widget<Icon>(_key('podcast-episode-done-0'));
        expect(icon.semanticLabel, 't-finished');
      });
    }

    testWidgets('no progress provided — screen works without it', (
      tester,
    ) async {
      final source = _Source()..feeds[_a] = _many(2);
      final shown = await _show(tester, source: source, progress: false);
      expect(_key('podcast-episode-progress-0'), findsNothing);
      await tester.tap(_key('podcast-episode-0'));
      expect(shown.played, ['g0']);
    });

    testWidgets('list retains its own scroll position per each feed', (
      tester,
    ) async {
      final source = _Source()..feeds[_a] = _many(1);
      await _show(tester, source: source);
      final list = tester.widget<ListView>(find.byType(ListView));
      expect(list.key, const PageStorageKey('podcast-feed $_a'));
    });
  });

  group('next page', () {
    testWidgets('server not queried while end is far', (tester) async {
      final source = _Source()..feeds[_a] = _many(120);
      await _show(tester, source: source);
      await tester.pump();
      expect(source.calls, ['episodes $_a $podcastEpisodePage 0']);
      expect(find.byType(ListTile).evaluate().length, lessThan(30));
    });

    testWidgets('scrolled to end — page requested and appended', (
      tester,
    ) async {
      final source = _Source()..feeds[_a] = _many(120);
      final shown = await _show(tester, source: source);
      await _toEnd(tester);
      expect(source.calls.last, 'episodes $_a $podcastEpisodePage 50');
      expect(shown.library.episodes, hasLength(100));
      await _toEnd(tester);
      expect(source.calls.last, 'episodes $_a $podcastEpisodePage 100');
      expect(shown.library.episodes, hasLength(120));
      // Incomplete page is not end yet: model queries further and receives empty.
      await _toEnd(tester);
      expect(source.calls.last, 'episodes $_a $podcastEpisodePage 150');
      await _toEnd(tester);
      expect(source.calls, hasLength(4), reason: 'empty page ends list');
      expect(_key('podcast-more-loading'), findsNothing);
      expect(_key('podcast-episode-119'), findsOneWidget);
    });

    testWidgets('page requested in advance, before reaching last row', (
      tester,
    ) async {
      final source = _Source()
        ..feeds[_a] = _many(120)
        ..holds['$_a 50'] = Completer();
      await _show(tester, source: source);
      expect(source.calls, hasLength(1), reason: 'too early at list start');
      final row = tester.getSize(_key('podcast-episode-0')).height;
      final list = tester.state<ScrollableState>(find.byType(Scrollable).first);
      // First visible row is 26th: far from page end, but within 10 rows
      // list is already prebuilding.
      list.position.jumpTo(row * 26);
      await tester.pump();
      await tester.pump();
      expect(_key('podcast-episode-49'), findsNothing);
      expect(_key('podcast-more-loading'), findsNothing);
      expect(source.calls.last, 'episodes $_a $podcastEpisodePage 50');
    });

    testWidgets('bottom spinner and single request while loading', (
      tester,
    ) async {
      final source = _Source()
        ..feeds[_a] = _many(120)
        ..holds['$_a 50'] = Completer();
      await _show(tester, source: source);
      await _toEnd(tester);
      await _toEnd(tester);
      expect(_key('podcast-more-loading'), findsOneWidget);
      expect(source.calls.where((c) => c.endsWith(' 50')), hasLength(1));
      source.holds['$_a 50']!.complete(_many(3, 'n'));
      await tester.pump();
      await tester.pump();
      expect(_key('podcast-more-loading'), findsNothing);
    });

    testWidgets('page failed — message and retry, no hammering', (
      tester,
    ) async {
      final source = _Source()..feeds[_a] = _many(120);
      final shown = await _show(tester, source: source);
      source.episodesError = _fail(PodcastFailure.offline);
      await _toEnd(tester);
      await _toEnd(tester);
      expect(shown.library.moreFailed, isTrue);
      expect(_message(tester, 'podcast-more-message'), 't-more-failed');
      expect(_live(tester, 'podcast-more-message'), isTrue);
      expect(_key('podcast-more-loading'), findsNothing);
      expect(
        tester.getSize(_key('podcast-more-retry')).height,
        greaterThanOrEqualTo(48),
      );
      final asked = source.calls.length;
      await tester.pump();
      await _toEnd(tester);
      expect(
        source.calls,
        hasLength(asked),
        reason: 'does not retry without tap',
      );
      // Displayed items remained.
      expect(shown.library.episodes, hasLength(50));
    });

    testWidgets('retry button requests page again', (tester) async {
      final source = _Source()..feeds[_a] = _many(120);
      final shown = await _show(tester, source: source);
      source.episodesError = _fail(PodcastFailure.offline);
      await _toEnd(tester);
      await _toEnd(tester);
      source
        ..episodesError = null
        ..calls.clear();
      await tester.tap(_key('podcast-more-retry'));
      await tester.pump();
      expect(source.calls, ['episodes $_a $podcastEpisodePage 50']);
      expect(shown.library.episodes, hasLength(100));
      expect(_key('podcast-more-message'), findsNothing);
    });
  });

  group('screen lifecycle', () {
    testWidgets('account logout — previous user episodes cleared', (
      tester,
    ) async {
      final source = _Source()..feeds[_a] = [_episode('one', title: 'First')];
      final shown = await _show(tester, source: source);
      source.calls.clear();
      shown.library.clear();
      await tester.pump();
      await tester.pump();
      expect(find.text('First'), findsNothing);
      expect(_key('podcast-feed-message'), findsNothing);
      expect(source.calls, isEmpty, reason: 'does not reopen feed on its own');
    });

    testWidgets(
      'model opened another feed — its episodes are not displayed here at all',
      (tester) async {
        final source = _Source()
          ..feeds[_a] = [_episode('one', title: 'Mine')]
          ..feeds[_b] = [_episode('two', title: 'Other')];
        final shown = await _show(tester, source: source);
        await shown.library.openFeed(_b);
        await tester.pump();
        expect(find.text('Other'), findsNothing);
        expect(find.text('Mine'), findsNothing);
      },
    );

    testWidgets('screen closed — listener removed, does not close feed', (
      tester,
    ) async {
      final source = _Source()..feeds[_a] = _many(2);
      final shown = await _show(tester, source: source);
      expect(shown.library.listened, isTrue);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      expect(shown.library.listened, isFalse);
      expect(shown.library.feedUrl, _a);
      await shown.library.openFeed(_b);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('screen closed near list end — page not requested', (
      tester,
    ) async {
      final source = _Source()..feeds[_a] = _many(120);
      await _show(tester, source: source);
      final list = tester.state<ScrollableState>(find.byType(Scrollable).first);
      list.position.jumpTo(list.position.maxScrollExtent);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump();
      await tester.pump();
      expect(source.calls, ['episodes $_a $podcastEpisodePage 0']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('given different url — opens new one', (tester) async {
      final source = _Source()
        ..feeds[_a] = [_episode('one', title: 'Mine')]
        ..feeds[_b] = [_episode('two', title: 'Other')];
      final shown = await _show(tester, source: source);
      await tester.pumpWidget(_app(shown, feedUrl: _b));
      await tester.pump();
      expect(_opened(source).last, 'episodes $_b $podcastEpisodePage 0');
      expect(find.text('Other'), findsOneWidget);
      expect(find.text('Mine'), findsNothing);
    });

    testWidgets(
      'same url and same model — widget rebuild does not query server again',
      (tester) async {
        final source = _Source()..feeds[_a] = _many(2);
        final shown = await _show(tester, source: source);
        source.calls.clear();
        await tester.pumpWidget(_app(shown));
        await tester.pump();
        expect(source.calls, isEmpty);
      },
    );

    testWidgets('given new model — listens to it, detached from old', (
      tester,
    ) async {
      final source = _Source()..feeds[_a] = [_episode('one', title: 'Old')];
      final shown = await _show(tester, source: source);
      final other = _Source()..feeds[_a] = [_episode('two', title: 'New')];
      final next = _Library(other);
      addTearDown(next.dispose);
      await tester.pumpWidget(_app(shown, library: next));
      await tester.pump();
      expect(_opened(other), ['episodes $_a $podcastEpisodePage 0']);
      expect(shown.library.listened, isFalse);
      expect(next.listened, isTrue);
      expect(find.text('New'), findsOneWidget);
      expect(find.text('Old'), findsNothing);
    });

    testWidgets('screen opened over another listening to same model — '
        'rendering does not crash', (tester) async {
      final source = _Source()..feeds = {_a: _many(3)};
      final library = _Library(source);
      final shown = _Shown(source, library);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: Scaffold(
            body: ListenableBuilder(
              listenable: library,
              builder: (context, child) =>
                  Text('below-${library.episodes.length}'),
            ),
          ),
        ),
      );
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (context) => Scaffold(
            body: PodcastFeedView(
              library: library,
              feedUrl: _a,
              texts: _texts,
              onPlay: (episode) => shown.played.add(episode.guid),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(_opened(source), hasLength(1));
      expect(find.text('E g0'), findsOneWidget);
    });

    testWidgets('no hardcoded strings: all text from words and data', (
      tester,
    ) async {
      final source = _Source()..feeds[_a] = _many(120);
      await _show(tester, source: source, heard: {'g0': 1, 'g1': 0.5});
      final seen = <String>{};
      void collect() {
        for (final element in find.byType(Text).evaluate()) {
          final data = (element.widget as Text).data;
          if (data != null) seen.add(data);
        }
        for (final element in find.byType(Icon).evaluate()) {
          final label = (element.widget as Icon).semanticLabel;
          if (label != null) seen.add(label);
        }
      }

      collect();
      source.episodesError = _fail(PodcastFailure.broken);
      await _toEnd(tester);
      await _toEnd(tester);
      collect();
      for (final text in seen) {
        expect(
          text.startsWith('t-') || text.startsWith('E g'),
          isTrue,
          reason: 'unexpected words on screen: «$text»',
        );
      }
      expect(seen, containsAll(['t-finished', 't-more-failed', 't-retry']));
    });
  });
}
