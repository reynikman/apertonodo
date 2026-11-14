import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/playback.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';
import 'golden_support.dart';

/// FT-801 (owner 12.10 remark: "we always have mini-player"). "My
/// music" must fit entirely ABOVE mini-player: song plays almost
/// always, and screen fitting only without it does not fit.
/// FT-798 checked layout on empty player — "Import" stood on mini-player
/// spot, and with playing song screen slid into scrolling.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const tiles = [
    'favorites',
    'playlists',
    'history',
    'downloads',
    'device',
    'rated',
    'disliked',
    'import',
  ];
  final mini = find.byKey(const Key('mini-player'));

  Future<void> libraryWhilePlaying(WidgetTester tester, Size size) async {
    usePhone(tester, size);
    final rig = Rig();
    await rig.start(tester);
    await tester.pumpAndSettle();
    await typeSearch(tester, 'metallica');
    await tester.tap(find.text('Nothing Else Matters'));
    await tester.pump();
    rig.audio.emit(AudioPhase.playing);
    await tester.pumpAndSettle();
    await openTab(tester, 'library');
    await tester.pumpAndSettle();
  }

  for (final size in const [Size(412, 915), Size(360, 800)]) {
    final name = '${size.width.toInt()}×${size.height.toInt()}';

    testWidgets('$name, playing: entire screen fits above mini-player', (
      tester,
    ) async {
      await libraryWhilePlaying(tester, size);
      expect(tester.takeException(), isNull);
      expect(mini, findsOneWidget);
      final ceiling = tester.getRect(mini).top;

      for (final tile in tiles) {
        final finder = find.byKey(Key('library-$tile'));
        expect(finder, findsOneWidget, reason: 'missing «$tile»');
        final rect = tester.getRect(finder);
        expect(
          rect.bottom,
          lessThanOrEqualTo(ceiling + 0.5),
          reason: '«$tile» goes under mini-player',
        );
        expect(
          rect.height,
          greaterThanOrEqualTo(48),
          reason: '«$tile» < 48 — cannot tap with finger',
        );
      }

      for (final element in find.byType(Scrollable).evaluate()) {
        final state = (element as StatefulElement).state as ScrollableState;
        if (state.position.axis != Axis.vertical) continue;
        expect(
          state.position.maxScrollExtent,
          0,
          reason: 'screen scrolls — must fit entirely',
        );
      }
    });

    testWidgets('$name, playing: favorites tile still remains primary', (
      tester,
    ) async {
      await libraryWhilePlaying(tester, size);
      final fav = tester.getRect(find.byKey(const Key('library-favorites')));
      final cell = tester.getRect(find.byKey(const Key('library-playlists')));
      expect(fav.height, greaterThanOrEqualTo(cell.height * 1.1));
    });
  }

  testWidgets(
    'font is not bold: tile titles use w500, section headers at most w600',
    (tester) async {
      // Owner 12.10 remark: "why is it so bold, as if written in triple
      // caps". Only screen header remains bold.
      await libraryWhilePlaying(tester, const Size(412, 915));
      int weight(String text) {
        final found = find.text(text);
        expect(found, findsOneWidget, reason: 'missing text «$text»');
        final widget = tester.widget<Text>(found);
        final style = DefaultTextStyle.of(
          tester.element(found),
        ).style.merge(widget.style);
        return style.fontWeight!.value;
      }

      for (final title in [
        'Плейлисты',
        'История',
        'Скачанное',
        'С телефона',
        'Оценённые',
        'Не нравится',
        'Импорт',
      ]) {
        expect(
          weight(title),
          lessThanOrEqualTo(500),
          reason: '«$title» is bold',
        );
      }
      for (final heading in ['Любимые песни', 'Медиатека', 'Мои оценки']) {
        expect(
          weight(heading),
          lessThanOrEqualTo(600),
          reason: '«$heading» is bold',
        );
      }
    },
  );
}
