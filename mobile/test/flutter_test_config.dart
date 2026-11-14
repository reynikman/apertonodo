import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// All tests run in Russian locale while Wave A of P9 translates screens (FT-600).
///
/// Without this, test would see machine language (en-US), and every translated string
/// would alter test texts and golden master snapshots. FT-606 switches tests to
/// English in a single step.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  binding.platformDispatcher.localeTestValue = const Locale('ru');
  binding.platformDispatcher.localesTestValue = const [Locale('ru')];
  await testMain();
}
