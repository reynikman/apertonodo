import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../server_api.dart';
import '../theme.dart';
import 'parts.dart';

/// "Channels" (FT-582, P-A83): curated list with toggles, "add by
/// link" and "popular on this server" — custom channels added by at
/// least 3 users; popular displays only count of users without names.
///
/// Labels are bilingual (P-A84) like news feed. Content exceeds screen height
/// (curated channels count ~10), but text input already contains `Scrollable`, and
/// second `Scrollable` in tree is forbidden — test checks full screen
/// (`news_channels_test.dart`). Hence long content is paged via translation
/// (`InteractiveViewer`), not scroll list.
class NewsChannelsScreen extends StatelessWidget {
  const NewsChannelsScreen({super.key, required this.services});

  final Services services;

  Future<_ChannelsPage> _load() async {
    final server = services.server;
    return _ChannelsPage(
      curated: await server.newsCurated(),
      own: await server.newsChannels(),
      popular: await server.newsPopularChannels(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = l10n(context);
    return Scaffold(
      appBar: AppBar(title: Text(text.channelsTitle)),
      body: SafeArea(
        child: Loaded<_ChannelsPage>(
          server: services.server,
          screen: 'news-channels',
          notFound: text.channelsUnavailable,
          load: _load,
          builder: (context, page, reload) =>
              _ChannelsBody(services: services, page: page, reload: reload),
        ),
      ),
    );
  }
}

/// All three screen lists in a single server pass.
class _ChannelsPage {
  const _ChannelsPage({
    required this.curated,
    required this.own,
    required this.popular,
  });

  final List<CuratedChannel> curated;
  final List<OwnChannel> own;
  final List<PopularChannel> popular;
}

class _ChannelsBody extends StatefulWidget {
  const _ChannelsBody({
    required this.services,
    required this.page,
    required this.reload,
  });

  final Services services;
  final _ChannelsPage page;
  final VoidCallback reload;

  @override
  State<_ChannelsBody> createState() => _ChannelsBodyState();
}

class _ChannelsBodyState extends State<_ChannelsBody> {
  final _link = TextEditingController();
  var _adding = false;
  String? _addError;

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    if (_adding) return;
    final link = _link.text.trim();
    if (link.isEmpty) return;
    setState(() {
      _adding = true;
      _addError = null;
    });
    final result = await widget.services.server.addNewsChannel(link);
    if (!mounted) return;
    final text = l10n(context);
    setState(() {
      _adding = false;
      _addError = switch (result) {
        ChannelAddResult.added => null,
        ChannelAddResult.notPublic => text.channelsAddErrorNotPublic,
        ChannelAddResult.tooMany => text.channelsAddErrorTooMany,
        ChannelAddResult.notFeed => text.channelsAddErrorNotFeed,
        ChannelAddResult.failed => text.channelsAddErrorFailed,
      };
    });
    if (result == ChannelAddResult.added) {
      _link.clear();
      widget.reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = l10n(context);
    final page = widget.page;
    return LayoutBuilder(
      builder: (context, constraints) {
        return InteractiveViewer(
          alignment: Alignment.topLeft,
          panAxis: PanAxis.vertical,
          scaleEnabled: false,
          minScale: 1,
          maxScale: 1,
          constrained: false,
          child: SizedBox(
            width: constraints.maxWidth,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Heading(text.channelsCuratedHeading),
                for (final channel in page.curated)
                  _CuratedTile(
                    server: widget.services.server,
                    channel: channel,
                  ),
                Heading(text.channelsOwnHeading),
                if (page.own.isEmpty)
                  _Hint(text.channelsOwnEmpty)
                else
                  for (final channel in page.own) _OwnTile(channel: channel),
                Heading(text.channelsAddHeading),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  child: TextField(
                    key: const Key('channel-link'),
                    controller: _link,
                    style: ApertonoText.trackTitle,
                    decoration: InputDecoration(
                      hintText: text.channelsAddLinkHint,
                      hintStyle: ApertonoText.trackArtist,
                      filled: true,
                      fillColor: ApertonoColors.surface,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(
                          ApertonoRadii.medium,
                        ),
                        borderSide: const BorderSide(
                          color: ApertonoColors.border,
                        ),
                      ),
                    ),
                    onSubmitted: (_) => unawaited(_add()),
                  ),
                ),
                if (_addError case final error?)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Text(
                      error,
                      key: const Key('channel-add-error'),
                      style: ApertonoText.trackArtist.copyWith(
                        color: ApertonoColors.error,
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: FilledButton(
                    key: const Key('channel-add'),
                    onPressed: _adding ? null : () => unawaited(_add()),
                    child: Text(text.channelsAddButton),
                  ),
                ),
                Heading(text.channelsPopularHeading),
                if (page.popular.isEmpty)
                  _Hint(text.channelsPopularEmpty)
                else
                  for (final channel in page.popular)
                    _PopularTile(channel: channel),
                const SizedBox(height: 24),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Section header hint line: dimmed, non-interactive.
class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Text(text, style: ApertonoText.trackArtist),
    );
  }
}

/// Curated channel with toggle — per-user state (FT-582).
class _CuratedTile extends StatefulWidget {
  const _CuratedTile({required this.server, required this.channel});

  final ServerApi server;
  final CuratedChannel channel;

  @override
  State<_CuratedTile> createState() => _CuratedTileState();
}

class _CuratedTileState extends State<_CuratedTile> {
  late var _enabled = widget.channel.enabled;

  Future<void> _toggle(bool value) async {
    // Switch toggles immediately: new state is sent to server.
    setState(() => _enabled = value);
    try {
      await widget.server.setNewsCurated(widget.channel.id, value);
    } on ServerFailed {
      // Server rejected — revert to previous state.
      if (mounted) setState(() => _enabled = !value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final channel = widget.channel;
    return MergeSemantics(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        minTileHeight: 52,
        title: Text(channel.name, style: ApertonoText.trackTitle),
        subtitle: channel.lang.isEmpty
            ? null
            : Text(channel.lang.toUpperCase(), style: ApertonoText.trackArtist),
        trailing: Switch(
          key: Key('curated-${channel.id}'),
          value: _enabled,
          onChanged: (value) => unawaited(_toggle(value)),
        ),
        onTap: () => unawaited(_toggle(!_enabled)),
      ),
    );
  }
}

/// User custom channel (FT-577).
class _OwnTile extends StatelessWidget {
  const _OwnTile({required this.channel});

  final OwnChannel channel;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      minTileHeight: 52,
      title: Text(channel.name, style: ApertonoText.trackTitle),
      subtitle: Text(
        channel.feedUrl,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: ApertonoText.trackArtist,
      ),
    );
  }
}

/// Server popular channel: name and how many users added it (FT-582).
class _PopularTile extends StatelessWidget {
  const _PopularTile({required this.channel});

  final PopularChannel channel;

  @override
  Widget build(BuildContext context) {
    final people = channel.people;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      minTileHeight: 52,
      title: Text(channel.name, style: ApertonoText.trackTitle),
      subtitle: Text(
        l10n(context).channelsPopularAdded(people),
        style: ApertonoText.trackArtist,
      ),
    );
  }
}
