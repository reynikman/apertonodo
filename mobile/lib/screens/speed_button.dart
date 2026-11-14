import 'package:flutter/material.dart';
import 'package:music_stream/theme.dart';

/// Speed as text for button: "1×", "1.25×", "0.5×".
String speedLabel(double speed) {
  final text = speed.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
  return '$text×';
}

/// Episode playback speed button (FT-730): shows current speed, tapping
/// opens list of allowed speeds.
class SpeedButton extends StatelessWidget {
  const SpeedButton({
    super.key,
    required this.speed,
    required this.speeds,
    required this.onSelected,
    required this.tooltip,
  });

  final double speed;
  final List<double> speeds;
  final ValueChanged<double> onSelected;

  /// Accessibility label for TalkBack: "Speed".
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final label = speedLabel(speed);
    return PopupMenuButton<double>(
      // Label is read by Semantics below; tooltip would duplicate it for TalkBack.
      tooltip: '',
      initialValue: speed,
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final s in speeds)
          PopupMenuItem<double>(
            key: ValueKey('speed-$s'),
            value: s,
            child: Text(
              speedLabel(s),
              style: TextStyle(
                fontFamily: ApertonoFonts.sans,
                fontWeight: s == speed ? FontWeight.w700 : FontWeight.w400,
                color: s == speed
                    ? ApertonoColors.accent
                    : ApertonoColors.textPrimary,
              ),
            ),
          ),
      ],
      child: Semantics(
        label: '$tooltip $label',
        button: true,
        excludeSemantics: true,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          child: Center(
            child: ExcludeSemantics(
              child: Text(
                label,
                style: TextStyle(
                  fontFamily: ApertonoFonts.sans,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: speed == 1.0
                      ? ApertonoColors.textPrimary
                      : ApertonoColors.accent,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
