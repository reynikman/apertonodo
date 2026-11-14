import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Dark Obsidian colors. The single place the app gets them from.
abstract final class ApertonoColors {
  static const background = Color(0xFF07090C);
  static const surface = Color(0xFF0E1217);
  static const surfaceRaised = Color(0xFF151920);
  static const navItemActive = Color(0xFF181D24);
  static const border = Color(0x12FFFFFF);
  static const borderStrong = Color(0x1FFFFFFF);
  static const divider = Color(0x0FFFFFFF);
  static const accent = Color(0xFFE5A93B);
  static const accentHighlight = Color(0xFFF5B842);
  static const accentSoft = Color(0x24E5A93B);
  static const textPrimary = Color(0xFFFFFFFF);
  static const inkOnLight = Color(0xDD000000);
  static const textSecondary = Color(0xFF8C93A4);
  static const textMuted = Color(0xFF5D6574);
  static const error = Color(0xFFFFB4AB);
  static const shadow = Color(0x99000000);
  static const progressTrack = Color(0xFF1B1F26);
  static const scrim = Color(0xFF000000);
  static const cardGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF12161C), Color(0xFF0A0D12)],
  );
  static const navGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF13171D), Color(0xFF0B0E13)],
  );
}

abstract final class ApertonoFonts {
  static const sans = 'Onest';
  static const mono = 'JetBrains Mono';
}

abstract final class ApertonoRadii {
  static const pill = 26.0;
  static const xLarge = 24.0;
  static const large = 22.0;
  static const row = 20.0;
  static const medium = 16.0;
  static const genre = 14.0;
  static const album = 12.0;
  static const cover = 10.0;
  static const capsule = 22.0;
  static const hairline = 2.0;
}

abstract final class ApertonoText {
  static const screenTitle = TextStyle(
    fontFamily: ApertonoFonts.sans,
    fontSize: 26,
    height: 32 / 26,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.52,
    color: ApertonoColors.textPrimary,
  );
  static const sectionTitle = TextStyle(
    fontFamily: ApertonoFonts.sans,
    fontSize: 18,
    height: 22 / 18,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.18,
  );
  static const trackTitle = TextStyle(
    fontFamily: ApertonoFonts.sans,
    fontSize: 15,
    height: 19 / 15,
    fontWeight: FontWeight.w600,
  );
  static const trackArtist = TextStyle(
    fontFamily: ApertonoFonts.sans,
    fontSize: 12.5,
    height: 16 / 12.5,
    fontWeight: FontWeight.w400,
    color: ApertonoColors.textSecondary,
  );
  static const promoTitle = TextStyle(
    fontFamily: ApertonoFonts.sans,
    fontSize: 16.5,
    height: 20 / 16.5,
    fontWeight: FontWeight.w700,
  );
  static const artistName = TextStyle(
    fontFamily: ApertonoFonts.sans,
    fontSize: 12,
    height: 15 / 12,
    fontWeight: FontWeight.w500,
  );
  static const time = TextStyle(
    fontFamily: ApertonoFonts.mono,
    fontSize: 12,
    height: 16 / 12,
    fontWeight: FontWeight.w500,
    fontFeatures: [FontFeature.tabularFigures()],
  );
}

void registerFontLicenses() {
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'Onest',
    ], await rootBundle.loadString('fonts/OFL-Onest.txt'));
    yield LicenseEntryWithLineBreaks([
      'JetBrains Mono',
    ], await rootBundle.loadString('fonts/OFL-JetBrainsMono.txt'));
  });
}

/// Time digits: monospaced so "1:02" does not jitter.
TextStyle apertonoTimeStyle(BuildContext context) => ApertonoText.time;

ThemeData apertonoTheme() {
  const scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: ApertonoColors.accent,
    onPrimary: ApertonoColors.background,
    primaryContainer: ApertonoColors.surfaceRaised,
    onPrimaryContainer: ApertonoColors.textPrimary,
    secondary: ApertonoColors.accent,
    onSecondary: ApertonoColors.background,
    secondaryContainer: ApertonoColors.surfaceRaised,
    onSecondaryContainer: ApertonoColors.textPrimary,
    tertiary: ApertonoColors.accent,
    onTertiary: ApertonoColors.background,
    tertiaryContainer: ApertonoColors.surfaceRaised,
    onTertiaryContainer: ApertonoColors.textPrimary,
    error: ApertonoColors.error,
    onError: Color(0xFF690005),
    errorContainer: Color(0xFF93000A),
    onErrorContainer: Color(0xFFFFDAD6),
    surface: ApertonoColors.background,
    onSurface: ApertonoColors.textPrimary,
    onSurfaceVariant: ApertonoColors.textSecondary,
    outline: ApertonoColors.borderStrong,
    outlineVariant: ApertonoColors.border,
    shadow: Colors.black,
    scrim: Colors.black,
    inverseSurface: ApertonoColors.textPrimary,
    onInverseSurface: ApertonoColors.background,
    inversePrimary: ApertonoColors.accent,
    surfaceTint: Colors.transparent,
    surfaceContainerLowest: ApertonoColors.background,
    surfaceContainerLow: ApertonoColors.surface,
    surfaceContainer: ApertonoColors.surface,
    surfaceContainerHigh: ApertonoColors.surfaceRaised,
    surfaceContainerHighest: ApertonoColors.surfaceRaised,
  );

  final textTheme = Typography.material2021().white.apply(
    fontFamily: ApertonoFonts.sans,
    bodyColor: ApertonoColors.textPrimary,
    displayColor: ApertonoColors.textPrimary,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    fontFamily: ApertonoFonts.sans,
    scaffoldBackgroundColor: ApertonoColors.background,
    canvasColor: ApertonoColors.background,
    textTheme: textTheme,
    primaryTextTheme: textTheme,
    appBarTheme: const AppBarTheme(
      backgroundColor: ApertonoColors.background,
      foregroundColor: ApertonoColors.textPrimary,
      iconTheme: IconThemeData(color: ApertonoColors.textPrimary),
      actionsIconTheme: IconThemeData(color: ApertonoColors.textPrimary),
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      titleTextStyle: TextStyle(
        fontFamily: ApertonoFonts.sans,
        fontSize: 22,
        fontWeight: FontWeight.w600,
        color: ApertonoColors.textPrimary,
      ),
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: ApertonoColors.textSecondary,
      textColor: ApertonoColors.textPrimary,
      selectedColor: ApertonoColors.accent,
      selectedTileColor: ApertonoColors.surface,
      tileColor: Colors.transparent,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: ApertonoColors.accent,
        foregroundColor: ApertonoColors.background,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: ApertonoColors.accent,
        foregroundColor: ApertonoColors.background,
        elevation: 0,
        shadowColor: Colors.transparent,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: ApertonoColors.accent),
    ),
    chipTheme: const ChipThemeData(
      backgroundColor: ApertonoColors.surface,
      side: BorderSide(color: ApertonoColors.border),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
      ),
      labelStyle: TextStyle(
        fontFamily: ApertonoFonts.sans,
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: ApertonoColors.textSecondary,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: ApertonoColors.accent),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: ApertonoColors.accent,
      foregroundColor: ApertonoColors.background,
      elevation: 0,
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: ApertonoColors.surface,
      hintStyle: TextStyle(
        color: ApertonoColors.textSecondary,
        fontFamily: ApertonoFonts.sans,
      ),
      border: OutlineInputBorder(
        borderSide: BorderSide(color: ApertonoColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderSide: BorderSide(color: ApertonoColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderSide: BorderSide(color: ApertonoColors.accent),
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: ApertonoColors.divider,
      thickness: 1,
      space: 1,
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: ApertonoColors.accent,
      thumbColor: ApertonoColors.accent,
      inactiveTrackColor: ApertonoColors.borderStrong,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: ApertonoColors.accent,
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: ApertonoColors.surfaceRaised,
      contentTextStyle: TextStyle(
        color: ApertonoColors.textPrimary,
        fontFamily: ApertonoFonts.sans,
      ),
    ),
    cardTheme: CardThemeData(
      color: ApertonoColors.surface,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: ApertonoColors.border),
      ),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: ApertonoColors.surfaceRaised,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(ApertonoRadii.medium)),
        side: BorderSide(color: ApertonoColors.borderStrong),
      ),
    ),
    popupMenuTheme: const PopupMenuThemeData(
      color: ApertonoColors.surfaceRaised,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(ApertonoRadii.album)),
        side: BorderSide(color: ApertonoColors.borderStrong),
      ),
    ),
  );
}
