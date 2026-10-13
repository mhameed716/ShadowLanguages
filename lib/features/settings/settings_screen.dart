import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/providers.dart';
import '../../core/localization/strings.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/formatters.dart';
import '../../services/translation/gemini_client.dart';
import '../../services/translation/translation_options.dart';
import '../terminal/terminal_controller.dart';

/// Screen 3 — system configuration.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key, required this.accent});

  final Color accent;

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final TextEditingController _keyController = TextEditingController();
  bool _keyVisible = false;
  bool _testing = false;
  String? _testResult;
  bool _testOk = false;

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider).valueOrNull;
    final t = ref.watch(stringsProvider);
    final controller = ref.read(settingsProvider.notifier);
    final theme = AppTypography.buildTextTheme();
    final accent = widget.accent;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        Row(
          children: [
            Icon(Icons.settings_input_component, color: accent, size: 20),
            const SizedBox(width: 10),
            Text(
              t('settings_title'),
              style: theme.titleMedium?.copyWith(color: accent, letterSpacing: 1.4),
            ),
          ],
        ),
        const SizedBox(height: 16),

        // ------------------------------------------------------------ API key
        CyberSection(
          title: t('section_api'),
          accent: accent,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _keyController,
                obscureText: !_keyVisible,
                autocorrect: false,
                enableSuggestions: false,
                style: AppTypography.logLine.copyWith(fontSize: 12.5),
                decoration: InputDecoration(
                  labelText: t('api_key_label'),
                  helperText: settings?.hasApiKey == true
                      ? t('api_key_set', {'last': settings!.apiKeyHint})
                      : t('api_key_hint'),
                  helperMaxLines: 2,
                  suffixIcon: IconButton(
                    icon: Icon(
                      _keyVisible ? Icons.visibility_off : Icons.visibility,
                      size: 18,
                    ),
                    onPressed: () => setState(() => _keyVisible = !_keyVisible),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () async {
                        final value = _keyController.text.trim();
                        if (value.isEmpty) return;
                        await controller.setApiKey(value);
                        _keyController.clear();
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(t('api_key_set', {'last': '••••'}))),
                          );
                        }
                      },
                      icon: const Icon(Icons.key, size: 16),
                      label: Text(t('api_key_save')),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _testing ? null : () => _test(t),
                      icon: _testing
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.wifi_tethering, size: 16),
                      label: Text(t('api_key_test')),
                    ),
                  ),
                ],
              ),
              if (_testResult != null) ...[
                const SizedBox(height: 8),
                Text(
                  _testResult!,
                  style: theme.bodySmall?.copyWith(
                    color: _testOk ? AppColors.success : AppColors.danger,
                  ),
                ),
              ],
              const SizedBox(height: 6),
              Text(
                t('privacy_note'),
                style: theme.bodySmall?.copyWith(fontSize: 11),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: settings?.model ?? 'gemini-2.5-flash',
                decoration: InputDecoration(labelText: t('model_label')),
                items: [
                  for (final model in TranslationOptions.availableModels)
                    DropdownMenuItem(value: model, child: Text(model)),
                ],
                onChanged: (value) {
                  if (value != null) unawaited(controller.setModel(value));
                },
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  SizedBox(
                    width: 70,
                    child: Text(
                      t('temperature_label'),
                      style: theme.bodySmall,
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      value: (settings?.temperature ?? 0.2).clamp(0.0, 1.0),
                      divisions: 20,
                      label: (settings?.temperature ?? 0.2).toStringAsFixed(2),
                      onChanged: (value) => controller.setTemperature(value),
                    ),
                  ),
                  Text(
                    (settings?.temperature ?? 0.2).toStringAsFixed(2),
                    style: theme.labelSmall,
                  ),
                ],
              ),
              Row(
                children: [
                  SizedBox(
                    width: 70,
                    child: Text(t('concurrency_label'), style: theme.bodySmall),
                  ),
                  Expanded(
                    child: Slider(
                      value: (settings?.concurrency ?? 3).toDouble().clamp(1, 8),
                      divisions: 7,
                      min: 1,
                      max: 8,
                      label: '${settings?.concurrency ?? 3}',
                      onChanged: (value) =>
                          controller.setConcurrency(value.round()),
                    ),
                  ),
                  Text('${settings?.concurrency ?? 3}', style: theme.labelSmall),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // --------------------------------------------------------- PDF engine
        CyberSection(
          title: t('section_pdf'),
          accent: accent,
          child: Column(
            children: [
              _SwitchTile(
                label: t('cloak_label'),
                hint: t('cloak_hint'),
                value: settings?.cloak ?? true,
                accent: accent,
                onChanged: (v) => controller.toggle(cloak: v),
              ),
              _SwitchTile(
                label: t('autofit_label'),
                hint: t('autofit_hint'),
                value: settings?.shrinkToFit ?? true,
                accent: accent,
                onChanged: (v) => controller.toggle(shrinkToFit: v),
              ),
              _SwitchTile(
                label: t('keep_numbers_label'),
                value: settings?.keepNumbers ?? true,
                accent: accent,
                onChanged: (v) => controller.toggle(keepNumbers: v),
              ),
              _SwitchTile(
                label: t('glossary_label'),
                hint: t('glossary_hint2'),
                value: settings?.useGlossary ?? true,
                accent: accent,
                onChanged: (v) => controller.toggle(useGlossary: v),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // ---------------------------------------------------------- interface
        CyberSection(
          title: t('section_ui'),
          accent: accent,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t('accent_label'), style: theme.bodySmall),
              const SizedBox(height: 10),
              Row(
                children: [
                  for (final option in AppColors.accents)
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: _AccentDot(
                        color: option.primary,
                        selected: (settings?.accent ?? 'green') == option.id,
                        onTap: () => controller.setAccent(option.id),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Text(t('language_label'), style: theme.bodySmall),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                children: [
                  for (final language in Strings.supported)
                    ChoiceChip(
                      label: Text(language.name),
                      selected:
                          (settings?.interfaceLanguageCode ?? 'en') == language.code,
                      selectedColor: accent.withValues(alpha: 0.2),
                      onSelected: (_) =>
                          controller.setInterfaceLanguage(language.code),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // ------------------------------------------------------------ storage
        CyberSection(
          title: t('section_storage'),
          accent: accent,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              OutlinedButton.icon(
                onPressed: () async {
                  final freed = await ref
                      .read(libraryRepositoryProvider)
                      .clearCache();
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          t('clear_cache_done', {'size': Formatters.bytes(freed)}),
                        ),
                      ),
                    );
                  }
                },
                icon: const Icon(Icons.cleaning_services, size: 16),
                label: Text(t('clear_cache')),
              ),
              const SizedBox(height: 14),
              Text(t('library_title'), style: theme.bodySmall),
              const SizedBox(height: 8),
              _LibraryList(accent: accent),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // -------------------------------------------------------------- about
        CyberSection(
          title: t('about_title'),
          accent: accent,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.asset(
                      'assets/branding/app_icon_512.png',
                      width: 44,
                      height: 44,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t('app_name'),
                          style: theme.titleSmall?.copyWith(color: accent),
                        ),
                        Text(
                          '${t('version')} 1.0.0 (1)',
                          style: theme.labelSmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(t('about_body'), style: theme.bodySmall),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _test(Strings t) async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    try {
      final client = ref.read(geminiClientProvider);
      final reply = await client.ping();
      if (!mounted) return;
      setState(() {
        _testOk = true;
        _testResult =
            t('api_key_ok', {'model': '${reply.trim()} · ${client.model}'});
      });
    } on TranslationException catch (e) {
      if (!mounted) return;
      setState(() {
        _testOk = false;
        _testResult = t('api_key_fail', {'message': e.message});
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testOk = false;
        _testResult = t('api_key_fail', {'message': '$e'});
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }
}

/// A titled neon section used across the config screen.
class CyberSection extends StatelessWidget {
  const CyberSection({
    super.key,
    required this.title,
    required this.child,
    required this.accent,
  });

  final String title;
  final Widget child;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.panelBlack,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withValues(alpha: 0.14)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: AppTypography.buildTextTheme().labelSmall?.copyWith(
                  color: accent,
                  letterSpacing: 1.5,
                ),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _SwitchTile extends StatelessWidget {
  const _SwitchTile({
    required this.label,
    required this.value,
    required this.onChanged,
    required this.accent,
    this.hint,
  });

  final String label;
  final String? hint;
  final bool value;
  final ValueChanged<bool> onChanged;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final theme = AppTypography.buildTextTheme();
    return SwitchListTile.adaptive(
      contentPadding: EdgeInsets.zero,
      value: value,
      onChanged: onChanged,
      activeColor: accent,
      title: Text(label, style: theme.bodyMedium?.copyWith(color: AppColors.textPrimary)),
      subtitle: hint == null ? null : Text(hint!, style: theme.bodySmall),
    );
  }
}

class _AccentDot extends StatelessWidget {
  const _AccentDot({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(22),
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withValues(alpha: selected ? 0.35 : 0.12),
          border: Border.all(
            color: selected ? color : color.withValues(alpha: 0.4),
            width: selected ? 2 : 1,
          ),
          boxShadow: selected
              ? [BoxShadow(color: color.withValues(alpha: 0.7), blurRadius: 12)]
              : null,
        ),
      ),
    );
  }
}

class _LibraryList extends ConsumerWidget {
  const _LibraryList({required this.accent});

  final Color accent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final books = ref.watch(libraryProvider).valueOrNull ?? const [];
    final t = ref.watch(stringsProvider);
    final theme = AppTypography.buildTextTheme();
    if (books.isEmpty) {
      return Text(t('library_empty'), style: theme.bodySmall);
    }
    return Column(
      children: [
        for (final book in books.take(8))
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(Icons.picture_as_pdf_outlined, color: accent, size: 18),
            title: Text(
              book.name,
              style: theme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${Formatters.bytes(book.sizeBytes)} · ${book.pageCount} pages',
              style: theme.labelSmall,
            ),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline, size: 18),
              color: AppColors.textDisabled,
              onPressed: () async {
                await ref.read(libraryRepositoryProvider).deleteBook(book);
                ref.invalidate(libraryProvider);
                ref.invalidate(terminalControllerProvider);
              },
            ),
          ),
      ],
    );
  }
}
