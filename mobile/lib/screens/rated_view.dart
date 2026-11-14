import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/track.dart';
import '../rated_list.dart';
import '../ratings.dart';
import '../theme.dart';
import 'rating_controls.dart';

/// Body of "Liked" screen and "Disliked" list (FT-642, P-A94, P-A95).
///
/// Not a `Scaffold`: inserted into "My Music". Does not call `load()` itself.
class RatedView extends StatelessWidget {
  const RatedView({
    super.key,
    required this.list,
    required this.store,
    required this.onOpen,
  });

  final RatedList list;
  final RatingsStore store;
  final ValueChanged<Track> onOpen;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: list,
      builder: (context, _) => Column(
        children: [
          if (!list.disliked) _Filter(list: list),
          Expanded(
            child: _Body(list: list, store: store, onOpen: onOpen),
          ),
        ],
      ),
    );
  }
}

/// "From N stars" threshold: five buttons, visible on empty list and failure.
class _Filter extends StatelessWidget {
  const _Filter({required this.list});

  final RatedList list;

  @override
  Widget build(BuildContext context) {
    final text = l10n(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (var n = 1; n <= 5; n++)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  key: Key('rated-filter-$n'),
                  label: Text(text.ratedFrom(n)),
                  selected: n == list.minStars,
                  onSelected: (_) => list.setMinStars(n),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.list, required this.store, required this.onOpen});

  final RatedList list;
  final RatingsStore store;
  final ValueChanged<Track> onOpen;

  @override
  Widget build(BuildContext context) {
    final text = l10n(context);
    final tracks = list.tracks;
    if (tracks.isEmpty) {
      if (list.loading) {
        return const Center(
          child: CircularProgressIndicator(key: Key('rated-loading')),
        );
      }
      if (list.failed) return Center(child: _Failed(list: list));
      return Center(
        child: Text(
          list.disliked ? text.dislikedEmpty : text.ratedEmpty,
          key: const Key('rated-empty'),
          style: ApertonoText.trackArtist,
          textAlign: TextAlign.center,
        ),
      );
    }
    // Footer slot is reserved while more items can be loaded: scrolling to it
    // requests next page; on failure retry button is shown right there.
    final footer = list.hasMore || list.failed || list.loading;
    return ListView.builder(
      itemCount: tracks.length + (footer ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == tracks.length) {
          if (list.failed) return _Failed(list: list);
          // After failure request does not auto-retry — only via button.
          if (!list.loading) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              list.loadMore();
            });
          }
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        return _Row(
          track: tracks[index],
          store: store,
          disliked: list.disliked,
          onOpen: onOpen,
        );
      },
    );
  }
}

/// Failure text and "Retry" button.
class _Failed extends StatelessWidget {
  const _Failed({required this.list});

  final RatedList list;

  @override
  Widget build(BuildContext context) {
    final text = l10n(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text.ratedFailed,
            style: ApertonoText.trackArtist.copyWith(
              color: ApertonoColors.error,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          TextButton(
            key: const Key('rated-retry'),
            onPressed: list.retry,
            child: Text(text.ratedRetry),
          ),
        ],
      ),
    );
  }
}

/// Song row: clickable area opens song, right side shows rating.
class _Row extends StatelessWidget {
  const _Row({
    required this.track,
    required this.store,
    required this.disliked,
    required this.onOpen,
  });

  final Track track;
  final RatingsStore store;
  final bool disliked;
  final ValueChanged<Track> onOpen;

  @override
  Widget build(BuildContext context) {
    final text = l10n(context);
    return Row(
      children: [
        Expanded(
          child: AnimatedBuilder(
            animation: store,
            builder: (context, _) {
              final stars = store.ratingOf(track.id).stars;
              final label = [
                track.title,
                track.artist,
                if (!disliked && stars > 0) text.ratingStar(stars),
              ].join(', ');
              return Semantics(
                button: true,
                label: label,
                excludeSemantics: true,
                onTap: () => onOpen(track),
                child: InkWell(
                  key: Key('rated-row-${track.id}'),
                  onTap: () => onOpen(track),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 56),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 16, right: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  track.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: ApertonoText.trackTitle,
                                ),
                                Text(
                                  track.artist,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: ApertonoText.trackArtist,
                                ),
                              ],
                            ),
                          ),
                          if (!disliked) ...[
                            const SizedBox(width: 8),
                            Text(
                              '$stars',
                              key: Key('rated-stars-${track.id}'),
                              style: ApertonoText.trackTitle.copyWith(
                                color: ApertonoColors.accent,
                              ),
                            ),
                            const Icon(
                              Icons.star,
                              color: ApertonoColors.accent,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        if (disliked) RatingDislike(store: store, trackId: track.id),
      ],
    );
  }
}
