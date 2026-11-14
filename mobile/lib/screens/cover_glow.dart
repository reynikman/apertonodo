import 'dart:async';

import 'package:flutter/material.dart';

/// Dominant cover color. Failure is null, not amber.
Future<Color?> colorFromCover(ImageProvider image) async {
  final stream = image.resolve(
    const ImageConfiguration(size: Size(112.0, 112.0)),
  );
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, sync) {
      stream.removeListener(listener);
      info.dispose();
    },
    onError: (exception, stackTrace) {
      stream.removeListener(listener);
    },
  );
  stream.addListener(listener);

  try {
    final scheme = await ColorScheme.fromImageProvider(
      provider: image,
      brightness: Brightness.dark,
    );
    return scheme.primary;
  } catch (_) {
    return null;
  }
}

/// Glow and lighting from dominant cover color.
///
/// Buttons, bars, and tabs are not tinted with this color. Color is computed
/// asynchronously: cover is drawn immediately, glow appears when ready.
/// No artwork means no glow, not an error.
class CoverGlow extends StatefulWidget {
  const CoverGlow({
    super.key,
    required this.child,
    this.image,
    this.size = 48,
    this.readColor = colorFromCover,
  });

  static const glowKey = Key('cover-glow');

  final Widget child;
  final ImageProvider? image;
  final double size;
  final Future<Color?> Function(ImageProvider image) readColor;

  @override
  State<CoverGlow> createState() => _CoverGlowState();
}

class _CoverGlowState extends State<CoverGlow> {
  Color? _glow;

  @override
  void initState() {
    super.initState();
    unawaited(_read());
  }

  @override
  void didUpdateWidget(CoverGlow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image != widget.image) {
      _glow = null;
      unawaited(_read());
    }
  }

  Future<void> _read() async {
    final image = widget.image;
    if (image == null) return;
    try {
      final color = await widget.readColor(image);
      if (!mounted || widget.image != image) return;
      setState(() => _glow = color);
    } catch (_) {
      // No color — no glow. Artwork is already on screen.
    }
  }

  @override
  Widget build(BuildContext context) {
    final glow = widget.image == null ? null : _glow;
    final size = widget.size;
    return Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        if (glow != null) ...[
          // Glow is wider than artwork, but takes no layout space: Positioned
          // does not participate in Stack size. Otherwise player reserved
          // 2.2x cover heights for glow, pushing controls off-screen (snapshot
          // from device 21.09).
          Positioned(
            left: -size * 0.6,
            top: -size * 0.6,
            right: -size * 0.6,
            bottom: -size * 0.6,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      glow.withValues(alpha: 0.28),
                      glow.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
          ),
          IgnorePointer(
            child: DecoratedBox(
              key: CoverGlow.glowKey,
              decoration: BoxDecoration(
                boxShadow: [
                  BoxShadow(
                    color: glow.withValues(alpha: 0.55),
                    blurRadius: size * 0.45,
                    spreadRadius: size * 0.08,
                  ),
                ],
              ),
              child: SizedBox(width: size, height: size),
            ),
          ),
        ],
        widget.child,
      ],
    );
  }
}
