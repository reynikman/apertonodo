import 'package:flutter/material.dart';

import '../history_control.dart';
import '../l10n/l10n.dart';
import '../theme.dart';

/// Deadline time by phone clock, always `HH:MM` with leading zeros.
String _clock(DateTime time) {
  final local = time.toLocal();
  final h = local.hour.toString().padLeft(2, '0');
  final m = local.minute.toString().padLeft(2, '0');
  return '$h:$m';
}

/// "Pause history" tile with toggle (FT-634).
///
/// While not paused — hint; during pause — deadline "Until HH:MM"; error
/// on toggle — error text. Listens to [control] to turn off switch
/// when time expires automatically. Turning it on asks for how long
/// (FT-853): an hour, till tomorrow or until turned back on.
class HistoryPauseTile extends StatefulWidget {
  const HistoryPauseTile({super.key, required this.control});

  final HistoryControl control;

  @override
  State<HistoryPauseTile> createState() => _HistoryPauseTileState();
}

class _HistoryPauseTileState extends State<HistoryPauseTile> {
  bool _failed = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.control.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.control.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  Future<void> _toggle(bool value) async {
    if (_busy) return;
    DateTime? until;
    if (value) {
      until = await _askHowLong();
      if (until == null || !mounted || _busy) return;
    }
    _busy = true;
    final ok = await widget.control.setPaused(value, until: until);
    _busy = false;
    if (!mounted) return;
    setState(() => _failed = !ok);
  }

  /// The deadline the person picked, by the phone clock; `null` — the sheet
  /// was closed without a pick.
  Future<DateTime?> _askHowLong() {
    final text = l10n(context);
    final now = widget.control.now;
    final choices = [
      (
        const Key('history-pause-hour'),
        text.historyPauseForHour,
        now.add(const Duration(hours: 1)),
      ),
      (
        const Key('history-pause-tomorrow'),
        text.historyPauseTillTomorrow,
        DateTime(now.year, now.month, now.day + 1),
      ),
      (
        const Key('history-pause-forever'),
        text.historyPauseForever,
        DateTime(now.year + 100, now.month, now.day),
      ),
    ];
    return showModalBottomSheet<DateTime>(
      context: context,
      useRootNavigator: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(text.historyPauseTitle, style: ApertonoText.sectionTitle),
              const SizedBox(height: 12),
              for (final (key, label, until) in choices)
                ListTile(
                  key: key,
                  minTileHeight: 48,
                  contentPadding: EdgeInsets.zero,
                  title: Text(label, style: ApertonoText.trackTitle),
                  onTap: () => Navigator.of(context).pop(until),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// "Until 19:30", "Till tomorrow" for the coming midnight, no clock time
  /// for "until turned back on".
  String _deadline(DateTime until) {
    final text = l10n(context);
    if (widget.control.pausedForever) return text.historyPauseForeverOn;
    final now = widget.control.now;
    final local = until.toLocal();
    if (local == DateTime(now.year, now.month, now.day + 1)) {
      return text.historyPauseTillTomorrow;
    }
    return text.historyPauseUntil(_clock(until));
  }

  @override
  Widget build(BuildContext context) {
    final text = l10n(context);
    final control = widget.control;
    final until = control.pausedUntil;
    final String subtitle;
    if (_failed) {
      subtitle = text.historyError;
    } else if (until != null) {
      subtitle = _deadline(until);
    } else {
      subtitle = text.historyPauseHint;
    }
    return Container(
      key: const Key('history-pause'),
      constraints: const BoxConstraints(minHeight: 48),
      // Single line for TalkBack: title, explanation, and state together.
      child: MergeSemantics(
        child: InkWell(
          onTap: () => _toggle(!control.paused),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        text.historyPauseTitle,
                        style: ApertonoText.trackTitle,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: ApertonoText.trackArtist.copyWith(
                          color: _failed
                              ? ApertonoColors.error
                              : ApertonoColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(value: control.paused, onChanged: _toggle),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Clear history" button with confirmation prompt (FT-634).
///
/// Tap prompts confirmation; only "Clear" calls [HistoryControl.clear].
/// Success calls [onCleared], failure displays error text truthfully.
class HistoryClearButton extends StatefulWidget {
  const HistoryClearButton({
    super.key,
    required this.control,
    required this.onCleared,
  });

  final HistoryControl control;
  final VoidCallback onCleared;

  @override
  State<HistoryClearButton> createState() => _HistoryClearButtonState();
}

class _HistoryClearButtonState extends State<HistoryClearButton> {
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    widget.control.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.control.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  Future<void> _ask() async {
    setState(() => _failed = false);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final t = l10n(ctx);
        return AlertDialog(
          content: Text(t.historyClearQuestion),
          actions: [
            TextButton(
              key: const Key('history-clear-cancel'),
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.historyClearCancel),
            ),
            TextButton(
              key: const Key('history-clear-confirm'),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.historyClearConfirm),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
    final ok = await widget.control.clear();
    if (!mounted) return;
    if (ok) {
      widget.onCleared();
    } else {
      setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = l10n(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          key: const Key('history-clear'),
          constraints: const BoxConstraints(minHeight: 48),
          child: InkWell(
            onTap: _ask,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                children: [
                  const Icon(
                    Icons.delete_outline,
                    color: ApertonoColors.textSecondary,
                  ),
                  const SizedBox(width: 12),
                  Text(text.historyClear, style: ApertonoText.trackTitle),
                ],
              ),
            ),
          ),
        ),
        if (_failed)
          Padding(
            padding: const EdgeInsets.only(left: 8, bottom: 4),
            child: Text(
              text.historyError,
              style: ApertonoText.trackArtist.copyWith(
                color: ApertonoColors.error,
              ),
            ),
          ),
      ],
    );
  }
}

/// "Undo" bar for recently removed row (FT-634).
///
/// Visible while [HistoryControl.canUndo]; button restores row [HistoryControl.undo].
/// Removal failure shown as text. Otherwise empty: no [Text] widgets.
class HistoryUndoBar extends StatelessWidget {
  const HistoryUndoBar({super.key, required this.control});

  final HistoryControl control;

  @override
  Widget build(BuildContext context) {
    final text = l10n(context);
    return AnimatedBuilder(
      animation: control,
      builder: (context, _) {
        // Previous row failure does not revoke "Undo" for subsequent row.
        if (!control.canUndo && !control.removeFailed) {
          return const SizedBox.shrink();
        }
        final undo = Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  text.historyRemoved,
                  style: ApertonoText.trackArtist,
                ),
              ),
              SizedBox(
                height: 48,
                child: TextButton(
                  key: const Key('history-undo'),
                  onPressed: control.undo,
                  child: Text(text.historyUndo),
                ),
              ),
            ],
          ),
        );
        final failed = Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Text(
            text.historyRemoveFailed,
            style: ApertonoText.trackArtist.copyWith(
              color: ApertonoColors.error,
            ),
          ),
        );
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (control.removeFailed) failed,
            if (control.canUndo) undo,
          ],
        );
      },
    );
  }
}
