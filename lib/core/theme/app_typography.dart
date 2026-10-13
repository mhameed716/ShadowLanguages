import 'package:flutter/material.dart';

import 'app_colors.dart';

/// Font families bundled with the app (no network fetch, instant cold start).
abstract final class AppFonts {
  static const String display = 'Orbitron';
  static const String terminal = 'ShareTechMono';
  static const String mono = 'JetBrainsMono';
  static const String body = 'NotoSans';
  static const String arabic = 'NotoNaskhArabic';

  /// Body family that also covers Arabic script.
  static const List<String> bodyFallback = [body, arabic];
}

/// Typography scale of the terminal UI.
abstract final class AppTypography {
  static const String _display = AppFonts.display;
  static const String _terminal = AppFonts.terminal;
  static const String _mono = AppFonts.mono;

  static TextTheme buildTextTheme({Color body = AppColors.textSecondary}) {
    return TextTheme(
      displayLarge: const TextStyle(
        fontFamily: _display,
        fontSize: 40,
        height: 1.1,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.4,
        color: AppColors.textPrimary,
      ),
      displayMedium: const TextStyle(
        fontFamily: _display,
        fontSize: 30,
        height: 1.15,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.2,
        color: AppColors.textPrimary,
      ),
      titleLarge: const TextStyle(
        fontFamily: _display,
        fontSize: 20,
        height: 1.25,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.0,
        color: AppColors.textPrimary,
      ),
      titleMedium: const TextStyle(
        fontFamily: _display,
        fontSize: 16,
        height: 1.3,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.8,
        color: AppColors.textPrimary,
      ),
      titleSmall: const TextStyle(
        fontFamily: _mono,
        fontSize: 14,
        height: 1.35,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.4,
        color: AppColors.textPrimary,
      ),
      bodyLarge: TextStyle(
        fontFamily: AppFonts.body,
        fontFamilyFallback: AppFonts.bodyFallback,
        fontSize: 15,
        height: 1.5,
        color: body,
      ),
      bodyMedium: TextStyle(
        fontFamily: AppFonts.body,
        fontFamilyFallback: AppFonts.bodyFallback,
        fontSize: 13.5,
        height: 1.5,
        color: body,
      ),
      bodySmall: TextStyle(
        fontFamily: AppFonts.body,
        fontFamilyFallback: AppFonts.bodyFallback,
        fontSize: 12,
        height: 1.45,
        color: body.withValues(alpha: 0.85),
      ),
      labelLarge: const TextStyle(
        fontFamily: _terminal,
        fontSize: 14,
        letterSpacing: 1.1,
        fontWeight: FontWeight.w500,
        color: AppColors.textPrimary,
      ),
      labelMedium: const TextStyle(
        fontFamily: _terminal,
        fontSize: 12,
        letterSpacing: 1.0,
        color: AppColors.textSecondary,
      ),
      labelSmall: const TextStyle(
        fontFamily: _terminal,
        fontSize: 10.5,
        letterSpacing: 0.9,
        color: AppColors.textDisabled,
      ),
    );
  }

  /// Log stream / code style.
  static const TextStyle logLine = TextStyle(
    fontFamily: _mono,
    fontSize: 12,
    height: 1.55,
    letterSpacing: 0.2,
    color: AppColors.neonGreen,
  );

  static const TextStyle terminalLine = TextStyle(
    fontFamily: _terminal,
    fontSize: 13,
    letterSpacing: 0.8,
    color: AppColors.neonCyan,
  );
}
