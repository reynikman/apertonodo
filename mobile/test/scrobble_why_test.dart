import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/app.dart';

import 'fake_server.dart';

/// FT-799 (owner finding 12.10 item 2): "Why is Last.fm in settings?
/// If I didn't understand, others won't either — explanation needed". Screen
/// "ListenBrainz and Last.fm" begins with explanation of purpose, and
/// guides where to obtain ListenBrainz token.
void main() {
  final dispatcher =
      TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher;
  tearDown(dispatcher.clearLocaleTestValue);
  tearDown(dispatcher.clearLocalesTestValue);

  final opened = <String>[];
  setUp(() {
    opened.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('apertono/device'), (
          call,
        ) async {
          if (call.method == 'openUrl') opened.add(call.arguments as String);
          return null;
        });
  });

  Future<void> openScreen(WidgetTester tester, String language) async {
    dispatcher.localeTestValue = Locale(language);
    dispatcher.localesTestValue = [Locale(language)];
    final server = FakeServer();
    await tester.pumpWidget(
      MusicApp(
        catalogSource: server.catalog(),
        server: server.api(),
        onAccountAction: (_) async {},
      ),
    );
    await tester.tap(find.byKey(const Key('tab-library')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('account-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('scrobble')));
    await tester.pumpAndSettle();
  }

  final why = find.byKey(const Key('scrobble-why'));
  final where = find.byKey(const Key('scrobble-lb-where'));

  String textOf(WidgetTester tester, Finder finder) => tester
      .widgetList<Text>(
        find.descendant(
          of: finder,
          matching: find.byType(Text),
          matchRoot: true,
        ),
      )
      .map((text) => text.data ?? text.textSpan?.toPlainText() ?? '')
      .join(' ');

  testWidgets('top explains purpose: your stats, optional', (tester) async {
    await openScreen(tester, 'ru');
    expect(why, findsOneWidget);
    final words = textOf(tester, why).toLowerCase();
    for (final part in ['статистик', 'необязательно', 'бесплатн']) {
      expect(words, contains(part), reason: part);
    }
    // Explanation is first on screen, above token field.
    expect(
      tester.getRect(why).bottom,
      lessThanOrEqualTo(
        tester.getRect(find.byKey(const Key('scrobble-lb-token'))).top,
      ),
    );
  });

  testWidgets('"Where to get token" opens ListenBrainz settings', (
    tester,
  ) async {
    await openScreen(tester, 'ru');
    expect(where, findsOneWidget);
    expect(tester.getSize(where).height, greaterThanOrEqualTo(48));
    await tester.tap(where);
    await tester.pumpAndSettle();
    expect(opened, ['https://listenbrainz.org/settings/']);
  });

  testWidgets('in English - in English', (tester) async {
    await openScreen(tester, 'en');
    final words = textOf(tester, why).toLowerCase();
    expect(words, contains('optional'));
    expect(words, isNot(matches(RegExp('[а-я]'))));
    expect(textOf(tester, where), isNot(matches(RegExp('[А-Яа-я]'))));
  });
}
