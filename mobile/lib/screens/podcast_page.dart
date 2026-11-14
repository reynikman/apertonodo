import 'package:flutter/material.dart';

import '../feed_order.dart';
import '../podcast_client.dart';
import '../podcast_downloads.dart';
import '../theme.dart';

/// Podcast information for [PodcastPage] screen.
class PodcastPageInfo {
  final String feedUrl;
  final String title;
  final String author;
  final String description;
  final List<String> chips;
  final String? image;

  const PodcastPageInfo({
    required this.feedUrl,
    required this.title,
    this.author = '',
    this.description = '',
    this.chips = const [],
    this.image,
  });
}

/// Localized strings for [PodcastPage] screen.
class PodcastPageTexts {
  final String subscribe;
  final String subscribed;
  final String subscribeFailed;
  final String about;
  final String episodes;
  final String newestFirst;
  final String oldestFirst;
  final String empty;
  final String untitled;
  final String download;
  final String downloading;
  final String onPhone;
  final String downloadFailed;
  final String noRoom;
  final String metered;
  final String play;
  final String Function(int ms) duration;

  /// Episode date for the row ("12 мар. 2024"); without it only duration is shown.
  final String Function(DateTime date)? date;

  const PodcastPageTexts({
    required this.subscribe,
    required this.subscribed,
    required this.subscribeFailed,
    required this.about,
    required this.episodes,
    required this.newestFirst,
    required this.oldestFirst,
    required this.empty,
    required this.untitled,
    required this.download,
    required this.downloading,
    required this.onPhone,
    required this.downloadFailed,
    required this.noRoom,
    required this.metered,
    required this.play,
    required this.duration,
    this.date,
  });
}

/// Orders episodes by date according to [order].
///
/// Episodes without date remain at end in original relative order.
/// Original list is not modified.
List<PodcastEpisode> orderEpisodes(
  List<PodcastEpisode> episodes,
  FeedOrder order,
) {
  final withDate = <(int, PodcastEpisode)>[];
  final withoutDate = <PodcastEpisode>[];
  for (var i = 0; i < episodes.length; i++) {
    final ep = episodes[i];
    if (ep.published != null) {
      withDate.add((i, ep));
    } else {
      withoutDate.add(ep);
    }
  }
  withDate.sort((a, b) {
    final cmp = a.$2.published!.compareTo(b.$2.published!);
    if (cmp != 0) {
      return order == FeedOrder.newestFirst ? -cmp : cmp;
    }
    return a.$1.compareTo(b.$1);
  });
  return <PodcastEpisode>[for (final pair in withDate) pair.$2, ...withoutDate];
}

/// Podcast page (Pk-4).
class PodcastPage extends StatefulWidget {
  final PodcastPageInfo info;
  final List<PodcastEpisode> episodes;
  final bool subscribed;
  final Future<bool> Function() onSubscribe;
  final FeedOrder order;
  final ValueChanged<FeedOrder> onOrder;
  final EpisodeDownloadState Function(PodcastEpisode) downloadState;
  final Future<EpisodeDownloadResult> Function(PodcastEpisode) onDownload;
  final ValueChanged<PodcastEpisode> onPlay;
  final PodcastPageTexts texts;
  final double? Function(PodcastEpisode)? progress;
  final Listenable? downloads;

  /// Podcast picture through our server (FT-860); without it the header is text only.
  final Widget Function(String? image, String title, double size)? art;

  const PodcastPage({
    super.key,
    required this.info,
    required this.episodes,
    required this.subscribed,
    required this.onSubscribe,
    required this.order,
    required this.onOrder,
    required this.downloadState,
    required this.onDownload,
    required this.onPlay,
    required this.texts,
    this.progress,
    this.downloads,
    this.art,
  });

  @override
  State<PodcastPage> createState() => _PodcastPageState();
}

class _PodcastPageState extends State<PodcastPage> {
  late bool _isSubscribed;
  bool _subscribing = false;
  final Set<String> _downloadingGuids = <String>{};
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _isSubscribed = widget.subscribed;
    widget.downloads?.addListener(_onDownloadsChanged);
  }

  @override
  void didUpdateWidget(covariant PodcastPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.downloads != widget.downloads) {
      oldWidget.downloads?.removeListener(_onDownloadsChanged);
      widget.downloads?.addListener(_onDownloadsChanged);
    }
    if (oldWidget.info.feedUrl != widget.info.feedUrl) {
      _isSubscribed = widget.subscribed;
      _subscribing = false;
      _downloadingGuids.clear();
      _errorMessage = null;
    } else if (oldWidget.subscribed != widget.subscribed) {
      _isSubscribed = widget.subscribed;
    }
  }

  @override
  void dispose() {
    widget.downloads?.removeListener(_onDownloadsChanged);
    super.dispose();
  }

  void _onDownloadsChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _handleSubscribe() async {
    if (_isSubscribed || _subscribing) return;
    final feedUrl = widget.info.feedUrl;
    setState(() {
      _subscribing = true;
      _errorMessage = null;
    });
    try {
      final ok = await widget.onSubscribe();
      if (!mounted || widget.info.feedUrl != feedUrl) return;
      if (ok) {
        _isSubscribed = true;
      } else {
        _errorMessage = widget.texts.subscribeFailed;
      }
    } catch (_) {
      if (!mounted || widget.info.feedUrl != feedUrl) return;
      _errorMessage = widget.texts.subscribeFailed;
    } finally {
      if (mounted && widget.info.feedUrl == feedUrl) {
        _subscribing = false;
        setState(() {});
      }
    }
  }

  Future<void> _handleDownload(PodcastEpisode episode) async {
    if (_downloadingGuids.contains(episode.guid)) return;
    final state = widget.downloadState(episode);
    if (state == EpisodeDownloadState.downloading ||
        state == EpisodeDownloadState.onPhone) {
      return;
    }
    final feedUrl = widget.info.feedUrl;
    setState(() {
      _downloadingGuids.add(episode.guid);
      _errorMessage = null;
    });
    try {
      final result = await widget.onDownload(episode);
      if (!mounted || widget.info.feedUrl != feedUrl) return;
      switch (result) {
        case EpisodeDownloadResult.started:
        case EpisodeDownloadResult.alreadyThere:
          break;
        case EpisodeDownloadResult.noRoom:
          _errorMessage = widget.texts.noRoom;
        case EpisodeDownloadResult.metered:
          _errorMessage = widget.texts.metered;
        case EpisodeDownloadResult.badUrl:
          _errorMessage = widget.texts.downloadFailed;
      }
    } catch (_) {
      if (!mounted || widget.info.feedUrl != feedUrl) return;
      _errorMessage = widget.texts.downloadFailed;
    } finally {
      if (mounted && widget.info.feedUrl == feedUrl) {
        _downloadingGuids.remove(episode.guid);
        setState(() {});
      }
    }
  }

  void _showAboutSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SingleChildScrollView(
              key: const ValueKey('podcast-about-sheet'),
              child: Text(
                widget.info.description,
                style: ApertonoText.trackTitle,
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final sortedEpisodes = orderEpisodes(widget.episodes, widget.order);

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.art != null) ...[
                  widget.art!(widget.info.image, widget.info.title, 112),
                  const SizedBox(width: 16),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Semantics(
                        header: true,
                        container: true,
                        child: Text(
                          widget.info.title,
                          style: ApertonoText.screenTitle,
                        ),
                      ),
                      if (widget.info.author.trim().isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          widget.info.author,
                          style: ApertonoText.trackArtist,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            if (widget.info.chips.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final chip in widget.info.chips)
                    Chip(
                      key: ValueKey('podcast-chip-$chip'),
                      label: Text(chip),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton(
                  key: const ValueKey('podcast-subscribe'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(48, 48),
                  ),
                  onPressed: (_isSubscribed || _subscribing)
                      ? null
                      : _handleSubscribe,
                  child: Text(
                    _isSubscribed
                        ? widget.texts.subscribed
                        : widget.texts.subscribe,
                  ),
                ),
                if (widget.info.description.trim().isNotEmpty)
                  OutlinedButton(
                    key: const ValueKey('podcast-about'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(48, 48),
                    ),
                    onPressed: () => _showAboutSheet(context),
                    child: Text(widget.texts.about),
                  ),
              ],
            ),
            if (_errorMessage != null) ...[
              const SizedBox(height: 12),
              Semantics(
                key: const ValueKey('podcast-error'),
                liveRegion: true,
                child: Text(
                  _errorMessage!,
                  style: const TextStyle(color: ApertonoColors.textSecondary),
                ),
              ),
            ],
            const SizedBox(height: 24),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                Text(widget.texts.episodes, style: ApertonoText.sectionTitle),
                TextButton(
                  key: const ValueKey('podcast-order'),
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () {
                    final next = widget.order == FeedOrder.newestFirst
                        ? FeedOrder.oldestFirst
                        : FeedOrder.newestFirst;
                    widget.onOrder(next);
                  },
                  child: Text(
                    widget.order == FeedOrder.newestFirst
                        ? widget.texts.newestFirst
                        : widget.texts.oldestFirst,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (sortedEpisodes.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text(
                    widget.texts.empty,
                    key: const ValueKey('podcast-empty'),
                    style: ApertonoText.trackArtist,
                  ),
                ),
              )
            else
              for (final episode in sortedEpisodes) _buildEpisodeItem(episode),
          ],
        ),
      ),
    );
  }

  Widget _buildEpisodeItem(PodcastEpisode episode) {
    final displayTitle = episode.title.trim().isEmpty
        ? widget.texts.untitled
        : episode.title;
    final durationMs = episode.durationMs;
    final durationText = (durationMs != null && durationMs > 0)
        ? widget.texts.duration(durationMs)
        : null;
    final prog = widget.progress?.call(episode);

    final state = widget.downloadState(episode);
    final isStarting = _downloadingGuids.contains(episode.guid);
    final String downloadText;
    final VoidCallback? downloadOnPressed;

    if (isStarting || state == EpisodeDownloadState.downloading) {
      downloadText = widget.texts.downloading;
      downloadOnPressed = null;
    } else if (state == EpisodeDownloadState.onPhone) {
      downloadText = widget.texts.onPhone;
      downloadOnPressed = null;
    } else {
      downloadText = widget.texts.download;
      downloadOnPressed = () => _handleDownload(episode);
    }

    final date = episode.published;
    final dateText = (date != null) ? widget.texts.date?.call(date) : null;
    final meta = [?dateText, ?durationText].join(' · ');
    final art = widget.art;
    final IconData downloadIcon = switch (state) {
      EpisodeDownloadState.onPhone => Icons.download_done,
      _ => Icons.download,
    };
    final downloading = isStarting || state == EpisodeDownloadState.downloading;

    return Padding(
      key: ValueKey('episode-${episode.guid}'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          if (art != null) ...[
            art(episode.image ?? widget.info.image, widget.info.title, 56),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  displayTitle,
                  style: ApertonoText.trackTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (meta.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(meta, style: ApertonoText.trackArtist),
                ],
                if (prog != null && prog > 0) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    key: ValueKey('episode-progress-${episode.guid}'),
                    value: prog,
                  ),
                ],
                if (state == EpisodeDownloadState.failed && !isStarting) ...[
                  const SizedBox(height: 4),
                  Semantics(
                    key: ValueKey('episode-failed-${episode.guid}'),
                    liveRegion: true,
                    child: Text(
                      widget.texts.downloadFailed,
                      style: const TextStyle(
                        color: ApertonoColors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            key: ValueKey('episode-download-${episode.guid}'),
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            tooltip: '$downloadText: $displayTitle',
            onPressed: downloadOnPressed,
            icon: downloading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    downloadIcon,
                    color: state == EpisodeDownloadState.onPhone
                        ? ApertonoColors.accent
                        : ApertonoColors.textSecondary,
                  ),
          ),
          IconButton.filled(
            key: ValueKey('episode-play-${episode.guid}'),
            style: IconButton.styleFrom(
              backgroundColor: ApertonoColors.accent,
              foregroundColor: ApertonoColors.background,
            ),
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            icon: const Icon(Icons.play_arrow),
            tooltip: '${widget.texts.play}: $displayTitle',
            onPressed: () => widget.onPlay(episode),
          ),
        ],
      ),
    );
  }
}
