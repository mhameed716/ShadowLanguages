import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/providers.dart';
import '../../core/localization/strings.dart';
import '../../core/utils/job_cancellation.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/formatters.dart';
import '../../services/translation/gemini_client.dart';
import '../../services/translation/onnx/model_downloader.dart';
import '../../services/translation/onnx/model_manager.dart';
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

        // -------------------------------------------------- on-device engine
        _OfflineSection(accent: accent),
        const SizedBox(height: 14),

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
                    child: Text(t('chunk_label'), style: theme.bodySmall),
                  ),
                  Expanded(
                    child: Slider(
                      value: (settings?.maxCharactersPerRequest ?? 1800)
                          .toDouble()
                          .clamp(600, 4000),
                      divisions: 17,
                      min: 600,
                      max: 4000,
                      label: '${settings?.maxCharactersPerRequest ?? 1800}',
                      onChanged: (value) =>
                          controller.setMaxCharacters(value.round()),
                    ),
                  ),
                  Text('${settings?.maxCharactersPerRequest ?? 1800}',
                      style: theme.labelSmall),
                ],
              ),
              Text(
                t('chunk_hint'),
                style: theme.bodySmall?.copyWith(fontSize: 11),
              ),
              const SizedBox(height: 8),
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
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () async {
                  final removed = await ref
                      .read(checkpointRepositoryProvider)
                      .clearStale();
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                            t('clear_checkpoints_done', {'count': '$removed'})),
                      ),
                    );
                  }
                },
                icon: const Icon(Icons.restart_alt, size: 16),
                label: Text(t('clear_checkpoints')),
              ),
              const SizedBox(height: 8),
              Text(t('pacing_note'), style: theme.bodySmall?.copyWith(fontSize: 11)),
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

/// The on-device engine panel: engine choice, model files, OCR and tuning.
///
/// Models are hundreds of megabytes, so they are never bundled: this is where
/// the user imports them once and the app then works forever without a network.
class _OfflineSection extends ConsumerStatefulWidget {
  const _OfflineSection({required this.accent});

  final Color accent;

  @override
  ConsumerState<_OfflineSection> createState() => _OfflineSectionState();
}

class _OfflineSectionState extends ConsumerState<_OfflineSection> {
  bool _importing = false;
  double _progress = 0;
  String? _note;

  bool _downloading = false;
  double _downloadProgress = 0;
  String? _downloadLabel;
  ModelDownloader? _downloader;

  /// Fetches the missing model files **once**. After this the phone can stay in
  /// airplane mode forever.
  Future<void> _download() async {
    final t = ref.read(stringsProvider);
    final inventory = ref.read(modelInventoryProvider).valueOrNull ??
        await ref.read(modelInventoryProvider.future);
    final downloader = _downloader = ref.read(modelDownloaderProvider);
    setState(() {
      _downloading = true;
      _downloadProgress = 0;
      _downloadLabel = null;
    });
    try {
      final done = await downloader.downloadMissing(
        inventory: inventory,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() {
            _downloadProgress = progress.ratio;
            _downloadLabel = progress.label;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _note = done.isEmpty
            ? t('models_download_failed')
            : t('models_download_done');
      });
      ref.invalidate(modelInventoryProvider);
      ref.invalidate(translationClientProvider);
      ref.read(translationPipelineProvider).resetEngine();
    } on JobCancelledException {
      if (mounted) setState(() => _downloading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _downloading = false;
          _note = '${t('models_download_failed')}: $e';
        });
      }
    } finally {
      _downloader = null;
    }
  }

  Future<void> _import() async {
    final t = ref.read(stringsProvider);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
        withData: false,
      );
      final path = result?.files.single.path;
      if (path == null) return;
      setState(() {
        _importing = true;
        _progress = 0;
        _note = null;
      });
      final status = await ref.read(modelManagerProvider).importFile(
        path,
        onProgress: (copied, total) {
          if (!mounted) return;
          setState(() => _progress = total == 0 ? 0 : copied / total);
        },
      );
      if (!mounted) return;
      setState(() {
        _importing = false;
        _note = t('models_imported', {'n': status.spec.labelEnglish});
      });
      ref.invalidate(modelInventoryProvider);
      ref.invalidate(translationClientProvider);
      ref.invalidate(ocrEngineProvider);
      ref.invalidate(ocrExtractorProvider);
      ref.read(translationPipelineProvider).resetEngine();
    } on ModelException catch (e) {
      if (!mounted) return;
      setState(() {
        _importing = false;
        _note = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _importing = false;
        _note = '${t('models_import_failed')}: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final settings = ref.watch(settingsProvider).valueOrNull;
    final controller = ref.read(settingsProvider.notifier);
    final inventory = ref.watch(modelInventoryProvider);
    final offline = settings?.useOfflineEngine ?? true;
    final theme = AppTypography.buildTextTheme();

    return CyberSection(
      title: t('models_title'),
      accent: widget.accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t('models_body'),
            style: theme.bodySmall?.copyWith(fontSize: 11.5),
          ),
          const SizedBox(height: 12),

          // ------------------------------------------------ engine selection
          _EngineChoice(
            accent: widget.accent,
            offline: offline,
            onChanged: (value) {
              controller.setOfflineEngine(value);
              ref.invalidate(translationClientProvider);
              // The pipeline caches the engine it resolved: drop it so the next
              // job really runs on the newly selected one.
              ref.read(translationPipelineProvider).resetEngine();
            },
          ),
          const SizedBox(height: 14),

          // ------------------------------------------------------ model list
          inventory.when(
            loading: () => Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(t('models_scanning'), style: theme.bodySmall),
            ),
            error: (error, _) => Text(
              '$error',
              style: theme.bodySmall?.copyWith(color: AppColors.danger),
            ),
            data: (models) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final status in models.items)
                  _ModelRow(
                    status: status,
                    accent: widget.accent,
                    onDelete: status.present
                        ? () async {
                            await ref
                                .read(modelManagerProvider)
                                .delete(status.kind);
                            ref.invalidate(modelInventoryProvider);
                          }
                        : null,
                  ),
                const SizedBox(height: 8),
                Text(
                  t('models_total', {'s': _size(models.totalBytes)}),
                  style: theme.labelSmall,
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),

          if (_importing) ...[
            LinearProgressIndicator(
              value: _progress == 0 ? null : _progress,
              color: widget.accent,
            ),
            const SizedBox(height: 6),
          ],
          if (_note != null) ...[
            Text(
              _note!,
              style: theme.bodySmall?.copyWith(
                fontSize: 11,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 8),
          ],

          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _downloading || _importing ? null : _download,
                  icon: _downloading
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download_for_offline, size: 16),
                  label: Text(t('models_download')),
                ),
              ),
              if (_downloading) ...[
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () {
                    _downloader?.cancel();
                    setState(() => _downloading = false);
                  },
                  child: Text(t('models_cancel')),
                ),
              ],
            ],
          ),
          if (_downloading) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: _downloadProgress == 0 ? null : _downloadProgress,
              color: widget.accent,
            ),
            const SizedBox(height: 4),
            Text(
              _downloadLabel == null
                  ? t('models_downloading', {'p': '0'})
                  : '${_downloadLabel!} · ${(_downloadProgress * 100).toStringAsFixed(0)}%',
              style: theme.bodySmall?.copyWith(fontSize: 11),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            t('models_download_note'),
            style: theme.bodySmall?.copyWith(fontSize: 11),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _importing || _downloading ? null : _import,
            icon: const Icon(Icons.file_open, size: 16),
            label: Text(t('models_import')),
          ),
          const SizedBox(height: 8),
          Text(
            t('models_help'),
            style: theme.bodySmall?.copyWith(fontSize: 11),
          ),
          const SizedBox(height: 4),
          Text(
            t('models_ocr_manual'),
            style: theme.bodySmall?.copyWith(fontSize: 11),
          ),

          const SizedBox(height: 14),

          // ------------------------------------------------------------- OCR
          _SwitchTile(
            label: t('ocr_title'),
            hint: t('ocr_body'),
            value: settings?.enableOcr ?? true,
            accent: widget.accent,
            onChanged: (value) {
              controller.setOcr(value);
              ref.invalidate(ocrExtractorProvider);
            },
          ),

          // ------------------------------------------------------- tuning
          _SliderRow(
            label: t('perf_threads'),
            value: (settings?.inferenceThreads ?? 2).toDouble(),
            min: 1,
            max: 4,
            divisions: 3,
            display: '${settings?.inferenceThreads ?? 2}',
            onChanged: (value) => controller.setInferenceThreads(value.round()),
          ),
          _SliderRow(
            label: t('perf_beam'),
            value: (settings?.beamSize ?? 1).toDouble(),
            min: 1,
            max: 4,
            divisions: 3,
            display: '${settings?.beamSize ?? 1}',
            onChanged: (value) => controller.setBeamSize(value.round()),
          ),
          _SliderRow(
            label: t('perf_pause'),
            value: (settings?.pauseBetweenBlocksMs ?? 0).toDouble(),
            min: 0,
            max: 500,
            divisions: 10,
            display: '${settings?.pauseBetweenBlocksMs ?? 0} ms',
            onChanged: (value) => controller.setBlockPause(value.round()),
          ),
          Text(
            t('perf_pause_hint'),
            style: theme.bodySmall?.copyWith(fontSize: 11),
          ),
        ],
      ),
    );
  }

  static String _size(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes == 0) return '—';
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }
}

/// Offline (on-device) vs cloud.
class _EngineChoice extends ConsumerWidget {
  const _EngineChoice({
    required this.accent,
    required this.offline,
    required this.onChanged,
  });

  final Color accent;
  final bool offline;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    return Row(
      children: [
        Expanded(
          child: _EngineCard(
            accent: accent,
            selected: offline,
            icon: Icons.memory,
            title: t('engine_offline'),
            hint: t('engine_offline_hint'),
            onTap: () => onChanged(true),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _EngineCard(
            accent: accent,
            selected: !offline,
            icon: Icons.cloud_outlined,
            title: t('engine_cloud'),
            hint: t('engine_cloud_hint'),
            onTap: () => onChanged(false),
          ),
        ),
      ],
    );
  }
}

class _EngineCard extends StatelessWidget {
  const _EngineCard({
    required this.accent,
    required this.selected,
    required this.icon,
    required this.title,
    required this.hint,
    required this.onTap,
  });

  final Color accent;
  final bool selected;
  final IconData icon;
  final String title;
  final String hint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = AppTypography.buildTextTheme();
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? accent : accent.withValues(alpha: 0.15),
            width: selected ? 1.6 : 1,
          ),
          color: selected ? accent.withValues(alpha: 0.08) : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: selected ? accent : AppColors.textSecondary, size: 18),
            const SizedBox(height: 6),
            Text(
              title,
              style: theme.bodyMedium?.copyWith(
                color: selected ? accent : AppColors.textPrimary,
                fontSize: 12.5,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              hint,
              style: theme.bodySmall?.copyWith(fontSize: 10.5),
            ),
          ],
        ),
      ),
    );
  }
}

/// One line of the model inventory.
class _ModelRow extends ConsumerWidget {
  const _ModelRow({
    required this.status,
    required this.accent,
    this.onDelete,
  });

  final ModelStatus status;
  final Color accent;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final theme = AppTypography.buildTextTheme();
    final color = status.present ? AppColors.success : AppColors.danger;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            status.present ? Icons.check_circle_outline : Icons.error_outline,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(status.spec.labelArabic, style: theme.bodySmall),
                Text(
                  status.present
                      ? '${t('models_ready')} · ${_size(status.sizeBytes)}'
                      : (status.note ?? t('models_missing')),
                  style: theme.labelSmall?.copyWith(color: color, fontSize: 10),
                ),
              ],
            ),
          ),
          if (onDelete != null)
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 16),
              color: AppColors.textSecondary,
              tooltip: t('models_delete'),
              onPressed: onDelete,
            ),
        ],
      ),
    );
  }

  static String _size(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }
}

/// Label + slider + value, the shape used all over the config screen.
class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.display,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String display;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = AppTypography.buildTextTheme();
    return Row(
      children: [
        SizedBox(width: 96, child: Text(label, style: theme.bodySmall)),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            label: display,
            onChanged: onChanged,
          ),
        ),
        Text(display, style: theme.labelSmall),
      ],
    );
  }
}
