import 'package:flutter/material.dart';

import '../audio_info.dart';
import '../l10n/l10n.dart';
import '../models/track.dart';
import '../player.dart';
import '../theme.dart';
import 'parts.dart';
import 'problem_sheet.dart';
import 'rating_controls.dart';

/// Catalog song ID is a UUID; only with it server accepts report and rating.
final _songId = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);

/// Open three-dots sheet for music player (FT-807).
Future<void> showPlayerMenuSheet(
  BuildContext context, {
  required Player player,
  required Track current,
  Services? services,
}) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: ApertonoColors.surfaceRaised,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(ApertonoRadii.xLarge),
      ),
    ),
    builder: (sheetContext) => PlayerMenuSheet(
      player: player,
      current: current,
      services: services,
      parentContext: context,
    ),
  );
}

class PlayerMenuSheet extends StatelessWidget {
  const PlayerMenuSheet({
    super.key,
    required this.player,
    required this.current,
    this.services,
    required this.parentContext,
  });

  final Player player;
  final Track current;
  final Services? services;
  final BuildContext parentContext;

  @override
  Widget build(BuildContext context) {
    final text = l10n(context);
    final ratings = services?.ratings;
    final hasRatings = ratings != null && _songId.hasMatch(current.id);

    final songItems = <Widget>[
      if (services != null)
        _MenuSheetItem(
          itemKey: const Key('player-add-to-playlist'),
          icon: Icons.playlist_add,
          label: text.playerAddToPlaylist,
          onTap: () {
            Navigator.of(context).pop();
            addToPlaylist(parentContext, services!, current);
          },
        ),
      if (hasRatings)
        _MenuSheetItem(
          itemKey: const Key('player-rate'),
          icon: Icons.star_border,
          label: text.playerRate,
          onTap: () {
            Navigator.of(context).pop();
            showRatingSheet(parentContext, ratings, current.id);
          },
        ),
      if (hasRatings)
        ListenableBuilder(
          listenable: ratings,
          builder: (context, _) {
            final disliked = ratings.ratingOf(current.id).disliked;
            return _MenuSheetItem(
              itemKey: const Key('player-dislike'),
              icon: disliked ? Icons.thumb_down : Icons.thumb_down_off_alt,
              label: disliked ? text.playerUndislike : text.ratingDislike,
              accent: disliked,
              onTap: () {
                Navigator.of(context).pop();
                ratings.setDisliked(current.id, !disliked);
              },
            );
          },
        ),
    ];

    final goItems = <Widget>[
      if (services?.openArtist case final openArtist?)
        _MenuSheetItem(
          itemKey: const Key('player-to-artist'),
          icon: Icons.person_outline,
          label: text.partsOpenArtist,
          onTap: () {
            Navigator.of(context).pop();
            openArtist(current.artist);
          },
        ),
      if (services != null && !current.missing && services?.openPage != null)
        _MenuSheetItem(
          itemKey: const Key('player-to-album'),
          icon: Icons.album_outlined,
          label: text.partsOpenAlbum,
          onTap: () {
            Navigator.of(context).pop();
            openTrackAlbum(
              parentContext,
              services!,
              current,
              services!.openPage!,
              still: () => player.current?.id == current.id,
            );
          },
        ),
    ];

    // Catalog song, format is known and not lossless (FT-809).
    final once = services?.losslessOnce;
    final format = services?.formats?.of(current.id);
    final soundItems = <Widget>[
      if (once != null &&
          format != null &&
          _songId.hasMatch(current.id) &&
          !AudioInfo(format).lossless)
        _MenuSheetItem(
          itemKey: const Key('player-lossless-once'),
          icon: Icons.graphic_eq,
          label: text.playerLosslessOnce,
          onTap: () {
            // Sheet context is disposed after pop: grab everything needed in advance.
            final messenger = ScaffoldMessenger.of(parentContext);
            final message = text.playerLosslessMissed;
            final formats = services!.formats!;
            Navigator.of(context).pop();
            once.ask(current.id);
            player.reloadCurrent().then((_) {
              final now = formats.of(current.id);
              if (player.failure == null &&
                  player.current?.id == current.id &&
                  now != null &&
                  !AudioInfo(now).lossless) {
                messenger.showSnackBar(SnackBar(content: Text(message)));
              }
            });
          },
        ),
    ];

    final helpItems = <Widget>[
      if (services != null && _songId.hasMatch(current.id))
        _MenuSheetItem(
          itemKey: const Key('player-problem'),
          icon: Icons.outlined_flag,
          label: text.problemTitle,
          onTap: () {
            Navigator.of(context).pop();
            showProblemSheet(
              parentContext,
              services!.server,
              place: ProblemPlace.player,
              trackId: current.id,
            );
          },
        ),
    ];

    return Material(
      key: const Key('player-menu-sheet'),
      color: ApertonoColors.surfaceRaised,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(ApertonoRadii.xLarge),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.symmetric(vertical: 8),
                decoration: const BoxDecoration(
                  color: ApertonoColors.borderStrong,
                  borderRadius: BorderRadius.all(
                    Radius.circular(ApertonoRadii.hairline),
                  ),
                ),
              ),
            ),
            Padding(
              key: const Key('player-menu-head'),
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: Row(
                children: [
                  services != null
                      ? Cover(
                          server: services!.server,
                          path: coverPath(current),
                          artist: current.artist,
                          size: 44,
                          radius: ApertonoRadii.cover,
                        )
                      : ArtistSquare(
                          current.artist,
                          size: 44,
                          radius: ApertonoRadii.cover,
                        ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          current.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: ApertonoFonts.sans,
                            fontSize: 15,
                            height: 19 / 15,
                            fontWeight: FontWeight.w600,
                            color: ApertonoColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          current.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: ApertonoFonts.sans,
                            fontSize: 12.5,
                            height: 16 / 12.5,
                            color: ApertonoColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(
              color: ApertonoColors.divider,
              height: 1,
              thickness: 1,
            ),
            if (songItems.isNotEmpty) ...[
              _SectionHeader(
                headerKey: const Key('player-menu-song'),
                title: text.playerMenuSong.toUpperCase(),
              ),
              ...songItems,
            ],
            if (goItems.isNotEmpty) ...[
              _SectionHeader(
                headerKey: const Key('player-menu-go'),
                title: text.playerMenuGo.toUpperCase(),
              ),
              ...goItems,
            ],
            if (soundItems.isNotEmpty) ...[
              _SectionHeader(
                headerKey: const Key('player-menu-sound'),
                title: text.playerMenuSound.toUpperCase(),
              ),
              ...soundItems,
            ],
            if (helpItems.isNotEmpty) ...[
              _SectionHeader(
                headerKey: const Key('player-menu-help'),
                title: text.playerMenuHelp.toUpperCase(),
              ),
              ...helpItems,
            ],
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.headerKey, required this.title});

  final Key headerKey;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: headerKey,
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
      child: Text(
        title,
        style: const TextStyle(
          fontFamily: ApertonoFonts.sans,
          fontSize: 11.5,
          height: 14 / 11.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.6,
          color: ApertonoColors.textMuted,
        ),
      ),
    );
  }
}

class _MenuSheetItem extends StatelessWidget {
  const _MenuSheetItem({
    required this.itemKey,
    required this.icon,
    required this.label,
    required this.onTap,
    this.accent = false,
  });

  final Key itemKey;
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final iconColor = accent
        ? ApertonoColors.accent
        : ApertonoColors.textSecondary;
    final textColor = accent
        ? ApertonoColors.accent
        : ApertonoColors.textPrimary;
    return InkWell(
      key: itemKey,
      onTap: onTap,
      child: SizedBox(
        height: 48,
        child: Row(
          children: [
            const SizedBox(width: 24),
            Icon(icon, size: 22, color: iconColor),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: ApertonoFonts.sans,
                  fontSize: 15,
                  height: 19 / 15,
                  color: textColor,
                ),
              ),
            ),
            const SizedBox(width: 24),
          ],
        ),
      ),
    );
  }
}
