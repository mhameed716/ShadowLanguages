import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/formatters.dart';
import '../../services/translation/language_catalog.dart';
import '../terminal/terminal_controller.dart';
import 'widgets/detection_line.dart';
import 'widgets/language_sheet.dart';
import 'widgets/upload_zone.dart';

/// Screen 1 — the cyber terminal where the book is uploaded, profiled and
/// translated, with a live log streaming every operation.
class TerminalScreen extends ConsumerStatefulWidget {
  const TerminalScreen({super.key, required this.accent, this.onOpenReader});

  final Color accent;
  final VoidCallback? onOpenReader;

  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends ConsumerState<TerminalScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final bus = ref.read(logBusProvider);
      if (bus.length == 0) {
        final t = ref.read(stringsProvider);
        bus.system(t('log_booting'));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(terminalControllerProvider);
    final controller = ref.read(terminalControllerProvider.notifier);
    final t = ref.watch(stringsProvider);
    final settings = ref.watch(settingsProvider).valueOrNull;
    final theme = AppTypography.buildTextTheme();
    final accent = widget.accent;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        // ------------------------------------------------------------ header
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: accent.withValues(alpha: 0.3)),
              ),
              child: Icon(Icons.terminal, color: accent, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t('terminal_title'),
                    style: theme.titleMedium?.copyWith(color: accent, letterSpacing: 1.6),
                  ),
                  Text(
                    t('terminal_subtitle'),
                    style: theme.bodySmall,
                  ),
                ],
              ),
            ),
            _StatusPill(stage: state.stage, accent: accent),
          ],
        ),
        const SizedBox(height: 16),

        // -------------------------------------------------------- upload zone
        UploadZone(
          accent: accent,
          file: state.file,
          layout: state.layout,
          scanning: state.stage == JobStage.scanning,
        ),
        const SizedBox(height: 14),

        // ------------------------------------------------------ target + detect
        LanguageSelector(
          accent: accent,
          selectedCode: settings?.targetLanguageCode ?? 'ar',
        ),
        const SizedBox(height: 10),
        DetectionLine(
          accent: accent,
          detection: state.detection,
          detecting: state.stage == JobStage.detecting,
          hasFile: state.hasFile,
          onRetry: controller.retryDetection,
        ),
        const SizedBox(height: 14),

        // ------------------------------------------------------------- stats
        if (state.layout != null) _StatsRow(state: state, accent: accent),
        if (state.layout != null) const SizedBox(height: 14),

        // ---------------------------------------------------------- progress
        NeonProgressBar(
          value: state.progress,
          accent: state.stage == JobStage.failed
              ? AppColors.danger
              : state.stage == JobStage.cancelled
                  ? AppColors.warning
                  : accent,
          indeterminate: state.stage == JobStage.scanning ||
              state.stage == JobStage.injecting ||
              state.stage == JobStage.saving,
          label: '${state.stage.label(t)}   ${Formatters.percent(state.progress)}',
          trailing: state.elapsed == null
              ? null
              : Text(
                  Formatters.duration(state.elapsed!),
                  style: theme.labelSmall?.copyWith(color: AppColors.textSecondary),
                ),
        ),
        const SizedBox(height: 16),

        // ---------------------------------------------------------- actions
        Row(
          children: [
            Expanded(
              flex: 3,
              child: FilledButton.icon(
                onPressed: state.isBusy ? null : controller.start,
                icon: Icon(state.stage == JobStage.done ? Icons.refresh : Icons.bolt,
                    size: 18),
                label: Text(state.stage == JobStage.done ? t('retry') : t('start')),
              ),
            ),
            if (state.isBusy) ...[
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: OutlinedButton.icon(
                  onPressed: controller.cancel,
                  icon: const Icon(Icons.stop, size: 16),
                  label: Text(t('abort')),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.danger,
                    side: const BorderSide(color: AppColors.danger),
                  ),
                ),
              ),
            ],
          ],
        ),
        if (state.hasOutput) ...[
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: widget.onOpenReader,
            icon: const Icon(Icons.menu_book, size: 18),
            label: Text(t('open_reader')),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.neonCyan.withValues(alpha: 0.14),
              foregroundColor: AppColors.neonCyan,
              side: const BorderSide(color: AppColors.neonCyan),
            ),
          ),
        ],
        if (state.errorKey != null) ...[
          const SizedBox(height: 12),
          _ErrorCard(
            message: t(state.errorKey!, {
              if (state.errorArgument != null) 'message': state.errorArgument!,
              if (state.errorArgument != null) 'code': state.errorArgument!,
            }),
          ),
        ],
        const SizedBox(height: 16),

        // -------------------------------------------------------------- logs
        LogStreamView(bus: ref.watch(logBusProvider), accent: accent, maxHeight: 320),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Text(
                t('glossary_hint'),
                style: theme.bodySmall,
              ),
            ),
            Text(
              '${state.glossarySize}',
              style: theme.labelSmall?.copyWith(color: accent),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          '${t('engine_model')}: ${settings?.model ?? '—'}',
          style: theme.labelSmall,
        ),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.stage, required this.accent});

  final JobStage stage;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final color = stage == JobStage.failed
        ? AppColors.danger
        : stage == JobStage.cancelled
            ? AppColors.warning
            : stage == JobStage.done
                ? AppColors.success
                : stage.isBusy
                    ? accent
                    : AppColors.textDisabled;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: color.withValues(alpha: 0.8), blurRadius: 6)],
            ),
          ),
          const SizedBox(width: 6),
          Text(
            stage.name.toUpperCase(),
            style: AppTypography.buildTextTheme().labelSmall?.copyWith(
                  color: color,
                  fontSize: 9.5,
                  letterSpacing: 1.1,
                ),
          ),
        ],
      ),
    );
  }
}

class _StatsRow extends ConsumerWidget {
  const _StatsRow({required this.state, required this.accent});

  final TerminalState state;
  final Color accent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final theme = AppTypography.buildTextTheme();
    final layout = state.layout!;
    final target = AppLanguageCatalog.byCode(
        ref.watch(settingsProvider).valueOrNull?.targetLanguageCode ?? 'ar');

    return Row(
      children: [
        Expanded(
          child: _StatTile(
            label: t('file_pages'),
            value: '${layout.pageCount}',
            accent: accent,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _StatTile(
            label: t('file_blocks'),
            value: '${layout.blockCount}',
            accent: accent,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _StatTile(
            label: t('estimated_cost'),
            value: Formatters.bytes(layout.characterCount),
            accent: accent,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _StatTile(
            label: t('target_language'),
            value: target.code.toUpperCase(),
            accent: accent,
          ),
        ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.label, required this.value, required this.accent});

  final String label;
  final String value;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final theme = AppTypography.buildTextTheme();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.panelBlack,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.gridLine),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.labelSmall?.copyWith(fontSize: 8.5),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: theme.titleSmall?.copyWith(color: accent, fontSize: 13),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = AppTypography.buildTextTheme();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: AppColors.danger, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: theme.bodySmall?.copyWith(color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
  }
}
