import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:music_stream/app.dart';
import 'test_session.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('clean install first frame is search', (tester) async {
    await seedTestSession();
    await tester.pumpWidget(const MusicApp());
    await tester.pump();
    expect(find.byKey(const Key('search-field')), findsOneWidget);
    expect(find.text('Войти'), findsNothing);
  });
}
