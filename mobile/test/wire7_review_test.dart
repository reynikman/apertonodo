import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/app.dart';
import 'package:music_stream/equalizer.dart';
import 'package:music_stream/l10n/l10n.dart';
import 'package:music_stream/screens/equalizer_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'equalizer_test.dart' show FakeEqualizerPort;
import 'fake_server.dart';

/// Listeners accessible only from inside `ChangeNotifier` — hence subclass.
class _Watched extends Equalizer {
  _Watched({required super.port});

  bool get listened => hasListeners;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('1. no ChangeNotifier leak: closing screen removes listener', (
    tester,
  ) async {
    final port = FakeEqualizerPort();
    final eq = _Watched(port: port);
    addTearDown(eq.dispose);
    await eq.load();

    expect(eq.listened, isFalse);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => EqualizerScreen(equalizer: eq)),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.byType(EqualizerScreen), findsOneWidget);
    expect(eq.listened, isTrue);

    Navigator.of(tester.element(find.byType(EqualizerScreen))).pop();
    await tester.pumpAndSettle();
    expect(find.byType(EqualizerScreen), findsNothing);
    expect(eq.listened, isFalse);
  });

  testWidgets('2. switching user preserves single Equalizer instance', (
    tester,
  ) async {
    final port = FakeEqualizerPort();
    final eq = Equalizer(port: port);
    addTearDown(eq.dispose);
    await eq.load();

    Equalizer? seenInUser1;
    Equalizer? seenInUser2;

    final server = FakeServer();
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          return MaterialApp(
            home: MusicApp(
              key: const ValueKey('user-1'),
              catalogSource: server.catalog(),
              server: server.api(),
              onAccountAction: (_) async {},
              equalizer: eq,
            ),
          );
        },
      ),
    );
    await tester.pumpAndSettle();
    seenInUser1 = tester.widget<MusicApp>(find.byType(MusicApp)).equalizer;

    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          return MaterialApp(
            home: MusicApp(
              key: const ValueKey('user-2'),
              catalogSource: server.catalog(),
              server: server.api(),
              onAccountAction: (_) async {},
              equalizer: eq,
            ),
          );
        },
      ),
    );
    await tester.pumpAndSettle();
    seenInUser2 = tester.widget<MusicApp>(find.byType(MusicApp)).equalizer;

    expect(identical(seenInUser1, seenInUser2), isTrue);
    expect(identical(seenInUser1, eq), isTrue);
  });

  testWidgets(
    '3. load() before bands appear keeps selection and updates screen',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'eq-enabled': true,
        'eq-preset': 'bass',
        'eq-gains': ['6.0', '4.0', '0.0', '0.0', '0.0'],
      });

      final ready = Completer<void>();
      final port = FakeEqualizerPort(ready: ready);
      final eq = Equalizer(port: port);
      addTearDown(eq.dispose);

      final loadFuture = eq.load();

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: EqualizerScreen(equalizer: eq),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('eq-waiting')), findsOneWidget);
      expect(find.byKey(const Key('eq-band-0')), findsNothing);

      ready.complete();
      await tester.runAsync(() => loadFuture);
      await tester.pump();

      expect(find.byKey(const Key('eq-waiting')), findsNothing);
      expect(find.byKey(const Key('eq-band-0')), findsOneWidget);
      expect(eq.enabled, isTrue);
      expect(eq.preset, 'bass');
      expect(port.enabled, isTrue);
      expect(port.gains[0], 6.0);
    },
  );

  testWidgets('4. saved selection passed to device after restart', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'eq-enabled': true,
      'eq-preset': 'custom',
      'eq-gains': ['3.0', '-2.0', '1.0', '4.0', '-5.0'],
    });

    final port = FakeEqualizerPort();
    final eq = Equalizer(port: port);
    addTearDown(eq.dispose);
    await eq.load();

    expect(eq.enabled, isTrue);
    expect(port.enabled, isTrue);
    expect(port.gains[0], 3.0);
    expect(port.gains[1], -2.0);
    expect(port.gains[2], 1.0);
    expect(port.gains[3], 4.0);
    expect(port.gains[4], -5.0);
  });

  testWidgets('5. device without equalizer does not crash', (tester) async {
    final port = FakeEqualizerPort()..broken = true;
    final eq = Equalizer(port: port);
    addTearDown(eq.dispose);
    await eq.load();

    expect(eq.available, isFalse);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: EqualizerScreen(equalizer: eq),
      ),
    );
    await tester.pump();

    expect(find.text('На этом телефоне эквалайзера нет'), findsOneWidget);
    expect(find.byKey(const Key('eq-band-0')), findsNothing);
    expect(find.byKey(const Key('eq-enabled')), findsNothing);
  });

  testWidgets('6. disabled equalizer sends setEnabled(false)', (tester) async {
    final port = FakeEqualizerPort();
    final eq = Equalizer(port: port);
    addTearDown(eq.dispose);
    await eq.load();

    await eq.setEnabled(true);
    expect(port.enabled, isTrue);

    await eq.setEnabled(false);
    expect(port.enabled, isFalse);
  });

  testWidgets('7. en localization: screen and menu in English', (tester) async {
    final port = FakeEqualizerPort();
    final eq = Equalizer(port: port);
    addTearDown(eq.dispose);
    await eq.load();

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: EqualizerScreen(equalizer: eq),
      ),
    );
    await tester.pump();

    expect(find.text('Equalizer'), findsWidgets);
    expect(find.text('Flat'), findsOneWidget);
    expect(find.text('Bass'), findsOneWidget);
    expect(find.text('Treble'), findsOneWidget);
    expect(find.text('Vocal'), findsOneWidget);
    expect(find.text('60 Hz'), findsOneWidget);
    expect(find.text('3.6 kHz'), findsOneWidget);
  });

  testWidgets('8. menu item opens screen, hidden without equalizer', (
    tester,
  ) async {
    final server = FakeServer();
    final port = FakeEqualizerPort();
    final eq = Equalizer(port: port);
    addTearDown(eq.dispose);
    await eq.load();

    // With equalizer:
    await tester.pumpWidget(
      MaterialApp(
        home: MusicApp(
          catalogSource: server.catalog(),
          server: server.api(),
          onAccountAction: (_) async {},
          equalizer: eq,
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('tab-library')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('account-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('equalizer')), findsOneWidget);
    await tester.tap(find.byKey(const Key('equalizer')));
    await tester.pumpAndSettle();
    expect(find.byType(EqualizerScreen), findsOneWidget);

    // Without equalizer:
    await tester.pumpWidget(
      MaterialApp(
        home: MusicApp(
          catalogSource: server.catalog(),
          server: server.api(),
          onAccountAction: (_) async {},
          equalizer: null,
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('tab-library')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('account-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('equalizer')), findsNothing);
  });

  testWidgets(
    '9. TalkBack: sliders and chips follow accessibility guidelines',
    (tester) async {
      final handle = tester.ensureSemantics();
      final port = FakeEqualizerPort();
      final eq = Equalizer(port: port);
      addTearDown(eq.dispose);
      await tester.runAsync(eq.load);

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: EqualizerScreen(equalizer: eq),
        ),
      );
      await tester.pump();

      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      handle.dispose();
    },
  );
}
