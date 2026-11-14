import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

const _channel = MethodChannel('apertono/screen');

/// Keeps the phone screen from going dark while [on] is true (FT-843): song lyrics are read
/// without touching the screen. Released when [on] turns false and when the widget goes away.
class KeepScreenOn extends StatefulWidget {
  const KeepScreenOn({super.key, required this.on, required this.child});

  final bool on;
  final Widget child;

  @override
  State<KeepScreenOn> createState() => _KeepScreenOnState();
}

class _KeepScreenOnState extends State<KeepScreenOn> {
  void _set(bool on) {
    // No platform side (tests, another OS) — the screen simply behaves as usual.
    _channel.invokeMethod<void>('keepOn', on).catchError((Object _) {});
  }

  @override
  void initState() {
    super.initState();
    if (widget.on) _set(true);
  }

  @override
  void didUpdateWidget(KeepScreenOn old) {
    super.didUpdateWidget(old);
    if (old.on != widget.on) _set(widget.on);
  }

  @override
  void dispose() {
    if (widget.on) _set(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
