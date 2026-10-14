import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/providers.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../services/translation/gemini_client.dart';

/// `[System]: Source language detected successfully: [English - 99.9%]`
///
/// Typed out character by character the first time it appears, so the hub feels
/// like a real terminal.
class DetectionLine extends ConsumerStatefulWidget {
  const DetectionLine({
    super.key,
    required this.accent,
    required this.detection,
    required this.detecting,
    required this.hasFile,
    this.onRetry,
  });

  final Color accent;
  final LanguageDetection? detection;
  final bool detecting;
  final bool hasFile;
  final VoidCallback? onRetry;

  @override
  ConsumerState<DetectionLine> createState() => _DetectionLineState();
}

class _DetectionLineState extends ConsumerState<DetectionLine> {
  Timer? _timer;
  String _revealed = '';
  String _full = '';
  String _signature = '';

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _animateTo(String text, String signature) {
    if (_signature == signature) return;
    _signature = signature;
    _full = text;
    _revealed = '';
    _timer?.cancel();
    if (text.isEmpty) {
      setState(() {});
      return;
    }
    var index = 0;
    _timer = Timer.periodic(const Duration(milliseconds: 12), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      index += 2;
      if (index >= text.length) {
        setState(() => _revealed = text);
        timer.cancel();
        return;
      }
      setState(() => _revealed = text.substring(0, index));
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final theme = AppTypography.buildTextTheme();
    final detection = widget.detection;

    final String body;
    final Color color;
    final String signature;
    if (widget.detecting) {
      body = t('source_detecting');
      color = AppColors.neonCyan;
      signature = 'detecting';
    } else if (detection != null) {
      body = t('source_detected', {
        'name': detection.name,
        'confidence': detection.confidence.toStringAsFixed(1),
      });
      color = AppColors.neonGreen;
      signature = 'detected:${detection.code}:${detection.confidence}';
    } else if (widget.hasFile) {
      body = t('source_failed');
      color = AppColors.warning;
      signature = 'failed';
    } else {
      body = t('source_none');
      color = AppColors.textDisabled;
      signature = 'none';
    }
    const prefix = '[System]: ';
    final message = prefix + body;

    _animateTo(message, signature);
    final shown = _revealed.isEmpty && message.isNotEmpty ? '' : _revealed;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.voidBlack,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text.rich(
              TextSpan(
                style: AppTypography.terminalLine.copyWith(color: color),
                children: [
                  TextSpan(
                    text: shown,
                    style: TextStyle(
                      shadows: [
                        Shadow(color: color.withValues(alpha: 0.6), blurRadius: 8),
                      ],
                    ),
                  ),
                  if (shown.length < message.length)
                    const TextSpan(text: '▊'),
                ],
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (!widget.detecting && detection == null && widget.hasFile)
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.refresh, size: 16, color: widget.accent),
              tooltip: t('retry'),
              onPressed: widget.onRetry,
            ),
        ],
      ),
    );
  }
}
