import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../auth/foreign_login.dart';
import '../auth/login.dart';
import '../auth/login_errors.dart';
import '../l10n/l10n.dart';
import '../server_kind.dart';
import '../theme.dart';

class LoginWizard extends StatefulWidget {
  const LoginWizard({
    super.key,
    required this.onLogin,
    this.initialServer,
    this.expired = false,
    this.detect,
    this.onForeignLogin,
    this.onClaim,
  });
  final Uri? initialServer;
  final bool expired;
  final Future<void> Function(Uri server, String username, String password)
  onLogin;

  /// Detects server kind by address. Without it and without [onForeignLogin] wizard
  /// does not probe address and behaves as before: server is own.
  final Future<DetectedServer> Function(Uri origin)? detect;

  /// Login to Navidrome or Jellyfin. Without it, foreign server is address error.
  final Future<void> Function(ForeignLogin login)? onForeignLogin;

  /// FT-856: first sign-in with the admin's code; the person makes up the password.
  /// Without it the wizard offers no code link.
  final Future<void> Function(
    Uri server,
    String username,
    String code,
    String password,
  )?
  onClaim;

  @override
  State<LoginWizard> createState() => _LoginWizardState();
}

class _LoginWizardState extends State<LoginWizard> {
  final _address = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  final _repeat = TextEditingController();
  bool _claiming = false;
  bool _differ = false;
  Uri? _server;
  LoginError? _error;
  String? _addressError;
  ServerKind? _kind;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _server = widget.initialServer;
  }

  @override
  void dispose() {
    _address.dispose();
    _username.dispose();
    _password.dispose();
    _code.dispose();
    _repeat.dispose();
    super.dispose();
  }

  Future<void> _next() async {
    if (_busy) return;
    final address = _address.text;
    final origin = serverOrigin(
      address.contains('://') ? address : '${schemeFor(address)}$address',
    );
    final text = l10n(context);
    if (origin == null) {
      setState(() => _addressError = text.loginAddressInvalid);
      return;
    }
    if (widget.detect == null && widget.onForeignLogin == null) {
      setState(() {
        _addressError = null;
        _server = origin;
      });
      return;
    }
    setState(() {
      _busy = true;
      _addressError = null;
    });
    String? error;
    DetectedServer? found;
    try {
      found = await _detect(origin);
    } on ServerDetectError catch (failure) {
      error = failure.kind == ServerDetectFailure.unreachable
          ? text.loginAddressUnreachable
          : text.loginAddressUnsupported;
    }
    if (!mounted) return;
    final kind = found?.kind;
    final foreign = kind == ServerKind.subsonic || kind == ServerKind.jellyfin;
    if (found != null &&
        kind != ServerKind.apertonodo &&
        !(foreign && widget.onForeignLogin != null)) {
      error = text.loginAddressUnsupported;
    }
    setState(() {
      _busy = false;
      _addressError = error;
      if (error == null && found != null) {
        _kind = kind;
        _server = foreign ? found.base : origin;
      }
    });
  }

  /// Back to the address step: after "Log out" the wizard opens on the login step
  /// of the same server, and this is the only way to another one.
  void _changeServer() {
    setState(() {
      _address.text = _server?.origin ?? '';
      _server = null;
      _kind = null;
      _error = null;
      _addressError = null;
      _password.clear();
      _repeat.clear();
      _claiming = false;
    });
  }

  static bool _typedInFull(Uri origin) {
    final host = origin.host;
    if (RegExp(r'^[0-9.]+$').hasMatch(host)) {
      return InternetAddress.tryParse(host) != null;
    }
    return (host.contains('.') && !host.endsWith('.')) || origin.hasPort;
  }

  void _toggleClaim() {
    setState(() {
      _claiming = !_claiming;
      _error = null;
      _differ = false;
      _password.clear();
      _repeat.clear();
    });
  }

  Future<DetectedServer> _detect(Uri origin) {
    final detect = widget.detect;
    if (detect != null) return detect(origin);
    final client = http.Client();
    return detectServer(
      origin.toString(),
      client: client,
    ).whenComplete(client.close);
  }

  Future<void> _submit() async {
    if (_server == null || _busy) return;
    if (_claiming) {
      if (_password.text.length < 8) {
        setState(() {
          _error = LoginError.weakPassword;
          _differ = false;
        });
        return;
      }
      if (_password.text != _repeat.text) {
        setState(() {
          _error = null;
          _differ = true;
        });
        return;
      }
    }
    setState(() {
      _busy = true;
      _error = null;
      _differ = false;
    });
    try {
      final user = _username.text.trim();
      final kind = _kind;
      if (kind == ServerKind.subsonic || kind == ServerKind.jellyfin) {
        await widget.onForeignLogin!(
          ForeignLogin(
            kind: kind!,
            base: _server!,
            username: user,
            password: _password.text,
          ),
        );
      } else if (_claiming) {
        await widget.onClaim!(_server!, user, _code.text, _password.text);
      } else {
        await widget.onLogin(_server!, user, _password.text);
      }
    } on LoginFailed catch (failure) {
      if (mounted) setState(() => _error = failure.reason);
    } finally {
      if (mounted) {
        _password.clear();
        _repeat.clear();
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = l10n(context);
    final server = _server;
    final typed = _address.text;
    // Where Next will go, shown before the tap: owner 13.10, a fixed
    // "https://" in front of the field read as "https only".
    final origin = typed.isEmpty
        ? null
        : serverOrigin(
            typed.contains('://') ? typed : '${schemeFor(typed)}$typed',
          );
    // Half-typed "mus" or "192.168." would read as a real address.
    final target = origin != null && _typedInFull(origin) ? origin : null;
    final theme = apertonoTheme().copyWith(
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ApertonoRadii.medium),
          ),
        ),
      ),
    );
    const fieldDecoration = InputDecoration(
      filled: true,
      fillColor: ApertonoColors.surface,
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(ApertonoRadii.medium)),
        borderSide: BorderSide(color: ApertonoColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(ApertonoRadii.medium)),
        borderSide: BorderSide(color: ApertonoColors.accent),
      ),
    );
    return MaterialApp(
      title: 'Apertono',
      theme: theme,
      darkTheme: theme,
      themeMode: ThemeMode.dark,
      home: Scaffold(
        key: Key(server == null ? 'wizard-address' : 'wizard-login'),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 32, 16, 16),
                children: [
                  Text(
                    text.loginTitle,
                    key: const Key('wizard-title'),
                    style: ApertonoText.screenTitle,
                  ),
                  const SizedBox(height: 24),
                  if (widget.expired) ...[
                    Text(
                      text.loginSessionExpired,
                      key: const Key('session-expired'),
                    ),
                    const SizedBox(height: 16),
                  ],
                  if (server == null) ...[
                    SizedBox(
                      height: 50,
                      child: TextField(
                        key: const Key('server-address-field'),
                        controller: _address,
                        autofocus: true,
                        decoration: fieldDecoration.copyWith(
                          labelText: text.loginServerAddress,
                          hintText: text.loginAddressExample,
                        ),
                        keyboardType: TextInputType.url,
                        onChanged: (_) => setState(() => _addressError = null),
                        onSubmitted: (_) => _next(),
                      ),
                    ),
                    if (target != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        text.loginConnectVia(target.origin),
                        key: const Key('wizard-scheme-note'),
                        style: ApertonoText.trackArtist.copyWith(
                          color: ApertonoColors.textMuted,
                        ),
                      ),
                    ],
                    if (_addressError != null)
                      Text(
                        _addressError!,
                        key: const Key('wizard-address-error'),
                        style: const TextStyle(color: ApertonoColors.error),
                      ),
                    const SizedBox(height: 16),
                    FilledButton(
                      key: const Key('server-address-next'),
                      onPressed: _busy ? null : _next,
                      child: Text(text.loginNext),
                    ),
                  ] else ...[
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            server.origin,
                            key: const Key('wizard-server'),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        TextButton(
                          key: const Key('wizard-change-server'),
                          onPressed: _busy ? null : _changeServer,
                          child: Text(text.loginChangeServer),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 50,
                      child: TextField(
                        key: const Key('login-username'),
                        controller: _username,
                        decoration: fieldDecoration.copyWith(
                          labelText: text.loginUsername,
                        ),
                      ),
                    ),
                    if (_claiming) ...[
                      const SizedBox(height: 12),
                      SizedBox(
                        height: 50,
                        child: TextField(
                          key: const Key('login-code'),
                          controller: _code,
                          textCapitalization: TextCapitalization.characters,
                          autocorrect: false,
                          decoration: fieldDecoration.copyWith(
                            labelText: text.loginCode,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 50,
                      child: TextField(
                        key: const Key('login-password'),
                        controller: _password,
                        obscureText: true,
                        decoration: fieldDecoration.copyWith(
                          labelText: _claiming
                              ? text.loginNewPassword
                              : text.loginPassword,
                        ),
                      ),
                    ),
                    if (_claiming) ...[
                      const SizedBox(height: 12),
                      SizedBox(
                        height: 50,
                        child: TextField(
                          key: const Key('login-repeat'),
                          controller: _repeat,
                          obscureText: true,
                          decoration: fieldDecoration.copyWith(
                            labelText: text.loginRepeatPassword,
                          ),
                        ),
                      ),
                    ],
                    if (_differ)
                      Text(
                        text.loginPasswordsDiffer,
                        key: const Key('wizard-error'),
                        style: const TextStyle(color: ApertonoColors.error),
                      ),
                    if (_error != null)
                      Text(
                        loginErrorText(_error!, text),
                        key: const Key('wizard-error'),
                        style: const TextStyle(color: ApertonoColors.error),
                      ),
                    const SizedBox(height: 16),
                    FilledButton(
                      key: const Key('login-submit'),
                      onPressed: _busy ? null : _submit,
                      child: Text(
                        _claiming ? text.loginClaim : text.loginSignIn,
                      ),
                    ),
                    // A code is only ours: Navidrome and Jellyfin have their own accounts.
                    if (widget.onClaim != null &&
                        _kind != ServerKind.subsonic &&
                        _kind != ServerKind.jellyfin) ...[
                      const SizedBox(height: 8),
                      TextButton(
                        key: const Key('wizard-code-toggle'),
                        onPressed: _busy ? null : _toggleClaim,
                        child: Text(
                          _claiming
                              ? text.loginHavePassword
                              : text.loginHaveCode,
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
