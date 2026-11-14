// FT-717: single podcast screen — FT-713 composition from server episodes.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../feed_order.dart';
import '../l10n/l10n.dart';
import '../podcast_client.dart';
import '../podcast_downloads.dart';
import 'parts.dart';
import 'podcast_page.dart';
import 'podcasts_screen.dart';

/// Episode order stored in device preferences as a single string (FT-707).
class PrefsFeedOrderBox implements FeedOrderBox {
  static const key = 'podcast_feed_order';

  @override
  Future<String?> read() async =>
      (await SharedPreferences.getInstance()).getString(key);

  @override
  Future<void> write(String data) async =>
      (await SharedPreferences.getInstance()).setString(key, data);
}

class PodcastScreen extends StatefulWidget {
  const PodcastScreen({
    super.key,
    required this.source,
    required this.podcast,
    required this.subscribed,
    required this.onSubscribe,
    required this.orders,
    required this.onPlay,
    this.downloads,
    this.art,
  });

  final PodcastsSource source;
  final FoundPodcast podcast;
  final bool subscribed;
  final Future<bool> Function() onSubscribe;
  final FeedOrderStore orders;
  final void Function(FoundPodcast podcast, PodcastEpisode episode) onPlay;

  /// Episode downloads (FT-710). If null — "Download" buttons are disabled.
  final PodcastDownloads? downloads;

  /// Podcast picture through our server (FT-860).
  final Widget Function(String? image, String title, double size)? art;

  @override
  State<PodcastScreen> createState() => _PodcastScreenState();
}

class _PodcastScreenState extends State<PodcastScreen> {
  List<PodcastEpisode>? _episodes;
  bool _failed = false;

  /// Which end episodes were loaded from: for feeds longer than 200 "from first"
  /// is a different page, not reversed identical page (FT-732).
  FeedOrder? _loaded;

  /// Sequence number of last request: order could return to previous while in flight
  /// — outdated response of same order is discarded.
  int _attempt = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final order = widget.orders.orderOf(widget.podcast.feedUrl);
    final attempt = ++_attempt;
    _loaded = order;
    setState(() => _failed = false);
    try {
      final episodes = await widget.source.episodes(
        widget.podcast.feedUrl,
        order: order,
      );
      // Order changed while loading: response is obsolete.
      if (!mounted || attempt != _attempt) return;
      setState(() => _episodes = episodes);
      // Which episodes are already on device — verify against storage (FT-733).
      final feed = widget.podcast.feedUrl;
      unawaited(
        widget.downloads?.refresh([for (final e in episodes) (feed, e.guid)]),
      );
    } catch (_) {
      if (!mounted || attempt != _attempt) return;
      setState(() => _failed = true);
    }
  }

  String _duration(int ms) {
    final text = l10n(context);
    final minutes = (ms / 60000).round();
    if (minutes < 60) return text.podcastMinutes(minutes);
    return text.podcastHoursMinutes(minutes ~/ 60, minutes % 60);
  }

  @override
  Widget build(BuildContext context) {
    final text = l10n(context);
    final episodes = _episodes;
    final downloads = widget.downloads;
    final Widget body;
    if (_failed) {
      body = Message(text.podcastEpisodesFailed, onRetry: _load);
    } else if (episodes == null) {
      body = const Center(
        key: Key('podcast-loading'),
        child: CircularProgressIndicator(),
      );
    } else {
      body = ListenableBuilder(
        listenable: widget.orders,
        builder: (context, _) => PodcastPage(
          info: PodcastPageInfo(
            feedUrl: widget.podcast.feedUrl,
            title: widget.podcast.title,
            author: widget.podcast.author,
            image: widget.podcast.image,
          ),
          art: widget.art,
          episodes: episodes,
          subscribed: widget.subscribed,
          onSubscribe: widget.onSubscribe,
          order: widget.orders.orderOf(widget.podcast.feedUrl),
          onOrder: (order) {
            unawaited(widget.orders.set(widget.podcast.feedUrl, order));
            if (order != _loaded) unawaited(_load());
          },
          downloadState: (episode) => downloads == null
              ? EpisodeDownloadState.none
              : downloads.stateOf(widget.podcast.feedUrl, episode.guid),
          onDownload: (episode) async {
            if (downloads == null) return EpisodeDownloadResult.badUrl;
            downloads.describe(
              feedUrl: widget.podcast.feedUrl,
              guid: episode.guid,
              enclosureUrl: episode.audioUrl,
              title: episode.title,
              show: widget.podcast.title,
              durationMs: episode.durationMs,
              image: episode.image ?? widget.podcast.image,
            );
            return downloads.download(
              feedUrl: widget.podcast.feedUrl,
              guid: episode.guid,
              enclosureUrl: episode.audioUrl,
            );
          },
          onPlay: (episode) => widget.onPlay(widget.podcast, episode),
          downloads: downloads,
          texts: PodcastPageTexts(
            subscribe: text.podcastsSubscribe,
            subscribed: text.podcastsSubscribed,
            subscribeFailed: text.podcastsSubscribeFailed,
            about: text.podcastAbout,
            episodes: text.podcastEpisodes,
            newestFirst: text.podcastNewestFirst,
            oldestFirst: text.podcastOldestFirst,
            empty: text.podcastNoEpisodes,
            untitled: text.podcastUntitled,
            download: text.podcastDownload,
            downloading: text.podcastDownloading,
            onPhone: text.podcastOnPhone,
            downloadFailed: text.podcastDownloadFailed,
            noRoom: text.podcastNoRoom,
            metered: text.podcastMetered,
            play: text.podcastPlay,
            duration: _duration,
            date: (date) => DateFormat.yMMMd(
              Localizations.localeOf(context).toLanguageTag(),
            ).format(date.toLocal()),
          ),
        ),
      );
    }
    return Scaffold(
      // Loaded page shows the title in its own header (FT-862).
      appBar: AppBar(
        title: _failed || episodes == null ? Text(widget.podcast.title) : null,
      ),
      body: body,
    );
  }
}
