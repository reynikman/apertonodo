// FT-704: podcast catalog section page (P-A108 item 2, block Pk-3).

import 'package:flutter/material.dart';

import '../podcast_client.dart';
import '../theme.dart';

/// Text labels for podcast section page (P-A84).
class PodcastCategoryTexts {
  final String loadFailed;
  final String retry;
  final String empty;
  final String subscribe;
  final String subscribed;
  final String subscribeFailed;

  const PodcastCategoryTexts({
    required this.loadFailed,
    required this.retry,
    required this.empty,
    required this.subscribe,
    required this.subscribed,
    required this.subscribeFailed,
  });
}

/// Podcasts page of selected category with subscription support.
class PodcastCategoryPage extends StatefulWidget {
  final String title;
  final Future<List<FoundPodcast>> Function() load;
  final Set<String> subscribed;
  final Future<bool> Function(FoundPodcast podcast) onSubscribe;
  final void Function(FoundPodcast podcast) onOpen;
  final PodcastCategoryTexts texts;

  /// Podcast picture through our server (FT-860); without it rows are text only.
  final Widget Function(String? image, String title, double size)? art;

  const PodcastCategoryPage({
    super.key,
    required this.title,
    required this.load,
    required this.subscribed,
    required this.onSubscribe,
    required this.onOpen,
    required this.texts,
    this.art,
  });

  @override
  State<PodcastCategoryPage> createState() => _PodcastCategoryPageState();
}

class _PodcastCategoryPageState extends State<PodcastCategoryPage> {
  bool _loading = true;
  bool _error = false;
  List<FoundPodcast>? _podcasts;
  final Set<String> _localSubscribed = {};
  final Set<String> _subscribing = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    setState(() {
      _loading = true;
      _error = false;
    });
    _performLoad();
  }

  Future<void> _performLoad() async {
    try {
      final items = await widget.load();
      if (!mounted) return;
      setState(() {
        _podcasts = items;
        _loading = false;
        _error = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = true;
      });
    }
  }

  bool _isSubscribed(String feedUrl) {
    return widget.subscribed.contains(feedUrl) ||
        _localSubscribed.contains(feedUrl);
  }

  Future<void> _subscribe(FoundPodcast podcast) async {
    if (_subscribing.contains(podcast.feedUrl)) return;
    if (_isSubscribed(podcast.feedUrl)) return;

    setState(() {
      _subscribing.add(podcast.feedUrl);
    });

    var success = false;
    try {
      success = await widget.onSubscribe(podcast);
      if (!mounted) return;
      if (!success) {
        _showSubscribeFailed();
      }
    } catch (_) {
      if (!mounted) return;
      _showSubscribeFailed();
    } finally {
      if (mounted) {
        setState(() {
          _subscribing.remove(podcast.feedUrl);
          if (success) {
            _localSubscribed.add(podcast.feedUrl);
          }
        });
      }
    }
  }

  void _showSubscribeFailed() {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(widget.texts.subscribeFailed)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ApertonoColors.background,
      appBar: AppBar(
        title: Text(widget.title),
        backgroundColor: ApertonoColors.background,
        foregroundColor: ApertonoColors.textPrimary,
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: ApertonoColors.accent),
      );
    }

    if (_error) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.texts.loadFailed,
                textAlign: TextAlign.center,
                style: ApertonoText.trackArtist.copyWith(
                  color: ApertonoColors.textSecondary,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _load,
                style: FilledButton.styleFrom(
                  backgroundColor: ApertonoColors.accent,
                  foregroundColor: ApertonoColors.background,
                ),
                child: Text(widget.texts.retry),
              ),
            ],
          ),
        ),
      );
    }

    final podcasts = _podcasts ?? const <FoundPodcast>[];
    if (podcasts.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            widget.texts.empty,
            textAlign: TextAlign.center,
            style: ApertonoText.trackArtist.copyWith(
              color: ApertonoColors.textSecondary,
            ),
          ),
        ),
      );
    }

    return ListView.builder(
      itemCount: podcasts.length,
      itemBuilder: (context, index) {
        final podcast = podcasts[index];
        return _buildTile(podcast);
      },
    );
  }

  Widget _buildTile(FoundPodcast podcast) {
    final subscribed = _isSubscribed(podcast.feedUrl);
    final inProgress = _subscribing.contains(podcast.feedUrl);
    final hasAuthor = podcast.author.trim().isNotEmpty;

    return InkWell(
      key: ValueKey('podcast-${podcast.feedUrl}'),
      onTap: () => widget.onOpen(podcast),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              if (widget.art != null) ...[
                widget.art!(podcast.image, podcast.title, 72),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      podcast.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: ApertonoText.trackTitle.copyWith(
                        color: ApertonoColors.textPrimary,
                      ),
                    ),
                    if (hasAuthor) ...[
                      const SizedBox(height: 2),
                      Text(
                        podcast.author,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ApertonoText.trackArtist.copyWith(
                          color: ApertonoColors.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (subscribed)
                Text(
                  widget.texts.subscribed,
                  key: ValueKey('subscribed-${podcast.feedUrl}'),
                  style: ApertonoText.trackArtist.copyWith(
                    color: ApertonoColors.textSecondary,
                    fontWeight: FontWeight.w500,
                  ),
                )
              else
                TextButton(
                  key: ValueKey('subscribe-${podcast.feedUrl}'),
                  onPressed: inProgress ? null : () => _subscribe(podcast),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(64, 48),
                    foregroundColor: ApertonoColors.accent,
                  ),
                  child: Text(widget.texts.subscribe),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
