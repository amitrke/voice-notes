import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Red of the record and stop buttons. Kept apart from the error colour so
/// recording never reads as a failure.
const recordColor = Color(0xFFD7372A);

/// Background of the full-screen recorder, in both themes.
const recorderBackground = Color(0xFF121519);

/// Quiet paper-and-ink palette: one teal accent, red only for recording.
ColorScheme _scheme(Brightness b) => b == Brightness.light
    ? const ColorScheme(
        brightness: Brightness.light,
        primary: Color(0xFF0E6B66),
        onPrimary: Colors.white,
        primaryContainer: Color(0xFFDDEFEC),
        onPrimaryContainer: Color(0xFF123B39),
        secondary: Color(0xFF16191D),
        onSecondary: Colors.white,
        secondaryContainer: Color(0xFFE8EAEC),
        onSecondaryContainer: Color(0xFF16191D),
        tertiary: Color(0xFF6B4A00),
        onTertiary: Colors.white,
        tertiaryContainer: Color(0xFFFFF4DD),
        onTertiaryContainer: Color(0xFF3F2C00),
        error: Color(0xFFB3261E),
        onError: Colors.white,
        errorContainer: Color(0xFFFCE4E1),
        onErrorContainer: Color(0xFF5C1510),
        surface: Color(0xFFF5F6F4),
        onSurface: Color(0xFF16191D),
        onSurfaceVariant: Color(0xFF5B6370),
        surfaceContainerLowest: Colors.white,
        surfaceContainerLow: Colors.white,
        surfaceContainer: Color(0xFFEEF0F2),
        surfaceContainerHigh: Color(0xFFE8EAEC),
        surfaceContainerHighest: Color(0xFFE3E6EA),
        outline: Color(0xFF9AA1AB),
        outlineVariant: Color(0xFFE3E6EA),
        inverseSurface: Color(0xFF16191D),
        onInverseSurface: Color(0xFFF2F3F1),
      )
    : const ColorScheme(
        brightness: Brightness.dark,
        primary: Color(0xFF5CC8BE),
        onPrimary: Color(0xFF00201E),
        primaryContainer: Color(0xFF12302E),
        onPrimaryContainer: Color(0xFFBFE8E3),
        secondary: Color(0xFFEEF0EE),
        onSecondary: Color(0xFF16191D),
        secondaryContainer: Color(0xFF2A3038),
        onSecondaryContainer: Color(0xFFEEF0EE),
        tertiary: Color(0xFFF2C66D),
        onTertiary: Color(0xFF2A1D00),
        tertiaryContainer: Color(0xFF3A2E12),
        onTertiaryContainer: Color(0xFFFBE3B0),
        error: Color(0xFFFF8A7E),
        onError: Color(0xFF3B0905),
        errorContainer: Color(0xFF4A1D19),
        onErrorContainer: Color(0xFFFFDAD5),
        surface: Color(0xFF111417),
        onSurface: Color(0xFFEEF0EE),
        onSurfaceVariant: Color(0xFFA3AAB4),
        surfaceContainerLowest: Color(0xFF0C0E10),
        surfaceContainerLow: Color(0xFF1A1E23),
        surfaceContainer: Color(0xFF1F242A),
        surfaceContainerHigh: Color(0xFF252B32),
        surfaceContainerHighest: Color(0xFF2A3038),
        outline: Color(0xFF6B737E),
        outlineVariant: Color(0xFF2A3038),
        inverseSurface: Color(0xFFEEF0EE),
        onInverseSurface: Color(0xFF16191D),
      );

ThemeData buildTheme(Brightness brightness) {
  final scheme = _scheme(brightness);
  const stadium = StadiumBorder();
  const buttonSize = Size(64, 48);
  // Button labels replace labelLarge rather than merging with it, so build
  // them from it to keep the font family.
  final label = ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
  ).textTheme.labelLarge?.copyWith(fontSize: 15, fontWeight: FontWeight.w600);
  final base = ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: stadium,
        minimumSize: buttonSize,
        textStyle: label,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: stadium,
        minimumSize: buttonSize,
        foregroundColor: scheme.onSurface,
        side: BorderSide(color: scheme.outline.withValues(alpha: 0.6)),
        textStyle: label,
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        selectedBackgroundColor: scheme.primaryContainer,
        selectedForegroundColor: scheme.onPrimaryContainer,
        minimumSize: const Size(0, 44),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerLow,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.outline),
      ),
    ),
    searchBarTheme: SearchBarThemeData(
      elevation: const WidgetStatePropertyAll(0),
      backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerLow),
      side: WidgetStatePropertyAll(BorderSide(color: scheme.outlineVariant)),
      constraints: const BoxConstraints(minHeight: 48),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
  // Material 3's letter spacing is tuned for Roboto and looks loose in
  // Apple's system font.
  if (defaultTargetPlatform != TargetPlatform.iOS) return base;
  TextStyle? tight(TextStyle? s) => s?.copyWith(letterSpacing: 0);
  final t = base.textTheme;
  return base.copyWith(
    textTheme: t.copyWith(
      headlineMedium: tight(t.headlineMedium),
      headlineSmall: tight(t.headlineSmall),
      titleLarge: tight(t.titleLarge),
      titleMedium: tight(t.titleMedium),
      titleSmall: tight(t.titleSmall),
      bodyLarge: tight(t.bodyLarge),
      bodyMedium: tight(t.bodyMedium),
      bodySmall: tight(t.bodySmall),
      labelLarge: tight(t.labelLarge),
      labelMedium: tight(t.labelMedium),
      labelSmall: tight(t.labelSmall),
    ),
  );
}

/// Small uppercase heading over a group, e.g. a day in the notes list.
class SectionLabel extends StatelessWidget {
  final String text;
  final EdgeInsetsGeometry padding;
  final Color? color;
  const SectionLabel(
    this.text, {
    super.key,
    this.padding = const EdgeInsets.fromLTRB(4, 16, 4, 8),
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: padding,
      child: Text(
        text.toUpperCase(),
        style: theme.textTheme.labelMedium?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: color ?? theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
