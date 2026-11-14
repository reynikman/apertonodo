import 'package:flutter/material.dart';
import 'package:music_stream/theme.dart';

/// Seek direction for podcasts and books (P-A100).
enum SkipKind { back, forward }

/// Seek step: back 15 seconds, forward 30 seconds.
Duration skipStep(SkipKind kind) => switch (kind) {
  SkipKind.back => const Duration(seconds: 15),
  SkipKind.forward => const Duration(seconds: 30),
};

/// Target position calculation clamped to 0...duration.
///
/// If duration is unknown (`null`) or equals 0, there is no upper bound.
Duration skipTarget(Duration position, SkipKind kind, Duration? duration) {
  final step = skipStep(kind);
  final target = kind == SkipKind.back ? position - step : position + step;
  if (target < Duration.zero) {
    return Duration.zero;
  }
  if (duration != null && duration > Duration.zero && target > duration) {
    return duration;
  }
  return target;
}

/// Accessibility labels (TalkBack).
class SkipTexts {
  const SkipTexts({required this.back, required this.forward});

  final String back;
  final String forward;
}

/// Skip button "-15 / +30 s" for podcasts and books.
class SkipButton extends StatelessWidget {
  const SkipButton({
    super.key,
    required this.kind,
    this.onPressed,
    required this.texts,
  });

  final SkipKind kind;
  final VoidCallback? onPressed;
  final SkipTexts texts;

  @override
  Widget build(BuildContext context) {
    final tooltip = switch (kind) {
      SkipKind.back => texts.back,
      SkipKind.forward => texts.forward,
    };
    final seconds = switch (kind) {
      SkipKind.back => '15',
      SkipKind.forward => '30',
    };
    final icon = switch (kind) {
      SkipKind.back => Icons.rotate_left,
      SkipKind.forward => Icons.rotate_right,
    };

    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Stack(
        alignment: Alignment.center,
        children: [
          Icon(icon),
          ExcludeSemantics(
            child: Builder(
              builder: (context) {
                return Text(
                  seconds,
                  style: TextStyle(
                    fontFamily: ApertonoFonts.sans,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: IconTheme.of(context).color,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
