// FT-717: "Podcasts" screen — FT-714 page assembly from server clients.
import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../feed_order.dart';
import '../listening_languages.dart';
import '../podcast_catalog_client.dart';
import '../podcast_client.dart';
import '../podcast_downloads.dart';
import 'languages_sheet.dart';
import 'parts.dart';
import 'podcast_category_page.dart';
import 'podcast_screen.dart';
import 'podcasts_page.dart';

/// Apple catalog country for listening language (FT-723): Apple provides
/// "Popular" and categories by country, not language. Without country server uses `us`.
const Map<String, String> podcastCountryByLanguage = {
  'ru': 'ru',
  'en': 'us',
  'uk': 'ua',
  'de': 'de',
  'fr': 'fr',
  'es': 'es',
  'it': 'it',
  'pl': 'pl',
  'pt': 'br',
  'tr': 'tr',
  'be': 'by',
  'zh': 'cn',
  'ja': 'jp',
  'ko': 'kr',
};

/// First selected language with matching country; "all languages" — device language.
String? podcastCountry(List<String>? chosen, String phoneLanguage) {
  for (final code in chosen ?? [phoneLanguage]) {
    final country = podcastCountryByLanguage[code];
    if (country != null) return country;
  }
  return null;
}

/// Where screen fetches podcasts from. Distinct port allows mocking in tests.
abstract class PodcastsSource {
  Future<List<PodcastSubscription>> subscriptions();
  Future<List<FoundPodcast>> search(String query);
  Future<bool> subscribe(String feedUrl);
  Future<List<FoundPodcast>> top({int? category, String? country});
  Future<List<PodcastCategory>> categories();

  /// New episodes of subscriptions (FT-752).
  Future<List<NewPodcastEpisode>> newEpisodes();

  /// In-progress episodes (FT-756).
  Future<List<ContinuePodcastEpisode>> continueEpisodes();

  /// Feed episodes; [order] specifies which end to take first 200 from (FT-732).
  Future<List<PodcastEpisode>> episodes(
    String feedUrl, {
    FeedOrder order = FeedOrder.newestFirst,
  });
}

/// Production source: FT-702/FT-703 clients on top of `ServerApi.podcastSend`.
class ServerPodcastsSource implements PodcastsSource {
  ServerPodcastsSource(this._client, this._catalog);

  final PodcastClient _client;
  final PodcastCatalogClient _catalog;

  @override
  Future<List<PodcastSubscription>> subscriptions() => _client.subscriptions();

  @override
  Future<List<FoundPodcast>> search(String query) => _client.search(query);

  @override
  Future<bool> subscribe(String feedUrl) async {
    await _client.subscribe(feedUrl);
    return true;
  }

  @override
  Future<List<FoundPodcast>> top({int? category, String? country}) =>
      _catalog.top(category: category, country: country);

  @override
  Future<List<PodcastCategory>> categories() => _catalog.categories();

  @override
  Future<List<NewPodcastEpisode>> newEpisodes() => _client.newEpisodes();

  @override
  Future<List<ContinuePodcastEpisode>> continueEpisodes() =>
      _client.continueEpisodes();

  @override
  Future<List<PodcastEpisode>> episodes(
    String feedUrl, {
    FeedOrder order = FeedOrder.newestFirst,
  }) async {
    // Catalog podcast can be opened before subscribing, and crawler may not have
    // fetched freshly subscribed feed yet — in that case server previews feed directly (FT-723).
    final List<PodcastEpisode> stored;
    try {
      stored = await _client.episodes(
        feedUrl,
        limit: 200,
        oldestFirst: order == FeedOrder.oldestFirst,
      );
    } on PodcastException catch (e) {
      if (e.reason != PodcastFailure.notSubscribed) rethrow;
      return _client.preview(feedUrl);
    }
    if (stored.isNotEmpty) return stored;
    // Subscribed feed may genuinely be empty: unreachable feed website
    // does not turn empty page into error.
    try {
      return await _client.preview(feedUrl);
    } on PodcastException {
      return stored;
    }
  }
}

class PodcastsScreen extends StatefulWidget {
  const PodcastsScreen({
    super.key,
    required this.source,
    required this.languages,
    required this.orders,
    required this.onPlay,
    this.downloads,
    this.art,
  });

  final PodcastsSource source;
  final ListeningLanguages languages;
  final FeedOrderStore orders;
  final void Function(FoundPodcast podcast, PodcastEpisode episode) onPlay;
  final PodcastDownloads? downloads;

  /// Podcast and episode pictures through our server (FT-860).
  final Widget Function(String? image, String title, double size)? art;

  @override
  State<PodcastsScreen> createState() => _PodcastsScreenState();
}

class _PodcastsScreenState extends State<PodcastsScreen> {
  bool _loading = true;
  bool _failed = false;
  List<FoundPodcast> _subscriptions = const [];
  List<FoundPodcast> _popular = const [];
  List<PodcastCategory> _categories = const [];
  List<NewPodcastEpisode> _fresh = const [];
  List<ContinuePodcastEpisode> _resume = const [];

  /// Subscriptions in observable value: opened section sits below podcast page
  /// in stack and without notifier would not detect subscription made there.
  final _subscribedNow = ValueNotifier<Set<String>>(const {});
  Set<String> get _subscribed => _subscribedNow.value;
  set _subscribed(Set<String> value) => _subscribedNow.value = value;

  /// Catalog country for "Popular" and categories — based on listening languages.
  String? get _country => podcastCountry(
    widget.languages.chosen(LanguageScope.podcasts),
    PlatformDispatcher.instance.locale.languageCode,
  );
  String? _loadedCountry;
  int _generation = 0;

  @override
  void dispose() {
    widget.languages.removeListener(_languagesChanged);
    _subscribedNow.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    widget.languages.addListener(_languagesChanged);
    unawaited(_reload());
  }

  void _languagesChanged() {
    if (mounted && _country != _loadedCountry) unawaited(_reload());
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    final generation = ++_generation;
    final country = _loadedCountry = _country;
    // Each shelf loads independently: failing "Popular" does not hide subscriptions.
    final results = await Future.wait<Object?>([
      _quiet(widget.source.subscriptions),
      _quiet(() => widget.source.top(country: country)),
      _quiet(widget.source.categories),
      _quiet(widget.source.newEpisodes),
      _quiet(widget.source.continueEpisodes),
    ]);
    // Stale response from previous country does not overwrite new one (language change in flight).
    if (!mounted || generation != _generation) return;
    final subs = results[0] as List<PodcastSubscription>?;
    final popular = results[1] as List<FoundPodcast>?;
    final categories = results[2] as List<PodcastCategory>?;
    final fresh = results[3] as List<NewPodcastEpisode>?;
    final resume = results[4] as List<ContinuePodcastEpisode>?;
    setState(() {
      _loading = false;
      _failed =
          subs == null &&
          popular == null &&
          categories == null &&
          fresh == null &&
          resume == null;
      if (subs != null) {
        _subscriptions = [for (final sub in subs) _found(sub)];
        _subscribed = {for (final sub in subs) sub.feedUrl};
      }
      _popular = popular ?? const [];
      _categories = categories ?? const [];
      _fresh = fresh ?? const [];
      _resume = resume ?? const [];
    });
  }

  /// On subscription — add new feed episodes to shelf; if failed — keep shelf as is.
  Future<void> _reloadFresh() async {
    final generation = _generation;
    final fresh = await _quiet(widget.source.newEpisodes);
    if (!mounted || fresh == null || generation != _generation) return;
    setState(() => _fresh = fresh);
  }

  static String _freshId(NewPodcastEpisode item) =>
      '${item.feedUrl}\n${item.episode.guid}';

  static String _continueId(ContinuePodcastEpisode item) =>
      '${item.feedUrl}\n${item.episode.guid}';

  void _openItem(PodcastShelfItem shelf) {
    for (final item in _resume) {
      if (_continueId(item) == shelf.id) {
        widget.onPlay(
          FoundPodcast(feedUrl: item.feedUrl, title: item.feedTitle),
          item.episode,
        );
        return;
      }
    }
    for (final item in _fresh) {
      if (_freshId(item) == shelf.id) {
        widget.onPlay(
          FoundPodcast(feedUrl: item.feedUrl, title: item.feedTitle),
          item.episode,
        );
        return;
      }
    }
  }

  static Future<T?> _quiet<T>(Future<T> Function() load) async {
    try {
      return await load();
    } catch (_) {
      return null;
    }
  }

  static FoundPodcast _found(PodcastSubscription sub) => FoundPodcast(
    feedUrl: sub.feedUrl,
    title: sub.title ?? '',
    author: sub.author,
    image: sub.image,
    episodes: sub.episodes,
  );

  Future<bool> _subscribe(FoundPodcast podcast) async {
    try {
      final ok = await widget.source.subscribe(podcast.feedUrl);
      if (!ok || !mounted) return ok;
      // New set instance rather than in-place mutation: pages compare sets.
      setState(() {
        _subscribed = {..._subscribed, podcast.feedUrl};
        if (!_subscriptions.any((p) => p.feedUrl == podcast.feedUrl)) {
          _subscriptions = [podcast, ..._subscriptions];
        }
      });
      unawaited(_reloadFresh());
      return true;
    } catch (_) {
      return false;
    }
  }

  void _openPodcast(FoundPodcast podcast) {
    open(
      context,
      PodcastScreen(
        source: widget.source,
        podcast: podcast,
        subscribed: _subscribed.contains(podcast.feedUrl),
        onSubscribe: () => _subscribe(podcast),
        orders: widget.orders,
        onPlay: widget.onPlay,
        downloads: widget.downloads,
        art: widget.art,
      ),
    );
  }

  void _openCategory(PodcastCategory category) {
    final text = l10n(context);
    final code = Localizations.localeOf(context).languageCode;
    open(
      context,
      // Section page renders its own header and "Back" button.
      ValueListenableBuilder<Set<String>>(
        valueListenable: _subscribedNow,
        builder: (context, subscribed, _) => PodcastCategoryPage(
          title: category.title(code),
          load: () =>
              widget.source.top(category: category.id, country: _country),
          subscribed: subscribed,
          onSubscribe: _subscribe,
          onOpen: _openPodcast,
          texts: PodcastCategoryTexts(
            loadFailed: text.podcastsLoadFailed,
            retry: text.podcastsRetry,
            empty: text.podcastsEmpty,
            subscribe: text.podcastsSubscribe,
            subscribed: text.podcastsSubscribed,
            subscribeFailed: text.podcastsSubscribeFailed,
          ),
          art: widget.art,
        ),
      ),
    );
  }

  void _openLanguages() {
    final text = l10n(context);
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        useRootNavigator: true,
        builder: (_) => LanguagesSheet(
          languages: widget.languages,
          scope: LanguageScope.podcasts,
          texts: LanguagesTexts(
            title: text.podcastsLanguages,
            all: text.podcastsAllLanguages,
            name: text.languageName,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = l10n(context);
    final code = Localizations.localeOf(context).languageCode;
    final Widget body;
    if (_loading && _subscriptions.isEmpty && _popular.isEmpty) {
      body = const Center(
        key: Key('podcasts-loading'),
        child: CircularProgressIndicator(),
      );
    } else if (_failed) {
      body = Message(text.podcastsLoadFailed, onRetry: _reload);
    } else {
      body = PodcastsPage(
        texts: PodcastsPageTexts(
          searchHint: text.podcastsSearchHint,
          languages: text.podcastsLanguages,
          continueTitle: text.podcastsContinue,
          newEpisodes: text.podcastsNewEpisodes,
          subscriptions: text.podcastsSubscriptions,
          popular: text.podcastsPopular,
          categories: text.podcastsCategories,
          subscribe: text.podcastsSubscribe,
          subscribed: text.podcastsSubscribed,
          subscribeFailed: text.podcastsSubscribeFailed,
          searchFailed: text.podcastsSearchFailed,
          nothingFound: text.podcastsNothingFound,
          searchAllLanguages: text.podcastsSearchAllLanguages,
          categoryTitle: (category) => category.title(code),
        ),
        // Podcast language not provided by server yet — search always queries all languages.
        search: (query, {required allLanguages}) => widget.source.search(query),
        subscribed: _subscribed,
        onSubscribe: _subscribe,
        onOpenPodcast: _openPodcast,
        onOpenCategory: _openCategory,
        onOpenItem: _openItem,
        onLanguages: _openLanguages,
        languagesFiltered: false,
        subscriptions: _subscriptions,
        popular: _popular,
        categories: _categories,
        art: widget.art,
        continueItems: [
          for (final item in _resume)
            PodcastShelfItem(
              id: _continueId(item),
              title: item.episode.title,
              subtitle: item.feedTitle,
              image: item.episode.image,
              progress: switch (item.episode.durationMs) {
                final total? when total > 0 => item.positionMs / total,
                _ => null,
              },
            ),
        ],
        newEpisodes: [
          for (final item in _fresh)
            PodcastShelfItem(
              id: _freshId(item),
              title: item.episode.title,
              subtitle: item.feedTitle,
              image: item.episode.image,
            ),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(text.podcastsTitle)),
      body: body,
    );
  }
}
