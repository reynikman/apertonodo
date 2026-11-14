import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/app.dart';

void main() {
  testWidgets('first frame is Search without login', (tester) async {
    await tester.pumpWidget(const MusicApp());

    expect(find.byKey(const Key('search-field')), findsOneWidget);
    expect(find.text('Войти'), findsNothing);
    expect(find.text('0'), findsNothing);
  });
}
