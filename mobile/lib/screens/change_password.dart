import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../server_api.dart';
import '../theme.dart';

/// FT-856: "Change password" from the account menu. The current password is
/// asked so that a phone left unlocked cannot lock its owner out.
class ChangePasswordDialog extends StatefulWidget {
  const ChangePasswordDialog({super.key, required this.change});

  final Future<PasswordChange> Function(String old, String fresh) change;

  @override
  State<ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<ChangePasswordDialog> {
  final _old = TextEditingController();
  final _fresh = TextEditingController();
  final _repeat = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _old.dispose();
    _fresh.dispose();
    _repeat.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final text = l10n(context);
    if (_fresh.text.length < 8) {
      setState(() => _error = text.loginErrorWeakPassword);
      return;
    }
    if (_fresh.text != _repeat.text) {
      setState(() => _error = text.loginPasswordsDiffer);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await widget.change(_old.text, _fresh.text);
    if (!mounted) return;
    if (result == PasswordChange.changed) {
      Navigator.pop(context, true);
      return;
    }
    setState(() {
      _busy = false;
      _error = switch (result) {
        PasswordChange.wrongOld => text.passwordWrongOld,
        PasswordChange.weak => text.loginErrorWeakPassword,
        _ => text.passwordFailed,
      };
    });
  }

  Widget _field(Key key, TextEditingController controller, String label) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          key: key,
          controller: controller,
          obscureText: true,
          decoration: InputDecoration(labelText: label),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final text = l10n(context);
    return AlertDialog(
      title: Text(text.accountChangePassword),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _field(const Key('password-old'), _old, text.passwordOld),
            _field(const Key('password-new'), _fresh, text.loginNewPassword),
            _field(
              const Key('password-repeat'),
              _repeat,
              text.loginRepeatPassword,
            ),
            if (_error != null)
              Text(
                _error!,
                key: const Key('password-error'),
                style: const TextStyle(color: ApertonoColors.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('password-cancel'),
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: Text(text.accountCancel),
        ),
        FilledButton(
          key: const Key('password-save'),
          onPressed: _busy ? null : _save,
          child: Text(text.passwordSave),
        ),
      ],
    );
  }
}
