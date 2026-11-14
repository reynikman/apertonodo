import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';

/// Cover art storage on device disk (FT-534).
class CoverStore {
  CoverStore({required this.root, required this.fetch});

  final Directory root;
  final Future<Uint8List?> Function(String path) fetch;
  final Map<String, Future<void>> _inFlight = {};

  static String _fileName(String path) =>
      sha1.convert(utf8.encode(path)).toString();

  File _file(String path) => File('${root.path}/${_fileName(path)}');

  File? fileFor(String path) {
    if (path.isEmpty) return null;
    final file = _file(path);
    return file.existsSync() ? file : null;
  }

  Future<void> keep(String path) {
    if (path.isEmpty) return Future.value();
    final ready = _file(path);
    if (ready.existsSync()) return Future.value();
    final inFlight = _inFlight[path];
    if (inFlight != null) return inFlight;

    final future = _doKeep(path, ready);
    _inFlight[path] = future;
    return future.whenComplete(() => _inFlight.remove(path));
  }

  Future<void> _doKeep(String path, File ready) async {
    Uint8List? bytes;
    try {
      bytes = await fetch(path);
    } catch (_) {
      return;
    }
    if (bytes == null) return;

    try {
      if (!root.existsSync()) {
        await root.create(recursive: true);
      }
      final part = File('${ready.path}.part');
      await part.writeAsBytes(bytes, flush: true);
      await part.rename(ready.path);
    } catch (_) {
      try {
        final part = File('${ready.path}.part');
        if (await part.exists()) {
          await part.delete();
        }
      } catch (_) {}
    }
  }

  Future<void> drop(String path) async {
    if (path.isEmpty) return;
    final ready = _file(path);
    try {
      if (await ready.exists()) {
        await ready.delete();
      }
    } catch (_) {}
    try {
      final part = File('${ready.path}.part');
      if (await part.exists()) {
        await part.delete();
      }
    } catch (_) {}
  }
}

/// Access to local cover art files from widget tree.
class CoverFiles extends InheritedWidget {
  const CoverFiles({super.key, required this.store, required super.child});

  /// `null` until account database is opened. Wrapper is always present: changing root
  /// from `MusicApp` to `CoverFiles(MusicApp)` recreated the entire app, and
  /// open search with entered text was reset in the middle of typing.
  final CoverStore? store;

  static CoverStore? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<CoverFiles>()?.store;
  }

  @override
  bool updateShouldNotify(CoverFiles oldWidget) => store != oldWidget.store;
}
