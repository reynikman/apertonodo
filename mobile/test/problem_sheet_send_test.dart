// FT-792 (owner finding 12.10): in "Report problem" sheet user
// entered text, tapped "Send" — and nothing happened: button silently
// waited for "Other" to be selected. Tap had no visual feedback, and "Thank you"
// appeared as single line at the very bottom of screen.
//
// Guarded:
// - text without reason is sufficient: report sent with reason `other`;
// - while nothing to send, button is disabled visibly (`onPressed == null`);
// - while sending, button label replaced by indicator `problem-sending`;
// - "Thank you" (`problem-sent`) replaces button, sheet does not collapse.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/l10n/l10n.dart';
import 'package:music_stream/screens/problem_sheet.dart';

Future<void> _open(WidgetTester tester, ProblemSend send) => tester.pumpWidget(
  MaterialApp(
    locale: const Locale('ru'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: SingleChildScrollView(
        child: ProblemSheet(
          place: ProblemPlace.player,
          trackId: '33333333-3333-3333-3333-333333333333',
          appVersion: '0.9.0+42',
          send: send,
        ),
      ),
    ),
  ),
);

Finder _reason(String id) => find.byKey(Key('problem-reason-$id'));
final _text = find.byKey(const Key('problem-text'));
final _send = find.byKey(const Key('problem-send'));
final _sending = find.byKey(const Key('problem-sending'));
final _sent = find.byKey(const Key('problem-sent'));

bool _enabled(WidgetTester tester) =>
    tester.widget<FilledButton>(_send).onPressed != null;

void main() {
  testWidgets('text without reason sent as \'Other\'', (tester) async {
    final reports = <ProblemReport>[];
    await _open(tester, (report) async {
      reports.add(report);
      return ProblemResult.sent;
    });

    await tester.enterText(_text, '  шипит на второй минуте ');
    await tester.pump();
    expect(_enabled(tester), isTrue);
    await tester.tap(_send);
    await tester.pumpAndSettle();

    expect(reports, hasLength(1));
    expect(reports.single.reason, 'other');
    expect(reports.single.text, 'шипит на второй минуте');
    // "Other" is checked: user sees which reason was sent.
    expect(
      find.descendant(of: _reason('other'), matching: find.byIcon(Icons.check)),
      findsOneWidget,
    );
  });

  testWidgets('selected reason not replaced by text', (tester) async {
    final reports = <ProblemReport>[];
    await _open(tester, (report) async {
      reports.add(report);
      return ProblemResult.sent;
    });

    await tester.tap(_reason('bad_sound'));
    await tester.enterText(_text, 'шипит');
    await tester.pump();
    await tester.tap(_send);
    await tester.pumpAndSettle();

    expect(reports.single.reason, 'bad_sound');
  });

  testWidgets('nothing to send - button is disabled and visible', (
    tester,
  ) async {
    var calls = 0;
    await _open(tester, (_) async {
      calls++;
      return ProblemResult.sent;
    });

    expect(_enabled(tester), isFalse);

    await tester.enterText(_text, '   ');
    await tester.pump();
    expect(_enabled(tester), isFalse);

    await tester.tap(_reason('other'));
    await tester.pump();
    expect(_enabled(tester), isFalse);

    await tester.tap(_reason('no_play'));
    await tester.pump();
    expect(_enabled(tester), isTrue);

    await tester.tap(_reason('other'));
    await tester.enterText(_text, 'x');
    await tester.pump();
    expect(_enabled(tester), isTrue);
    expect(calls, 0);
  });

  testWidgets('while report sends, button shows tap accepted', (tester) async {
    final gate = Completer<ProblemResult>();
    await _open(tester, (_) => gate.future);
    await tester.tap(_reason('no_play'));
    await tester.pump();
    expect(_sending, findsNothing);

    await tester.tap(_send);
    await tester.pump();

    expect(_sending, findsOneWidget);
    expect(find.descendant(of: _send, matching: _sending), findsOneWidget);
    expect(_enabled(tester), isFalse);

    gate.complete(ProblemResult.failed);
    await tester.pumpAndSettle();
    expect(_sending, findsNothing);
    expect(_enabled(tester), isTrue);
  });

  testWidgets('\'Thank you\' replaces button, sheet stays open', (
    tester,
  ) async {
    await _open(tester, (_) async => ProblemResult.sent);
    await tester.tap(_reason('no_play'));
    await tester.pump();
    final button = tester.getRect(_send);
    final sheet = tester.getSize(find.byType(ProblemSheet));

    await tester.tap(_send);
    await tester.pumpAndSettle();

    expect(_send, findsNothing);
    expect(find.text('Спасибо, отчёт отправлен'), findsOneWidget);
    final thanks = tester.getRect(_sent);
    expect((thanks.center.dy - button.center.dy).abs(), lessThanOrEqualTo(8));
    expect(thanks.height, greaterThanOrEqualTo(48));
    expect(
      (tester.getSize(find.byType(ProblemSheet)).height - sheet.height).abs(),
      lessThanOrEqualTo(8),
    );
  });

  testWidgets('after \'Thank you\', second report is not sent', (tester) async {
    var calls = 0;
    await _open(tester, (_) async {
      calls++;
      return ProblemResult.sent;
    });
    await tester.tap(_reason('no_play'));
    await tester.pump();
    await tester.tap(_send);
    await tester.pumpAndSettle();

    await tester.tap(_reason('cover'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(_send, findsNothing);
    expect(calls, 1);
    // Selected reason matches the one sent with report.
    expect(
      find.descendant(
        of: _reason('no_play'),
        matching: find.byIcon(Icons.check),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _reason('cover'), matching: find.byIcon(Icons.check)),
      findsNothing,
    );
  });
}
