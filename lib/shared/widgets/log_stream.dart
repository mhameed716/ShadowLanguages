import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/providers.dart';
import '../../core/localization/strings.dart';
import '../../core/logging/log_entry.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';

/// The live log stream: a black terminal window that prints every step of the
/// pipeline, auto-scrolling as new lines arrive.
class LogStreamView extends ConsumerStatefulWidget {
  const LogStreamView({
    super.key,
    required this.bus,
    this.accent = AppColors.neonGreen,
    this.maxHeight = 260,
  });

  final LogBus bus;
  final Color accent;
  final double maxHeight;

  @override
  State<LogStreamView> createState() => _LogStreamViewState();
}

class _LogStreamViewState extends ConsumerState<LogStreamView> {
  final ScrollController _controller = ScrollController();
  bool _follow = true;

  @override
  void initState() {
    super.initState();
    widget.bus.addListener(_onLog);
  }

  @override
  void didUpdateWidget(covariant LogStreamView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bus != widget.bus) {
      oldWidget.bus.removeListener(_onLog);
      widget.bus.addListener(_onLog);
    }
  }

  @override
  void dispose() {
    widget.bus.removeListener(_onLog);
    _controller.dispose();
    super.dispose();
  }

  void _onLog() {
    if (!mounted) return;
    setState(() {});
    if (_follow) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_controller.hasClients) return;
        _controller.animateTo(
          _controller.position.maxScrollExtent + 60,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = widget.bus.entries;
    final t = ref.watch(stringsProvider);
    return Container(
      constraints: BoxConstraints(maxHeight: widget.maxHeight),
      decoration: BoxDecoration(
        color: AppColors.voidBlack,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: widget.accent.withValues(alpha: 0.14)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              children: [
                Text(
                  'shadow@core:~$ ./translate --live',
                  style: AppTypography.buildTextTheme().labelSmall?.copyWith(
                        color: widget.accent.withValues(alpha: 0.7),
                      ),
                ),
                const Spacer(),
                if (!_follow)
                  TextButton(
                    onPressed: () => setState(() => _follow = true),
                    child: Text(
                      'FOLLOW',
                      style: AppTypography.buildTextTheme().labelSmall?.copyWith(
                            color: AppColors.warning,
                          ),
                    ),
                  ),
                IconButton(
                  tooltip: t('clear_log'),
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.bus.clear,
                  icon: Icon(Icons.delete_outline,
                      size: 16, color: AppColors.textDisabled),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: NotificationListener<UserScrollNotification>(
              onNotification: (notification) {
                if (notification.direction == ScrollDirection.forward && _follow) {
                  setState(() => _follow = false);
                }
                return false;
              },
              child: ListView.builder(
                controller: _controller,
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
                itemCount: entries.length + 1,
                itemBuilder: (context, index) {
                  if (index == entries.length) {
                    return Row(
                      children: [
                        Text(
                          '> ',
                          style: AppTypography.logLine
                              .copyWith(color: widget.accent),
                        ),
                        BlinkingCursor(color: widget.accent, size: 7),
                      ],
                    );
                  }
                  final entry = entries[index];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: RichText(
                      text: TextSpan(
                        style: AppTypography.logLine,
                        children: [
                          TextSpan(
                            text: '${entry.clock} ',
                            style: TextStyle(color: AppColors.textDisabled),
                          ),
                          TextSpan(
                            text: '${entry.prefix} ',
                            style: TextStyle(color: _colorOf(entry.level)),
                          ),
                          TextSpan(
                            text: entry.message,
                            style: TextStyle(
                              color: _colorOf(entry.level).withValues(alpha: 0.92),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  static Color _colorOf(LogLevel level) => switch (level) {
        LogLevel.system => AppColors.neonCyan,
        LogLevel.info => AppColors.textSecondary,
        LogLevel.success => AppColors.neonGreen,
        LogLevel.warning => AppColors.warning,
        LogLevel.error => AppColors.danger,
        LogLevel.incoming => AppColors.neonPurple,
        LogLevel.outgoing => AppColors.neonCyan,
      };
}
