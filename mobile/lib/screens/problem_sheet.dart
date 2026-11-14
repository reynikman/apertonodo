import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../server_api.dart';
import '../theme.dart';

/// Where user encountered problem (FT-627). Value names match server keywords
/// in `POST /v1/problems` — `place.name` is sent in report body.
enum ProblemPlace { song, album, artist, playlist, player }

/// Reasons for place, in display order. Identifiers sent in report as `reason`.
List<String> problemReasons(ProblemPlace place) => switch (place) {
  ProblemPlace.song || ProblemPlace.player => const [
    'wrong_track',
    'no_play',
    'bad_sound',
    'cover',
    'wrong_name',
    'other',
  ],
  ProblemPlace.album => const ['cover', 'wrong_name', 'no_play', 'other'],
  ProblemPlace.artist => const ['cover', 'wrong_name', 'other'],
  ProblemPlace.playlist => const ['no_play', 'other'],
};

/// Report body — strictly the fields server accepts (FT-622). Empty field is
/// omitted from body: extraneous fields cause server to reject request.
class ProblemReport {
  const ProblemReport({
    required this.reason,
    required this.place,
    this.trackId,
    this.albumId,
    this.artist,
    this.playlistId,
    required this.appVersion,
    this.text,
  });

  final String reason;
  final ProblemPlace place;
  final String? trackId;
  final String? albumId;
  final String? artist;
  final String? playlistId;
  final String appVersion;
  final String? text;

  Map<String, Object?> toJson() => {
    'reason': reason,
    'place': place.name,
    if (trackId != null) 'track_id': trackId,
    if (albumId != null) 'album_id': albumId,
    if (artist != null) 'artist': artist,
    if (playlistId != null) 'playlist_id': playlistId,
    'app_version': appVersion,
    if (text != null) 'text': text,
  };
}

enum ProblemResult { sent, tooMany, failed }

typedef ProblemSend = Future<ProblemResult> Function(ProblemReport report);

/// "Report a problem" sheet: select reason, optionally add note,
/// submit. Submission callback `send` provided externally — sheet makes no HTTP calls.
class ProblemSheet extends StatefulWidget {
  const ProblemSheet({
    super.key,
    required this.place,
    this.trackId,
    this.albumId,
    this.artist,
    this.playlistId,
    required this.appVersion,
    required this.send,
  });

  final ProblemPlace place;
  final String? trackId;
  final String? albumId;
  final String? artist;
  final String? playlistId;
  final String appVersion;
  final ProblemSend send;

  @override
  State<ProblemSheet> createState() => _ProblemSheetState();
}

class _ProblemSheetState extends State<ProblemSheet> {
  final _text = TextEditingController();
  String? _reason;
  bool _busy = false;
  bool _sent = false;
  ProblemResult? _notice;

  @override
  void initState() {
    super.initState();
    _text.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _text.removeListener(_onTextChanged);
    _text.dispose();
    super.dispose();
  }

  bool get _canSend {
    if (_busy || _sent) return false;
    final words = _text.text.trim();
    if (_reason == null || _reason == 'other') {
      return words.isNotEmpty;
    }
    return true;
  }

  Future<void> _submit() async {
    if (!_canSend) return;
    final words = _text.text.trim();
    final reason = _reason ?? 'other';
    setState(() {
      _reason = reason;
      _busy = true;
      _notice = null;
    });
    ProblemResult result;
    try {
      result = await widget.send(
        ProblemReport(
          reason: reason,
          place: widget.place,
          trackId: widget.trackId,
          albumId: widget.albumId,
          artist: widget.artist,
          playlistId: widget.playlistId,
          appVersion: widget.appVersion,
          text: words.isEmpty ? null : words,
        ),
      );
    } catch (_) {
      result = ProblemResult.failed;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      switch (result) {
        case ProblemResult.sent:
          _sent = true;
        case ProblemResult.tooMany:
        case ProblemResult.failed:
          _notice = result;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = l10n(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(text.problemTitle, style: ApertonoText.sectionTitle),
        ),
        for (final id in problemReasons(widget.place))
          ListTile(
            key: Key('problem-reason-$id'),
            minTileHeight: 48,
            title: Text(_reasonLabel(text, id), style: ApertonoText.trackTitle),
            trailing: _reason == id
                ? const Icon(Icons.check, color: ApertonoColors.accent)
                : null,
            onTap: _sent || _busy ? null : () => setState(() => _reason = id),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TextField(
            key: const Key('problem-text'),
            controller: _text,
            readOnly: _sent,
            minLines: 2,
            maxLines: 3,
            maxLength: 500,
            decoration: InputDecoration(hintText: text.problemTextHint),
          ),
        ),
        if (_notice != null && !_sent)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              _notice == ProblemResult.tooMany
                  ? text.problemTooMany
                  : text.problemFailed,
              style: const TextStyle(color: ApertonoColors.error),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: _sent
              ? ConstrainedBox(
                  key: const Key('problem-sent'),
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.check_circle,
                          color: ApertonoColors.accent,
                        ),
                        const SizedBox(width: 8),
                        Text(text.problemSent, style: ApertonoText.trackTitle),
                      ],
                    ),
                  ),
                )
              : FilledButton(
                  key: const Key('problem-send'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  onPressed: _canSend ? _submit : null,
                  child: _busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            key: Key('problem-sending'),
                            strokeWidth: 2,
                          ),
                        )
                      : Text(text.problemSend),
                ),
        ),
      ],
    );
  }

  String _reasonLabel(AppLocalizations text, String id) => switch (id) {
    'wrong_track' => text.problemReasonWrongTrack,
    'no_play' => text.problemReasonNoPlay,
    'bad_sound' => text.problemReasonBadSound,
    'cover' => text.problemReasonCover,
    'wrong_name' => text.problemReasonWrongName,
    _ => text.problemReasonOther,
  };
}

/// Build version for report: same as for crash reports.
const problemAppVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: 'dev',
);

/// Open bottom sheet "Report a problem"; report is sent to this server.
Future<void> showProblemSheet(
  BuildContext context,
  ServerApi server, {
  required ProblemPlace place,
  String? trackId,
  String? albumId,
  String? artist,
  String? playlistId,
}) => showModalBottomSheet<void>(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  builder: (sheet) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(sheet).bottom),
    child: SingleChildScrollView(
      child: ProblemSheet(
        place: place,
        trackId: trackId,
        albumId: albumId,
        artist: artist,
        playlistId: playlistId,
        appVersion: problemAppVersion,
        send: server.sendProblem,
      ),
    ),
  ),
);
