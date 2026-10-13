import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';

/// The animated neon progress bar of the operations hub.
class NeonProgressBar extends StatefulWidget {
  const NeonProgressBar({
    super.key,
    required this.value,
    this.accent = AppColors.neonGreen,
    this.height = 14,
    this.label,
    this.trailing,
    this.indeterminate = false,
  });

  /// 0..1
  final double value;
  final Color accent;
  final double height;
  final String? label;
  final Widget? trailing;
  final bool indeterminate;

  @override
  State<NeonProgressBar> createState() => _NeonProgressBarState();
}

class _NeonProgressBarState extends State<NeonProgressBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
    value: widget.value.clamp(0.0, 1.0),
  );
  late final AnimationController _shimmer = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat();

  @override
  void didUpdateWidget(covariant NeonProgressBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.value.clamp(0.0, 1.0);
    if (next != _controller.value) {
      _controller.animateTo(next, curve: Curves.easeOutCubic);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _shimmer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = AppTypography.buildTextTheme();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.label != null || widget.trailing != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                if (widget.label != null)
                  Expanded(
                    child: Text(
                      widget.label!,
                      style: theme.labelSmall?.copyWith(color: widget.accent),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                if (widget.trailing != null) widget.trailing!,
              ],
            ),
          ),
        SizedBox(
          height: widget.height,
          child: AnimatedBuilder(
            animation: Listenable.merge([_controller, _shimmer]),
            builder: (context, _) {
              final value = widget.indeterminate ? 1.0 : _controller.value;
              return CustomPaint(
                painter: _NeonBarPainter(
                  value: value,
                  accent: widget.accent,
                  shimmer: _shimmer.value,
                  indeterminate: widget.indeterminate,
                  segments: 32,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _NeonBarPainter extends CustomPainter {
  _NeonBarPainter({
    required this.value,
    required this.accent,
    required this.shimmer,
    required this.indeterminate,
    required this.segments,
  });

  final double value;
  final Color accent;
  final double shimmer;
  final bool indeterminate;
  final int segments;

  @override
  void paint(Canvas canvas, Size size) {
    final track = Paint()..color = AppColors.gridLine;
    final radius = Radius.circular(size.height / 2);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, radius),
      track,
    );

    final cellWidth = size.width / segments;
    final filled = (value * segments).floor();
    final partial = value * segments - filled;

    for (var i = 0; i < segments; i++) {
      final double fillRatio;
      if (indeterminate) {
        final wave = (math.sin((i / segments * 4 * math.pi) + shimmer * 2 * math.pi) + 1) / 2;
        fillRatio = 0.15 + wave * 0.85;
      } else if (i < filled) {
        fillRatio = 1;
      } else if (i == filled) {
        fillRatio = partial;
      } else {
        continue;
      }
      final gap = cellWidth * 0.22;
      final rect = Rect.fromLTWH(
        i * cellWidth + gap / 2,
        gap / 2,
        (cellWidth - gap) * fillRatio.clamp(0.0, 1.0),
        size.height - gap,
      );
      if (rect.width <= 0) continue;
      final paint = Paint()
        ..color = accent.withValues(alpha: 0.35 + 0.65 * fillRatio)
        ..maskFilter = MaskFilter.blur(BlurStyle.solid, size.height * 0.35);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(rect.height / 2)),
        paint,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(rect.height / 2)),
        Paint()..color = accent.withValues(alpha: 0.9),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _NeonBarPainter old) =>
      old.value != value || old.shimmer != shimmer || old.accent != accent;
}
