import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/providers.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../data/models/book_layout.dart';
import '../../terminal/terminal_controller.dart';

/// Cyberpunk drop zone: dashed neon frame that turns into a file card once a
/// payload is mounted.
class UploadZone extends ConsumerWidget {
  const UploadZone({
    super.key,
    required this.accent,
    required this.file,
    required this.layout,
    required this.scanning,
  });

  final Color accent;
  final PickedFile? file;
  final BookLayout? layout;
  final bool scanning;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final theme = AppTypography.buildTextTheme();

    if (file == null) {
      return InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => ref.read(terminalControllerProvider.notifier).pickFile(),
        child: CustomPaint(
          painter: _DashedBorderPainter(color: accent.withValues(alpha: 0.55)),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 34, horizontal: 20),
            child: Column(
              children: [
                Icon(Icons.upload_file, size: 40, color: accent),
                const SizedBox(height: 14),
                Text(
                  t('upload_title'),
                  style: theme.titleSmall?.copyWith(
                    color: accent,
                    letterSpacing: 1.6,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  t('upload_hint'),
                  textAlign: TextAlign.center,
                  style: theme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.panelBlack,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.picture_as_pdf_outlined, color: accent, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file!.name,
                      style: theme.titleSmall
                          ?.copyWith(color: AppColors.textPrimary, fontSize: 13.5),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 10,
                      runSpacing: 4,
                      children: [
                        _chip(theme, t('file_size'), Formatters.bytes(file!.sizeBytes)),
                        if (layout != null)
                          _chip(theme, t('file_pages'), '${layout!.pageCount}'),
                        if (layout != null)
                          _chip(theme, t('file_blocks'), '${layout!.blockCount}'),
                        if (scanning) _chip(theme, 'STATUS', t('file_scanning')),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: scanning
                      ? null
                      : () => ref.read(terminalControllerProvider.notifier).pickFile(),
                  icon: const Icon(Icons.swap_horiz, size: 16),
                  label: Text(t('upload_change')),
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: scanning
                      ? null
                      : () => ref.read(terminalControllerProvider.notifier).clearFile(),
                  icon: const Icon(Icons.close, size: 16),
                  label: Text(t('upload_remove')),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 40),
                    foregroundColor: AppColors.danger,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _chip(TextTheme theme, String label, String value) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$label: ',
          style: theme.labelSmall?.copyWith(fontSize: 10),
        ),
        Text(
          value,
          style: theme.labelSmall?.copyWith(
            fontSize: 10,
            color: AppColors.textPrimary,
          ),
        ),
      ],
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  _DashedBorderPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    const dash = 10.0;
    const gap = 7.0;
    final radius = 16.0;
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(1, 1, size.width - 2, size.height - 2),
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final length = distance + dash < metric.length ? dash : metric.length - distance;
        canvas.drawPath(metric.extractPath(distance, distance + length), paint);
        distance += dash + gap;
      }
    }
    canvas.drawRRect(
      rrect,
      Paint()..color = color.withValues(alpha: 0.04),
    );
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter old) => old.color != color;
}
