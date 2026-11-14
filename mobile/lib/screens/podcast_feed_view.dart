import 'package:flutter/material.dart';

import '../podcast_client.dart';
import '../podcast_library.dart';

const int podcastFeedAhead = 10;

class PodcastFeedTexts {
  final String empty;
  final String failed;
  final String notSubscribed;
  final String offline;
  final String signedOut;
  final String retry;
  final String moreFailed;
  final String untitled;
  final String finished;
  final String Function(DateTime published) date;
  final String Function(int milliseconds) duration;

  const PodcastFeedTexts({
    required this.empty,
    required this.failed,
    required this.notSubscribed,
    required this.offline,
    required this.signedOut,
    required this.retry,
    required this.moreFailed,
    required this.untitled,
    required this.finished,
    required this.date,
    required this.duration,
  });
}

class PodcastFeedView extends StatefulWidget {
  const PodcastFeedView({
    super.key,
    required this.library,
    required this.feedUrl,
    required this.texts,
    required this.onPlay,
    this.progress,
  });

  final PodcastLibrary library;
  final String feedUrl;
  final PodcastFeedTexts texts;
  final ValueChanged<PodcastEpisode> onPlay;
  final double? Function(PodcastEpisode episode)? progress;

  @override
  State<PodcastFeedView> createState() => _PodcastFeedViewState();
}

class _PodcastFeedViewState extends State<PodcastFeedView> {
  bool _loadMoreScheduled = false;
  bool _openScheduled = false;

  @override
  void initState() {
    super.initState();
    widget.library.addListener(_onLibraryChanged);
    _scheduleOpen();
  }

  /// Open feed after frame: model notifies listeners immediately, while screen is created mid-frame
  /// — adjacent screen listening to the same model cannot be rebuilt at this moment.
  void _scheduleOpen() {
    if (_openScheduled || widget.library.feedUrl == widget.feedUrl) return;
    _openScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _openScheduled = false;
      if (!mounted || widget.library.feedUrl == widget.feedUrl) return;
      widget.library.openFeed(widget.feedUrl);
    });
  }

  @override
  void didUpdateWidget(covariant PodcastFeedView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.library != widget.library) {
      oldWidget.library.removeListener(_onLibraryChanged);
      widget.library.addListener(_onLibraryChanged);
      _scheduleOpen();
    } else if (oldWidget.feedUrl != widget.feedUrl) {
      _scheduleOpen();
    }
  }

  @override
  void dispose() {
    widget.library.removeListener(_onLibraryChanged);
    super.dispose();
  }

  void _onLibraryChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _scheduleLoadMore() {
    if (_loadMoreScheduled) return;
    if (!widget.library.hasMore ||
        widget.library.loadingMore ||
        widget.library.moreFailed) {
      return;
    }
    _loadMoreScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadMoreScheduled = false;
      if (!mounted) return;
      if (!widget.library.hasMore ||
          widget.library.loadingMore ||
          widget.library.moreFailed) {
        return;
      }
      widget.library.loadMore();
    });
  }

  String _failureMessage(PodcastFailure? failure) {
    return switch (failure) {
      PodcastFailure.offline => widget.texts.offline,
      PodcastFailure.signedOut => widget.texts.signedOut,
      PodcastFailure.notSubscribed => widget.texts.notSubscribed,
      _ => widget.texts.failed,
    };
  }

  @override
  Widget build(BuildContext context) {
    if (widget.library.feedUrl != widget.feedUrl) {
      return _openScheduled
          ? const Center(
              child: CircularProgressIndicator(
                key: Key('podcast-feed-loading'),
              ),
            )
          : const SizedBox.shrink();
    }

    return switch (widget.library.episodesState) {
      PodcastLoad.idle || PodcastLoad.loading => const Center(
        child: CircularProgressIndicator(key: Key('podcast-feed-loading')),
      ),
      PodcastLoad.empty => Center(
        child: Semantics(
          key: const Key('podcast-feed-message'),
          liveRegion: true,
          child: Text(widget.texts.empty),
        ),
      ),
      PodcastLoad.failed => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              key: const Key('podcast-feed-message'),
              liveRegion: true,
              child: Text(_failureMessage(widget.library.episodesFailure)),
            ),
            const SizedBox(height: 16),
            FilledButton(
              key: const Key('podcast-feed-retry'),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
              onPressed: () => widget.library.openFeed(widget.feedUrl),
              child: Text(widget.texts.retry),
            ),
          ],
        ),
      ),
      PodcastLoad.ready => _buildEpisodesList(context),
    };
  }

  Widget _buildEpisodesList(BuildContext context) {
    final episodes = widget.library.episodes;
    final hasMore = widget.library.hasMore;
    final itemCount = episodes.length + (hasMore ? 1 : 0);

    return ListView.builder(
      key: PageStorageKey('podcast-feed ${widget.feedUrl}'),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        if (index >= episodes.length - podcastFeedAhead) {
          _scheduleLoadMore();
        }

        if (index < episodes.length) {
          return _buildEpisodeItem(context, index, episodes[index]);
        }

        return _buildMoreItem(context);
      },
    );
  }

  Widget _buildEpisodeItem(
    BuildContext context,
    int index,
    PodcastEpisode episode,
  ) {
    final titleText = episode.title.trim().isEmpty
        ? widget.texts.untitled
        : episode.title;

    final String? subtitleText;
    final hasPublished = episode.published != null;
    final hasDuration = episode.durationMs != null && episode.durationMs! > 0;

    if (hasPublished && hasDuration) {
      subtitleText =
          '${widget.texts.date(episode.published!)} · ${widget.texts.duration(episode.durationMs!)}';
    } else if (hasPublished) {
      subtitleText = widget.texts.date(episode.published!);
    } else if (hasDuration) {
      subtitleText = widget.texts.duration(episode.durationMs!);
    } else {
      subtitleText = null;
    }

    final p = widget.progress?.call(episode);
    final isDone = p != null && p >= 1.0;
    final showProgress = p != null && p < 1.0;
    final clampedProgress = p != null ? p.clamp(0.0, 1.0) : 0.0;

    final Widget? subtitleWidget;
    if (subtitleText != null && showProgress) {
      subtitleWidget = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(subtitleText, maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 4),
          LinearProgressIndicator(
            key: Key('podcast-episode-progress-$index'),
            value: clampedProgress,
          ),
        ],
      );
    } else if (subtitleText != null) {
      subtitleWidget = Text(
        subtitleText,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    } else if (showProgress) {
      subtitleWidget = Padding(
        padding: const EdgeInsets.only(top: 4.0),
        child: LinearProgressIndicator(
          key: Key('podcast-episode-progress-$index'),
          value: clampedProgress,
        ),
      );
    } else {
      subtitleWidget = null;
    }

    final Widget? trailingWidget;
    if (isDone) {
      trailingWidget = Icon(
        Icons.check,
        key: Key('podcast-episode-done-$index'),
        semanticLabel: widget.texts.finished,
      );
    } else {
      trailingWidget = null;
    }

    return ListTile(
      key: Key('podcast-episode-$index'),
      title: Text(titleText, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: subtitleWidget,
      trailing: trailingWidget,
      onTap: () => widget.onPlay(episode),
    );
  }

  Widget _buildMoreItem(BuildContext context) {
    if (widget.library.moreFailed) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16.0, horizontal: 16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              key: const Key('podcast-more-message'),
              liveRegion: true,
              child: Text(widget.texts.moreFailed),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              key: const Key('podcast-more-retry'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
              onPressed: () => widget.library.loadMore(),
              child: Text(widget.texts.retry),
            ),
          ],
        ),
      );
    }

    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 16.0),
      child: Center(
        child: CircularProgressIndicator(key: Key('podcast-more-loading')),
      ),
    );
  }
}
