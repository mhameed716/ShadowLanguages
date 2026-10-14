import 'package:flutter/material.dart';

/// The ShadowLanguages palette.
///
/// Terminal black canvases, neon green for "system OK", neon cyan for
/// interactive/cyber accents, and a warm amber/red pair reserved for warnings
/// and failures.
abstract final class AppColors {
  // ---------------------------------------------------------------- canvases
  static const Color voidBlack = Color(0xFF000000);
  static const Color carbonBlack = Color(0xFF0D0D0D);
  static const Color terminalBlack = Color(0xFF0A0A0A);
  static const Color panelBlack = Color(0xFF111316);
  static const Color panelElevated = Color(0xFF16191D);
  static const Color gridLine = Color(0xFF1C2026);

  // ------------------------------------------------------------------- neon
  static const Color neonGreen = Color(0xFF00FF66);
  static const Color neonGreenDim = Color(0xFF0B7A38);
  static const Color neonCyan = Color(0xFF00E5FF);
  static const Color neonCyanDim = Color(0xFF0A6E7A);
  static const Color neonPurple = Color(0xFFB14BFF);

  // --------------------------------------------------------------- semantic
  static const Color warning = Color(0xFFFFC53D);
  static const Color danger = Color(0xFFFF3B30);
  static const Color success = neonGreen;

  // ------------------------------------------------------------------- text
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFFA0A0A0);
  static const Color textDisabled = Color(0xFF5A5F66);

  /// Accent used by the whole chrome (user switchable green / cyan / purple).
  static const List<AccentTheme> accents = [
    AccentTheme(
      id: 'green',
      primary: neonGreen,
      secondary: neonCyan,
      label: 'Terminal Green',
    ),
    AccentTheme(
      id: 'cyan',
      primary: neonCyan,
      secondary: neonGreen,
      label: 'Cyber Cyan',
    ),
    AccentTheme(
      id: 'purple',
      primary: neonPurple,
      secondary: neonCyan,
      label: 'Ghost Purple',
    ),
  ];

  static AccentTheme accentById(String id) => accents.firstWhere(
        (a) => a.id == id,
        orElse: () => accents.first,
      );
}

/// A switchable neon accent pair.
class AccentTheme {
  const AccentTheme({
    required this.id,
    required this.primary,
    required this.secondary,
    required this.label,
  });

  final String id;
  final Color primary;
  final Color secondary;
  final String label;

  Color get primarySoft => primary.withValues(alpha: 0.14);
  Color get primaryFaint => primary.withValues(alpha: 0.07);
  Color get primaryBorder => primary.withValues(alpha: 0.45);
}

/// Colour helpers used when sampling / injecting text inside a PDF.
abstract final class PdfInk {
  static const Color defaultBackground = Color(0xFFFFFFFF);
  static const Color defaultText = Color(0xFF000000);

  static double _r(Color c) => ((c.value >> 16) & 0xFF) / 255.0;
  static double _g(Color c) => ((c.value >> 8) & 0xFF) / 255.0;
  static double _b(Color c) => (c.value & 0xFF) / 255.0;

  /// Perceived luminance (0..1) of an sRGB colour.
  static double luminance(Color c) => 0.299 * _r(c) + 0.587 * _g(c) + 0.114 * _b(c);

  /// True when [c] is dark enough that light text should be drawn on it.
  static bool isDark(Color c) => luminance(c) < 0.5;

  /// Distance between two colours (manhattan, 0..3).
  static double distance(Color a, Color b) =>
      (_r(a) - _r(b)).abs() + (_g(a) - _g(b)).abs() + (_b(a) - _b(b)).abs();

  /// Build a Flutter [Color] from PDF colour components (0..1 floats).
  static Color fromPdf(double r, double g, double b) => Color.fromRGBO(
        (r.clamp(0.0, 1.0) * 255).round(),
        (g.clamp(0.0, 1.0) * 255).round(),
        (b.clamp(0.0, 1.0) * 255).round(),
        1,
      );

  /// PDF colour components (0..1) for a Flutter [Color].
  static List<double> toPdf(Color c) => [_r(c), _g(c), _b(c)];
}
