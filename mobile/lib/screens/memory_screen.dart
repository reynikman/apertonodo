import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../offline/downloads.dart';
import '../theme.dart';

const _gib = 1024 * 1024 * 1024;

/// Language comes from the screen, not the phone: otherwise a Russian screen string
/// would get "GB" on a phone with an English system language.
String formatGb(int bytes, AppLocalizations text) {
  final gb = bytes / _gib;
  final rounded10 = (gb * 10).round() / 10;
  final formatted = rounded10 == rounded10.truncateToDouble()
      ? '${rounded10.toInt()}'
      : rounded10.toStringAsFixed(1).replaceAll('.', ',');
  return text.memoryGigabytes(formatted);
}

class MemoryScreen extends StatelessWidget {
  const MemoryScreen({super.key, required this.downloads});

  final DownloadsPort downloads;

  bool _isSelected(int gb) {
    if (gb == 0) {
      return downloads.reserveLimitBytes == 0;
    }
    return (downloads.reserveLimitBytes / _gib).round() == gb;
  }

  bool _isEnabled(int gb) {
    if (gb == 0) return true;
    final free = downloads.freeBytes;
    if (free == null) return true;
    return gb * _gib <= (free - _gib);
  }

  Future<void> _confirmRemoveAll(BuildContext context) async {
    final text = l10n(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(text.memoryDeleteAllTitle),
        content: Text(
          text.memoryDeleteAllMessage,
          style: ApertonoText.trackArtist,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(text.memoryCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              text.memoryDelete,
              style: const TextStyle(
                fontFamily: ApertonoFonts.sans,
                color: ApertonoColors.error,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await downloads.removeAll();
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = l10n(context);
    return Scaffold(
      key: const Key('memory-window'),
      appBar: AppBar(title: Text(text.memoryTitle)),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: downloads,
          builder: (context, _) {
            final downloadBytes = downloads.downloadBytes;
            final reserveBytes = downloads.reserveBytes;
            final freeBytes = downloads.freeBytes ?? 0;
            final total = downloadBytes + reserveBytes + freeBytes;

            return SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final whole = constraints.maxWidth;
                      final widthDownloads = total > 0
                          ? whole * downloadBytes / total
                          : 0.0;
                      final widthReserve = total > 0
                          ? whole * reserveBytes / total
                          : 0.0;
                      final widthFree = whole - widthDownloads - widthReserve;

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          ClipRRect(
                            borderRadius: const BorderRadius.all(
                              Radius.circular(ApertonoRadii.hairline),
                            ),
                            child: SizedBox(
                              key: const Key('memory-bar'),
                              width: whole,
                              height: 12,
                              child: Row(
                                children: [
                                  SizedBox(
                                    key: const Key('memory-bar-downloads'),
                                    width: widthDownloads,
                                    height: 12,
                                    child: const ColoredBox(
                                      color: ApertonoColors.accent,
                                    ),
                                  ),
                                  SizedBox(
                                    key: const Key('memory-bar-reserve'),
                                    width: widthReserve,
                                    height: 12,
                                    child: const ColoredBox(
                                      color: ApertonoColors.textSecondary,
                                    ),
                                  ),
                                  SizedBox(
                                    key: const Key('memory-bar-free'),
                                    width: widthFree,
                                    height: 12,
                                    child: const ColoredBox(
                                      color: ApertonoColors.surfaceRaised,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 16,
                            runSpacing: 8,
                            children: [
                              _Legend(
                                color: ApertonoColors.accent,
                                text: text.memoryLegendDownloaded(
                                  formatGb(downloadBytes, text),
                                ),
                              ),
                              _Legend(
                                color: ApertonoColors.textSecondary,
                                text: text.memoryLegendReserve(
                                  formatGb(reserveBytes, text),
                                ),
                              ),
                              _Legend(
                                color: ApertonoColors.surfaceRaised,
                                text: text.memoryLegendFree(
                                  formatGb(freeBytes, text),
                                ),
                              ),
                            ],
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 24),
                  Text(text.memoryReserveTitle, style: ApertonoText.trackTitle),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final gb in [0, 1, 2, 5, 10])
                        ChoiceChip(
                          key: Key('memory-reserve-$gb'),
                          label: Text(
                            gb == 0
                                ? text.memoryReserveOff
                                : text.memoryGigabytes('$gb'),
                          ),
                          selected: _isSelected(gb),
                          onSelected: _isEnabled(gb)
                              ? (_) => downloads.setReserveLimit(gb * _gib)
                              : null,
                        ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  const Divider(),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      text.memoryClearReserve,
                      style: ApertonoText.trackTitle,
                    ),
                    onTap: () => downloads.clearReserve(),
                  ),
                  const Divider(),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      text.memoryDeleteAll,
                      style: const TextStyle(
                        fontFamily: ApertonoFonts.sans,
                        fontSize: 15,
                        height: 19 / 15,
                        fontWeight: FontWeight.w600,
                        color: ApertonoColors.error,
                      ),
                    ),
                    onTap: () => _confirmRemoveAll(context),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.text});

  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(text, style: ApertonoText.trackArtist),
      ],
    );
  }
}
