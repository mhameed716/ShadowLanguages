import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_colors.dart';
import 'app_typography.dart';

/// Builds the dark cyberpunk [ThemeData] for a chosen accent.
abstract final class AppTheme {
  static ThemeData build(AccentTheme accent) {
    const base = Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: accent.primary,
      brightness: base,
      primary: accent.primary,
      secondary: accent.secondary,
      surface: AppColors.panelBlack,
      onPrimary: AppColors.voidBlack,
      onSurface: AppColors.textPrimary,
      error: AppColors.danger,
      outline: AppColors.gridLine,
    ).copyWith(
      surfaceContainerHighest: AppColors.panelElevated,
      surfaceTint: Colors.transparent,
    );

    final text = AppTypography.buildTextTheme();

    return ThemeData(
      useMaterial3: true,
      brightness: base,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.terminalBlack,
      canvasColor: AppColors.carbonBlack,
      splashFactory: InkSparkle.splashFactory,
      fontFamily: AppFonts.body,
      textTheme: text,
      dividerColor: AppColors.gridLine,
      dividerTheme: const DividerThemeData(
        color: AppColors.gridLine,
        thickness: 1,
        space: 1,
      ),
      iconTheme: const IconThemeData(color: AppColors.textSecondary, size: 22),
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.carbonBlack,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        systemOverlayStyle: const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          statusBarBrightness: Brightness.dark,
          systemNavigationBarColor: AppColors.voidBlack,
          systemNavigationBarIconBrightness: Brightness.light,
        ),
        titleTextStyle: text.titleLarge,
      ),
      cardTheme: CardThemeData(
        color: AppColors.panelBlack,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: accent.primary.withValues(alpha: 0.16)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent.primary.withValues(alpha: 0.14),
          foregroundColor: accent.primary,
          disabledBackgroundColor: AppColors.panelElevated,
          disabledForegroundColor: AppColors.textDisabled,
          elevation: 0,
          minimumSize: const Size.fromHeight(48),
          textStyle: AppTypography.buildTextTheme().labelLarge,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: accent.primaryBorder),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.textSecondary,
          side: const BorderSide(color: AppColors.gridLine),
          minimumSize: const Size.fromHeight(46),
          textStyle: AppTypography.buildTextTheme().labelMedium,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: accent.primary,
          textStyle: AppTypography.buildTextTheme().labelMedium,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.panelBlack,
        hintStyle: const TextStyle(color: AppColors.textDisabled),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.gridLine),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: accent.primary, width: 1.4),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.danger),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.danger, width: 1.4),
        ),
        labelStyle: const TextStyle(color: AppColors.textSecondary),
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        textStyle: AppTypography.buildTextTheme().bodyMedium?.copyWith(
              color: AppColors.textPrimary,
            ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: AppColors.panelBlack,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppColors.gridLine),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: accent.primary),
          ),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: AppColors.panelElevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: accent.primary.withValues(alpha: 0.18)),
        ),
        textStyle: AppTypography.buildTextTheme().bodyMedium,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.panelElevated,
        contentTextStyle: AppTypography.buildTextTheme().bodyMedium?.copyWith(
              color: AppColors.textPrimary,
            ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: accent.primary.withValues(alpha: 0.28)),
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: accent.primary,
        inactiveTrackColor: AppColors.gridLine,
        thumbColor: accent.primary,
        overlayColor: accent.primary.withValues(alpha: 0.15),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? accent.primary
                : AppColors.textDisabled),
        trackColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? accent.primary.withValues(alpha: 0.32)
                : AppColors.gridLine),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? accent.primary
                : Colors.transparent),
        checkColor: WidgetStateProperty.all(AppColors.voidBlack),
        side: const BorderSide(color: AppColors.gridLine),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: accent.primary,
        linearTrackColor: AppColors.gridLine,
        circularTrackColor: AppColors.gridLine,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: AppColors.panelElevated,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: accent.primary.withValues(alpha: 0.3)),
        ),
        textStyle:
            AppTypography.buildTextTheme().bodySmall?.copyWith(color: AppColors.textPrimary),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStateProperty.all(accent.primary.withValues(alpha: 0.35)),
        trackColor: WidgetStateProperty.all(Colors.transparent),
        thickness: WidgetStateProperty.all(4),
        radius: const Radius.circular(4),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: AppColors.carbonBlack,
        selectedItemColor: accent.primary,
        unselectedItemColor: AppColors.textDisabled,
        type: BottomNavigationBarType.fixed,
        selectedLabelStyle: AppTypography.buildTextTheme().labelSmall,
        unselectedLabelStyle: AppTypography.buildTextTheme().labelSmall,
        elevation: 0,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.panelBlack,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: accent.primary.withValues(alpha: 0.22)),
        ),
        titleTextStyle: AppTypography.buildTextTheme().titleMedium,
        contentTextStyle: AppTypography.buildTextTheme().bodyMedium,
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: AppColors.textSecondary,
        textColor: AppColors.textPrimary,
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        },
      ),
    );
  }
}

/// Reusable neon decoration helpers.
abstract final class CyberDecorations {
  static List<BoxShadow> glow(Color color, {double intensity = 0.35}) => [
        BoxShadow(
          color: color.withValues(alpha: intensity),
          blurRadius: 18,
          spreadRadius: -4,
        ),
      ];

  static BoxDecoration panel({
    Color border = AppColors.gridLine,
    double radius = 14,
    Color? fill,
  }) =>
      BoxDecoration(
        color: fill ?? AppColors.panelBlack,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: border),
      );

  /// The classic "dashed drop zone" border used by the upload area.
  static BoxBorder dashed(Color color) => Border.all(color: color);
}
