// FT-714: "Podcasts" page (Pk-2).
import 'dart:async';

import 'package:flutter/material.dart';

import '../podcast_catalog_client.dart';
import '../podcast_client.dart';
import '../theme.dart';

class PodcastShelfItem {
  final String id;
  final String title;
  final String subtitle;
  final String? image;

  /// Listened share of the episode, 0..1; a bar under the tile when set.
  final double? progress;

  const PodcastShelfItem({
    required this.id,
    required this.title,
    required this.subtitle,
    this.image,
    this.progress,
  });
}

class PodcastsPageTexts {
  final String searchHint;
  final String languages;
  final String continueTitle;
  final String newEpisodes;
  final String subscriptions;
  final String popular;
  final String categories;
  final String subscribe;
  final String subscribed;
  final String subscribeFailed;
  final String searchFailed;
  final String nothingFound;
  final String searchAllLanguages;
  final String Function(PodcastCategory) categoryTitle;

  const PodcastsPageTexts({
    required this.searchHint,
    required this.languages,
    required this.continueTitle,
    required this.newEpisodes,
    required this.subscriptions,
    required this.popular,
    required this.categories,
    required this.subscribe,
    required this.subscribed,
    required this.subscribeFailed,
    required this.searchFailed,
    required this.nothingFound,
    required this.searchAllLanguages,
    required this.categoryTitle,
  });
}

class PodcastsPage extends StatefulWidget {
  final PodcastsPageTexts texts;
  final Future<List<FoundPodcast>> Function(
    String query, {
    required bool allLanguages,
  })
  search;
  final Set<String> subscribed;
  final Future<bool> Function(FoundPodcast podcast) onSubscribe;
  final void Function(FoundPodcast podcast) onOpenPodcast;
  final void Function(PodcastCategory category) onOpenCategory;
  final void Function(PodcastShelfItem item) onOpenItem;
  final VoidCallback onLanguages;
  final bool languagesFiltered;
  final List<PodcastShelfItem> continueItems;
  final List<PodcastShelfItem> newEpisodes;
  final List<FoundPodcast> subscriptions;
  final List<FoundPodcast> popular;
  final List<PodcastCategory> categories;

  /// Picture of a podcast or an episode (FT-860); without it rows are text only.
  final Widget Function(String? image, String title, double size)? art;

  const PodcastsPage({
    super.key,
    required this.texts,
    required this.search,
    required this.subscribed,
    required this.onSubscribe,
    required this.onOpenPodcast,
    required this.onOpenCategory,
    required this.onOpenItem,
    required this.onLanguages,
    required this.languagesFiltered,
    this.continueItems = const [],
    this.newEpisodes = const [],
    this.subscriptions = const [],
    this.popular = const [],
    this.categories = const [],
    this.art,
  });

  @override
  State<PodcastsPage> createState() => _PodcastsPageState();
}

class _PodcastsPageState extends State<PodcastsPage> {
  final TextEditingController _searchController = TextEditingController();

  final Set<String> _localSubscribed = {};
  final Set<String> _subscribingFeeds = {};

  int _searchRequestId = 0;
  bool _hasSearched = false;
  bool _isSearching = false;
  String _currentQuery = '';
  bool _allLanguages = false;
  List<FoundPodcast>? _searchResults;
  String? _searchError;
  String? _subscribeError;

  static bool _setsEqual(Set<String> a, Set<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    return a.containsAll(b);
  }

  @override
  void didUpdateWidget(PodcastsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_setsEqual(widget.subscribed, oldWidget.subscribed)) {
      _localSubscribed.clear();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool _isSubscribed(String feedUrl) {
    return widget.subscribed.contains(feedUrl) ||
        _localSubscribed.contains(feedUrl);
  }

  void _onSearchChanged(String value) {
    if (value.isEmpty) {
      _searchRequestId++;
      setState(() {
        _hasSearched = false;
        _isSearching = false;
        _currentQuery = '';
        _allLanguages = false;
        _searchResults = null;
        _searchError = null;
        _subscribeError = null;
      });
    }
  }

  void _onSubmitSearch(String text) {
    final query = text.trim();
    if (query.isEmpty) return;
    _performSearch(query, allLanguages: false);
  }

  Future<void> _performSearch(
    String query, {
    required bool allLanguages,
  }) async {
    final requestId = ++_searchRequestId;
    setState(() {
      _hasSearched = true;
      _isSearching = true;
      _currentQuery = query;
      _allLanguages = allLanguages;
      _searchError = null;
      _subscribeError = null;
    });

    try {
      final results = await widget.search(query, allLanguages: allLanguages);
      if (!mounted || requestId != _searchRequestId) return;
      setState(() {
        _isSearching = false;
        _searchResults = results;
        _searchError = null;
      });
    } catch (_) {
      if (!mounted || requestId != _searchRequestId) return;
      setState(() {
        _isSearching = false;
        _searchResults = null;
        _searchError = widget.texts.searchFailed;
      });
    }
  }

  Future<void> _subscribe(FoundPodcast podcast) async {
    if (_isSubscribed(podcast.feedUrl) ||
        _subscribingFeeds.contains(podcast.feedUrl)) {
      return;
    }

    setState(() {
      _subscribingFeeds.add(podcast.feedUrl);
      _subscribeError = null;
    });

    try {
      final success = await widget.onSubscribe(podcast);
      if (!mounted) return;
      setState(() {
        _subscribingFeeds.remove(podcast.feedUrl);
        if (success) {
          _localSubscribed.add(podcast.feedUrl);
          _subscribeError = null;
        } else {
          _subscribeError = widget.texts.subscribeFailed;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _subscribingFeeds.remove(podcast.feedUrl);
        _subscribeError = widget.texts.subscribeFailed;
      });
    }
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: TextField(
        key: const ValueKey('podcasts-search'),
        controller: _searchController,
        autocorrect: false,
        enableSuggestions: false,
        textInputAction: TextInputAction.search,
        style: const TextStyle(color: ApertonoColors.textPrimary),
        decoration: InputDecoration(
          hintText: widget.texts.searchHint,
          hintStyle: const TextStyle(color: ApertonoColors.textSecondary),
          prefixIcon: const Icon(
            Icons.search,
            color: ApertonoColors.textSecondary,
          ),
          filled: true,
          fillColor: ApertonoColors.surface,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 12,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(ApertonoRadii.large),
            borderSide: const BorderSide(color: ApertonoColors.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(ApertonoRadii.large),
            borderSide: const BorderSide(color: ApertonoColors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(ApertonoRadii.large),
            borderSide: const BorderSide(color: ApertonoColors.borderStrong),
          ),
        ),
        onChanged: _onSearchChanged,
        onSubmitted: _onSubmitSearch,
      ),
    );
  }

  Widget _buildSubscribeError() {
    return Semantics(
      key: const ValueKey('podcasts-error'),
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Text(
          _subscribeError!,
          style: ApertonoText.trackArtist.copyWith(
            color: ApertonoColors.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _buildLanguagesRow() {
    return InkWell(
      key: const ValueKey('podcasts-languages'),
      onTap: widget.onLanguages,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.texts.languages,
                  style: ApertonoText.trackArtist.copyWith(
                    color: ApertonoColors.textSecondary,
                    fontSize: 14,
                  ),
                ),
              ),
              const Icon(
                Icons.chevron_right,
                color: ApertonoColors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Semantics(
        header: true,
        child: Text(
          title,
          style: ApertonoText.sectionTitle.copyWith(
            color: ApertonoColors.textPrimary,
          ),
        ),
      ),
    );
  }

  static const _artSize = 56.0;

  Widget _withArt(String? image, String title, Widget info) {
    final art = widget.art;
    if (art == null) return info;
    return Row(
      children: [
        art(image, title, _artSize),
        const SizedBox(width: 12),
        Flexible(child: info),
      ],
    );
  }

  static const _tileSize = 148.0;

  /// Horizontal shelf of tiles (Astra: «Продолжить», «Новые выпуски»).
  /// A row of tiles, not a fixed-height list, so large fonts still fit.
  Widget _buildShelf(String title, List<Widget> tiles) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSectionHeader(title),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < tiles.length; i++) ...[
                if (i > 0) const SizedBox(width: 12),
                tiles[i],
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _tileArt(String? image, String title, double size) {
    final art = widget.art;
    if (art != null) return art(image, title, size);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: ApertonoColors.surface,
        borderRadius: BorderRadius.circular(ApertonoRadii.large),
      ),
      child: const Icon(Icons.podcasts, color: ApertonoColors.textSecondary),
    );
  }

  Widget _buildTile({
    required Key key,
    required String? image,
    required String artTitle,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    double? progress,
    double size = _tileSize,
  }) {
    // TalkBack: tile is one button (FT-759); title and subtitle read together.
    return Semantics(
      button: true,
      child: InkWell(
        key: key,
        onTap: onTap,
        borderRadius: BorderRadius.circular(ApertonoRadii.large),
        child: SizedBox(
          width: size,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _tileArt(image, artTitle, size),
              const SizedBox(height: 8),
              Text(
                title,
                style: ApertonoText.trackTitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (subtitle.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: ApertonoText.trackArtist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (progress != null && progress > 0) ...[
                const SizedBox(height: 6),
                LinearProgressIndicator(
                  value: progress.clamp(0.0, 1.0),
                  minHeight: 3,
                  borderRadius: BorderRadius.circular(ApertonoRadii.hairline),
                  color: ApertonoColors.accent,
                  backgroundColor: ApertonoColors.border,
                ),
              ],
              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildShelfTile(String keyPrefix, PodcastShelfItem item) {
    return _buildTile(
      key: ValueKey('$keyPrefix-${item.id}'),
      image: item.image,
      artTitle: item.subtitle,
      title: item.title,
      subtitle: item.subtitle,
      progress: item.progress,
      onTap: () => widget.onOpenItem(item),
    );
  }

  Widget _buildSubscriptionTile(FoundPodcast item) {
    return _buildTile(
      key: ValueKey('sub-${item.feedUrl}'),
      image: item.image,
      artTitle: item.title,
      title: item.title,
      subtitle: item.author,
      onTap: () => widget.onOpenPodcast(item),
      // Podcasts themselves are smaller than episodes (Astra «Популярное сейчас»).
      size: 112,
    );
  }

  Widget _buildPopularRow(FoundPodcast item) {
    return InkWell(
      key: ValueKey('popular-${item.feedUrl}'),
      onTap: () => widget.onOpenPodcast(item),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isLargeFont =
                  MediaQuery.textScalerOf(context).scale(1) > 1.3;
              final info = _withArt(
                item.image,
                item.title,
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      item.title,
                      style: ApertonoText.trackTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (item.author.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        item.author,
                        style: ApertonoText.trackArtist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              );
              if (isLargeFont) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    info,
                    const SizedBox(height: 8),
                    _buildSubscribeButton('popular', item),
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: info),
                  const SizedBox(width: 8),
                  _buildSubscribeButton('popular', item),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildCategories() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final category in widget.categories)
            OutlinedButton(
              key: ValueKey('category-${category.id}'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(48, 48),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                side: const BorderSide(color: ApertonoColors.borderStrong),
                foregroundColor: ApertonoColors.textPrimary,
                shape: const StadiumBorder(),
              ),
              onPressed: () => widget.onOpenCategory(category),
              child: Text(widget.texts.categoryTitle(category)),
            ),
        ],
      ),
    );
  }

  Widget _buildSearchResultRow(FoundPodcast item) {
    return InkWell(
      key: ValueKey('result-${item.feedUrl}'),
      onTap: () => widget.onOpenPodcast(item),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isLargeFont =
                  MediaQuery.textScalerOf(context).scale(1) > 1.3;
              final info = _withArt(
                item.image,
                item.title,
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      item.title,
                      style: ApertonoText.trackTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (item.author.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        item.author,
                        style: ApertonoText.trackArtist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              );
              if (isLargeFont) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    info,
                    const SizedBox(height: 8),
                    _buildSubscribeButton('result', item),
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: info),
                  const SizedBox(width: 8),
                  _buildSubscribeButton('result', item),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildSubscribeButton(String prefix, FoundPodcast item) {
    final isSubscribed = _isSubscribed(item.feedUrl);
    final isBusy = _subscribingFeeds.contains(item.feedUrl);
    final actionText = isSubscribed
        ? widget.texts.subscribed
        : widget.texts.subscribe;
    final semanticsLabel = item.title.isNotEmpty
        ? '$actionText: ${item.title}'
        : actionText;
    return OutlinedButton(
      key: ValueKey('$prefix-subscribe-${item.feedUrl}'),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        side: const BorderSide(color: ApertonoColors.borderStrong),
        foregroundColor: isSubscribed
            ? ApertonoColors.textSecondary
            : ApertonoColors.textPrimary,
      ),
      onPressed: isSubscribed || isBusy ? null : () => _subscribe(item),
      child: Text(actionText, semanticsLabel: semanticsLabel, maxLines: 1),
    );
  }

  Widget _buildMainContent() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildLanguagesRow(),
          if (widget.continueItems.isNotEmpty)
            _buildShelf(widget.texts.continueTitle, [
              for (final item in widget.continueItems)
                _buildShelfTile('continue', item),
            ]),
          if (widget.newEpisodes.isNotEmpty)
            _buildShelf(widget.texts.newEpisodes, [
              for (final item in widget.newEpisodes)
                _buildShelfTile('new', item),
            ]),
          if (widget.subscriptions.isNotEmpty)
            _buildShelf(widget.texts.subscriptions, [
              for (final item in widget.subscriptions)
                _buildSubscriptionTile(item),
            ]),
          if (widget.popular.isNotEmpty) ...[
            _buildSectionHeader(widget.texts.popular),
            for (final item in widget.popular) _buildPopularRow(item),
          ],
          if (widget.categories.isNotEmpty) ...[
            _buildSectionHeader(widget.texts.categories),
            _buildCategories(),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildSearchResults() {
    if (_isSearching) {
      return const Center(
        child: CircularProgressIndicator(key: ValueKey('podcasts-searching')),
      );
    }

    if (_searchError != null) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Semantics(
            key: const ValueKey('podcasts-error'),
            liveRegion: true,
            child: Text(
              _searchError!,
              style: ApertonoText.trackArtist.copyWith(
                color: ApertonoColors.textSecondary,
                fontSize: 16,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    if (_searchResults != null) {
      if (_searchResults!.isEmpty) {
        final showAllLanguages = widget.languagesFiltered && !_allLanguages;
        return Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Semantics(
                  key: const ValueKey('podcasts-nothing'),
                  liveRegion: true,
                  child: Text(
                    widget.texts.nothingFound,
                    style: ApertonoText.trackArtist.copyWith(fontSize: 16),
                    textAlign: TextAlign.center,
                  ),
                ),
                if (showAllLanguages) ...[
                  const SizedBox(height: 16),
                  FilledButton(
                    key: const ValueKey('podcasts-all-languages'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(48, 48),
                    ),
                    onPressed: () =>
                        _performSearch(_currentQuery, allLanguages: true),
                    child: Text(widget.texts.searchAllLanguages),
                  ),
                ],
              ],
            ),
          ),
        );
      }

      return ListView(
        children: [
          for (final item in _searchResults!) _buildSearchResultRow(item),
        ],
      );
    }

    return const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ApertonoColors.background,
      body: SafeArea(
        child: Column(
          children: [
            _buildSearchBar(),
            if (_subscribeError != null) _buildSubscribeError(),
            Expanded(
              child: _hasSearched ? _buildSearchResults() : _buildMainContent(),
            ),
          ],
        ),
      ),
    );
  }
}
