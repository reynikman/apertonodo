import 'package:flutter/material.dart';

import '../theme.dart';

/// Quick row below playback controls (FT-805): "download · lyrics · sleep
/// timer" — three equal unlabeled buttons. No callback means no button,
/// remainder share width.
class PlayerQuickRow extends StatelessWidget {
  const PlayerQuickRow({
    super.key,
    required this.downloadTooltip,
    required this.lyricsTooltip,
    required this.sleepTooltip,
    this.onDownload,
    this.downloaded = false,
    this.onLyrics,
    this.lyricsMissing = false,
    this.onSleep,
    this.sleepActive = false,
  });

  final String downloadTooltip;
  final String lyricsTooltip;
  final String sleepTooltip;
  final VoidCallback? onDownload;
  final bool downloaded;
  final VoidCallback? onLyrics;

  /// The server has answered that this song has no lyrics: the button is dimmed, a tap
  /// still opens the sheet with the explanation.
  final bool lyricsMissing;
  final VoidCallback? onSleep;
  final bool sleepActive;

  @override
  Widget build(BuildContext context) {
    final buttons = <Widget>[
      if (onDownload != null)
        _QuickButton(
          buttonKey: const Key('player-quick-download'),
          tooltip: downloadTooltip,
          selected: downloaded,
          icon: Icons.file_download_outlined,
          selectedIcon: Icons.download_done,
          onPressed: onDownload!,
        ),
      if (onLyrics != null)
        _dimmed(
          lyricsMissing,
          _QuickButton(
            buttonKey: const Key('player-quick-lyrics'),
            tooltip: lyricsTooltip,
            selected: false,
            icon: Icons.notes,
            selectedIcon: Icons.notes,
            onPressed: onLyrics!,
          ),
        ),
      if (onSleep != null)
        _QuickButton(
          buttonKey: const Key('player-quick-sleep'),
          tooltip: sleepTooltip,
          selected: sleepActive,
          icon: Icons.bedtime_outlined,
          selectedIcon: Icons.bedtime,
          onPressed: onSleep!,
        ),
    ];
    if (buttons.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      key: const Key('player-quick'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Row(
        spacing: 8,
        children: [for (final button in buttons) Expanded(child: button)],
      ),
    );
  }
}

Widget _dimmed(bool dim, Widget button) => dim
    ? Opacity(
        key: const Key('player-quick-lyrics-dim'),
        opacity: 0.38,
        child: button,
      )
    : button;

class _QuickButton extends StatelessWidget {
  const _QuickButton({
    required this.buttonKey,
    required this.tooltip,
    required this.selected,
    required this.icon,
    required this.selectedIcon,
    required this.onPressed,
  });

  final Key buttonKey;
  final String tooltip;
  final bool selected;
  final IconData icon;
  final IconData selectedIcon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: buttonKey,
      tooltip: tooltip,
      isSelected: selected,
      icon: Icon(icon),
      selectedIcon: Icon(selectedIcon),
      onPressed: onPressed,
      style: ButtonStyle(
        fixedSize: const WidgetStatePropertyAll(Size(double.infinity, 48)),
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? ApertonoColors.accent
              : ApertonoColors.textPrimary,
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? ApertonoColors.accentSoft
              : states.contains(WidgetState.pressed)
              ? ApertonoColors.surfaceRaised
              : ApertonoColors.surface,
        ),
        side: WidgetStateProperty.resolveWith(
          (states) => BorderSide(
            color: states.contains(WidgetState.selected)
                ? ApertonoColors.accentSoft
                : ApertonoColors.border,
          ),
        ),
        shape: const WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.all(
              Radius.circular(ApertonoRadii.medium),
            ),
          ),
        ),
      ),
    );
  }
}
