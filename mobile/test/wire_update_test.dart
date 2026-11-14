import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_stream/app.dart';
import 'package:music_stream/app_update.dart';
import 'package:music_stream/screens/update_sheet.dart';
import 'package:music_stream/update_platform.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';

/// Lead check FT-768: auto-update wired. Newer release —
/// on launch "Update available" sheet shown; menu item checks immediately;
/// APK downloaded with progress, verified against sha256 before handing
/// to Android installer. Live in-place installation tested on device only.
class _Source implements UpdateSource {
  _Source(this.info);
  UpdateInfo? info;
  int asked = 0;

  @override
  Future<UpdateInfo?> latest() async {
    asked++;
    return info;
  }
}

class _Installer implements UpdateInstaller {
  @override
  Stream<double> install(UpdateInfo info) => const Stream.empty();
}

UpdateInfo _info(String version) => UpdateInfo(
  version: version,
  apk: Uri.parse('https://example.org/a.apk'),
  sha256: '0' * 64,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<AppUpdate> make(_Source source) async => AppUpdate(
    current: '0.9.0+2',
    source: source,
    installer: _Installer(),
    prefs: await SharedPreferences.getInstance(),
  );

  Future<void> start(WidgetTester tester, AppUpdate? update) async {
    final server = FakeServer();
    await tester.pumpWidget(
      MusicApp(
        catalogSource: server.catalog(),
        server: server.api(),
        onAccountAction: (_) async {},
        update: update,
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('newer release shows update sheet on startup', (tester) async {
    final source = _Source(_info('0.9.1+3'));
    await start(tester, await make(source));

    expect(source.asked, 1);
    expect(find.byType(UpdateSheet), findsOneWidget);
  });

  testWidgets('no update sheet when up to date', (tester) async {
    final source = _Source(_info('0.9.0+2'));
    await start(tester, await make(source));

    expect(source.asked, 1);
    expect(find.byType(UpdateSheet), findsNothing);
  });

  testWidgets('menu item checks immediately, bypassing 24h delay', (
    tester,
  ) async {
    final source = _Source(null);
    await start(tester, await make(source));
    expect(source.asked, 1);

    source.info = _info('1.0.0+4');
    await tester.tap(find.byKey(const Key('tab-library')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('account-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('check-update')));
    await tester.pumpAndSettle();

    expect(source.asked, 2);
    expect(find.byType(UpdateSheet), findsOneWidget);
  });

  testWidgets('no update source disables check and hides menu item', (
    tester,
  ) async {
    await start(tester, null);
    await tester.tap(find.byKey(const Key('tab-library')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('account-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('check-update')), findsNothing);
    expect(find.byKey(const Key('logout')), findsOneWidget);
  });

  Map<String, Object?> release(
    String tag, {
    bool prerelease = false,
    bool draft = false,
  }) => {
    'tag_name': tag,
    'prerelease': prerelease,
    'draft': draft,
    'assets': [
      {
        'name': 'apertono.apk',
        'browser_download_url': 'https://github.com/x/y/a.apk',
        'digest': 'sha256:${'a' * 64}',
        'size': 10,
      },
    ],
  };

  Future<(UpdateInfo?, List<Uri>)> ask(List<Map<String, Object?>> list) async {
    final asked = <Uri>[];
    final client = MockClient((request) async {
      asked.add(request.url);
      return http.Response(jsonEncode(list), 200);
    });
    final info = await GithubUpdateSource(
      repo: 'reynikman/apertonodo',
      client: client,
    ).latest();
    return (info, asked);
  }

  test('GitHub lists releases of own repo and finds a pre-release', () async {
    final (info, asked) = await ask([
      release('v0.9.1+3', prerelease: true),
      release('v0.9.0+2'),
    ]);
    expect(asked.single.path, '/repos/reynikman/apertonodo/releases');
    expect(info?.version, '0.9.1+3');
  });

  test('GitHub draft release is skipped', () async {
    final (info, _) = await ask([
      release('v0.9.2+4', draft: true),
      release('v0.9.1+3', prerelease: true),
    ]);
    expect(info?.version, '0.9.1+3');
  });

  test('GitHub only drafts yields no update', () async {
    final (info, _) = await ask([release('v0.9.2+4', draft: true)]);
    expect(info, isNull);
  });

  test('GitHub non-200 response yields no update', () async {
    final client = MockClient((_) async => http.Response('{}', 404));
    final info = await GithubUpdateSource(
      repo: 'apertono/apertono',
      client: client,
    ).latest();
    expect(info, isNull);
  });

  group('installer', () {
    const channel = MethodChannel('apertono/update');
    late Directory dir;
    late List<MethodCall> calls;

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      dir = Directory.systemTemp.createTempSync('ft768');
      calls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      dir.deleteSync(recursive: true);
    });

    final bytes = List<int>.generate(4096, (i) => i % 251);
    MockClient serve() =>
        MockClient((_) async => http.Response.bytes(bytes, 200));

    test('checksum matched: progress to 1 and apk sent to Android', () async {
      final info = UpdateInfo(
        version: '0.9.1+3',
        apk: Uri.parse('https://github.com/x/y/a.apk'),
        sha256: sha256.convert(bytes).toString(),
        bytes: bytes.length,
      );
      final shares = await ApkInstaller(
        client: serve(),
        dir: () async => dir,
      ).install(info).toList();

      expect(shares.last, 1.0);
      expect(calls.single.method, 'install');
      final path = (calls.single.arguments as Map)['path'] as String;
      expect(File(path).readAsBytesSync(), bytes);
    });

    test('checksum failed: rejected, Android not invoked, no file', () async {
      final info = UpdateInfo(
        version: '0.9.1+3',
        apk: Uri.parse('https://github.com/x/y/a.apk'),
        sha256: 'f' * 64,
      );
      await expectLater(
        ApkInstaller(client: serve(), dir: () async => dir).install(info),
        emitsThrough(emitsError(anything)),
      );
      expect(calls, isEmpty);
      expect(dir.listSync(), isEmpty);
    });
  });

  test('manifest requests REQUEST_INSTALL_PACKAGES', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    expect(manifest, contains('android.permission.REQUEST_INSTALL_PACKAGES'));
  });
}
