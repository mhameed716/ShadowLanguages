import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/di/providers.dart';
import 'core/theme/app_colors.dart';
import 'core/theme/app_theme.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/shell/app_shell.dart';

/// Root widget: theme, locale and the onboarding gate.
class ShadowLanguagesApp extends ConsumerWidget {
  const ShadowLanguagesApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(settingsProvider);
    final strings = ref.watch(stringsProvider);
    final accentTheme = AppColors.accentById(
      settingsAsync.valueOrNull?.accent ?? 'green',
    );

    return MaterialApp(
      title: 'ShadowLanguages',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(accentTheme),
      locale: Locale(strings.languageCode),
      supportedLocales: const [Locale('en'), Locale('ar')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(
            // keep the terminal readable on devices with aggressive font scaling
            textScaler: TextScaler.linear(
              MediaQuery.of(context).textScaler.scale(1).clamp(0.85, 1.25).toDouble(),
            ),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: settingsAsync.when(
        data: (settings) {
          if (settings.onboardingDone && settings.hasApiKey) {
            return const AppShell();
          }
          return OnboardingScreen(accent: accentTheme.primary);
        },
        loading: () => _Splash(accent: accentTheme.primary),
        error: (error, _) => _Splash(accent: accentTheme.primary),
      ),
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash({required this.accent});

  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: Image.asset(
                'assets/branding/app_icon_512.png',
                width: 96,
                height: 96,
              ),
            ),
            const SizedBox(height: 20),
            CircularProgressIndicator(color: accent),
          ],
        ),
      ),
    );
  }
}
