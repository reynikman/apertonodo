import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/catalog.dart';
import 'package:music_stream/models/track.dart';
import 'package:music_stream/screens/account_bar.dart';
import 'package:music_stream/screens/catalog_screens.dart';
import 'package:music_stream/screens/parts.dart';
import 'package:music_stream/screens/search_screen.dart';
import 'package:music_stream/theme.dart';

import 'fake_server.dart';

/// Owner feedback 02.10 (H; `plan/p4-fixes.md`, "Window design"): 6 — "to
/// playlist" modals and "⋮" menu; 15 — playlist selector ("+" far from "New
/// playlist", rows misaligned); 20 — account menu (checkmark, icon);
/// 22 — yellow back arrow in genre; 26 — search field; "Play album".
/// Owner: "yes, if anything I will ask to adjust later" — strictly per
/// DESIGN.md and concept (`docs/design/concept-home-overview-search.png`).
///
/// DESIGN.md rule: amber is action (play, seek, active tab,
/// primary button). Back arrow, account, clear search — chrome, light.
Future<Services> themed(
  WidgetTester tester,
  Rig rig,
  Widget Function(Services services) build,
) async {
  addTearDown(() => expect(rig.server.unknown, isEmpty));
  final services = Services(
    server: rig.server.api(),
    search: rig.server.catalog().search,
    play: (_, _) {},
    prepare: (_) {},
  );
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(theme: apertonoTheme(), home: build(services)),
  );
  await tester.pumpAndSettle();
  return services;
}

/// Color used to render icon (icon font glyph).
Color? glyphColor(WidgetTester tester, Finder icon) => tester
    .widget<RichText>(
      find.descendant(of: icon, matching: find.byType(RichText)).first,
    )
    .text
    .style
    ?.color;

Widget opener(String label, void Function(BuildContext context) onTap) =>
    Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => onTap(context),
            child: Text(label),
          ),
        ),
      ),
    );

void main() {
  testWidgets('22: back arrow on genre screen is light, not amber', (
    tester,
  ) async {
    final rig = Rig();
    await themed(
      tester,
      rig,
      (services) => opener(
        'rock',
        (context) => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ArtistsScreen(
              services: services,
              title: 'Рок',
              load: (offset) =>
                  services.server.artistCatalog(genre: 'rock', offset: offset),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('rock'));
    await tester.pumpAndSettle();

    expect(
      glyphColor(tester, find.byType(BackButtonIcon)),
      ApertonoColors.textPrimary,
    );
  });

  group('20: account menu', () {
    Future<void> openMenu(WidgetTester tester, {required bool reports}) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: apertonoTheme(),
          // As in "My music" header (library_screens.dart): in row, not AppBar.
          home: Scaffold(
            body: SafeArea(
              child: Row(
                children: [
                  const Spacer(),
                  AccountBar(
                    text: (en, ru) => ru,
                    onAction: (_) {},
                    automaticReports: reports,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('account icon is light like the rest of chrome elements', (
      tester,
    ) async {
      await openMenu(tester, reports: false);
      expect(
        glyphColor(tester, find.byKey(const Key('account-button'))),
        ApertonoColors.textPrimary,
      );
    });

    for (final reports in [false, true]) {
      testWidgets('reports: switch not checkbox (enabled: $reports)', (
        tester,
      ) async {
        await openMenu(tester, reports: reports);
        await tester.tap(find.byKey(const Key('account-button')));
        await tester.pumpAndSettle();

        expect(find.byType(CheckedPopupMenuItem<String>), findsNothing);
        expect(find.byIcon(Icons.check), findsNothing);
        final toggle = find.descendant(
          of: find.byKey(const Key('auto-reports')),
          matching: find.byType(Switch),
        );
        expect(toggle, findsOneWidget);
        expect(tester.widget<Switch>(toggle).value, reports);
      });
    }
  });

  test('6, 20: menus and dialogs graphite with border, no shadow', () {
    final theme = apertonoTheme();

    final menu = theme.popupMenuTheme;
    expect(menu.color, ApertonoColors.surfaceRaised);
    expect(menu.elevation, 0);
    expect(menu.surfaceTintColor, Colors.transparent);
    expect(
      menu.shape,
      const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(ApertonoRadii.album)),
        side: BorderSide(color: ApertonoColors.borderStrong),
      ),
    );

    final dialog = theme.dialogTheme;
    expect(dialog.backgroundColor, ApertonoColors.surfaceRaised);
    expect(dialog.elevation, 0);
    expect(dialog.surfaceTintColor, Colors.transparent);
    expect(
      dialog.shape,
      const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(ApertonoRadii.medium)),
        side: BorderSide(color: ApertonoColors.borderStrong),
      ),
    );
  });

  testWidgets('15: playlist picker rows aligned on same line, + nearby', (
    tester,
  ) async {
    final rig = Rig();
    await themed(
      tester,
      rig,
      (services) => opener(
        'add',
        (context) => addToPlaylist(
          context,
          services,
          const Track(
            id: '00000000-0000-4000-8000-000000000001',
            title: 'Hello',
            artist: 'Adele',
            durationMs: 295000,
            artworkUrl: '',
          ),
        ),
      ),
    );
    await tester.tap(find.text('add'));
    await tester.pumpAndSettle();

    final playlist = tester.getTopLeft(find.text('В дорогу'));
    final create = tester.getTopLeft(find.text('Новый плейлист'));
    expect(
      playlist.dx,
      create.dx,
      reason: 'playlist name and New Playlist start at different positions',
    );
    final plus = tester.getTopRight(find.byIcon(Icons.add));
    expect(
      create.dx - plus.dx,
      lessThanOrEqualTo(24),
      reason: '+ is too far from New Playlist',
    );
    expect(
      glyphColor(tester, find.byIcon(Icons.add)),
      ApertonoColors.accent,
      reason: 'New Playlist is an action',
    );
  });

  group('26: search field per DESIGN.md', () {
    Future<void> openSearch(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: apertonoTheme(),
          home: SearchScreen(
            onSearch: (_) async => const SearchResult(),
            onSelect: (_, _) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    // Field dimensions (50, radius 16) — per Figma export, covered by
    // search_design_test.dart; here — what DESIGN.md specifies for text input.
    testWidgets(
      'in focus: amber border 2, white text 16, and amber cursor color',
      (tester) async {
        await openSearch(tester);
        final field = find.byKey(const Key('search-field'));
        final widget = tester.widget<TextField>(field);
        expect(
          widget.decoration!.focusedBorder,
          const OutlineInputBorder(
            borderRadius: BorderRadius.all(
              Radius.circular(ApertonoRadii.medium),
            ),
            borderSide: BorderSide(color: ApertonoColors.accent, width: 2),
          ),
        );
        final typed = tester
            .widget<EditableText>(
              find.descendant(of: field, matching: find.byType(EditableText)),
            )
            .style;
        expect(typed.color, ApertonoColors.textPrimary);
        expect(typed.fontSize, 16);
        expect(typed.fontFamily, ApertonoFonts.sans);
        expect(
          tester
              .widget<EditableText>(
                find.descendant(of: field, matching: find.byType(EditableText)),
              )
              .cursorColor,
          ApertonoColors.accent,
        );
      },
    );

    testWidgets('magnifier and cross light, not amber', (tester) async {
      await openSearch(tester);
      await tester.enterText(find.byKey(const Key('search-field')), 'numb');
      await tester.pumpAndSettle();
      expect(
        glyphColor(tester, find.byIcon(Icons.search).first),
        ApertonoColors.textSecondary,
      );
      expect(
        glyphColor(tester, find.byKey(const Key('search-clear'))),
        ApertonoColors.textSecondary,
      );
    });
  });

  testWidgets(
    'Play Album is amber capsule 40 rather than full width bar on screen',
    (tester) async {
      final rig = Rig();
      await themed(
        tester,
        rig,
        (services) => AlbumScreen(
          services: services,
          id: '00000000-0000-4000-8000-0000000000a1',
          title: 'Альбом',
        ),
      );
      final button = find.ancestor(
        of: find.text('Играть альбом'),
        matching: find.byType(FilledButton),
      );
      expect(button, findsOneWidget);
      final box = tester.getRect(button);
      expect(box.height, 40);
      expect(
        box.width,
        lessThan(400 - 2 * 16),
        reason: 'bar takes full screen width',
      );
      expect(box.left, 16, reason: 'left aligned with screen text edge');
      final style = Theme.of(tester.element(button)).filledButtonTheme.style!;
      expect(
        style.backgroundColor!.resolve({}),
        ApertonoColors.accent,
        reason: 'primary button is amber',
      );
    },
  );
}
