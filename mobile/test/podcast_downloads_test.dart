import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/offline/download_queue.dart';
import 'package:music_stream/offline/track_store.dart';
import 'package:music_stream/podcast_downloads.dart';

const feed = 'https://example.org/feed.xml';
const guid = 'ep-1';
const audio = 'https://cdn.example.org/audio/ep1.mp3';

class FakeStore implements EpisodeStore {
  FakeStore(this.dir);
  final Directory dir;
  final Map<String, File> ready = {};
  final List<(String, String, Hold)> commits = [];
  final List<String> removed = [];
  bool room = true;
  Completer<void>? commitGate;
  final Completer<void> commitStarted = Completer<void>();
  Completer<void>? fileForGate;
  bool fileForThrows = false;

  String _name(String id) => id.hashCode.toUnsigned(32).toString();

  @override
  File partFile(String id, {required String format}) =>
      File('${dir.path}/${_name(id)}.$format.part');

  @override
  Future<File> commit(
    String id, {
    required String format,
    required Hold hold,
  }) async {
    if (!commitStarted.isCompleted) commitStarted.complete();
    final gate = commitGate;
    if (gate != null) await gate.future;
    commits.add((id, format, hold));
    final file = await partFile(
      id,
      format: format,
    ).rename('${dir.path}/${_name(id)}.$format');
    ready[id] = file;
    return file;
  }

  @override
  Future<File?> fileFor(String id) async {
    final gate = fileForGate;
    if (gate != null) {
      fileForGate = null;
      await gate.future;
    }
    if (fileForThrows) throw const FileSystemException('closed');
    return ready[id];
  }

  @override
  Future<void> remove(String id) async {
    removed.add(id);
    final file = ready.remove(id);
    if (file != null && await file.exists()) await file.delete();
  }

  @override
  Future<bool> roomForDownload() async => room;
}

class FakeTransfer implements FileTransfer {
  final List<TransferJob> jobs = [];
  final List<String> cancelled = [];
  final Map<String, Completer<bool>> pending = {};
  bool cancelThrows = false;

  @override
  Future<bool> fetch(TransferJob job) {
    jobs.add(job);
    final done = Completer<bool>();
    pending[job.trackId] = done;
    return done.future;
  }

  Future<void> finish(String id, {bool ok = true, int bytes = 10}) async {
    final job = jobs.lastWhere((j) => j.trackId == id);
    await job.file.writeAsBytes(List.filled(bytes, 7));
    pending.remove(id)!.complete(ok);
    await pumpAsync();
    // Download completes with real file: temporary renamed or
    // deleted. Under load (full check.sh) twenty ticks was insufficient
    // (FT-740) — wait for file itself, up to 2 s.
    for (var i = 0; i < 400 && job.file.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await pumpAsync();
  }

  @override
  Future<void> cancel(String trackId) async {
    cancelled.add(trackId);
    if (cancelThrows) throw const SocketException('cancel');
  }
}

Future<void> pumpAsync() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late Directory dir;
  late FakeStore store;
  late FakeTransfer transfer;
  late bool metered;
  late bool mobileAllowed;
  late PodcastDownloads downloads;
  late int notifications;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('podcast_dl');
    store = FakeStore(dir);
    transfer = FakeTransfer();
    metered = false;
    mobileAllowed = false;
    downloads = PodcastDownloads(
      store: store,
      transfer: transfer,
      isMetered: () async => metered,
      allowMobile: () async => mobileAllowed,
    );
    notifications = 0;
    downloads.addListener(() => notifications++);
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  final id = PodcastDownloads.idFor(feed, guid);

  test('new episode — none', () {
    expect(downloads.stateOf(feed, guid), EpisodeDownloadState.none);
  });

  test('id distinguishes podcasts and episodes', () {
    expect(
      PodcastDownloads.idFor(feed, 'a'),
      isNot(PodcastDownloads.idFor(feed, 'b')),
    );
    expect(
      PodcastDownloads.idFor('https://a/x', guid),
      isNot(PodcastDownloads.idFor('https://b/x', guid)),
    );
    expect(PodcastDownloads.idFor(feed, guid), startsWith('podcast:'));
  });

  test('format by extension, mp3 by default', () {
    expect(
      PodcastDownloads.formatOf(Uri.parse('https://a/b/c.M4A?x=1')),
      'm4a',
    );
    expect(PodcastDownloads.formatOf(Uri.parse('https://a/b/c.ogg')), 'ogg');
    expect(PodcastDownloads.formatOf(Uri.parse('https://a/b/c.opus')), 'opus');
    expect(PodcastDownloads.formatOf(Uri.parse('https://a/b/c.aac')), 'aac');
    expect(PodcastDownloads.formatOf(Uri.parse('https://a/b/c.mp3')), 'mp3');
    expect(
      PodcastDownloads.formatOf(Uri.parse('https://a/b/play?id=3')),
      'mp3',
    );
  });

  test(
    'download: task without headers and token, status state is downloading',
    () async {
      final result = await downloads.download(
        feedUrl: feed,
        guid: guid,
        enclosureUrl: audio,
      );
      expect(result, EpisodeDownloadResult.started);
      expect(downloads.stateOf(feed, guid), EpisodeDownloadState.downloading);
      expect(transfer.jobs, hasLength(1));
      final job = transfer.jobs.single;
      expect(job.trackId, id);
      expect(job.url, Uri.parse(audio));
      expect(job.headers, isEmpty);
      expect(job.file.path, store.partFile(id, format: 'mp3').path);
      expect(job.unmeteredOnly, isTrue);
      expect(notifications, greaterThan(0));
    },
  );

  test('cellular allowed — unmeteredOnly false', () async {
    mobileAllowed = true;
    metered = true;
    final result = await downloads.download(
      feedUrl: feed,
      guid: guid,
      enclosureUrl: audio,
    );
    expect(result, EpisodeDownloadResult.started);
    expect(transfer.jobs.single.unmeteredOnly, isFalse);
  });

  test(
    'cellular forbidden and network is metered — metered, no task created',
    () async {
      metered = true;
      final result = await downloads.download(
        feedUrl: feed,
        guid: guid,
        enclosureUrl: audio,
      );
      expect(result, EpisodeDownloadResult.metered);
      expect(transfer.jobs, isEmpty);
      expect(downloads.stateOf(feed, guid), EpisodeDownloadState.none);
    },
  );

  test('no space — noRoom, no task', () async {
    store.room = false;
    final result = await downloads.download(
      feedUrl: feed,
      guid: guid,
      enclosureUrl: audio,
    );
    expect(result, EpisodeDownloadResult.noRoom);
    expect(transfer.jobs, isEmpty);
    expect(downloads.stateOf(feed, guid), EpisodeDownloadState.none);
  });

  test('bad URL — badUrl, no task', () async {
    for (final bad in [
      '',
      'ftp://a/b.mp3',
      'file:///sdcard/a.mp3',
      'not a url',
      'https:///x.mp3',
    ]) {
      final result = await downloads.download(
        feedUrl: feed,
        guid: guid,
        enclosureUrl: bad,
      );
      expect(result, EpisodeDownloadResult.badUrl, reason: bad);
    }
    expect(transfer.jobs, isEmpty);
  });

  test('http allowed (many feeds without https)', () async {
    final result = await downloads.download(
      feedUrl: feed,
      guid: guid,
      enclosureUrl: 'http://cdn.example.org/a.mp3',
    );
    expect(result, EpisodeDownloadResult.started);
  });

  test(
    'success: commit with Hold.download and format, onPhone, file exists',
    () async {
      await downloads.download(
        feedUrl: feed,
        guid: guid,
        enclosureUrl: 'https://cdn.example.org/a.m4a',
      );
      await transfer.finish(id);
      expect(store.commits, [(id, 'm4a', Hold.download)]);
      expect(downloads.stateOf(feed, guid), EpisodeDownloadState.onPhone);
      final file = await downloads.fileFor(feed, guid);
      expect(file, isNotNull);
      expect(await file!.exists(), isTrue);
    },
  );

  test('repeated tap during download — no second task', () async {
    await downloads.download(feedUrl: feed, guid: guid, enclosureUrl: audio);
    final again = await downloads.download(
      feedUrl: feed,
      guid: guid,
      enclosureUrl: audio,
    );
    expect(again, EpisodeDownloadResult.alreadyThere);
    expect(transfer.jobs, hasLength(1));
  });

  test('already on phone — alreadyThere, no task', () async {
    await downloads.download(feedUrl: feed, guid: guid, enclosureUrl: audio);
    await transfer.finish(id);
    final again = await downloads.download(
      feedUrl: feed,
      guid: guid,
      enclosureUrl: audio,
    );
    expect(again, EpisodeDownloadResult.alreadyThere);
    expect(transfer.jobs, hasLength(1));
  });

  test(
    'file in storage from previous run — alreadyThere and onPhone',
    () async {
      final part = store.partFile(id, format: 'mp3');
      await part.writeAsBytes([1, 2, 3]);
      await store.commit(id, format: 'mp3', hold: Hold.download);
      final result = await downloads.download(
        feedUrl: feed,
        guid: guid,
        enclosureUrl: audio,
      );
      expect(result, EpisodeDownloadResult.alreadyThere);
      expect(downloads.stateOf(feed, guid), EpisodeDownloadState.onPhone);
      expect(transfer.jobs, isEmpty);
    },
  );

  test('downloader rejected — failed, partial file deleted', () async {
    await downloads.download(feedUrl: feed, guid: guid, enclosureUrl: audio);
    final part = transfer.jobs.single.file;
    await transfer.finish(id, ok: false);
    expect(downloads.stateOf(feed, guid), EpisodeDownloadState.failed);
    expect(await part.exists(), isFalse);
    expect(store.commits, isEmpty);
  });

  test('downloader threw exception — failed, no crash', () async {
    final throwing = _ThrowingTransfer();
    final d = PodcastDownloads(
      store: store,
      transfer: throwing,
      isMetered: () async => false,
      allowMobile: () async => true,
    );
    await d.download(feedUrl: feed, guid: guid, enclosureUrl: audio);
    await pumpAsync();
    expect(d.stateOf(feed, guid), EpisodeDownloadState.failed);
    expect(store.commits, isEmpty);
  });

  test('"success" but file empty — failed, not in storage', () async {
    await downloads.download(feedUrl: feed, guid: guid, enclosureUrl: audio);
    await transfer.finish(id, bytes: 0);
    expect(downloads.stateOf(feed, guid), EpisodeDownloadState.failed);
    expect(store.commits, isEmpty);
  });

  test('can retry after failed', () async {
    await downloads.download(feedUrl: feed, guid: guid, enclosureUrl: audio);
    await transfer.finish(id, ok: false);
    final again = await downloads.download(
      feedUrl: feed,
      guid: guid,
      enclosureUrl: audio,
    );
    expect(again, EpisodeDownloadResult.started);
    expect(transfer.jobs, hasLength(2));
    await transfer.finish(id);
    expect(downloads.stateOf(feed, guid), EpisodeDownloadState.onPhone);
  });

  test('delete from phone — file deleted, state none', () async {
    await downloads.download(feedUrl: feed, guid: guid, enclosureUrl: audio);
    await transfer.finish(id);
    final file = (await downloads.fileFor(feed, guid))!;
    await downloads.remove(feed, guid);
    expect(store.removed, [id]);
    expect(await file.exists(), isFalse);
    expect(downloads.stateOf(feed, guid), EpisodeDownloadState.none);
    expect(transfer.cancelled, isEmpty);
  });

  test(
    'delete during download — cancel, late "done" does not resurrect episode',
    () async {
      await downloads.download(feedUrl: feed, guid: guid, enclosureUrl: audio);
      final part = transfer.jobs.single.file;
      await downloads.remove(feed, guid);
      expect(transfer.cancelled, [id]);
      expect(downloads.stateOf(feed, guid), EpisodeDownloadState.none);
      await transfer.finish(id);
      expect(downloads.stateOf(feed, guid), EpisodeDownloadState.none);
      expect(store.commits, isEmpty);
      expect(await downloads.fileFor(feed, guid), isNull);
      expect(await part.exists(), isFalse);
    },
  );

  test(
    'delete during download and re-download — old task does not block new',
    () async {
      await downloads.download(feedUrl: feed, guid: guid, enclosureUrl: audio);
      final first = transfer.pending[id]!;
      await downloads.remove(feed, guid);
      await downloads.download(feedUrl: feed, guid: guid, enclosureUrl: audio);
      expect(transfer.jobs, hasLength(2));
      first.complete(false);
      await pumpAsync();
      expect(downloads.stateOf(feed, guid), EpisodeDownloadState.downloading);
      await transfer.finish(id);
      expect(downloads.stateOf(feed, guid), EpisodeDownloadState.onPhone);
    },
  );

  test(
    'refresh: found file — onPhone, missing — none, leaves download alone',
    () async {
      final other = PodcastDownloads.idFor(feed, 'ep-2');
      await store.partFile(other, format: 'mp3').writeAsBytes([1]);
      await store.commit(other, format: 'mp3', hold: Hold.download);
      await downloads.download(feedUrl: feed, guid: guid, enclosureUrl: audio);
      final before = notifications;
      await downloads.refresh([(feed, guid), (feed, 'ep-2'), (feed, 'ep-3')]);
      expect(downloads.stateOf(feed, 'ep-2'), EpisodeDownloadState.onPhone);
      expect(downloads.stateOf(feed, 'ep-3'), EpisodeDownloadState.none);
      expect(downloads.stateOf(feed, guid), EpisodeDownloadState.downloading);
      expect(notifications, before + 1);
      await store.remove(other);
      await downloads.refresh([(feed, 'ep-2')]);
      expect(downloads.stateOf(feed, 'ep-2'), EpisodeDownloadState.none);
    },
  );

  test('refresh without changes does not notify listeners', () async {
    await downloads.refresh([(feed, guid)]);
    expect(notifications, 0);
  });

  test('repeated "delete" does not notify listeners', () async {
    await downloads.remove(feed, guid);
    final before = notifications;
    await downloads.remove(feed, guid);
    expect(notifications, before);
  });

  test(
    'two rapid taps while network checks run — single task created only',
    () async {
      final gate = Completer<void>();
      final d = PodcastDownloads(
        store: store,
        transfer: transfer,
        isMetered: () async => false,
        allowMobile: () async {
          await gate.future;
          return true;
        },
      );
      final first = d.download(feedUrl: feed, guid: guid, enclosureUrl: audio);
      final second = d.download(feedUrl: feed, guid: guid, enclosureUrl: audio);
      gate.complete();
      final results = await Future.wait([first, second]);
      expect(transfer.jobs, hasLength(1));
      expect(results, contains(EpisodeDownloadResult.started));
      expect(results, contains(EpisodeDownloadResult.alreadyThere));
    },
  );

  test(
    'delete while saving to storage — episode does not resurrect or fail',
    () async {
      await downloads.download(feedUrl: feed, guid: guid, enclosureUrl: audio);
      store.commitGate = Completer<void>();
      final job = transfer.jobs.single;
      await job.file.writeAsBytes(List.filled(10, 7));
      transfer.pending.remove(id)!.complete(true);
      await store.commitStarted.future;
      await downloads.remove(feed, guid);
      store.commitGate!.complete();
      await pumpAsync();
      expect(downloads.stateOf(feed, guid), EpisodeDownloadState.none);
      expect(await downloads.fileFor(feed, guid), isNull);
    },
  );

  test('refresh started before download does not overwrite download', () async {
    final gate = Completer<void>();
    store.fileForGate = gate;
    final refreshing = downloads.refresh([(feed, guid)]);
    await pumpAsync();
    final result = await downloads.download(
      feedUrl: feed,
      guid: guid,
      enclosureUrl: audio,
    );
    expect(result, EpisodeDownloadResult.started);
    gate.complete();
    await refreshing;
    expect(downloads.stateOf(feed, guid), EpisodeDownloadState.downloading);
  });

  test('refresh does not clear failed if file is missing', () async {
    await downloads.download(feedUrl: feed, guid: guid, enclosureUrl: audio);
    await transfer.finish(id, ok: false);
    await downloads.refresh([(feed, guid)]);
    expect(downloads.stateOf(feed, guid), EpisodeDownloadState.failed);
  });

  test(
    'downloader cancel failed — file deletion still completes to the end',
    () async {
      await downloads.download(feedUrl: feed, guid: guid, enclosureUrl: audio);
      final part = transfer.jobs.single.file;
      await part.writeAsBytes([1, 2]);
      transfer.cancelThrows = true;
      await downloads.remove(feed, guid);
      expect(downloads.stateOf(feed, guid), EpisodeDownloadState.none);
      expect(await part.exists(), isFalse);
    },
  );

  test('late "done" after dispose does not crash', () async {
    await downloads.download(feedUrl: feed, guid: guid, enclosureUrl: audio);
    downloads.dispose();
    await transfer.finish(id);
  });

  test(
    'refresh: storage closed (logout) — no exception (FT-733 review)',
    () async {
      store.fileForThrows = true;
      await downloads.refresh([(feed, guid), (feed, 'ep-2')]);
      expect(downloads.stateOf(feed, guid), EpisodeDownloadState.none);
    },
  );

  test('refresh after dispose ignores storage (FT-733 review)', () async {
    final gate = Completer<void>();
    store.fileForGate = gate;
    final running = downloads.refresh([(feed, guid), (feed, 'ep-2')]);
    downloads.dispose();
    store.fileForThrows = true;
    gate.complete();
    await running;
    expect(notifications, 0);
  });
}

class _ThrowingTransfer implements FileTransfer {
  @override
  Future<bool> fetch(TransferJob job) async => throw const SocketException('x');

  @override
  Future<void> cancel(String trackId) async {}
}
