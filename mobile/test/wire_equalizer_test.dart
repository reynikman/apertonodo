import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/app.dart';
import 'package:music_stream/equalizer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';

/// Wire FT-621: "Equalizer" in account menu opens screen, and
/// toggle routes to device audio output. No equalizer hardware —
/// menu item hidden. Verifying audio actually alters requires physical device.
class _Port implements EqualizerPort {
  bool? enabled;

  @override
  Future<List<EqBand>> bands() async => const [
    EqBand(centerHz: 60, minDb: -15, maxDb: 15),
    EqBand(centerHz: 230, minDb: -15, maxDb: 15),
    EqBand(centerHz: 910, minDb: -15, maxDb: 15),
    EqBand(centerHz: 3600, minDb: -15, maxDb: 15),
    EqBand(centerHz: 14000, minDb: -15, maxDb: 15),
  ];

  @override
  Future<void> setEnabled(bool on) async => enabled = on;

  @override
  Future<void> setGain(int index, double db) async {}
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> openMenu(WidgetTester tester, Equalizer? equalizer) async {
    final server = FakeServer();
    await tester.pumpWidget(
      MusicApp(
        catalogSource: server.catalog(),
        server: server.api(),
        onAccountAction: (_) async {},
        equalizer: equalizer,
      ),
    );
    await tester.tap(find.byKey(const Key('tab-library')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('account-button')));
    await tester.pumpAndSettle();
  }

  testWidgets('menu item opens equalizer, toggle reaches platform device', (
    tester,
  ) async {
    final port = _Port();
    final equalizer = Equalizer(port: port);
    await equalizer.load();
    await openMenu(tester, equalizer);

    await tester.tap(find.byKey(const Key('equalizer')));
    await tester.pumpAndSettle();
    expect(find.text('Эквалайзер'), findsWidgets);

    await tester.tap(find.byKey(const Key('eq-enabled')));
    await tester.pumpAndSettle();
    expect(port.enabled, isTrue);
  });

  testWidgets('no equalizer hides menu item', (tester) async {
    await openMenu(tester, null);

    expect(find.byKey(const Key('equalizer')), findsNothing);
    expect(find.byKey(const Key('logout')), findsOneWidget);
  });
}
