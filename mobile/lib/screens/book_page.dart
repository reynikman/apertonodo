import 'dart:async';

import 'package:flutter/material.dart';

import '../book_position.dart';
import '../theme.dart';

/// Book page texts (FT-711, P-A84).
class BookPageTexts {
  const BookPageTexts({
    required this.addToShelf,
    required this.addFailed,
    required this.listen,
    required this.continueListening,
    required this.restart,
    required this.removeFromShelf,
    required this.removeConfirm,
    required this.removeYes,
    required this.cancel,
    required this.narrator,
    required this.language,
    required this.duration,
    required this.parts,
    required this.year,
    required this.partsAfterAdding,
    required this.partsCount,
    required this.gone,
    required this.toMyShelf,
  });

  final String addToShelf;
  final String addFailed;
  final String listen;
  final String continueListening;
  final String restart;
  final String removeFromShelf;
  final String removeConfirm;
  final String removeYes;
  final String cancel;
  final String narrator;
  final String language;
  final String duration;
  final String parts;
  final String year;
  final String partsAfterAdding;
  final String Function(int count) partsCount;
  final String gone;
  final String toMyShelf;
}

/// Audiobook data for page (FT-711).
class BookPageInfo {
  const BookPageInfo({
    required this.title,
    this.author,
    this.narrator,
    required this.language,
    this.durationLabel,
    this.parts,
    this.year,
  });

  final String title;
  final String? author;
  final String? narrator;
  final String language;
  final String? durationLabel;
  final int? parts;
  final int? year;
}

/// Book page display mode (FT-711).
enum BookPageMode { notOnShelf, onShelf, gone }

/// Single audiobook screen (FT-711).
class BookPage extends StatefulWidget {
  const BookPage({
    super.key,
    required this.info,
    required this.mode,
    this.position,
    required this.texts,
    this.onAdd,
    this.onListen,
    this.onRestart,
    this.onRemove,
    this.onToShelf,
  });

  final BookPageInfo info;
  final BookPageMode mode;
  final BookPosition? position;
  final BookPageTexts texts;
  final Future<bool> Function()? onAdd;
  final VoidCallback? onListen;
  final FutureOr<void> Function()? onRestart;
  final VoidCallback? onRemove;
  final VoidCallback? onToShelf;

  @override
  State<BookPage> createState() => _BookPageState();
}

class _BookPageState extends State<BookPage> {
  bool _adding = false;
  bool _addFailed = false;
  bool _restarting = false;
  bool _confirmingRemove = false;

  Future<void> _handleAdd() async {
    if (_adding) return;
    setState(() {
      _adding = true;
      _addFailed = false;
    });
    try {
      final success = await widget.onAdd?.call() ?? false;
      if (mounted) {
        setState(() {
          _adding = false;
          _addFailed = !success;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _adding = false;
          _addFailed = true;
        });
      }
    }
  }

  Future<void> _handleRestart() async {
    if (_restarting) return;
    setState(() {
      _restarting = true;
    });
    try {
      await widget.onRestart?.call();
    } catch (_) {
      // Exception does not crash page.
    } finally {
      if (mounted) {
        setState(() {
          _restarting = false;
        });
      }
    }
  }

  Future<void> _handleRemove() async {
    if (_confirmingRemove) return;
    _confirmingRemove = true;
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(
            widget.texts.removeConfirm,
            style: ApertonoText.sectionTitle,
          ),
          actions: [
            TextButton(
              key: const ValueKey('book-remove-cancel'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(widget.texts.cancel),
            ),
            TextButton(
              key: const ValueKey('book-remove-confirm'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(
                widget.texts.removeYes,
                style: const TextStyle(color: ApertonoColors.error),
              ),
            ),
          ],
        ),
      );

      if (confirmed == true && mounted && widget.mode == BookPageMode.onShelf) {
        widget.onRemove?.call();
      }
    } finally {
      _confirmingRemove = false;
    }
  }

  String _buildSummary() {
    final items = <String>[];
    if (widget.info.language.isNotEmpty) {
      items.add(widget.info.language);
    }
    if (widget.info.durationLabel != null &&
        widget.info.durationLabel!.isNotEmpty) {
      items.add(widget.info.durationLabel!);
    }
    if (widget.mode == BookPageMode.onShelf && widget.info.parts != null) {
      items.add(widget.texts.partsCount(widget.info.parts!));
    }
    return items.join(' · ');
  }

  Widget _buildRow(String key, String label, String value) {
    return Padding(
      key: ValueKey(key),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontFamily: ApertonoFonts.sans,
                fontSize: 14,
                color: ApertonoColors.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: const TextStyle(
                fontFamily: ApertonoFonts.sans,
                fontSize: 14,
                color: ApertonoColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildActions() {
    switch (widget.mode) {
      case BookPageMode.notOnShelf:
        return [
          FilledButton(
            key: const ValueKey('book-add'),
            onPressed: _adding ? null : _handleAdd,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
            child: Text(widget.texts.addToShelf),
          ),
          if (_addFailed) ...[
            const SizedBox(height: 12),
            Semantics(
              key: const ValueKey('book-add-failed'),
              liveRegion: true,
              child: Text(
                widget.texts.addFailed,
                style: const TextStyle(
                  fontFamily: ApertonoFonts.sans,
                  fontSize: 14,
                  color: ApertonoColors.textSecondary,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ];

      case BookPageMode.onShelf:
        final isContinue =
            widget.position != null &&
            !widget.position!.finished &&
            (widget.position!.part > 1 || widget.position!.positionMs > 0);
        final listenLabel = isContinue
            ? widget.texts.continueListening
            : widget.texts.listen;

        return [
          FilledButton(
            key: const ValueKey('book-listen'),
            onPressed: widget.onListen,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
            child: Text(listenLabel),
          ),
          if (widget.position != null) ...[
            const SizedBox(height: 12),
            OutlinedButton(
              key: const ValueKey('book-restart'),
              onPressed: _restarting ? null : _handleRestart,
              style: OutlinedButton.styleFrom(
                foregroundColor: ApertonoColors.textPrimary,
                side: const BorderSide(color: ApertonoColors.borderStrong),
                minimumSize: const Size.fromHeight(48),
              ),
              child: Text(widget.texts.restart),
            ),
          ],
          const SizedBox(height: 12),
          OutlinedButton(
            key: const ValueKey('book-remove'),
            onPressed: _handleRemove,
            style: OutlinedButton.styleFrom(
              foregroundColor: ApertonoColors.textSecondary,
              side: const BorderSide(color: ApertonoColors.borderStrong),
              minimumSize: const Size.fromHeight(48),
            ),
            child: Text(widget.texts.removeFromShelf),
          ),
        ];

      case BookPageMode.gone:
        return [
          Text(
            widget.texts.gone,
            key: const ValueKey('book-gone'),
            style: ApertonoText.trackArtist,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          FilledButton(
            key: const ValueKey('book-to-shelf'),
            onPressed: widget.onToShelf,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
            child: Text(widget.texts.toMyShelf),
          ),
        ];
    }
  }

  @override
  Widget build(BuildContext context) {
    final summary = _buildSummary();
    final hasAuthor =
        widget.info.author != null && widget.info.author!.isNotEmpty;

    return Scaffold(
      appBar: AppBar(),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
        children: [
          Text(widget.info.title, style: ApertonoText.screenTitle),
          if (hasAuthor) ...[
            const SizedBox(height: 6),
            Text(
              widget.info.author!,
              style: const TextStyle(
                fontFamily: ApertonoFonts.sans,
                fontSize: 16,
                color: ApertonoColors.textSecondary,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            summary,
            key: const ValueKey('book-summary'),
            style: ApertonoText.trackArtist,
          ),
          if (widget.mode != BookPageMode.gone) ...[
            const SizedBox(height: 24),
            if (widget.info.narrator != null &&
                widget.info.narrator!.isNotEmpty)
              _buildRow(
                'book-row-narrator',
                widget.texts.narrator,
                widget.info.narrator!,
              ),
            if (widget.info.language.isNotEmpty)
              _buildRow(
                'book-row-language',
                widget.texts.language,
                widget.info.language,
              ),
            if (widget.info.durationLabel != null &&
                widget.info.durationLabel!.isNotEmpty)
              _buildRow(
                'book-row-duration',
                widget.texts.duration,
                widget.info.durationLabel!,
              ),
            if (widget.mode == BookPageMode.onShelf) ...[
              if (widget.info.parts != null)
                _buildRow(
                  'book-row-parts',
                  widget.texts.parts,
                  '${widget.info.parts}',
                ),
            ] else ...[
              _buildRow(
                'book-row-parts',
                widget.texts.parts,
                widget.texts.partsAfterAdding,
              ),
            ],
            if (widget.info.year != null)
              _buildRow(
                'book-row-year',
                widget.texts.year,
                '${widget.info.year}',
              ),
          ],
          const SizedBox(height: 32),
          ..._buildActions(),
        ],
      ),
    );
  }
}
