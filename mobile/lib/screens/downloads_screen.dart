import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/track.dart';
import '../offline/download_queue.dart';
import '../offline/downloads.dart';
import '../podcast_downloads.dart';
import '../theme.dart';
import 'memory_screen.dart';

class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({
    super.key,
    required this.downloads,
    required this.play,
    this.episodes,
    this.playEpisode,
  });

  final DownloadsPort downloads;
  final void Function(List<Track> tracks, int index) play;

  /// Downloaded podcast episodes (FT-803); without them the screen remains as before.
  final PodcastDownloads? episodes;
  final void Function(DownloadedEpisode episode)? playEpisode;

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  static const _gib = 1024 * 1024 * 1024;

  DownloadsPort get _downloads => widget.downloads;

  String _memoryLabel(DownloadsPort downloads, AppLocalizations text) {
    final x = downloads.downloadBytes + downloads.reserveBytes;
    final free = downloads.freeBytes;
    if (free != null) {
      return text.downloadsMemoryOf(
        formatGb(x, text),
        formatGb(x + free, text),
      );
    }
    return text.downloadsMemory(formatGb(x, text));
  }

  Widget _episodeRow(DownloadedEpisode episode, AppLocalizations text) {
    final play = widget.playEpisode;
    return ListTile(
      key: Key('download-episode-row-${episode.id}'),
      title: Text(
        episode.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: ApertonoText.trackTitle,
      ),
      subtitle: Text(
        episode.show,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: ApertonoText.trackArtist,
      ),
      trailing: IconButton(
        key: Key('download-episode-remove-${episode.id}'),
        tooltip: text.downloadsRemove,
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        icon: const Icon(Icons.delete_outline),
        onPressed: () => widget.episodes?.remove(episode.feedUrl, episode.guid),
      ),
      onTap: play == null ? null : () => play(episode),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = l10n(context);
    return Scaffold(
      appBar: AppBar(title: Text(text.downloadsTitle)),
      body: ListenableBuilder(
        listenable: Listenable.merge([_downloads, ?widget.episodes]),
        builder: (context, _) {
          final episodes = widget.episodes?.episodes ?? const [];
          final progress = _downloads.progress;
          final free = _downloads.freeBytes;
          final hold = _downloads.hold;
          final items = _downloads.items;

          return SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          text.downloadsProgress(progress.done, progress.total),
                          key: const Key('downloads-progress'),
                          style: ApertonoText.trackArtist,
                        ),
                      ),
                      if (free != null)
                        Text(
                          text.downloadsFree(free ~/ _gib),
                          key: const Key('downloads-free'),
                          style: ApertonoText.trackArtist,
                        ),
                    ],
                  ),
                ),
                if (hold != QueueHold.none)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text(
                      switch (hold) {
                        QueueHold.metered => text.downloadsHoldMetered,
                        QueueHold.noRoom => text.downloadsHoldNoRoom,
                        QueueHold.none => '',
                      },
                      key: const Key('downloads-hold'),
                      style: const TextStyle(
                        fontFamily: ApertonoFonts.sans,
                        fontSize: 13,
                        color: ApertonoColors.accent,
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          text.downloadsAllowMobile,
                          style: ApertonoText.trackTitle,
                        ),
                      ),
                      Switch(
                        key: const Key('downloads-allow-mobile'),
                        value: _downloads.allowMobile,
                        onChanged: (value) => _downloads.setAllowMobile(value),
                      ),
                    ],
                  ),
                ),
                InkWell(
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => MemoryScreen(downloads: _downloads),
                      ),
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            _memoryLabel(_downloads, text),
                            key: const Key('downloads-memory'),
                            style: ApertonoText.trackTitle,
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
                const Divider(),
                if (items.isEmpty && episodes.isEmpty)
                  Expanded(
                    child: Center(
                      child: Text(
                        text.downloadsEmpty,
                        key: const Key('downloads-empty'),
                        style: ApertonoText.trackArtist,
                      ),
                    ),
                  )
                else
                  Expanded(
                    child: ListView.builder(
                      key: const Key('downloads-list'),
                      itemCount:
                          items.length +
                          (episodes.isEmpty ? 0 : episodes.length + 1),
                      itemBuilder: (context, index) {
                        if (index >= items.length) {
                          final at = index - items.length;
                          if (at == 0) {
                            return Padding(
                              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                              child: Text(
                                text.downloadsEpisodes,
                                key: const Key('downloads-episodes-title'),
                                style: ApertonoText.trackTitle,
                              ),
                            );
                          }
                          return _episodeRow(episodes[at - 1], text);
                        }
                        final item = items[index];
                        final isDone = item.status == DownloadStatus.done;
                        final sizeMb = item.bytes == null
                            ? null
                            : (item.bytes! / (1024 * 1024));
                        final sizeStr = sizeMb == null
                            ? null
                            : text.downloadsSizeMb(
                                sizeMb.toStringAsFixed(
                                  item.bytes! % (1024 * 1024) == 0 ? 0 : 1,
                                ),
                              );
                        final mark = switch (item.status) {
                          DownloadStatus.done => DownloadMark.done,
                          DownloadStatus.failed => DownloadMark.none,
                          _ => DownloadMark.progress,
                        };

                        return ListTile(
                          key: Key('download-row-${item.track.id}'),
                          title: Text(
                            item.track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: ApertonoText.trackTitle,
                          ),
                          subtitle: Text(
                            [item.track.artist, ?sizeStr].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: ApertonoText.trackArtist,
                          ),
                          leading: DownloadStateMark(mark, size: 24),
                          trailing: IconButton(
                            key: Key('download-remove-${item.track.id}'),
                            tooltip: text.downloadsRemove,
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _downloads.remove([item.track.id]),
                          ),
                          onTap: !isDone
                              ? null
                              : () {
                                  final doneTracks = items
                                      .where(
                                        (i) => i.status == DownloadStatus.done,
                                      )
                                      .map((i) => i.track)
                                      .toList();
                                  final start = doneTracks.indexWhere(
                                    (t) => t.id == item.track.id,
                                  );
                                  if (start >= 0) {
                                    widget.play(doneTracks, start);
                                  }
                                },
                        );
                      },
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
