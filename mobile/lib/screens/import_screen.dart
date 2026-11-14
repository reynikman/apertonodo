import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/track.dart';
import '../server_api.dart';
import '../theme.dart';
import 'library_screens.dart';
import 'parts.dart';

typedef ImportFile = ({String name, Uint8List bytes});

const _maxBytes = 10 * 1024 * 1024;

class ImportFileTooLarge implements Exception {
  const ImportFileTooLarge();
}

Future<ImportFile?> _pickFile() async {
  final file = await FilePicker.pickFile(type: FileType.any);
  if (file == null) return null;
  if ((file.lengthSync() ?? 0) > _maxBytes) {
    throw const ImportFileTooLarge();
  }
  // Do not read a huge file entirely into memory even if picker did not report its size.
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in file.readAsByteStream()) {
    if (bytes.length + chunk.length > _maxBytes) {
      throw const ImportFileTooLarge();
    }
    bytes.add(chunk);
  }
  return (name: file.name, bytes: bytes.takeBytes());
}

/// Selections remain preserved when returning from list to file overview.
class _Selection {
  _Selection(this.list) : favorites = list.favoritesHint;

  final ImportList list;
  final choices = <int, int?>{};
  bool favorites;
}

class ImportScreen extends StatefulWidget {
  const ImportScreen({
    super.key,
    required this.services,
    this.pickFile = _pickFile,
  });

  final Services services;
  final Future<ImportFile?> Function() pickFile;

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  final _text = TextEditingController();
  final _savedLists = <int>{};
  ImportReport? _report;
  List<_Selection> _lists = const [];
  _Selection? _selected;
  String? _error;
  bool _pasting = false;
  bool _busy = false;

  ServerApi get _server => widget.services.server;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _start() {
    setState(() {
      _busy = true;
      _error = null;
    });
    FocusManager.instance.primaryFocus?.unfocus();
  }

  void _failed(Object error) {
    if (!mounted) return;
    final text = l10n(context);
    setState(() {
      _error = switch (error) {
        ImportFileTooLarge() => text.importFileTooLarge,
        ImportFailed(:final message) => message,
        ServerFailed(:final reason) => failureText(reason),
        _ => failureText(ServerFailure.noAnswer),
      };
    });
  }

  void _finish() {
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _create(String? name, Uint8List bytes) async {
    if (bytes.length > _maxBytes) throw const ImportFileTooLarge();
    final report = await _server.createImport(name, bytes);
    if (!mounted) return;
    setState(() {
      _report = report;
      _lists = [for (final list in report.lists) _Selection(list)];
      _selected = _lists.length == 1 ? _lists.single : null;
    });
    _text.clear();
  }

  Future<void> _pick() async {
    if (_busy) return;
    _start();
    try {
      final file = await widget.pickFile();
      if (file != null && mounted) await _create(file.name, file.bytes);
    } catch (error) {
      _failed(error);
    } finally {
      _finish();
    }
  }

  Future<void> _send() async {
    if (_busy) return;
    _start();
    try {
      await _create(null, Uint8List.fromList(utf8.encode(_text.text)));
    } catch (error) {
      _failed(error);
    } finally {
      _finish();
    }
  }

  void _overview() {
    if (_busy) return;
    setState(() {
      _selected = null;
      _error = null;
    });
  }

  void _replace(Widget screen) {
    // _busy remains enabled: old button could still be pressed until animation finishes.
    Navigator.of(context).pushReplacement<void, void>(
      MaterialPageRoute<void>(builder: (_) => screen),
    );
  }

  Future<void> _save(_Selection selection) async {
    if (_busy) return;
    _start();
    try {
      final saved = await _server.saveImport(
        _report!.id,
        list: selection.list.index,
        target: selection.favorites ? 'favorites' : 'playlist',
        choices: selection.choices,
      );
      if (!mounted) return;
      _replace(
        saved.target == 'favorites'
            ? FavoritesScreen(services: widget.services)
            : PlaylistScreen(
                services: widget.services,
                id: saved.playlistId!,
                name: saved.name!,
              ),
      );
    } catch (error) {
      _failed(error);
      _finish();
    }
  }

  Future<void> _saveAll() async {
    if (_busy) return;
    _start();
    try {
      for (final selection in _lists) {
        final list = selection.list;
        if (_savedLists.contains(list.index)) continue;
        await _server.saveImport(
          _report!.id,
          list: list.index,
          target: list.favoritesHint ? 'favorites' : 'playlist',
          choices: selection.choices,
        );
        _savedLists.add(list.index);
        if (!mounted) return;
      }
      _replace(PlaylistsScreen(services: widget.services));
    } catch (error) {
      _failed(error);
      _finish();
    }
  }

  int? _choice(_Selection selection, ImportRow row) =>
      selection.choices.containsKey(row.n) ? selection.choices[row.n] : 0;

  Track? _track(_Selection selection, ImportRow row) {
    if (row.status != 'doubtful') return row.track;
    final choice = _choice(selection, row);
    return choice == null ? null : row.candidates[choice];
  }

  Future<void> _choose(_Selection selection, ImportRow row) async {
    if (_busy) return;
    final text = l10n(context);
    final choice = await showModalBottomSheet<({int? index})>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            Text(text.importChooseTrack, style: ApertonoText.sectionTitle),
            const SizedBox(height: 12),
            for (var i = 0; i < row.candidates.length; i++)
              ListTile(
                key: Key('import-choice-${row.n}-$i'),
                minTileHeight: 64,
                title: Text(
                  row.candidates[i].title,
                  style: ApertonoText.trackTitle,
                ),
                subtitle: Text(
                  '${row.candidates[i].artist} · '
                  '${formatDuration(row.candidates[i].durationMs)}',
                  style: ApertonoText.trackArtist,
                ),
                trailing: _choice(selection, row) == i
                    ? const Icon(Icons.check, color: ApertonoColors.textPrimary)
                    : null,
                onTap: () => Navigator.pop(context, (index: i)),
              ),
            ListTile(
              key: Key('import-choice-${row.n}-none'),
              minTileHeight: 48,
              title: Text(text.importNone, style: ApertonoText.trackTitle),
              trailing: _choice(selection, row) == null
                  ? const Icon(Icons.check, color: ApertonoColors.textPrimary)
                  : null,
              onTap: () => Navigator.pop(context, (index: null)),
            ),
            TextButton(
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => Navigator.pop(context),
              child: Text(text.importCancel),
            ),
          ],
        ),
      ),
    );
    if (choice != null && mounted) {
      setState(() => selection.choices[row.n] = choice.index);
    }
  }

  Widget _input() {
    final text = l10n(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(text.importDescription, style: ApertonoText.trackArtist),
        const SizedBox(height: 24),
        OutlinedButton.icon(
          key: const Key('import-pick-file'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _busy ? null : _pick,
          icon: const Icon(Icons.file_upload_outlined),
          label: Text(text.importPickFile),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const Key('import-paste'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _busy
              ? null
              : () => setState(() {
                  _pasting = true;
                  _error = null;
                }),
          icon: const Icon(Icons.paste),
          label: Text(text.importPasteText),
        ),
        if (_pasting) ...[
          const SizedBox(height: 16),
          TextField(
            key: const Key('import-text'),
            controller: _text,
            enabled: !_busy,
            minLines: 3,
            maxLines: 6,
            style: ApertonoText.trackTitle,
            decoration: InputDecoration(
              labelText: text.importTextHint,
              border: const OutlineInputBorder(
                borderRadius: BorderRadius.all(
                  Radius.circular(ApertonoRadii.medium),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            key: const Key('import-send'),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: _busy ? null : _send,
            child: Text(text.importSend),
          ),
        ],
      ],
    );
  }

  Widget _overviewBody() {
    final text = l10n(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        FilledButton(
          key: const Key('import-save-all'),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _busy ? null : _saveAll,
          child: Text(text.importSaveAll),
        ),
        const SizedBox(height: 16),
        for (final selection in _lists)
          ListTile(
            key: Key('import-list-${selection.list.index}'),
            minTileHeight: 64,
            title: Text(selection.list.name, style: ApertonoText.trackTitle),
            subtitle: Text(
              '${_savedLists.contains(selection.list.index) ? '${text.importSaved} · ' : ''}'
              '${text.importListFound(selection.list.found, selection.list.total)}',
              style: ApertonoText.trackArtist,
            ),
            trailing: const Icon(
              Icons.chevron_right,
              color: ApertonoColors.textSecondary,
            ),
            onTap: _busy || _savedLists.contains(selection.list.index)
                ? null
                : () => setState(() => _selected = selection),
          ),
      ],
    );
  }

  Widget _row(_Selection selection, ImportRow row) {
    final text = l10n(context);
    final track = _track(selection, row);
    final color = track == null
        ? paleColor(context)
        : ApertonoColors.textPrimary;
    final status = track == null
        ? (row.status == 'doubtful' ? text.importNone : text.importNotFound)
        : row.status == 'doubtful'
        ? (selection.choices.containsKey(row.n)
              ? text.importSelected
              : text.importDoubtful)
        : text.importFound;
    return ListTile(
      key: Key('import-row-${row.n}'),
      minTileHeight: 64,
      contentPadding: EdgeInsets.zero,
      title: Text(
        track?.title ?? row.title,
        style: ApertonoText.trackTitle.copyWith(color: color),
      ),
      subtitle: Text(
        '$status · ${track?.artist ?? row.artist}'
        '${track == null || track.durationMs <= 0 ? '' : ' · ${formatDuration(track.durationMs)}'}',
        style: ApertonoText.trackArtist.copyWith(
          color: track == null ? color : ApertonoColors.textSecondary,
        ),
      ),
      trailing: row.status == 'doubtful'
          ? const Icon(Icons.chevron_right, color: ApertonoColors.textSecondary)
          : null,
      onTap: row.status == 'doubtful' && !_busy
          ? () => _choose(selection, row)
          : null,
    );
  }

  Widget _reportBody(_Selection selection) {
    final text = l10n(context);
    final list = selection.list;
    return ListView.builder(
      key: ValueKey(list.index),
      padding: const EdgeInsets.all(16),
      itemCount: list.rows.length + 4,
      itemBuilder: (context, index) => switch (index) {
        0 => Text(
          text.importSummary(
            list.found,
            list.total,
            list.doubtful,
            list.missing,
          ),
          key: const Key('import-summary'),
          style: ApertonoText.trackTitle,
        ),
        1 => MergeSemantics(
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            minTileHeight: 48,
            title: Text(text.importToFavorites, style: ApertonoText.trackTitle),
            trailing: Switch(
              key: const Key('import-to-favorites'),
              value: selection.favorites,
              onChanged: _busy
                  ? null
                  : (value) => setState(() => selection.favorites = value),
            ),
            onTap: _busy
                ? null
                : () => setState(
                    () => selection.favorites = !selection.favorites,
                  ),
          ),
        ),
        2 => FilledButton(
          key: const Key('import-save'),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _busy ? null : () => _save(selection),
          child: Text(text.importSave),
        ),
        3 => Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Text(text.importDoubtfulHint, style: ApertonoText.trackArtist),
        ),
        _ => _row(selection, list.rows[index - 4]),
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = l10n(context);
    final inList = _lists.length > 1 && _selected != null;
    return PopScope(
      canPop: !inList,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _overview();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_selected?.list.name ?? text.importTitle),
          leading: inList ? BackButton(onPressed: _overview) : null,
        ),
        body: SafeArea(
          child: Column(
            children: [
              if (_busy) const LinearProgressIndicator(),
              if (_error case final error?)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    error,
                    style: ApertonoText.trackTitle.copyWith(
                      color: ApertonoColors.error,
                    ),
                  ),
                ),
              Expanded(
                child: _report == null
                    ? _input()
                    : _selected == null
                    ? _overviewBody()
                    : _reportBody(_selected!),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
