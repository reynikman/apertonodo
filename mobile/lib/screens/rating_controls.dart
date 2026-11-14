import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../ratings.dart';
import '../theme.dart';

/// Single rating button: 48×48 touch target, single accessibility node.
class _RatingButton extends StatelessWidget {
  const _RatingButton({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    bool? lit,
  }) : lit = lit ?? selected;

  final IconData icon;
  final String label;
  final bool selected;

  /// Drawn in the accent colour; differs from [selected] for stars below the rating.
  final bool lit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 48,
      height: 48,
      // Label and state on button node; icon is excluded from semantics tree.
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        excludeSemantics: true,
        onTap: onTap,
        child: InkResponse(
          onTap: onTap,
          child: Icon(
            icon,
            color: lit ? ApertonoColors.accent : ApertonoColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

/// Five stars in a row (FT-638, P-A94).
///
/// Stars up to rating are filled. Listens to [store]. Save failure
/// (stars or "dislike" of this song) is explained below row and cleared
/// after next successful action.
class RatingStars extends StatelessWidget {
  const RatingStars({super.key, required this.store, required this.trackId});

  final RatingsStore store;
  final String trackId;

  @override
  Widget build(BuildContext context) {
    final text = l10n(context);
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final stars = store.ratingOf(trackId).stars;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var n = 1; n <= 5; n++)
                  _RatingButton(
                    key: Key('rating-star-$n'),
                    icon: n <= stars ? Icons.star : Icons.star_border,
                    label: text.ratingStar(n),
                    // "Selected" — only star matching current rating.
                    selected: n == stars,
                    lit: n <= stars,
                    onTap: () => store.setStars(trackId, n),
                  ),
              ],
            ),
            if (store.failedOf(trackId))
              Padding(
                padding: const EdgeInsets.only(left: 8, bottom: 4),
                child: Text(
                  text.ratingFailed,
                  style: ApertonoText.trackArtist.copyWith(
                    color: ApertonoColors.error,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// "Dislike" button (FT-638, P-A95): sets dislike, second tap clears it.
class RatingDislike extends StatelessWidget {
  const RatingDislike({super.key, required this.store, required this.trackId});

  final RatingsStore store;
  final String trackId;

  @override
  Widget build(BuildContext context) {
    final text = l10n(context);
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final disliked = store.ratingOf(trackId).disliked;
        return _RatingButton(
          key: const Key('rating-dislike'),
          icon: disliked ? Icons.thumb_down : Icons.thumb_down_off_alt,
          label: text.ratingDislike,
          selected: disliked,
          onTap: () => store.setDisliked(trackId, !disliked),
        );
      },
    );
  }
}

/// "Rate" sheet from player menu: stars and "dislike" for track side by side.
Future<void> showRatingSheet(
  BuildContext context,
  RatingsStore store,
  String trackId,
) {
  store.load([trackId]).ignore();
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    builder: (_) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 16, 8, 24),
        child: Row(
          children: [
            RatingStars(store: store, trackId: trackId),
            const Spacer(),
            RatingDislike(store: store, trackId: trackId),
          ],
        ),
      ),
    ),
  );
}
