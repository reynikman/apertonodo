import 'package:flutter/material.dart';

import '../continue_shelf.dart';
import '../theme.dart';

/// Texts for "Continue" row (FT-731).
class ContinueTexts {
  const ContinueTexts({
    required this.title,
    required this.left,
    required this.part,
    required this.play,
  });

  /// Row title ("Continue").
  final String title;

  /// "18 min left".
  final String Function(String time) left;

  /// "Part 3 of 12".
  final String Function(int part, int count) part;

  /// Screen reader button label ("Continue: Episode 4").
  final String Function(String title) play;
}

/// Horizontal "Continue" row of unfinished podcasts and books.
class ContinueRow extends StatelessWidget {
  const ContinueRow({
    super.key,
    required this.items,
    required this.texts,
    required this.duration,
    required this.onTap,
    this.image,
  });

  final List<ContinueItem> items;
  final ContinueTexts texts;
  final String Function(int ms) duration;
  final void Function(ContinueItem item) onTap;
  final ImageProvider? Function(String url)? image;

  static const double _cardWidth = 120.0;
  static const double _coverSize = 120.0;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const SizedBox.shrink();
    }

    final textScaler = MediaQuery.textScalerOf(context);
    final cardHeight = _coverSize + 8.0 + textScaler.scale(80.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Semantics(
            header: true,
            child: Text(
              texts.title,
              style: ApertonoText.sectionTitle.copyWith(
                color: ApertonoColors.textPrimary,
              ),
            ),
          ),
        ),
        SizedBox(
          height: cardHeight,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final item = items[index];
              return _ContinueCard(
                item: item,
                texts: texts,
                duration: duration,
                onTap: onTap,
                image: image,
                width: _cardWidth,
                coverSize: _coverSize,
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ContinueCard extends StatelessWidget {
  const _ContinueCard({
    required this.item,
    required this.texts,
    required this.duration,
    required this.onTap,
    this.image,
    required this.width,
    required this.coverSize,
  });

  final ContinueItem item;
  final ContinueTexts texts;
  final String Function(int ms) duration;
  final void Function(ContinueItem item) onTap;
  final ImageProvider? Function(String url)? image;
  final double width;
  final double coverSize;

  Widget _placeholder() {
    return Container(
      width: coverSize,
      height: coverSize,
      decoration: BoxDecoration(
        color: ApertonoColors.surfaceRaised,
        borderRadius: BorderRadius.circular(ApertonoRadii.cover),
      ),
      child: Icon(
        item.meta.kind == ContinueKind.book
            ? Icons.auto_stories
            : Icons.podcasts,
        color: ApertonoColors.textMuted,
        size: 40,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    String? remainderText;
    if (item.meta.kind == ContinueKind.podcast && item.remainingMs != null) {
      remainderText = texts.left(duration(item.remainingMs!));
    } else if (item.meta.kind == ContinueKind.book &&
        item.part != null &&
        item.meta.partCount != null) {
      remainderText = texts.part(item.part!, item.meta.partCount!);
    }

    final imageUrl = item.meta.imageUrl;
    final ImageProvider? imageProvider =
        (imageUrl != null && imageUrl.isNotEmpty && image != null)
        ? image!(imageUrl)
        : null;

    final Widget coverWidget;
    if (imageProvider != null) {
      coverWidget = ClipRRect(
        borderRadius: BorderRadius.circular(ApertonoRadii.cover),
        child: Image(
          image: imageProvider,
          width: coverSize,
          height: coverSize,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _placeholder(),
        ),
      );
    } else {
      coverWidget = _placeholder();
    }

    final playLabel = texts.play(item.meta.title);
    final semanticLabel = remainderText != null
        ? '$playLabel, $remainderText'
        : playLabel;

    return Semantics(
      key: ValueKey('continue-${item.meta.key}'),
      button: true,
      label: semanticLabel,
      onTap: () => onTap(item),
      excludeSemantics: true,
      child: SizedBox(
        width: width,
        child: InkWell(
          onTap: () => onTap(item),
          borderRadius: BorderRadius.circular(ApertonoRadii.cover),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              coverWidget,
              const SizedBox(height: 6),
              Text(
                item.meta.title,
                style: ApertonoText.trackTitle.copyWith(
                  color: ApertonoColors.textPrimary,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                item.meta.subtitle,
                style: ApertonoText.trackArtist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (remainderText != null) ...[
                const SizedBox(height: 2),
                Text(
                  remainderText,
                  style: ApertonoText.trackArtist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
