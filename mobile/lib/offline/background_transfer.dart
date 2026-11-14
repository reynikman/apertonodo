import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/widgets.dart';

import '../l10n/l10n.dart';
import 'download_queue.dart';

/// System background download via background_downloader (FT-526, Р-A60).
class BackgroundTransfer implements FileTransfer {
  BackgroundTransfer({FileDownloader? downloader})
    : _downloader = downloader ?? FileDownloader() {
    _configure();
  }

  final FileDownloader _downloader;
  static bool _configured = false;

  void _configure() {
    if (_configured) return;
    _configured = true;
    _downloader.configure(
      globalConfig: [(Config.runInForeground, Config.always)],
    );
    // Notification is in device language, single language, like app screens.
    // `{numFinished}` and `{numTotal}` are library substitutions:
    // passed as is into translation string.
    final text = lookupAppLocalizations(
      Locale(
        WidgetsBinding.instance.platformDispatcher.locale.languageCode == 'ru'
            ? 'ru'
            : 'en',
      ),
    );
    _downloader.configureNotificationForGroup(
      'downloads',
      running: TaskNotification(
        'Apertono',
        text.downloadsNotificationProgress('{numFinished}', '{numTotal}'),
      ),
      complete: TaskNotification(
        'Apertono',
        text.downloadsNotificationComplete,
      ),
      progressBar: true,
      groupNotificationId: 'downloads',
    );
  }

  @override
  Future<bool> fetch(TransferJob job) async {
    final (baseDirectory, directory, filename) = await Task.split(
      file: job.file,
    );
    final task = DownloadTask(
      taskId: job.trackId,
      url: job.url.toString(),
      filename: filename,
      directory: directory,
      baseDirectory: baseDirectory,
      headers: job.headers,
      requiresWiFi: job.unmeteredOnly,
      updates: Updates.statusAndProgress,
      allowPause: true,
      group: 'downloads',
    );
    final update = await _downloader.download(task);
    return update.status == TaskStatus.complete && await job.file.exists();
  }

  @override
  Future<void> cancel(String trackId) async {
    await _downloader.cancelTaskWithId(trackId);
  }
}
