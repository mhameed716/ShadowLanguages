import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import '../reader/reader_screen.dart';
import '../settings/settings_screen.dart';
import '../terminal/terminal_controller.dart';
import '../terminal/terminal_screen.dart';

/// The three-way shell: TERMINAL · READER · CONFIG.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  int _index = 0;

  void _goTo(int index) => setState(() => _index = index);

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider).valueOrNull;
    final accent = AppColors.accentById(settings?.accent ?? 'green').primary;
    ref.watch(stringsProvider);
    final t = ref.read(stringsProvider);
    final theme = AppTypography.buildTextTheme();
    final output = ref.watch(terminalControllerProvider).output;

    return Scaffold(
      backgroundColor: AppColors.terminalBlack,
      body: SafeArea(
        bottom: false,
        child: IndexedStack(
          index: _index,
          children: [
            TerminalScreen(
              accent: accent,
              onOpenReader: output == null ? null : () => _goTo(1),
            ),
            ReaderScreen(
              accent: accent,
              initialBook: output,
              onOpenTerminal: () => _goTo(0),
            ),
            SettingsScreen(accent: accent),
          ],
        ),
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: AppColors.carbonBlack,
          border: Border(top: BorderSide(color: AppColors.gridLine)),
        ),
        child: BottomNavigationBar(
          currentIndex: _index,
          onTap: _goTo,
          items: [
            BottomNavigationBarItem(
              icon: const Icon(Icons.terminal_outlined),
              activeIcon: Icon(Icons.terminal, color: accent),
              label: t('tab_terminal'),
            ),
            BottomNavigationBarItem(
              icon: const Icon(Icons.auto_stories_outlined),
              activeIcon: Icon(Icons.auto_stories, color: accent),
              label: t('tab_reader'),
            ),
            BottomNavigationBarItem(
              icon: const Icon(Icons.tune_outlined),
              activeIcon: Icon(Icons.tune, color: accent),
              label: t('tab_settings'),
            ),
          ],
        ),
      ),
    );
  }
}
