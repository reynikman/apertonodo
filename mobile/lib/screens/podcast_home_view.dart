import 'dart:async';

import 'package:flutter/material.dart';

import '../podcast_client.dart';
import '../podcast_library.dart';

const Duration podcastSearchDelay = Duration(milliseconds: 400);

class PodcastHomeTexts {
  const PodcastHomeTexts({
    required this.searchHint,
    required this.clearSearch,
    required this.subscriptionsEmpty,
    required this.subscriptionsFailed,
    required this.refreshFailed,
    required this.searchEmpty,
    required this.searchFailed,
    required this.searchUnavailable,
    required this.offline,
    required this.signedOut,
    required this.retry,
    required this.subscribe,
    required this.unsubscribe,
    required this.untitled,
    required this.limit,
    required this.badUrl,
    required this.actionFailed,
    required this.episodeCount,
  });

  final String searchHint;
  final String clearSearch;
  final String subscriptionsEmpty;
  final String subscriptionsFailed;
  final String refreshFailed;
  final String searchEmpty;
  final String searchFailed;
  final String searchUnavailable;
  final String offline;
  final String signedOut;
  final String retry;
  final String subscribe;
  final String unsubscribe;
  final String untitled;
  final String limit;
  final String badUrl;
  final String actionFailed;
  final String Function(int count) episodeCount;
}

class PodcastHomeView extends StatefulWidget {
  const PodcastHomeView({
    super.key,
    required this.library,
    required this.texts,
    required this.onOpenFeed,
  });

  final PodcastLibrary library;
  final PodcastHomeTexts texts;
  final void Function(String feedUrl, String title) onOpenFeed;

  @override
  State<PodcastHomeView> createState() => _PodcastHomeViewState();
}

class _PodcastHomeViewState extends State<PodcastHomeView> {
  late final TextEditingController _controller;
  Timer? _debounceTimer;
  PodcastFailure? _actionFailure;

  bool _loadScheduled = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.library.query);
    widget.library.addListener(_onLibraryChanged);
    _scheduleLoad();
  }

  /// Query subscriptions after frame: model notifies listeners immediately, while screen is created
  /// mid-frame — adjacent screen listening to the same model cannot be rebuilt at this moment.
  void _scheduleLoad() {
    if (_loadScheduled) return;
    _loadScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadScheduled = false;
      if (!mounted) return;
      if (widget.library.subscriptionsState == PodcastLoad.idle) {
        widget.library.loadSubscriptions();
      }
    });
  }

  @override
  void didUpdateWidget(PodcastHomeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.library != oldWidget.library) {
      oldWidget.library.removeListener(_onLibraryChanged);
      _debounceTimer?.cancel();
      _debounceTimer = null;
      _actionFailure = null;
      _controller.text = widget.library.query;
      widget.library.addListener(_onLibraryChanged);
      _scheduleLoad();
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    widget.library.removeListener(_onLibraryChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onLibraryChanged() {
    if (!mounted) return;
    if (widget.library.query.isEmpty &&
        widget.library.subscriptionsState == PodcastLoad.idle &&
        widget.library.searchState == PodcastLoad.idle) {
      if (_controller.text.isNotEmpty) {
        _controller.text = '';
      }
      _debounceTimer?.cancel();
      _debounceTimer = null;
      _actionFailure = null;
    }
    setState(() {});
  }

  void _onQueryChanged(String value) {
    _actionFailure = null;
    final trimmed = value.trim();
    if (trimmed.runes.length < podcastSearchMinChars) {
      _debounceTimer?.cancel();
      _debounceTimer = null;
      widget.library.search(value);
      setState(() {});
      return;
    }

    _debounceTimer?.cancel();
    _debounceTimer = Timer(podcastSearchDelay, () {
      _debounceTimer = null;
      widget.library.search(value);
    });
    setState(() {});
  }

  void _onSubmitted(String value) {
    final trimmed = value.trim();
    if (trimmed.runes.length >= podcastSearchMinChars) {
      _debounceTimer?.cancel();
      _debounceTimer = null;
      widget.library.search(value);
      setState(() {});
    }
  }

  void _onClear() {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _controller.clear();
    _actionFailure = null;
    widget.library.search('');
    setState(() {});
  }

  Future<void> _toggleSubscription(String feedUrl, bool isSubscribed) async {
    setState(() {
      _actionFailure = null;
    });
    final library = widget.library;
    final failure = isSubscribed
        ? await library.unsubscribe(feedUrl)
        : await library.subscribe(feedUrl);
    // Screen was given another model in the meantime — do not show failure over new results.
    if (!mounted || !identical(library, widget.library)) return;
    if (failure != null) {
      setState(() {
        _actionFailure = failure;
      });
    }
  }

  String _failureText(
    PodcastFailure? failure, {
    bool subscriptions = false,
    bool refresh = false,
    bool search = false,
    bool action = false,
  }) {
    return switch (failure) {
      PodcastFailure.offline => widget.texts.offline,
      PodcastFailure.signedOut => widget.texts.signedOut,
      PodcastFailure.searchUnavailable => widget.texts.searchUnavailable,
      PodcastFailure.limit => widget.texts.limit,
      PodcastFailure.badUrl => widget.texts.badUrl,
      _ =>
        refresh
            ? widget.texts.refreshFailed
            : search
            ? widget.texts.searchFailed
            : action
            ? widget.texts.actionFailed
            : widget.texts.subscriptionsFailed,
    };
  }

  bool get _isLoadingSearch {
    final trimmed = _controller.text.trim();
    if (trimmed.runes.length < podcastSearchMinChars) return false;
    if (_debounceTimer != null && _debounceTimer!.isActive) return true;
    if (widget.library.searchState == PodcastLoad.loading) return true;
    if (trimmed != widget.library.query) return true;
    return false;
  }

  Widget _buildSearchBar() {
    return TextField(
      key: const Key('podcast-search-field'),
      controller: _controller,
      autocorrect: false,
      enableSuggestions: false,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: widget.texts.searchHint,
        suffixIcon: _controller.text.isNotEmpty
            ? IconButton(
                key: const Key('podcast-search-clear'),
                tooltip: widget.texts.clearSearch,
                icon: const Icon(Icons.clear),
                onPressed: _onClear,
              )
            : null,
      ),
      onChanged: _onQueryChanged,
      onSubmitted: _onSubmitted,
    );
  }

  Widget _buildSearchResults() {
    if (_isLoadingSearch) {
      return const Center(
        child: CircularProgressIndicator(key: Key('podcast-search-loading')),
      );
    }

    if (widget.library.searchState == PodcastLoad.failed) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              key: const Key('podcast-message'),
              liveRegion: true,
              child: Text(
                _failureText(widget.library.searchFailure, search: true),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              key: const Key('podcast-retry'),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
              onPressed: () => widget.library.search(_controller.text),
              child: Text(widget.texts.retry),
            ),
          ],
        ),
      );
    }

    if (widget.library.searchState == PodcastLoad.empty) {
      return Center(
        child: Semantics(
          key: const Key('podcast-message'),
          liveRegion: true,
          child: Text(widget.texts.searchEmpty),
        ),
      );
    }

    if (widget.library.searchState == PodcastLoad.ready) {
      return Column(
        children: [
          if (_actionFailure != null)
            Semantics(
              key: const Key('podcast-action-message'),
              liveRegion: true,
              child: Text(_failureText(_actionFailure, action: true)),
            ),
          Expanded(
            child: ListView.builder(
              // Each search query has its own scroll position: fresh results open at top.
              key: PageStorageKey('podcast-found ${widget.library.query}'),
              itemCount: widget.library.found.length,
              itemBuilder: (context, index) {
                final item = widget.library.found[index];
                final isSubscribed = widget.library.isSubscribed(item.feedUrl);
                final isBusy = widget.library.isBusy(item.feedUrl);
                final title = item.title.isNotEmpty
                    ? item.title
                    : widget.texts.untitled;
                return ListTile(
                  key: Key('podcast-found-$index'),
                  title: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: item.author.isNotEmpty
                      ? Text(
                          item.author,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        )
                      : null,
                  trailing: IconButton(
                    key: Key('podcast-found-toggle-$index'),
                    tooltip: isSubscribed
                        ? widget.texts.unsubscribe
                        : widget.texts.subscribe,
                    isSelected: isSubscribed,
                    icon: const Icon(Icons.add),
                    selectedIcon: const Icon(Icons.check),
                    onPressed: isBusy
                        ? null
                        : () => _toggleSubscription(item.feedUrl, isSubscribed),
                  ),
                  onTap: isSubscribed
                      ? () => widget.onOpenFeed(item.feedUrl, title)
                      : null,
                );
              },
            ),
          ),
        ],
      );
    }

    return const SizedBox.shrink();
  }

  Widget _buildSubscriptions() {
    if (widget.library.subscriptions.isEmpty) {
      if (widget.library.subscriptionsState == PodcastLoad.idle ||
          widget.library.subscriptionsState == PodcastLoad.loading) {
        return const Center(
          child: CircularProgressIndicator(key: Key('podcast-loading')),
        );
      }

      if (widget.library.subscriptionsState == PodcastLoad.empty) {
        return Center(
          child: Semantics(
            key: const Key('podcast-message'),
            liveRegion: true,
            child: Text(widget.texts.subscriptionsEmpty),
          ),
        );
      }

      if (widget.library.subscriptionsState == PodcastLoad.failed) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                key: const Key('podcast-message'),
                liveRegion: true,
                child: Text(
                  _failureText(
                    widget.library.subscriptionsFailure,
                    subscriptions: true,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                key: const Key('podcast-retry'),
                style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: () => widget.library.loadSubscriptions(),
                child: Text(widget.texts.retry),
              ),
            ],
          ),
        );
      }

      return const SizedBox.shrink();
    }

    return Column(
      children: [
        if (widget.library.subscriptionsState == PodcastLoad.loading)
          const LinearProgressIndicator(key: Key('podcast-refreshing')),
        if (widget.library.subscriptionsState == PodcastLoad.failed)
          Semantics(
            key: const Key('podcast-message'),
            liveRegion: true,
            child: Text(
              _failureText(widget.library.subscriptionsFailure, refresh: true),
            ),
          ),
        Expanded(
          child: ListView.builder(
            key: const PageStorageKey('podcast-subs'),
            itemCount: widget.library.subscriptions.length,
            itemBuilder: (context, index) {
              final sub = widget.library.subscriptions[index];
              final title = (sub.title != null && sub.title!.isNotEmpty)
                  ? sub.title!
                  : widget.texts.untitled;
              final countText = widget.texts.episodeCount(sub.episodes);
              final subtitleText = sub.author.isNotEmpty
                  ? '${sub.author} · $countText'
                  : countText;
              return ListTile(
                key: Key('podcast-sub-$index'),
                title: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  subtitleText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => widget.onOpenFeed(sub.feedUrl, title),
              );
            },
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final trimmed = _controller.text.trim();
    // Character threshold is determined by model: rejection ("too short") shows subscriptions, not empty screen.
    final refused =
        _debounceTimer == null &&
        widget.library.query == trimmed &&
        widget.library.searchState == PodcastLoad.idle;
    final isSearching =
        trimmed.runes.length >= podcastSearchMinChars && !refused;

    return Column(
      children: [
        _buildSearchBar(),
        Expanded(
          child: isSearching ? _buildSearchResults() : _buildSubscriptions(),
        ),
      ],
    );
  }
}
