import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'app_update.dart';

/// Update source from GitHub Releases (FT-768).
class GithubUpdateSource implements UpdateSource {
  GithubUpdateSource({required this.repo, this.client});

  final String repo;
  final http.Client? client;

  @override
  Future<UpdateInfo?> latest() async {
    final c = client ?? http.Client();
    final shouldClose = client == null;
    try {
      final uri = Uri.parse(
        'https://api.github.com/repos/$repo/releases?per_page=10',
      );
      final response = await c
          .get(uri, headers: const {'Accept': 'application/vnd.github+json'})
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        return null;
      }
      final json = jsonDecode(response.body);
      if (json is! List) {
        return null;
      }
      // `releases/latest` hides pre-releases (the beta is one): take the newest
      // non-draft by version, not by GitHub order (an old beta may be published later).
      UpdateInfo? best;
      for (final item in json) {
        if (item is! Map || item['draft'] == true) continue;
        final info = updateFromGithubRelease(Map<String, Object?>.from(item));
        if (info == null) continue;
        if (best == null || isNewerVersion(info.version, than: best.version)) {
          best = info;
        }
      }
      return best;
    } catch (_) {
      return null;
    } finally {
      if (shouldClose) {
        c.close();
      }
    }
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// Downloads APK, verifies sha256 and passes to Android installer (FT-768).
class ApkInstaller implements UpdateInstaller {
  ApkInstaller({
    this.client,
    required this.dir,
    this.channel = const MethodChannel('apertono/update'),
  });

  final http.Client? client;
  final Future<Directory> Function() dir;
  final MethodChannel channel;
  bool _isInstalling = false;

  @override
  Stream<double> install(UpdateInfo info) async* {
    if (_isInstalling) {
      throw StateError('Install already in progress');
    }
    _isInstalling = true;

    final c = client ?? http.Client();
    final shouldClose = client == null;
    File? file;
    IOSink? sink;

    try {
      final directory = await dir();
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
      file = File('${directory.path}/update-${info.version}.apk');
      if (await file.exists()) {
        await file.delete();
      }

      final request = http.Request('GET', info.apk);
      final response = await c.send(request);
      if (response.statusCode != 200) {
        throw HttpException(
          'Failed to download APK: status ${response.statusCode}',
          uri: info.apk,
        );
      }

      final totalBytes =
          info.bytes ??
          (response.contentLength != null && response.contentLength! > 0
              ? response.contentLength
              : null);

      sink = file.openWrite();
      final digestSink = _DigestSink();
      final digestInput = sha256.startChunkedConversion(digestSink);

      var receivedBytes = 0;

      await for (final chunk in response.stream) {
        sink.add(chunk);
        digestInput.add(chunk);
        receivedBytes += chunk.length;
        if (totalBytes != null && totalBytes > 0) {
          final share = (receivedBytes / totalBytes).clamp(0.0, 1.0);
          yield share;
        }
      }

      await sink.flush();
      await sink.close();
      sink = null;
      digestInput.close();

      final actualSha256 = digestSink.value.toString().toLowerCase();
      final expectedSha256 = info.sha256.toLowerCase();

      if (actualSha256 != expectedSha256) {
        if (await file.exists()) {
          await file.delete();
        }
        throw StateError(
          'Checksum mismatch: expected $expectedSha256, got $actualSha256',
        );
      }

      await channel.invokeMethod('install', {'path': file.path});
      yield 1.0;
    } catch (e) {
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {}
      }
      if (file != null && await file.exists()) {
        try {
          await file.delete();
        } catch (_) {}
      }
      rethrow;
    } finally {
      _isInstalling = false;
      if (shouldClose) {
        c.close();
      }
    }
  }
}
