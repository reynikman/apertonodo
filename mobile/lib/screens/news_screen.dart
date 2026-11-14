import 'dart:async';

import 'package:flutter/material.dart';

import '../error_reports.dart';
import '../l10n/l10n.dart';
import '../news_prefs.dart';
import '../server_api.dart';
import '../theme.dart';
import 'news_channels_screen.dart';
import 'parts.dart';

/// "News" (FT-579, FT-581, P-A83): third tab, card feed similar to
/// Telegram or X — channel, time, header, full text (long text expands
/// in place via "more"), image from `/v1/photos/news/{id}`. News is read inside
/// the app: only "Source" leads outside. Release card — cover and
/// Play (album plays from the first track).
///
/// FT-581 (P-A83): before consent, the tab shows `news-consent` screen and does
/// not contact the server; disabled by user — tab is absent entirely (FT-796);
/// disabled by admin (`{"enabled": false}`) — `news-server-off`, without
/// error screen.
class NewsScreen extends StatefulWidget {
  const NewsScreen({super.key, required this.services, this.news});

  final Services services;

  /// Device news settings. If null, screen instantiates and loads its own;
  /// app passes shared instance so toggle in account menu and
  /// tab see the same state.
  final NewsPrefs? news;

  @override
  State<NewsScreen> createState() => _NewsScreenState();
}

class _NewsScreenState extends State<NewsScreen> {
  late final NewsPrefs _news = widget.news ?? NewsPrefs();
  late final bool _owns = widget.news == null;

  @override
  void initState() {
    super.initState();
    // Do not reload shared already-loaded instance: otherwise after disabling
    // feed we would reload stale value from storage.
    if (_owns) {
      unawaited(_news.load());
    }
  }

  @override
  void dispose() {
    if (_owns) {
      _news.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _news,
      builder: (context, _) {
        if (!_news.consent) {
          return _NewsConsent(onAccept: _news.accept);
        }
        return _NewsFeed(services: widget.services);
      },
    );
  }
}

/// First opening of tab: where news comes from and that server makes external calls.
class _NewsConsent extends StatelessWidget {
  const _NewsConsent({required this.onAccept});

  final Future<void> Function() onAccept;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          key: const Key('news-consent'),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(l10n(context).newsTitle, style: ApertonoText.screenTitle),
                const SizedBox(height: 12),
                Text(
                  l10n(context).newsConsentDescription,
                  textAlign: TextAlign.center,
                  style: ApertonoText.trackArtist.copyWith(
                    fontSize: 14,
                    height: 20 / 14,
                    color: ApertonoColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  key: const Key('news-consent-accept'),
                  onPressed: () => unawaited(onAccept()),
                  child: Text(l10n(context).newsConsentGotIt),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Card feed: consent given and feed enabled.
class _NewsFeed extends StatefulWidget {
  const _NewsFeed({required this.services});

  final Services services;

  @override
  State<_NewsFeed> createState() => _NewsFeedState();
}

class _NewsFeedState extends State<_NewsFeed> {
  NewsPage? _page;
  bool _loading = true;
  Object? _error;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _loadInitial();
  }

  Future<void> _loadInitial() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.services.server.news();
      if (mounted) {
        setState(() {
          _page = page;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final page = await widget.services.server.news();
      if (mounted) {
        setState(() {
          _page = page;
          _error = null;
        });
      }
    } catch (_) {
      // Refresh failure (no network, 5xx) does not clear currently displayed feed;
      // error message is not required.
    } finally {
      _refreshing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final page = _page;
    if (page == null) {
      if (_loading) {
        return const Scaffold(
          body: SafeArea(child: Center(child: CircularProgressIndicator())),
        );
      }
      final error = _error;
      final reason = error is ServerFailed
          ? error.reason
          : ServerFailure.noAnswer;
      final content = LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Message(
              failureText(
                reason,
                notFound: l10n(context).newsUnavailable,
                text: l10n(context),
              ),
              onRetry: reason == ServerFailure.notFound ? null : _loadInitial,
              server: widget.services.server,
              report: ErrorReport(
                kind: 'server.${reportName(reason.name)}',
                screen: 'news',
              ),
            ),
          ),
        ),
      );
      return Scaffold(
        body: SafeArea(
          child: RefreshIndicator(
            color: ApertonoColors.accent,
            backgroundColor: ApertonoColors.surfaceRaised,
            onRefresh: _refresh,
            child: content,
          ),
        ),
      );
    }

    final Widget content;
    if (!page.enabled) {
      content = LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Message(
              l10n(context).newsServerDisabled,
              key: const Key('news-server-off'),
            ),
          ),
        ),
      );
    } else if (page.items.isEmpty) {
      content = _NewsEmpty(services: widget.services);
    } else {
      content = ListView(
        key: const Key('news-list'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n(context).newsTitle,
                  key: const Key('news-title'),
                  style: ApertonoText.screenTitle,
                ),
              ),
              _ChannelsButton(services: widget.services),
            ],
          ),
          const SizedBox(height: 12),
          for (final item in page.items) ...[
            _NewsCard(services: widget.services, item: item),
            const SizedBox(height: 12),
          ],
        ],
      );
    }

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          color: ApertonoColors.accent,
          backgroundColor: ApertonoColors.surfaceRaised,
          onRefresh: _refresh,
          child: content,
        ),
      ),
    );
  }
}

/// Feed card. Text expansion is local state for each card.
class _NewsCard extends StatefulWidget {
  const _NewsCard({required this.services, required this.item});

  final Services services;
  final NewsItem item;

  @override
  State<_NewsCard> createState() => _NewsCardState();
}

class _NewsCardState extends State<_NewsCard> {
  /// Number of lines visible in feed; full text is in article (P-A111).
  static const _collapsedLines = 6;

  /// Character threshold above which text is considered long and collapsed in feed.
  static const _longText = 180;

  // Second tap while article is opening is blocked by Flutter automatically:
  // bottom screen does not accept touches during transition (FT-716 test).
  void _open() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) =>
          _NewsArticle(services: widget.services, item: widget.item),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final services = widget.services;
    final text = item.text.trim();
    final long = text.length > _longText;
    final date = _newsDate(item.published);
    return DecoratedBox(
      key: Key('news-card-${item.id}'),
      decoration: BoxDecoration(
        gradient: ApertonoColors.cardGradient,
        border: Border.all(color: ApertonoColors.border),
        borderRadius: BorderRadius.circular(ApertonoRadii.large),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    item.channel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ApertonoText.trackTitle.copyWith(
                      color: ApertonoColors.accent,
                    ),
                  ),
                ),
                if (date.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text(date, style: ApertonoText.trackArtist),
                ],
              ],
            ),
            const SizedBox(height: 6),
            GestureDetector(
              onTap: _open,
              behavior: HitTestBehavior.opaque,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.title, style: _titleStyle),
                  if (item.image case final image?) ...[
                    const SizedBox(height: 10),
                    _NewsImage(
                      server: services.server,
                      path: image,
                      item: item,
                    ),
                  ],
                  if (text.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      text,
                      key: Key('news-text-${item.id}'),
                      maxLines: long ? _collapsedLines : null,
                      overflow: TextOverflow.ellipsis,
                      style: _textStyle,
                    ),
                  ],
                ],
              ),
            ),
            TextButton(
              key: Key('news-read-${item.id}'),
              onPressed: _open,
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 48),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(l10n(context).newsReadFull),
            ),
            if (item.isRelease) _ReleasePlay(services: services, item: item),
          ],
        ),
      ),
    );
  }
}

final _titleStyle = ApertonoText.sectionTitle.copyWith(
  color: ApertonoColors.textPrimary,
);

final _textStyle = ApertonoText.trackArtist.copyWith(
  fontSize: 14,
  height: 20 / 14,
  color: ApertonoColors.textPrimary,
);

/// "05.10.2026" from ISO-8601; malformed string returns empty.
String _newsDate(String iso) {
  final at = DateTime.tryParse(iso)?.toLocal();
  if (at == null) return '';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(at.day)}.${two(at.month)}.${two(at.year)}';
}

/// Article shown fully inside the app (P-A83, P-A111); external link — only
/// "Source": top right and below text.
class _NewsArticle extends StatefulWidget {
  const _NewsArticle({required this.services, required this.item});

  final Services services;
  final NewsItem item;

  @override
  State<_NewsArticle> createState() => _NewsArticleState();
}

class _NewsArticleState extends State<_NewsArticle> {
  /// Link is already opening: second tap does not open externally a second time.
  var _leaving = false;

  Future<void> _source(Future<void> Function(Uri) openLink, String link) async {
    if (_leaving) return;
    _leaving = true;
    try {
      await openLink(Uri.parse(link));
    } finally {
      _leaving = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final services = widget.services;
    final item = widget.item;
    final openLink = services.openLink;
    final link = item.link;
    final source = !item.isRelease && link != null && openLink != null
        ? () => _source(openLink, link)
        : null;
    return Scaffold(
      key: Key('news-article-${item.id}'),
      backgroundColor: ApertonoColors.background,
      appBar: AppBar(
        backgroundColor: ApertonoColors.background,
        foregroundColor: ApertonoColors.textPrimary,
        title: Text(
          item.channel,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: ApertonoText.trackTitle.copyWith(color: ApertonoColors.accent),
        ),
        actions: [
          if (source != null)
            IconButton(
              key: Key('news-source-top-${item.id}'),
              onPressed: source,
              tooltip: l10n(context).newsSource,
              icon: const Icon(Icons.open_in_new),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: [
            if (_newsDate(item.published) case final date when date.isNotEmpty)
              Text(date, style: ApertonoText.trackArtist),
            const SizedBox(height: 8),
            Semantics(
              header: true,
              child: Text(item.title, style: _titleStyle),
            ),
            if (item.image case final image?) ...[
              const SizedBox(height: 12),
              _NewsImage(server: services.server, path: image, item: item),
            ],
            if (item.text.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                item.text.trim(),
                key: Key('news-article-text-${item.id}'),
                style: _textStyle.copyWith(fontSize: 16, height: 24 / 16),
              ),
            ],
            const SizedBox(height: 16),
            if (item.isRelease)
              _ReleasePlay(services: services, item: item)
            else if (source != null)
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  key: Key('news-source-${item.id}'),
                  onPressed: source,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(48, 48),
                  ),
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: Text(l10n(context).newsSource),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Image from server; if unavailable, square placeholder with artist initials.
class _NewsImage extends StatelessWidget {
  const _NewsImage({
    required this.server,
    required this.path,
    required this.item,
  });

  final ServerApi server;
  final String path;
  final NewsItem item;

  @override
  Widget build(BuildContext context) {
    final fallback = ArtistSquare(item.artist ?? item.channel, size: 180);
    return ClipRRect(
      borderRadius: BorderRadius.circular(ApertonoRadii.medium),
      child: SizedBox(
        height: 180,
        width: double.infinity,
        child: Image.network(
          server.url(path),
          headers: server.headers,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => fallback,
        ),
      ),
    );
  }
}

/// Play button for release card: fetches album from server and plays from first track.
class _ReleasePlay extends StatelessWidget {
  const _ReleasePlay({required this.services, required this.item});

  final Services services;
  final NewsItem item;

  @override
  Widget build(BuildContext context) {
    final albumId = item.albumId;
    final messenger = ScaffoldMessenger.maybeOf(context);
    return FilledButton.icon(
      key: Key('news-play-${item.id}'),
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 40),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: const Icon(Icons.play_arrow_rounded),
      label: Text(l10n(context).newsPlay),
      onPressed: albumId == null
          ? null
          : () async {
              try {
                final page = await services.server.album(albumId);
                services.play(page.tracks, 0);
              } on ServerFailed catch (failed) {
                if (messenger != null) {
                  say(messenger, failureText(failed.reason));
                }
              }
            },
    );
  }
}

/// Empty feed: artists user listens to most frequently (FT-580, P-A83).
///
/// Server responds with `history` (from listening history) or `popular`
/// (from catalog). Suggestions shown only for `history` — popular
/// catalog artists without listen history are not "yours".
class _NewsEmpty extends StatelessWidget {
  const _NewsEmpty({required this.services});

  final Services services;

  @override
  Widget build(BuildContext context) {
    return Loaded<NewsSuggestions>(
      server: services.server,
      screen: 'news',
      notFound: l10n(context).newsUnavailable,
      load: services.server.newsSuggestions,
      builder: (context, page, _) {
        final content = (page.source != 'history' || page.artists.isEmpty)
            ? LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: Message(
                      l10n(context).newsEmpty,
                      key: const Key('news-empty'),
                    ),
                  ),
                ),
              )
            : _Suggestions(services: services, page: page);
        // "Channels" needed from empty feed as well: custom channel is a way
        // to receive first news item without subscriptions (FT-582).
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: _ChannelsButton(services: services),
            ),
            Expanded(child: content),
          ],
        );
      },
    );
  }
}

/// "You often listen to..." and single button to follow all shown artists.
class _Suggestions extends StatefulWidget {
  const _Suggestions({required this.services, required this.page});

  final Services services;
  final NewsSuggestions page;

  @override
  State<_Suggestions> createState() => _SuggestionsState();
}

class _SuggestionsState extends State<_Suggestions> {
  var _following = false;
  var _done = false;

  Future<void> _followAll() async {
    if (_following || _done) return;
    setState(() => _following = true);
    for (final artist in widget.page.artists) {
      try {
        await widget.services.server.followArtist(artist.id);
      } on ServerFailed {
        // Failed to follow one — still attempt remaining artists.
      }
    }
    if (mounted) {
      setState(() {
        _following = false;
        _done = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = l10n(context);
    return ListView(
      key: const Key('news-suggestions'),
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      children: [
        Text(
          text.newsSuggestionsTitle,
          key: const Key('news-empty'),
          style: ApertonoText.screenTitle,
        ),
        const SizedBox(height: 12),
        for (final artist in widget.page.artists)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(artist.name, style: ApertonoText.trackTitle),
          ),
        const SizedBox(height: 12),
        FilledButton(
          key: const Key('news-follow-all'),
          onPressed: _done ? null : () => unawaited(_followAll()),
          child: Text(text.newsFollowAll),
        ),
      ],
    );
  }
}

/// Entry point to "Channels" (FT-582) from feed and from empty feed.
class _ChannelsButton extends StatelessWidget {
  const _ChannelsButton({required this.services});

  final Services services;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      key: const Key('news-channels'),
      onPressed: () =>
          unawaited(open(context, NewsChannelsScreen(services: services))),
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 48),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: const Icon(Icons.rss_feed, size: 20),
      label: Text(l10n(context).newsChannels),
    );
  }
}
