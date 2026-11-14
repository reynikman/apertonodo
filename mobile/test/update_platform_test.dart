import 'dart:async';
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

/// Executor tests FT-768:
/// 1. 15 s timeout on GitHub;
/// 2. without size fraction is 1.0 at completion only;
/// 3. repeated install during download;
/// 4. sheet displayed once;
/// 5. "Latest version installed" in menu.
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

  test('15s timeout for GitHub', () async {
    final client = MockClient((_) async {
      throw TimeoutException('15 seconds elapsed');
    });
    final source = GithubUpdateSource(
      repo: 'reynikman/apertonodo',
      client: client,
    );
    final info = await source.latest();
    expect(info, isNull);
  });

  group('newest release by version (FT-908)', () {
    Map<String, Object?> rel(String tag) => {
      'tag_name': tag,
      'draft': false,
      'assets': [
        {
          'name': 'a.apk',
          'browser_download_url': 'https://example.org/a.apk',
          'digest': 'sha256:${'a' * 64}',
        },
      ],
    };
    Future<UpdateInfo?> ask(List<String> tags) => GithubUpdateSource(
      repo: 'reynikman/apertonodo',
      client: MockClient(
        (_) async =>
            http.Response(jsonEncode([for (final t in tags) rel(t)]), 200),
      ),
    ).latest();

    test('v0.9.1-beta is found when 0.9.0 is installed', () async {
      final info = await ask(['v0.9.1-beta', 'v0.9.0-beta']);
      expect(info?.version, '0.9.1-beta');
      expect(isNewerVersion(info!.version, than: '0.9.0'), isTrue);
    });

    test('old beta published later is not chosen', () async {
      final info = await ask(['v0.9.0-beta', 'v0.9.1-beta']);
      expect(info?.version, '0.9.1-beta');
    });

    test('0.9.0-beta is not offered over installed 0.9.0', () async {
      final info = await ask(['v0.9.0-beta']);
      expect(isNewerVersion(info!.version, than: '0.9.0'), isFalse);
    });
  });

  group('ApkInstaller', () {
    const channel = MethodChannel('apertono/update');
    late Directory dir;
    late List<MethodCall> calls;

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      dir = Directory.systemTemp.createTempSync('ft768_platform');
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

    final bytes = List<int>.generate(2048, (i) => i % 251);

    test('unknown size reports progress 1.0 at end', () async {
      final info = UpdateInfo(
        version: '0.9.1+3',
        apk: Uri.parse('https://github.com/x/y/a.apk'),
        sha256: sha256.convert(bytes).toString(),
      );
      final client = MockClient.streaming((_, _) async {
        return http.StreamedResponse(
          http.ByteStream.fromBytes(bytes),
          200,
          contentLength: null,
        );
      });
      final shares = await ApkInstaller(
        client: client,
        dir: () async => dir,
      ).install(info).toList();

      expect(shares, [1.0]);
      expect(calls.single.method, 'install');
    });

    test('repeated install while downloading', () async {
      final info = UpdateInfo(
        version: '0.9.1+3',
        apk: Uri.parse('https://github.com/x/y/a.apk'),
        sha256: sha256.convert(bytes).toString(),
        bytes: bytes.length,
      );
      final completer = Completer<List<int>>();
      final client = MockClient.streaming((_, _) async {
        return http.StreamedResponse(
          http.ByteStream(Stream.fromFuture(completer.future)),
          200,
          contentLength: bytes.length,
        );
      });
      final installer = ApkInstaller(client: client, dir: () async => dir);
      final stream1 = installer.install(info);
      final sub1 = stream1.listen((_) {});
      await pumpEventQueue();

      await expectLater(installer.install(info), emitsError(isA<StateError>()));

      completer.complete(bytes);
      await sub1.asFuture();
    });
  });

  testWidgets('bottom sheet shown once', (tester) async {
    final source = _Source(_info('0.9.1+3'));
    final update = await make(source);
    await start(tester, update);

    expect(find.byType(UpdateSheet), findsOneWidget);

    update.notifyListeners();
    await tester.pumpAndSettle();

    expect(find.byType(UpdateSheet), findsOneWidget);
  });

  testWidgets('"Latest version installed" in menu', (tester) async {
    final source = _Source(_info('0.9.0+2'));
    final update = await make(source);
    await start(tester, update);

    expect(find.byType(UpdateSheet), findsNothing);

    await tester.tap(find.byKey(const Key('tab-library')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('account-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('check-update')));
    await tester.pumpAndSettle();

    expect(find.byType(UpdateSheet), findsNothing);
    expect(find.text('У вас последняя версия'), findsOneWidget);
  });
}
