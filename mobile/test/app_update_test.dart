// FT-628 (P-A94, beta condition): auto-update — the app detects new versions and installs them itself.
//
// The app lives outside app stores: without auto-update, a beta tester stays on an old build until
// sent a file manually. Here is all logic and sheet; download and calling Android installer are hidden behind
// `UpdateInstaller` (real implementation is `ota_update` package, wired by lead upon merge).
//
// Guarded:
// - new version — only strictly newer than current; draft release and release without APK do not count;
// - APK without sha256 checksum or not over https is not offered at all: unverified files are not installed;
// - network check for version — at most once a day; network failure is silent and does not interrupt listening;
// - "Skip this version" is remembered between launches, but the next version will be shown;
// - sheet: version, what's new, download progress, failure reason in words; Russian and English, tap target ≥ 48 dp.
//
// What the test does not prove: that Android on a real phone downloaded and installed the APK — this is verified during
// wiring (`ota_update`, install permission, permanent APK signature).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/app_update.dart';
import 'package:music_stream/l10n/l10n.dart';
import 'package:music_stream/screens/update_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _sha = 'a3f1c2d4e5b60718293a4b5c6d7e8f90112233445566778899aabbccddeeff00';

Map<String, Object?> _release({
  String tag = 'v0.9.1+43',
  bool draft = false,
  bool prerelease = true,
  String body = 'Починили паузу.\n\nДобавили таймер сна.',
  List<Map<String, Object?>>? assets,
}) => {
  'tag_name': tag,
  'draft': draft,
  'prerelease': prerelease,
  'body': body,
  'assets':
      assets ??
      [
        {
          'name': 'checksums.txt',
          'browser_download_url': 'https://example.org/dl/checksums.txt',
          'size': 120,
          'digest': 'sha256:${'0' * 64}',
        },
        {
          'name': 'apertono-0.9.1.apk',
          'browser_download_url': 'https://example.org/dl/apertono-0.9.1.apk',
          'size': 31457280,
          'digest': 'sha256:$_sha',
        },
      ],
};

UpdateInfo _info([String version = '0.9.1+43']) => UpdateInfo(
  version: version,
  apk: Uri.parse('https://example.org/dl/apertono.apk'),
  sha256: _sha,
  bytes: 31457280,
  notes: 'Починили паузу.',
);

class _Source implements UpdateSource {
  _Source(this.answer);
  UpdateInfo? answer;
  Object? error;
  int calls = 0;

  @override
  Future<UpdateInfo?> latest() async {
    calls++;
    if (error != null) throw error!;
    return answer;
  }
}

class _Installer implements UpdateInstaller {
  final installed = <UpdateInfo>[];
  StreamController<double>? running;

  @override
  Stream<double> install(UpdateInfo info) {
    installed.add(info);
    return (running = StreamController<double>()).stream;
  }
}

Future<AppUpdate> _update({
  String current = '0.9.0+42',
  required _Source source,
  _Installer? installer,
  DateTime Function()? clock,
}) async {
  final update = AppUpdate(
    current: current,
    source: source,
    installer: installer ?? _Installer(),
    prefs: await SharedPreferences.getInstance(),
    clock: clock,
  );
  addTearDown(update.dispose);
  return update;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('versions compared numerically, not alphabetically', () {
    bool newer(String a, String b) => isNewerVersion(a, than: b);
    expect(newer('0.9.1', '0.9.0'), isTrue);
    expect(newer('0.10.0', '0.9.9'), isTrue, reason: '10 is greater than 9');
    expect(newer('1.0.0', '0.99.99'), isTrue);
    expect(newer('v0.9.1+43', '0.9.0+42'), isTrue, reason: 'letter v in tag');
    expect(newer('0.9.0+43', '0.9.0+42'), isTrue, reason: 'build number');
    expect(newer('0.9.0', '0.9.0+42'), isFalse, reason: 'same version');
    expect(newer('0.9.0+42', '0.9.0+42'), isFalse);
    expect(newer('0.8.9+99', '0.9.0+1'), isFalse);
    expect(newer('nightly', '0.9.0'), isFalse, reason: 'unknown tag');
    expect(newer('0.9.1', 'dev'), isFalse, reason: 'own version unknown');
    expect(newer('', '0.9.0'), isFalse);
  });

  test('beta tags: order 0.9.0-beta < 0.9.1-beta < 0.9.1 < 1.0.0', () {
    bool newer(String a, String b) => isNewerVersion(a, than: b);
    expect(newer('v0.9.0-beta', '0.8.0'), isTrue);
    expect(newer('v0.9.1-beta', '0.9.0'), isTrue);
    expect(newer('0.9.1-beta', '0.9.0-beta'), isTrue);
    expect(newer('0.9.1', '0.9.1-beta'), isTrue, reason: 'release > beta');
    expect(newer('0.9.1-beta', '0.9.1'), isFalse);
    expect(newer('1.0.0', '0.9.1'), isTrue);
    expect(newer('0.9.0-beta', '0.9.0'), isFalse, reason: 'beta of installed');
    expect(newer('0.9.0-beta', '0.9.0+2'), isFalse);
    expect(
      updateFromGithubRelease(_release(tag: 'v0.9.0-beta'))?.version,
      '0.9.0-beta',
    );
  });

  test('GitHub release -> update', () {
    final info = updateFromGithubRelease(_release())!;
    expect(info.version, '0.9.1+43');
    expect(info.apk, Uri.parse('https://example.org/dl/apertono-0.9.1.apk'));
    expect(info.sha256, _sha);
    expect(info.bytes, 31457280);
    expect(info.notes, 'Починили паузу.\n\nДобавили таймер сна.');
  });

  test('unverifiable or foreign release is not update', () {
    Map<String, Object?> apk({Object? url, Object? digest = 'sha256:$_sha'}) =>
        {
          'name': 'apertono.apk',
          'browser_download_url': url ?? 'https://example.org/a.apk',
          'size': 1,
          'digest': ?digest,
        };

    expect(updateFromGithubRelease(_release(draft: true)), isNull);
    expect(updateFromGithubRelease(_release(assets: [])), isNull);
    expect(
      updateFromGithubRelease(_release(assets: [apk(digest: null)])),
      isNull,
      reason: 'no checksum',
    );
    expect(
      updateFromGithubRelease(_release(assets: [apk(digest: 'md5:abc')])),
      isNull,
    );
    expect(
      updateFromGithubRelease(_release(assets: [apk(digest: 'sha256:abc')])),
      isNull,
      reason: 'checksum not 64 hex characters',
    );
    expect(
      updateFromGithubRelease(
        _release(assets: [apk(url: 'http://example.org/a.apk')]),
      ),
      isNull,
      reason: 'not https',
    );
    expect(updateFromGithubRelease(_release(tag: 'nightly')), isNull);
    expect(updateFromGithubRelease({'message': 'Not Found'}), isNull);
    expect(updateFromGithubRelease({'tag_name': 7, 'assets': 'x'}), isNull);
  });

  test('long what is new is truncated', () {
    final info = updateFromGithubRelease(_release(body: 'я' * 5000))!;
    expect(info.notes.length, lessThanOrEqualTo(2000));
  });

  test('new version found, old or same version is not', () async {
    final found = await _update(source: _Source(_info()));
    var heard = 0;
    found.addListener(() => heard++);
    expect(found.available, isNull);
    await found.check();
    expect(found.available?.version, '0.9.1+43');
    expect(found.phase, UpdatePhase.available);
    expect(heard, greaterThan(0));

    for (final version in ['0.9.0+42', '0.8.0+1']) {
      SharedPreferences.setMockInitialValues({});
      final same = await _update(source: _Source(_info(version)));
      await same.check();
      expect(same.available, isNull, reason: version);
      expect(same.phase, UpdatePhase.idle);
    }

    SharedPreferences.setMockInitialValues({});
    final none = await _update(source: _Source(null));
    await none.check();
    expect(none.available, isNull);
  });

  test('network check at most daily, remembered', () async {
    var now = DateTime.utc(2026, 10, 6, 12);
    final source = _Source(null);
    final update = await _update(source: source, clock: () => now);
    await update.check();
    await update.check();
    expect(source.calls, 1);

    now = now.add(const Duration(hours: 23));
    final restarted = await _update(source: source, clock: () => now);
    await restarted.check();
    expect(source.calls, 1, reason: 'new app launch within same day');

    now = now.add(const Duration(hours: 2));
    await restarted.check();
    expect(source.calls, 2);

    await restarted.check(force: true);
    expect(source.calls, 3, reason: 'Check now from menu');
  });

  test('network error silent, next check after 24h', () async {
    var now = DateTime.utc(2026, 10, 6, 12);
    final source = _Source(_info())..error = TimeoutException('net');
    final update = await _update(source: source, clock: () => now);
    await update.check();
    expect(update.available, isNull);
    expect(update.phase, UpdatePhase.idle);

    source.error = null;
    await update.check();
    expect(source.calls, 1);
    now = now.add(const Duration(hours: 25));
    await update.check();
    expect(update.available, isNotNull);
  });

  test('skipped version not offered, subsequent one is', () async {
    final source = _Source(_info());
    final update = await _update(source: source);
    await update.check();
    update.skip();
    expect(update.available, isNull);
    expect(update.phase, UpdatePhase.idle);

    final restarted = await _update(source: source);
    await restarted.check(force: true);
    expect(restarted.available, isNull, reason: 'remembered across launches');

    source.answer = _info('0.9.2+44');
    await restarted.check(force: true);
    expect(restarted.available?.version, '0.9.2+44');
  });

  test('install: progress, finish, fail and retry', () async {
    final installer = _Installer();
    final update = await _update(
      source: _Source(_info()),
      installer: installer,
    );
    await update.install();
    expect(installer.installed, isEmpty, reason: 'nothing to install');

    await update.check();
    final done = update.install();
    await Future<void>.delayed(Duration.zero);
    expect(update.phase, UpdatePhase.downloading);
    expect(update.progress, 0);
    unawaited(update.install());
    expect(installer.installed, hasLength(1), reason: 'second tap');

    installer.running!.add(0.4);
    await Future<void>.delayed(Duration.zero);
    expect(update.progress, closeTo(0.4, 1e-9));

    installer.running!.addError(StateError('checksum'));
    await installer.running!.close();
    await done;
    expect(update.phase, UpdatePhase.failed);
    expect(update.available, isNotNull, reason: 'can retry');

    final again = update.install();
    await Future<void>.delayed(Duration.zero);
    expect(installer.installed, hasLength(2));
    expect(update.phase, UpdatePhase.downloading);
    installer.running!.add(1);
    await installer.running!.close();
    await again;
    expect(
      update.phase,
      UpdatePhase.available,
      reason: 'further is Android dialog',
    );
    expect(update.progress, 0);
  });

  for (final (locale, title, version, install, skip, failed) in [
    (
      const Locale('ru'),
      'Доступно обновление',
      'Версия 0.9.1',
      'Обновить',
      'Пропустить эту версию',
      'Не получилось обновить. Попробуйте ещё раз.',
    ),
    (
      const Locale('en'),
      'Update available',
      'Version 0.9.1',
      'Update',
      'Skip this version',
      'Could not update. Try again.',
    ),
  ]) {
    testWidgets('update sheet: $locale', (tester) async {
      final installer = _Installer();
      final update = await _update(
        source: _Source(_info()),
        installer: installer,
      );
      await update.check();

      await tester.pumpWidget(
        MaterialApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: UpdateSheet(update: update)),
        ),
      );
      expect(find.text(title), findsOneWidget);
      expect(find.text(version), findsOneWidget, reason: 'no build number');
      expect(find.text('Починили паузу.'), findsOneWidget);
      expect(find.text(install), findsOneWidget);
      expect(find.text(skip), findsOneWidget);
      for (final key in ['update-install', 'update-skip']) {
        expect(
          tester.getSize(find.byKey(Key(key))).height,
          greaterThanOrEqualTo(48),
          reason: key,
        );
      }
      expect(find.byKey(const Key('update-progress')), findsNothing);

      await tester.tap(find.byKey(const Key('update-install')));
      await tester.pump();
      expect(installer.installed, hasLength(1));
      expect(find.byKey(const Key('update-progress')), findsOneWidget);
      expect(find.byKey(const Key('update-install')), findsNothing);
      expect(find.byKey(const Key('update-skip')), findsNothing);

      installer.running!.add(0.4);
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('40'), findsOneWidget);

      installer.running!.addError(StateError('checksum'));
      await installer.running!.close();
      await tester.pump();
      await tester.pump();
      expect(find.text(failed), findsOneWidget);
      expect(find.byKey(const Key('update-install')), findsOneWidget);

      await tester.tap(find.byKey(const Key('update-skip')));
      await tester.pump();
      expect(update.available, isNull);
      expect(find.byKey(const Key('update-install')), findsNothing);
    });
  }
}
