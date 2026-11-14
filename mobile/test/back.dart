import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// "Back" arrow in screen header — in any language (FT-600).
///
/// `tester.pageBack()` looks for it by English tooltip "Back", but with translation
/// tooltip is in phone's language ("Назад"). We find the button itself.
Future<void> tapBack(WidgetTester tester) =>
    tester.tap(find.byType(BackButton).hitTestable().last);
