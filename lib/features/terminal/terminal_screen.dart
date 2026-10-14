import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/providers.dart';
import '../../core/error/failure.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/formatters.dart';
import '../../services/pdf/verification/layout_verifier.dart';
import '../../services/translation/language_catalog.dart';
import '../../shared/widgets/log_stream.dart';
import '../../shared/widgets/neon_progress.dart';
import 'terminal_controller.dart';
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

    return Stack(
      children: [
    ListView(
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

        // --------------------------------------------------------- pre-flight
        if (state.preflight != null) ...[
          _PreflightCard(preflight: state.preflight!, accent: accent),
          const SizedBox(height: 14),
        ],
        if (state.checkpoint != null && !state.isBusy) ...[
          _ResumeCard(checkpoint: state.checkpoint!, accent: accent),
          const SizedBox(height: 14),
        ],

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
        if (state.failure != null) ...[
          const SizedBox(height: 12),
          _FailureCard(failure: state.failure!, accent: accent),
        ],
        if (state.verification != null) ...[
          const SizedBox(height: 10),
          _VerificationLine(report: state.verification!, accent: accent),
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
    ),
        if (state.askingPassword)
          _PasswordOverlay(accent: accent, controller: controller),
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

/// Failure with the recovery actions that actually make sense.
class _FailureCard extends ConsumerWidget {
  const _FailureCard({required this.failure, required this.accent});

  final Failure failure;
  final Color accent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final controller = ref.read(terminalControllerProvider.notifier);
    final theme = AppTypography.buildTextTheme();
    final argument = failure.argument ?? '';
    final message = t(failure.messageKey, {
      'message': argument,
      'code': argument,
      'language': argument,
      'count': argument,
      'ratio': argument,
      'changed': argument,
      'page': argument,
      'total': argument,
      'done': argument,
      'percent': argument,
      'width': argument,
    });
    final color = failure.isCancelled ? AppColors.warning : AppColors.danger;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.error_outline, color: color, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  style: theme.bodySmall?.copyWith(color: color),
                ),
              ),
            ],
          ),
          if (failure.kind == FailureKind.pdfEncrypted ||
              failure.canResume ||
              failure.canRetry) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (failure.kind == FailureKind.pdfEncrypted ||
                    failure.kind == FailureKind.pdfWrongPassword)
                  OutlinedButton.icon(
                    onPressed: controller.requestPassword,
                    icon: const Icon(Icons.lock_open, size: 16),
                    label: Text(t('password_submit')),
                  ),
                if (failure.canResume)
                  FilledButton.icon(
                    onPressed: controller.resume,
                    icon: const Icon(Icons.play_arrow, size: 16),
                    label: Text(t('resume_cta')),
                  ),
                if (failure.canRetry)
                  OutlinedButton.icon(
                    onPressed: controller.retry,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: Text(t('retry_cta')),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Cost, fonts and artwork risk, computed before the first request.
class _PreflightCard extends ConsumerWidget {
  const _PreflightCard({required this.preflight, required this.accent});

  final PreflightReport preflight;
  final Color accent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final theme = AppTypography.buildTextTheme();
    final font = preflight.font;
    final fontColor = font.isCritical
        ? AppColors.danger
        : font.isPartial
            ? AppColors.warning
            : AppColors.success;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.panelBlack,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.fact_check_outlined, size: 16, color: accent),
              const SizedBox(width: 8),
              Text(
                t('preflight_title'),
                style: theme.labelSmall?.copyWith(color: accent, letterSpacing: 1.4),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                  child: _PreflightStat(
                      label: t('preflight_pages'),
                      value: '${preflight.pages}')),
              Expanded(
                  child: _PreflightStat(
                      label: t('preflight_blocks'),
                      value: '${preflight.blocks}')),
              Expanded(
                  child: _PreflightStat(
                      label: t('preflight_requests'),
                      value: '~${preflight.estimatedRequests}')),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _PreflightStat(
                  label: t('preflight_fonts'),
                  value: '${(font.ratio * 100).toStringAsFixed(0)}%',
                  color: fontColor,
                ),
              ),
              Expanded(
                child: _PreflightStat(
                  label: t('preflight_risks'),
                  value: '${preflight.placements?.riskyBlocks ?? 0}',
                  color: (preflight.placements?.riskyBlocks ?? 0) > 0
                      ? AppColors.warning
                      : AppColors.success,
                ),
              ),
              Expanded(
                child: _PreflightStat(
                  label: t('preflight_warnings'),
                  value: '${preflight.warnings.length}',
                  color: preflight.hasWarnings
                      ? AppColors.warning
                      : AppColors.success,
                ),
              ),
            ],
          ),
          if (preflight.hasWarnings) ...[
            const SizedBox(height: 10),
            for (final warning in preflight.warnings.take(4))
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.warning_amber_rounded,
                        size: 13, color: AppColors.warning),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(warning, style: theme.labelSmall),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _PreflightStat extends StatelessWidget {
  const _PreflightStat({required this.label, required this.value, this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = AppTypography.buildTextTheme();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: theme.labelSmall?.copyWith(fontSize: 9),
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
        const SizedBox(height: 2),
        Text(
          value,
          style: theme.bodyMedium?.copyWith(color: color ?? AppColors.textPrimary),
        ),
      ],
    );
  }
}

/// "You already translated 32 pages" — continue or throw it away.
class _ResumeCard extends ConsumerWidget {
  const _ResumeCard({required this.checkpoint, required this.accent});

  final JobCheckpoint checkpoint;
  final Color accent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final controller = ref.read(terminalControllerProvider.notifier);
    final theme = AppTypography.buildTextTheme();

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.restore, size: 16, color: AppColors.warning),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  t('resume_title'),
                  style: theme.labelSmall?.copyWith(
                      color: AppColors.warning, letterSpacing: 1.4),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            t('resume_body', {
              'done': '${checkpoint.completedCount}',
              'total': '${checkpoint.pageCount}',
              'percent': Formatters.percent(checkpoint.ratio),
            }),
            style: theme.bodySmall,
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              FilledButton.icon(
                onPressed: controller.resume,
                icon: const Icon(Icons.play_arrow, size: 16),
                label: Text(t('resume_cta')),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.warning.withValues(alpha: 0.2),
                  foregroundColor: AppColors.warning,
                  side: const BorderSide(color: AppColors.warning),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: controller.discardCheckpoint,
                child: Text(t('resume_discard')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Result of the pixel diff between the original and the translated book.
class _VerificationLine extends ConsumerWidget {
  const _VerificationLine({required this.report, required this.accent});

  final VerificationReport report;
  final Color accent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final theme = AppTypography.buildTextTheme();
    final ok = report.passed;
    final color = ok ? AppColors.success : AppColors.danger;
    final message = ok
        ? t('verify_ok', {'changed': '${report.totalChanged}'})
        : t('verify_failed',
            {'ratio': (report.worstRatio * 100).toStringAsFixed(2)});

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(ok ? Icons.verified_outlined : Icons.warning_amber_rounded,
              size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message,
                style: theme.labelSmall?.copyWith(color: color)),
          ),
          Text(
            t('verify_pages', {
              'count': '${report.checkedPages}',
              'width': '${report.renderWidth}',
            }),
            style: theme.labelSmall,
          ),
        ],
      ),
    );
  }
}

/// Modal that asks for the password of a protected document.
class _PasswordOverlay extends ConsumerStatefulWidget {
  const _PasswordOverlay({required this.accent, required this.controller});

  final Color accent;
  final TerminalController controller;

  @override
  ConsumerState<_PasswordOverlay> createState() => _PasswordOverlayState();
}

class _PasswordOverlayState extends ConsumerState<_PasswordOverlay> {
  final TextEditingController _field = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() => _busy = true);
    final value = _field.text;
    await widget.controller.submitPassword(value);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final theme = AppTypography.buildTextTheme();
    final accent = widget.accent;

    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.72),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: AppColors.panelBlack,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: accent.withValues(alpha: 0.35)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(Icons.lock_outline, color: accent, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          t('password_title'),
                          style: theme.titleSmall?.copyWith(color: accent),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(t('password_body'), style: theme.bodySmall),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _field,
                    obscureText: true,
                    autofocus: true,
                    style: AppTypography.logLine,
                    decoration: InputDecoration(labelText: t('password_label')),
                    onSubmitted: (_) => _submit(),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _busy ? null : _submit,
                          icon: _busy
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.lock_open, size: 16),
                          label: Text(t('password_submit')),
                        ),
                      ),
                      const SizedBox(width: 10),
                      TextButton(
                        onPressed: _busy ? null : widget.controller.cancelPassword,
                        child: Text(t('password_cancel')),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
