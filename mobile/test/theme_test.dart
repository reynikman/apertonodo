import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/app.dart';

void main() {
  testWidgets('obsidian bg, amber, shadowless menu, Onest', (tester) async {
    await tester.pumpWidget(const MusicApp());

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.dark);

    final context = tester.element(find.byType(Scaffold).first);
    final theme = Theme.of(context);

    expect(theme.scaffoldBackgroundColor, const Color(0xFF07090C));
    expect(theme.colorScheme.primary, const Color(0xFFE5A93B));
    expect(theme.textTheme.headlineSmall?.fontFamily, 'Onest');
  });
}
