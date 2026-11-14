// Phase J mobile: typing suggestions, recent queries, artist row,
// and dimmed notice "may not play".
//
// Primary invariant guarded here is privacy boundary. Search query text absent
// from server logs and database; only place search history exists is
// the device itself. If suggestions send queries externally or recent
// queries sync to server, owner decision from 20.09.2026 is violated
// silently.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/catalog.dart';
import 'package:music_stream/models/track.dart';
import 'package:music_stream/recent_queries.dart';
import 'package:music_stream/screens/parts.dart';
import 'package:music_stream/screens/search_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

const numb = Track(
  id: '1',
  title: 'Numb',
  artist: 'Linkin Park',
  durationMs: 185000,
  artworkUrl: '',
);
const chokehold = Track(
  id: '2',
  title: 'Chokehold',
  artist: 'Sleep Token',
  durationMs: 240000,
  artworkUrl: '',
  playable: false,
);

Future<void> type(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('search-field')), text);
  await tester.pump();
}

Future<void> submit(WidgetTester tester) async {
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pump();
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('suggestion arrives while typing and starts search', (
    tester,
  ) async {
    final asked = <String>[];
    final searched = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: SearchScreen(
          onSearch: (query) async {
            searched.add(query);
            return const SearchResult(tracks: [numb]);
          },
          onSuggest: (query) async {
            asked.add(query);
            return const ['Linkin Park', 'Linkin Park Numb'];
          },
          onSelect: (_, _) {},
        ),
      ),
    );

    await type(tester, 'lin');
    // No suggestion requested before debounce: single keystroke is not a query yet.
    expect(asked, isEmpty);
    await tester.pump(SearchScreen.typingPause);
    await tester.pump();
    expect(asked, ['lin']);
    expect(find.byKey(const Key('suggestion-Linkin Park')), findsOneWidget);

    await tester.tap(find.byKey(const Key('suggestion-Linkin Park')));
    await tester.pump();
    await tester.pump();
    expect(searched, ['Linkin Park']);
    // Results arrived — suggestions yield to results.
    expect(find.byKey(const Key('suggestion-Linkin Park')), findsNothing);
    expect(find.text('Numb'), findsOneWidget);
  });

  testWidgets('fast typing — one suggestion request, not six', (tester) async {
    final asked = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: SearchScreen(
          onSearch: (_) async => const SearchResult(),
          onSuggest: (query) async {
            asked.add(query);
            return const [];
          },
          onSelect: (_, _) {},
        ),
      ),
    );

    for (final text in ['l', 'li', 'lin', 'link', 'linki', 'linkin']) {
      await type(tester, text);
    }
    await tester.pump(SearchScreen.typingPause);
    await tester.pump();
    expect(asked, ['linkin']);
  });

  testWidgets('suggestion for old query is not shown', (tester) async {
    final answers = <String, List<String>>{
      'lin': ['Linkin Park'],
      'met': ['Metallica'],
    };
    await tester.pumpWidget(
      MaterialApp(
        home: SearchScreen(
          onSearch: (_) async => const SearchResult(),
          onSuggest: (query) async => answers[query] ?? const [],
          onSelect: (_, _) {},
        ),
      ),
    );

    await type(tester, 'lin');
    await tester.pump(SearchScreen.typingPause);
    await type(tester, 'met');
    await tester.pump(SearchScreen.typingPause);
    await tester.pump();

    expect(find.byKey(const Key('suggestion-Metallica')), findsOneWidget);
    expect(find.byKey(const Key('suggestion-Linkin Park')), findsNothing);
  });

  testWidgets('recent query stays on the phone and searches in one tap', (
    tester,
  ) async {
    final searched = <String>[];
    Widget screen() {
      return MaterialApp(
        home: SearchScreen(
          onSearch: (query) async {
            searched.add(query);
            return const SearchResult(tracks: [numb]);
          },
          onSelect: (_, _) {},
          recent: RecentQueries(),
        ),
      );
    }

    await tester.pumpWidget(screen());
    await tester.pump();
    await type(tester, 'linkin park');
    await submit(tester);

    // Reopened screen preserves query: stored in device memory.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(screen());
    await tester.pump();
    expect(find.byKey(const Key('recent-linkin park')), findsOneWidget);

    await tester.tap(find.byKey(const Key('recent-linkin park')));
    await tester.pump();
    await tester.pump();
    expect(searched, ['linkin park', 'linkin park']);
  });

  testWidgets('"Clear" removes recent from screen and storage', (tester) async {
    SharedPreferences.setMockInitialValues({
      'recent-queries': ['metallica'],
    });
    Widget screen() {
      return MaterialApp(
        home: SearchScreen(
          onSearch: (_) async => const SearchResult(),
          onSelect: (_, _) {},
          recent: RecentQueries(),
        ),
      );
    }

    await tester.pumpWidget(screen());
    await tester.pump();
    expect(find.byKey(const Key('recent-metallica')), findsOneWidget);

    await tester.tap(find.byKey(const Key('recent-clear')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('recent-metallica')), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(screen());
    await tester.pump();
    expect(find.byKey(const Key('recent-metallica')), findsNothing);
  });

  testWidgets('artist stands as a row above songs and opens the page', (
    tester,
  ) async {
    final opened = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: SearchScreen(
          onSearch: (_) async =>
              const SearchResult(artists: ['Linkin Park'], tracks: [numb]),
          onSelect: (_, _) {},
          onArtist: opened.add,
        ),
      ),
    );

    await type(tester, 'linkin park');
    await submit(tester);

    final artist = find.byKey(const Key('artist-Linkin Park'));
    expect(artist, findsOneWidget);
    // Artist appears above tracks: artist is primary response to band name query.
    expect(
      tester.getTopLeft(artist).dy,
      lessThan(tester.getTopLeft(find.text('Numb')).dy),
    );

    await tester.tap(artist);
    await tester.pump();
    expect(opened, ['Linkin Park']);
  });

  testWidgets('row "may not play" is pale but in place', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SearchScreen(
          onSearch: (_) async => const SearchResult(tracks: [numb, chokehold]),
          onSelect: (_, _) {},
        ),
      ),
    );

    await type(tester, 'numb');
    await submit(tester);

    // Color applied to rendered text rather than ListTile: row can be
    // constructed without it (FT-469).
    Color? colorOf(String title) => tester
        .renderObject<RenderParagraph>(find.text(title))
        .text
        .style
        ?.color;
    final pale = paleColor(tester.element(find.text('Chokehold')));
    expect(colorOf('Chokehold'), pale);
    expect(colorOf('Numb'), isNot(pale));
  });
}
