import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/device_info.dart';
import 'package:music_stream/error_reports.dart';

/// Android bridge (FT-522, P-A60): metered network check and actual Android version.
///
/// Downloads occur only on unmetered network — queried from Android, not
/// guessed. System version in crash report was previously parsed from first
/// number in kernel string, and TECNO on Android 14 reported "Android 7".
const channel = MethodChannel('apertono/device');
final osShape = RegExp(r'^[0-9A-Za-z .+-]{1,32}$');

void answer(Object? Function(MethodCall call)? handler) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        channel,
        handler == null ? null : (call) async => handler(call),
      );
}

String reportOs() =>
    const ErrorReport(kind: 'probe', screen: 'probe').toJson()['os'] as String;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(DeviceInfo.forget);
  tearDown(() {
    answer(null);
    DeviceInfo.forget();
  });

  test('Android version in report is from system not kernel', () async {
    answer((call) => call.method == 'androidRelease' ? '14' : null);
    await DeviceInfo.load();
    expect(reportOs(), 'Android 14');
  });

  test('foreign characters in version cleaned, format kept', () async {
    answer((call) => call.method == 'androidRelease' ? '15 (QPR1)' : null);
    await DeviceInfo.load();
    expect(reportOs(), 'Android 15 QPR1');
    expect(reportOs(), matches(osShape));
  });

  test('no bridge means no version: better nothing than Android 7', () async {
    await DeviceInfo.load();
    expect(reportOs(), matches(osShape));
    expect(reportOs(), isNot(matches(RegExp(r'\d'))));
  });

  test('network metered status is Android response', () async {
    answer((call) => call.method == 'isMetered' ? false : null);
    expect(await DeviceInfo.isMetered(), isFalse);
    answer((call) => call.method == 'isMetered' ? true : null);
    expect(await DeviceInfo.isMetered(), isTrue);
  });

  test(
    'unknown means metered: cannot download on mobile network silently',
    () async {
      expect(await DeviceInfo.isMetered(), isTrue, reason: 'no bridge');
      answer((call) => throw PlatformException(code: 'boom'));
      expect(await DeviceInfo.isMetered(), isTrue, reason: 'bridge crashed');
      answer((call) => null);
      expect(await DeviceInfo.isMetered(), isTrue, reason: 'bridge silent');
    },
  );

  test('bridge lives in own Activity on top of AudioServiceActivity', () {
    final activity = File(
      'android/app/src/main/kotlin/app/apertono/player/MainActivity.kt',
    );
    expect(activity.existsSync(), isTrue);
    final code = activity.readAsStringSync();
    for (final part in [
      'AudioServiceActivity',
      '"apertono/device"',
      'isActiveNetworkMetered',
      'Build.VERSION.RELEASE',
    ]) {
      expect(code, contains(part));
    }
  });

  test('manifest launches own Activity and can query network', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    expect(manifest, contains('android:name=".MainActivity"'));
    expect(
      manifest,
      isNot(
        contains(
          'android:name="com.ryanheise.audioservice.AudioServiceActivity"',
        ),
      ),
    );
    expect(manifest, contains('android.permission.ACCESS_NETWORK_STATE'));
  });

  test('version is read at app launch', () {
    expect(
      File('lib/main.dart').readAsStringSync(),
      contains('DeviceInfo.load()'),
    );
  });
}
