import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import '../../services/translation/gemini_client.dart';

/// First run.
///
/// The app ships with an on-device engine, so **nothing is required**: the
/// primary action is "start offline". The key field below is only for users who
/// explicitly want the optional cloud engine.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key, required this.accent});

  final Color accent;

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final TextEditingController _controller = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Starts with the on-device engine: no key, no network, nothing to wait for.
  Future<void> _startOffline() async {
    final t = ref.read(stringsProvider);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(settingsProvider.notifier).setOfflineEngine(true);
      await ref.read(settingsProvider.notifier).completeOnboarding();
      if (mounted) {
        ref.read(logBusProvider).system(t('log_booting'));
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveAndContinue() async {
    final t = ref.read(stringsProvider);
    final key = _controller.text.trim();
    if (key.isEmpty) {
      setState(() => _error = t('err_no_api_key'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(settingsProvider.notifier).setApiKey(key);
      await ref.read(settingsProvider.notifier).setOfflineEngine(false);
      final client = ref.read(geminiClientProvider);
      await client.ping();
      await ref.read(settingsProvider.notifier).completeOnboarding();
      if (mounted) {
        ref.read(logBusProvider).system(t('log_booting'));
      }
    } on TranslationException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final theme = AppTypography.buildTextTheme();
    final accent = widget.accent;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(26),
                  child: Image.asset(
                    'assets/branding/app_icon_512.png',
                    width: 104,
                    height: 104,
                  ),
                ),
                const SizedBox(height: 22),
                Text(
                  t('onboarding_title'),
                  style: theme.displayMedium?.copyWith(
                    color: accent,
                    letterSpacing: 2.2,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 6),
                Text(
                  t('onboarding_subtitle'),
                  style: theme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 18),
                Text(
                  t('onboarding_body'),
                  style: theme.bodySmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 26),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _startOffline,
                    icon: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.memory, size: 18),
                    label: Text(t('onboarding_offline_cta')),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  t('onboarding_offline_body'),
                  style: theme.bodySmall?.copyWith(fontSize: 11),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 26),
                Text(
                  t('onboarding_cloud_section'),
                  style: theme.labelSmall?.copyWith(
                    color: accent,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _controller,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: AppTypography.logLine,
                  decoration: InputDecoration(
                    labelText: t('onboarding_key_label'),
                    helperText: t('onboarding_key_help'),
                    helperMaxLines: 2,
                    prefixIcon: Icon(Icons.vpn_key_outlined, color: accent),
                  ),
                  onSubmitted: (_) => _saveAndContinue(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    _error!,
                    style: theme.bodySmall?.copyWith(color: AppColors.danger),
                    textAlign: TextAlign.center,
                  ),
                ],
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _saveAndContinue,
                    icon: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.lock_open, size: 18),
                    label: Text(t('onboarding_cloud_cta')),
                  ),
                ),
                const SizedBox(height: 10),
                TextButton(
                  onPressed: () =>
                      ref.read(settingsProvider.notifier).completeOnboarding(),
                  child: Text(t('onboarding_skip')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
