import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';

/// The signature ShadowLanguages surface: a dark panel framed by a neon hair
/// line with an optional terminal-style header.
class CyberPanel extends StatelessWidget {
  const CyberPanel({
    super.key,
    required this.child,
    this.title,
    this.trailing,
    this.accent = AppColors.neonGreen,
    this.padding = const EdgeInsets.all(16),
    this.glow = true,
  });

  final Widget child;
  final String? title;
  final Widget? trailing;
  final Color accent;
  final EdgeInsetsGeometry padding;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.panelBlack,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withValues(alpha: 0.16)),
        boxShadow: glow
            ? [
                BoxShadow(
                  color: accent.withValues(alpha: 0.06),
                  blurRadius: 24,
                  spreadRadius: -8,
                ),
              ]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null)
            Container(
              padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: accent.withValues(alpha: 0.12)),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: accent,
                      borderRadius: BorderRadius.circular(3),
                      boxShadow: [
                        BoxShadow(color: accent.withValues(alpha: 0.8), blurRadius: 8),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title!,
                      style: AppTypography.buildTextTheme().labelSmall?.copyWith(
                            color: accent,
                            letterSpacing: 1.4,
                          ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (trailing != null) trailing!,
                ],
              ),
            ),
          Padding(padding: padding, child: child),
        ],
      ),
    );
  }
}

/// Faint grid + scan lines used as the app background.
class CyberBackdrop extends StatelessWidget {
  const CyberBackdrop({super.key, required this.child, this.accent = AppColors.neonGreen});

  final Widget child;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: CustomPaint(painter: _GridPainter(accent: accent)),
        ),
        child,
      ],
    );
  }
}

class _GridPainter extends CustomPainter {
  _GridPainter({required this.accent});

  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    const step = 28.0;
    final paint = Paint()
      ..color = accent.withValues(alpha: 0.035)
      ..strokeWidth = 1;
    for (var x = 0.0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (var y = 0.0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter oldDelegate) =>
      oldDelegate.accent != accent;
}

/// Small blinking cursor used next to live status text.
class BlinkingCursor extends StatefulWidget {
  const BlinkingCursor({super.key, this.color = AppColors.neonGreen, this.size = 8});

  final Color color;
  final double size;

  @override
  State<BlinkingCursor> createState() => _BlinkingCursorState();
}

class _BlinkingCursorState extends State<BlinkingCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _controller,
      child: Container(
        width: widget.size,
        height: widget.size * 1.6,
        color: widget.color,
      ),
    );
  }
}
