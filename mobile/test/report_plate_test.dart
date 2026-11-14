import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/screens/catalog_screens.dart';
import 'package:music_stream/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';

/// P-A82 item 3 (FT-567): "Send report" is a badge styled like "Queue", row
/// does not jump.
///
/// Owner finding 05.10: after tap, button (48 px) was replaced by bare text
/// (~20 px), shifting screen below it. Badge maintains constant height across all
/// states; color and corner radius match "Queue" header in player.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final plate = find.byKey(const Key('report-plate'));

  for (final (name, code, status, says) in const [
    ('отправлен', 202, 'accepted', 'Отчёт отправлен'),
    ('выключены', 503, 'reports_off', 'Отчёты выключены на сервере'),
    ('не ушёл', 500, 'internal', 'Не удалось отправить'),
  ]) {
    testWidgets('report $name: banner same height, screen did not shift', (
      tester,
    ) async {
      final rig = Rig();
      rig.server.fail('GET /v1/genres', 500, 'internal');
      rig.server.on(
        'POST /v1/reports',
        (_) => answer(code, {'status': status}),
      );
      await rig.screen(tester, (services) => GenresScreen(services: services));

      expect(plate, findsOneWidget);
      expect(
        find.descendant(of: plate, matching: find.text('Отправить отчёт')),
        findsOneWidget,
      );
      final material = tester.widget<Material>(
        find
            .descendant(
              of: plate,
              matching: find.byType(Material),
              matchRoot: true,
            )
            .first,
      );
      expect(
        material.color,
        ApertonoColors.surface,
        reason: 'not in queue style',
      );
      final before = tester.getRect(plate);
      final retry = tester.getRect(find.text('Повторить'));

      await tapAndSettle(tester, find.byKey(const Key('send-report')));

      expect(
        find.descendant(of: plate, matching: find.text(says)),
        findsOneWidget,
      );
      expect(tester.getRect(plate), before, reason: 'banner resized');
      expect(
        tester.getRect(find.text('Повторить')),
        retry,
        reason: 'screen shifted after tap',
      );
    });
  }
}
