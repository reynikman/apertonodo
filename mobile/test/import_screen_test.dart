import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/screens/import_screen.dart';

import 'fake_server.dart';
import 'back.dart';

/// Import (P5, step 5; P-A47, P-A48): file or pasted text → report
/// "found N of M" → "Save" to new playlist or "Favorite songs".
/// Report and save — samples `contracts/import-*` (step 4 contract).

const importId = '4f0c2a9e-7d1b-4c3e-9a5f-2b8d6e1f0a3c';

final csv = Uint8List.fromList(
  utf8.encode('Track URI,Track Name,Artist Name(s)\n'),
);

ImportFile picked(String name, Uint8List bytes) => (name: name, bytes: bytes);

/// Server with import samples; save responds according to target in body.
Rig importRig({Map<String, dynamic>? report}) {
  final rig = Rig();
  rig.server.on(
    'POST /v1/imports',
    (_) => answer(200, report ?? sample('import-create')),
  );
  rig.server.on('POST /v1/imports/*/save', (request) {
    final body = bodyOf(request);
    if (body['target'] == 'favorites') {
      return answer(200, {'target': 'favorites', 'added': 2, 'missing': 1});
    }
    return answer(200, sample('import-save'));
  });
  return rig;
}

Future<void> openWithFile(
  WidgetTester tester,
  Rig rig, {
  ImportFile? file,
}) async {
  final chosen = file ?? picked('Liked_Songs.csv', csv);
  await rig.screen(
    tester,
    (services) =>
        ImportScreen(services: services, pickFile: () async => chosen),
  );
  await tapAndSettle(tester, find.byKey(const Key('import-pick-file')));
}

/// Request log writes path number with asterisk; whose report — [savedIds].
const saveRoute = 'POST /v1/imports/*/save';

List<String> savedIds(Rig rig) => [
  for (final request in rig.server.calls(saveRoute))
    request.url.pathSegments[2],
];

Finder row(int n) => find.byKey(Key('import-row-$n'));

void main() {
  testWidgets('Import is the last row of My Music and opens import screen', (
    tester,
  ) async {
    final rig = importRig();
    await rig.start(tester);
    await openTab(tester, 'library');

    final entry = find.byKey(const Key('library-import'));
    await tester.scrollUntilVisible(
      entry,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.descendant(of: entry, matching: find.text('Импорт')),
      findsOneWidget,
    );
    // Last: "Downloaded" does not shift down due to rare row.
    for (final above in ['library-playlists', 'library-downloads']) {
      final key = find.byKey(Key(above));
      if (key.evaluate().isNotEmpty) {
        expect(tester.getRect(entry).top, greaterThan(tester.getRect(key).top));
      }
    }

    await tapAndSettle(tester, entry);
    expect(find.byKey(const Key('import-pick-file')), findsOneWidget);
    expect(find.byKey(const Key('import-paste')), findsOneWidget);
    expect(rig.server.calls('POST /v1/imports'), isEmpty);
  });

  testWidgets('file sent to server in full, report accurate', (tester) async {
    final rig = importRig();
    await openWithFile(tester, rig);

    expect(rig.server.bodies('POST /v1/imports'), [
      {'name': 'Liked_Songs.csv', 'data': base64Encode(csv)},
    ]);
    expect(
      tester.widget<Text>(find.byKey(const Key('import-summary'))).data,
      'Нашлось 1 из 3 · сомнительно 1 · не нашлось 1',
    );
    // Each line in its place; unmatched is dim, but not missing.
    expect(tester.getRect(row(0)).top, lessThan(tester.getRect(row(1)).top));
    expect(tester.getRect(row(1)).top, lessThan(tester.getRect(row(2)).top));
    expect(
      find.descendant(of: row(0), matching: find.text('Duality')),
      findsOneWidget,
    );
    expect(alphaOf(tester, 'No Such Song'), lessThan(0.5));
    expect(alphaOf(tester, 'Duality'), 1.0);
    // Favorites export: switch "to Favorites" is already enabled.
    expect(
      tester.widget<Switch>(find.byKey(const Key('import-to-favorites'))).value,
      isTrue,
    );
  });

  testWidgets('doubtful need not be checked: Save sends to Favorites', (
    tester,
  ) async {
    final rig = importRig();
    await openWithFile(tester, rig);

    await tapAndSettle(tester, find.byKey(const Key('import-save')));

    expect(rig.server.bodies(saveRoute), [
      {'list': 0, 'target': 'favorites', 'choices': <String, dynamic>{}},
    ]);
    expect(savedIds(rig), [importId]);
    expect(find.widgetWithText(AppBar, 'Любимые песни'), findsOneWidget);
    expect(find.byType(ImportScreen), findsNothing);
  });

  testWidgets('picking variant and playlist over Favorites', (tester) async {
    final rig = importRig();
    await openWithFile(tester, rig);

    await tapAndSettle(tester, row(1));
    // Two Lithium tracks by two Nirvana artists distinguished by duration.
    expect(find.textContaining('4:17'), findsWidgets);
    expect(find.textContaining('3:10'), findsWidgets);
    expect(find.byKey(const Key('import-choice-1-none')), findsOneWidget);
    await tapAndSettle(tester, find.byKey(const Key('import-choice-1-1')));

    await tapAndSettle(tester, find.byKey(const Key('import-to-favorites')));
    await tapAndSettle(tester, find.byKey(const Key('import-save')));

    expect(rig.server.bodies(saveRoute), [
      {
        'list': 0,
        'target': 'playlist',
        'choices': {'1': 1},
      },
    ]);
    // New playlist opened under name from server response.
    expect(find.widgetWithText(AppBar, 'Liked Songs'), findsOneWidget);
    expect(rig.server.calls('GET /v1/playlists/*'), isNotEmpty);
  });

  testWidgets('None - track row remains dimmed', (tester) async {
    final rig = importRig();
    await openWithFile(tester, rig);

    await tapAndSettle(tester, row(1));
    await tapAndSettle(tester, find.byKey(const Key('import-choice-1-none')));
    await tapAndSettle(tester, find.byKey(const Key('import-to-favorites')));
    await tapAndSettle(tester, find.byKey(const Key('import-save')));

    expect(rig.server.bodies(saveRoute), [
      {
        'list': 0,
        'target': 'playlist',
        'choices': {'1': null},
      },
    ]);
  });

  testWidgets('double tap on Save results in single save', (tester) async {
    final rig = importRig();
    await openWithFile(tester, rig);

    final save = find.byKey(const Key('import-save'));
    await tester.tap(save);
    await tester.tap(save, warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(rig.server.calls(saveRoute), hasLength(1));
  });

  testWidgets('pasted text sends same request without file name', (
    tester,
  ) async {
    final rig = importRig();
    await rig.screen(
      tester,
      (services) =>
          ImportScreen(services: services, pickFile: () async => null),
    );

    await tapAndSettle(tester, find.byKey(const Key('import-paste')));
    const text = 'Slipknot — Duality\nNirvana — Lithium';
    await tester.enterText(find.byKey(const Key('import-text')), text);
    await tapAndSettle(tester, find.byKey(const Key('import-send')));

    expect(rig.server.bodies('POST /v1/imports'), [
      {'name': null, 'data': base64Encode(utf8.encode(text))},
    ]);
    expect(find.byKey(const Key('import-summary')), findsOneWidget);
  });

  testWidgets(
    'server failure shows its phrase; cancel and big file make no request',
    (tester) async {
      final rig = importRig();
      const message =
          'CSV должен содержать столбцы Track Name и Artist Name(s).';
      rig.server.on(
        'POST /v1/imports',
        (_) => answer(422, {'status': 'bad_columns', 'message': message}),
      );
      ImportFile? next = picked('Liked_Songs.csv', csv);
      await rig.screen(
        tester,
        (services) =>
            ImportScreen(services: services, pickFile: () async => next),
      );
      final pick = find.byKey(const Key('import-pick-file'));

      await tapAndSettle(tester, pick);
      expect(find.text(message), findsOneWidget);
      expect(find.byKey(const Key('import-summary')), findsNothing);
      expect(rig.server.calls('POST /v1/imports'), hasLength(1));

      next = null; // the person closed the file picker
      await tapAndSettle(tester, pick);
      expect(rig.server.calls('POST /v1/imports'), hasLength(1));

      next = picked('big.csv', Uint8List(10 * 1024 * 1024 + 1));
      await tapAndSettle(tester, pick);
      expect(find.textContaining('10 МиБ'), findsOneWidget);
      expect(rig.server.calls('POST /v1/imports'), hasLength(1));
    },
  );

  testWidgets('multiple lists in file: overview and Save All button', (
    tester,
  ) async {
    final one = sample('import-create');
    final list = (one['lists'] as List).first as Map<String, dynamic>;
    final report = {
      ...one,
      'lists': [
        list,
        {...list, 'index': 1, 'name': 'Дорога', 'favorites_hint': false},
      ],
    };
    final rig = importRig(report: report);
    await openWithFile(tester, rig, file: picked('spotify.zip', csv));

    expect(find.byKey(const Key('import-list-0')), findsOneWidget);
    expect(find.byKey(const Key('import-list-1')), findsOneWidget);
    expect(find.text('Дорога'), findsOneWidget);

    await tapAndSettle(tester, find.byKey(const Key('import-list-1')));
    expect(find.byKey(const Key('import-summary')), findsOneWidget);
    expect(
      tester.widget<Switch>(find.byKey(const Key('import-to-favorites'))).value,
      isFalse,
    );
    await tapBack(tester);
    await tester.pumpAndSettle();

    await tapAndSettle(tester, find.byKey(const Key('import-save-all')));
    // Export of favorites — to "Favorites", others — to playlists.
    expect(rig.server.bodies(saveRoute), [
      {'list': 0, 'target': 'favorites', 'choices': <String, dynamic>{}},
      {'list': 1, 'target': 'playlist', 'choices': <String, dynamic>{}},
    ]);
    expect(find.widgetWithText(AppBar, 'Плейлисты'), findsOneWidget);
  });

  testWidgets('TalkBack and touch: each report button has name and 48 dp', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final rig = importRig();
    await openWithFile(tester, rig);

    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    semantics.dispose();
  });
}
