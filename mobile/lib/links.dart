import 'package:flutter/services.dart';

/// Open news link externally (FT-579, Р-A83).
///
/// Browser or app, if installed (`t.me`, YouTube), is chosen by
/// Android: link is dispatched via general ACTION_VIEW intent (system chooser).
/// This is the only exit from app outward — news card itself navigates
/// nowhere.
class Links {
  Links._();

  static const _channel = MethodChannel('apertono/device');

  /// No bridge (tests, foreign screen) — nothing to open with, link simply remains.
  static Future<void> open(Uri uri) async {
    // Address comes from foreign feed: externally — only normal web link.
    if (uri.scheme != 'https' && uri.scheme != 'http') return;
    try {
      await _channel.invokeMethod<void>('openUrl', uri.toString());
    } catch (_) {
      // Silently: missing platform is no reason to crash over "Source" button.
    }
  }
}
