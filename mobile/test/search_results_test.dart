import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/app.dart';
import 'package:music_stream/models/track.dart';

void main() {
  testWidgets('results show canonical title and artist', (tester) async {
    await tester.pumpWidget(
      MusicApp(
        catalog: const [
          Track(
            id: '1',
            title: 'Nothing Else Matters',
            artist: 'Metallica',
            durationMs: 388000,
            artworkUrl: 'https://example.test/cover',
          ),
        ],
      ),
    );

    await tester.enterText(find.byKey(const Key('search-field')), 'metallica');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump();

    expect(find.text('Nothing Else Matters'), findsWidgets);
    expect(find.text('Metallica · 6:28'), findsWidgets);
    expect(find.text('FLAC'), findsNothing);
  });
}
