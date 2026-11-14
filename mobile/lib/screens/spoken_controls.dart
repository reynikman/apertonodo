import 'package:flutter/material.dart';
import 'package:music_stream/screens/skip_buttons.dart';
import 'package:music_stream/theme.dart';

/// Spoken audio content kind (podcast or audiobook).
enum SpokenKind { podcast, book }

/// Download state of podcast episode to device.
enum SpokenDownload { none, downloading, done }

/// Playback speed formatting: "1×", "1.25×", "0.5×", "2×".
String speedLabel(double speed) {
  if (speed == speed.roundToDouble()) {
    return '${speed.round()}\u00D7';
  }
  final s = speed
      .toStringAsFixed(2)
      .replaceAll(RegExp(r'0+$'), '')
      .replaceAll(RegExp(r'\.$'), '');
  return '$s\u00D7';
}

/// Text labels for spoken player controls.
class SpokenTexts {
  const SpokenTexts({
    required this.skip,
    required this.speed,
    required this.download,
    required this.downloaded,
    required this.sleep,
    required this.queue,
    required this.parts,
    required this.remaining,
  });

  final SkipTexts skip;
  final String speed;
  final String download;
  final String downloaded;
  final String sleep;
  final String queue;
  final String parts;
  final String remaining;
}

/// Skip buttons row: -15 s on left, +30 s on right, center buttons between them.
class SpokenTransport extends StatelessWidget {
  const SpokenTransport({
    super.key,
    required this.center,
    this.onBack,
    this.onForward,
    required this.texts,
  });

  final List<Widget> center;
  final VoidCallback? onBack;
  final VoidCallback? onForward;
  final SpokenTexts texts;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        SkipButton(
          key: const ValueKey('spoken-back'),
          kind: SkipKind.back,
          onPressed: onBack,
          texts: texts.skip,
        ),
        ...center,
        SkipButton(
          key: const ValueKey('spoken-forward'),
          kind: SkipKind.forward,
          onPressed: onForward,
          texts: texts.skip,
        ),
      ],
    );
  }
}

/// Four control tiles for podcast or audiobook.
class SpokenTiles extends StatelessWidget {
  const SpokenTiles({
    super.key,
    required this.kind,
    required this.speed,
    this.onSpeed,
    required this.sleepActive,
    this.onSleep,
    required this.texts,
    this.download = SpokenDownload.none,
    this.downloadPercent,
    this.onDownload,
    this.onQueue,
    this.onParts,
    this.remaining,
  });

  final SpokenKind kind;
  final double speed;
  final VoidCallback? onSpeed;
  final bool sleepActive;
  final VoidCallback? onSleep;
  final SpokenTexts texts;
  final SpokenDownload download;
  final int? downloadPercent;
  final VoidCallback? onDownload;
  final VoidCallback? onQueue;
  final VoidCallback? onParts;
  final String? remaining;

  @override
  Widget build(BuildContext context) {
    if (kind == SpokenKind.podcast) {
      final (downloadTitle, downloadValue) = switch (download) {
        SpokenDownload.none => (texts.download, null),
        SpokenDownload.downloading => (
          texts.download,
          downloadPercent == null
              ? null
              : '${downloadPercent!.clamp(0, 100)} %',
        ),
        SpokenDownload.done => (texts.downloaded, null),
      };
      final downloadIcon = switch (download) {
        SpokenDownload.none => Icons.download_outlined,
        SpokenDownload.downloading => Icons.downloading,
        SpokenDownload.done => Icons.download_done,
      };

      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SpokenTile(
            tileKey: 'spoken-speed',
            icon: Icons.speed,
            title: texts.speed,
            value: speedLabel(speed),
            onTap: onSpeed,
            selected: speed != 1.0,
          ),
          _SpokenTile(
            tileKey: 'spoken-download',
            icon: downloadIcon,
            title: downloadTitle,
            value: downloadValue,
            onTap: onDownload,
            selected: download == SpokenDownload.done,
          ),
          _SpokenTile(
            tileKey: 'spoken-sleep',
            icon: sleepActive ? Icons.bedtime : Icons.bedtime_outlined,
            title: texts.sleep,
            onTap: onSleep,
            selected: sleepActive,
          ),
          _SpokenTile(
            tileKey: 'spoken-queue',
            icon: Icons.queue_music,
            title: texts.queue,
            onTap: onQueue,
          ),
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SpokenTile(
          tileKey: 'spoken-speed',
          icon: Icons.speed,
          title: texts.speed,
          value: speedLabel(speed),
          onTap: onSpeed,
          selected: speed != 1.0,
        ),
        _SpokenTile(
          tileKey: 'spoken-parts',
          icon: Icons.auto_stories_outlined,
          title: texts.parts,
          onTap: onParts,
        ),
        _SpokenTile(
          tileKey: 'spoken-sleep',
          icon: sleepActive ? Icons.bedtime : Icons.bedtime_outlined,
          title: texts.sleep,
          onTap: onSleep,
          selected: sleepActive,
        ),
        _SpokenTile(
          tileKey: 'spoken-remaining',
          icon: Icons.hourglass_bottom_outlined,
          title: texts.remaining,
          value: remaining,
          isButton: false,
        ),
      ],
    );
  }
}

class _SpokenTile extends StatelessWidget {
  const _SpokenTile({
    required this.tileKey,
    required this.icon,
    required this.title,
    this.value,
    this.onTap,
    this.selected,
    this.isButton = true,
  });

  final String tileKey;
  final IconData icon;
  final String title;
  final String? value;
  final VoidCallback? onTap;
  final bool? selected;
  final bool isButton;

  @override
  Widget build(BuildContext context) {
    final isSelected = selected ?? false;
    final fgColor = isSelected
        ? ApertonoColors.accent
        : ApertonoColors.textSecondary;
    final valueColor = isSelected
        ? ApertonoColors.accent
        : ApertonoColors.textPrimary;

    Widget body = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 20, color: fgColor),
            const SizedBox(height: 4),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: ApertonoFonts.sans,
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: fgColor,
              ),
            ),
            if (value != null) ...[
              const SizedBox(height: 2),
              Text(
                value!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: ApertonoFonts.sans,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: valueColor,
                ),
              ),
            ],
          ],
        ),
      ),
    );

    if (isButton) {
      body = InkWell(
        excludeFromSemantics: true,
        canRequestFocus: false,
        onTap: onTap,
        child: body,
      );
    }

    return Expanded(
      child: Semantics(
        key: ValueKey(tileKey),
        container: true,
        button: isButton,
        enabled: isButton ? onTap != null : null,
        selected: isButton ? selected : null,
        onTap: isButton ? onTap : null,
        child: body,
      ),
    );
  }
}
