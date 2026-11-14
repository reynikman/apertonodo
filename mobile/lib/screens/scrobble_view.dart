import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../scrobble_settings.dart';
import '../theme.dart';

/// Body of "Scrobbling" screen: ListenBrainz and Last.fm (FT-644). Does not make requests itself.
class ScrobbleView extends StatefulWidget {
  const ScrobbleView({super.key, required this.settings, required this.onOpen});

  final ScrobbleSettings settings;
  final ValueChanged<Uri> onOpen;

  @override
  State<ScrobbleView> createState() => _ScrobbleViewState();
}

class _ScrobbleViewState extends State<ScrobbleView> {
  final _token = TextEditingController();

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final connected = await widget.settings.connectListenBrainz(_token.text);
    // Screen could be closed while request was in flight: field is already gone.
    if (connected && mounted) _token.clear();
  }

  Future<void> _allow() async {
    final page = await widget.settings.startLastfm();
    if (page != null && mounted) widget.onOpen(page);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.settings,
      builder: (context, _) => _body(context, l10n(context)),
    );
  }

  Widget _button(
    String key,
    String label,
    VoidCallback onPressed, {
    bool outlined = false,
  }) {
    final busy = widget.settings.busy;
    final style = ButtonStyle(
      minimumSize: WidgetStateProperty.all(const Size(48, 48)),
    );
    final child = Text(label, textAlign: TextAlign.center);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: outlined
          ? OutlinedButton(
              key: Key(key),
              style: style,
              onPressed: busy ? null : onPressed,
              child: child,
            )
          : FilledButton(
              key: Key(key),
              style: style,
              onPressed: busy ? null : onPressed,
              child: child,
            ),
    );
  }

  String _stateText(AppLocalizations text, ScrobbleState state) =>
      switch (state) {
        ScrobbleState.on => text.scrobbleStateOn,
        ScrobbleState.badToken => text.scrobbleStateBadToken,
        ScrobbleState.pending => text.scrobbleStatePending,
        _ => text.scrobbleStateOff,
      };

  String _errorText(AppLocalizations text, ScrobbleError error) =>
      switch (error) {
        ScrobbleError.load => text.scrobbleLoadFailed,
        ScrobbleError.tokenShape => text.scrobbleErrorTokenShape,
        ScrobbleError.save => text.scrobbleErrorSave,
        ScrobbleError.lastfmStart => text.scrobbleErrorLastfmStart,
        ScrobbleError.lastfmNotYet => text.scrobbleErrorLastfmNotYet,
        ScrobbleError.lastfmExpired => text.scrobbleErrorLastfmExpired,
      };

  Widget _body(BuildContext context, AppLocalizations text) {
    final settings = widget.settings;
    final error = settings.error;
    final children = <Widget>[];

    if (!settings.loaded) {
      if (error == ScrobbleError.load) {
        children
          ..add(Text(text.scrobbleLoadFailed))
          ..add(
            _button(
              'scrobble-retry',
              text.scrobbleRetry,
              settings.load,
              outlined: true,
            ),
          );
      } else {
        children.add(
          const Center(
            child: CircularProgressIndicator(key: Key('scrobble-loading')),
          ),
        );
      }
    } else {
      final lb = settings.listenbrainz;
      final lastfm = settings.lastfm;
      final whyText = lastfm != ScrobbleState.unavailable
          ? text.scrobbleWhy
          : text.scrobbleWhyLbOnly;
      children
        ..add(
          Text(
            whyText,
            key: const Key('scrobble-why'),
            style: const TextStyle(color: ApertonoColors.textSecondary),
          ),
        )
        ..add(const SizedBox(height: 24))
        ..add(const Text('ListenBrainz', style: ApertonoText.sectionTitle))
        ..add(const SizedBox(height: 4))
        ..add(
          Text(
            _stateText(text, lb),
            key: const Key('scrobble-lb-state'),
            style: const TextStyle(color: ApertonoColors.textSecondary),
          ),
        );
      if (lb == ScrobbleState.on) {
        children.add(
          _button(
            'scrobble-lb-remove',
            text.scrobbleDisconnect,
            settings.removeListenBrainz,
            outlined: true,
          ),
        );
      } else {
        children
          ..add(const SizedBox(height: 12))
          ..add(
            TextField(
              key: const Key('scrobble-lb-token'),
              controller: _token,
              enabled: !settings.busy,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(labelText: text.scrobbleTokenLabel),
            ),
          )
          ..add(
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const Key('scrobble-lb-where'),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => widget.onOpen(
                  Uri.parse('https://listenbrainz.org/settings/'),
                ),
                child: Text(text.scrobbleLbWhere),
              ),
            ),
          )
          ..add(_button('scrobble-lb-connect', text.scrobbleConnect, _connect));
      }

      if (lastfm != ScrobbleState.unavailable) {
        children
          ..add(const SizedBox(height: 32))
          ..add(
            const Text(
              'Last.fm',
              key: Key('scrobble-lastfm'),
              style: ApertonoText.sectionTitle,
            ),
          )
          ..add(const SizedBox(height: 4))
          ..add(
            Text(
              _stateText(text, lastfm),
              key: const Key('scrobble-lastfm-state'),
              style: const TextStyle(color: ApertonoColors.textSecondary),
            ),
          );
        if (lastfm == ScrobbleState.on) {
          children.add(
            _button(
              'scrobble-lastfm-remove',
              text.scrobbleDisconnect,
              settings.removeLastfm,
              outlined: true,
            ),
          );
        } else if (lastfm == ScrobbleState.pending) {
          children
            ..add(
              _button(
                'scrobble-lastfm-finish',
                text.scrobbleLastfmCheck,
                settings.finishLastfm,
              ),
            )
            ..add(
              _button(
                'scrobble-lastfm-remove',
                text.scrobbleLastfmCancel,
                settings.removeLastfm,
                outlined: true,
              ),
            );
        } else {
          children.add(
            _button('scrobble-lastfm-start', text.scrobbleLastfmAllow, _allow),
          );
        }
      }
    }

    if (settings.loaded && error != null) {
      children
        ..add(const SizedBox(height: 16))
        ..add(
          Semantics(
            container: true,
            liveRegion: true,
            child: Text(
              _errorText(text, error),
              key: const Key('scrobble-error'),
              style: const TextStyle(color: ApertonoColors.error),
            ),
          ),
        );
    }

    children
      ..add(const SizedBox(height: 32))
      ..add(
        Text(
          text.scrobbleHint,
          key: const Key('scrobble-hint'),
          style: const TextStyle(color: ApertonoColors.textSecondary),
        ),
      );

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ],
    );
  }
}
