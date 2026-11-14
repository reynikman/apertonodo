import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../theme.dart';

/// Account header in "My Music".
///
/// Previously positioned on separate line above entire app without safe area
/// inset, overlapping system status bar and clock.
class AccountBar extends StatelessWidget {
  const AccountBar({
    super.key,
    this.text,
    required this.onAction,
    this.automaticReports = false,
    this.newsEnabled = true,
    this.quality = false,
    this.equalizer = false,
    this.update = false,
    this.changePassword = false,
  });

  /// Localized label by device language (deprecated after FT-605, strings come from l10n).
  final String Function(String en, String ru)? text;

  final bool automaticReports;

  /// "News" feed enabled (FT-581). Switch is located here.
  final bool newsEnabled;

  /// Audio quality (FT-804) — "Audio quality" menu item.
  final bool quality;

  /// Equalizer present (FT-621) — "Equalizer" menu item.
  final bool equalizer;

  /// Updates enabled (FT-768) — "Check for updates" menu item.
  final bool update;

  /// Own server (FT-856) — "Change password" menu item.
  final bool changePassword;

  /// `logout`, `switch-server`, `auto-reports`, `news-switch`, `sound-quality`, `equalizer`, `scrobble`, `check-update` or `change-password`.
  final void Function(String action) onAction;

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (context) => IconButton(
        key: const Key('account-button'),
        onPressed: () => _menu(context),
        tooltip: l10n(context).accountTitle,
        icon: const Icon(
          Icons.account_circle_outlined,
          color: ApertonoColors.textPrimary,
        ),
      ),
    );
  }

  Future<void> _menu(BuildContext context) async {
    final text = l10n(context);
    final navigator = Navigator.of(context);
    final button = context.findRenderObject()! as RenderBox;
    final overlay = navigator.overlay!.context.findRenderObject()! as RenderBox;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        button.localToGlobal(Offset.zero, ancestor: overlay) & button.size,
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          key: const Key('auto-reports'),
          value: 'auto-reports',
          child: Row(
            children: [
              Expanded(child: Text(text.accountAutoReports)),
              const SizedBox(width: 12),
              IgnorePointer(
                child: Switch(value: automaticReports, onChanged: (_) {}),
              ),
            ],
          ),
        ),
        PopupMenuItem(
          key: const Key('news-switch'),
          value: 'news-switch',
          child: Row(
            children: [
              Expanded(child: Text(text.accountNews)),
              const SizedBox(width: 12),
              IgnorePointer(
                child: Switch(value: newsEnabled, onChanged: (_) {}),
              ),
            ],
          ),
        ),
        for (final (action, title) in [
          if (update) ('check-update', text.updateCheck),
          if (quality) ('sound-quality', text.qualityTitle),
          if (equalizer) ('equalizer', text.equalizerTitle),
          ('scrobble', text.accountScrobble),
          if (changePassword) ('change-password', text.accountChangePassword),
          ('logout', text.accountLogout),
          ('switch-server', text.accountSwitchServer),
          ('about', text.aboutTitle),
        ])
          PopupMenuItem(key: Key(action), value: action, child: Text(title)),
      ],
    );
    if (action == null) return;
    if (!navigator.mounted) return;

    late final String title;
    late final String confirmLabel;
    switch (action) {
      case 'sound-quality':
      case 'equalizer':
      case 'scrobble':
      case 'check-update':
      case 'change-password':
        onAction(action);
        return;
      case 'logout':
        title = text.accountLogoutConfirm;
        confirmLabel = text.accountLogout;
        break;
      case 'switch-server':
        title = text.accountSwitchServerConfirm;
        confirmLabel = text.accountSwitchServer;
        break;
      case 'auto-reports':
        if (automaticReports) {
          onAction(action);
          return;
        }
        final reportsConfirmed = await showDialog<bool>(
          context: navigator.context,
          builder: (dialogContext) {
            final dialogText = l10n(dialogContext);
            return AlertDialog(
              title: Text(dialogText.accountAutoReportsConfirm),
              content: Text(dialogText.accountAutoReportsDescription),
              actions: [
                TextButton(
                  key: const Key('reports-cancel'),
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: Text(dialogText.accountCancel),
                ),
                FilledButton(
                  key: const Key('reports-confirm'),
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: Text(dialogText.accountSendReports),
                ),
              ],
            );
          },
        );
        if (reportsConfirmed == true) onAction(action);
        return;
      case 'news-switch':
        // Toggle news feed immediately: this does not log out from account.
        onAction(action);
        return;
      case 'about':
        _about(navigator.context);
        return;
      default:
        return;
    }

    if (!navigator.mounted) return;
    final confirmed = await showDialog<bool>(
      context: navigator.context,
      builder: (dialogContext) {
        final dialogText = l10n(dialogContext);
        return AlertDialog(
          title: Text(title),
          content: Text(dialogText.accountLeaveWarning),
          actions: [
            TextButton(
              key: const Key('leave-cancel'),
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(dialogText.accountCancel),
            ),
            FilledButton(
              key: const Key('leave-confirm'),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(dialogContext).colorScheme.error,
                foregroundColor: Theme.of(dialogContext).colorScheme.onError,
              ),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(confirmLabel),
            ),
          ],
        );
      },
    );
    if (confirmed == true) onAction(action);
  }

  /// FT-861: thanks to the sources the app is built on (owner 13.10 on
  /// LRCLIB: "обязательно, в знак благодарности") and the licences.
  void _about(BuildContext context) {
    final text = l10n(context);
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Apertono'),
        content: SingleChildScrollView(child: Text(text.aboutCredits)),
        actions: [
          TextButton(
            key: const Key('about-licenses'),
            onPressed: () {
              Navigator.pop(dialogContext);
              showLicensePage(context: context, applicationName: 'Apertono');
            },
            child: Text(text.aboutLicenses),
          ),
          FilledButton(
            key: const Key('about-close'),
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(text.aboutClose),
          ),
        ],
      ),
    );
  }
}
