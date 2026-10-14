import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/providers.dart';
import '../../../core/localization/strings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../services/translation/language_catalog.dart';

/// Inline selector that opens the searchable language sheet.
class LanguageSelector extends ConsumerWidget {
  const LanguageSelector({
    super.key,
    required this.accent,
    required this.selectedCode,
  });

  final Color accent;
  final String selectedCode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final theme = AppTypography.buildTextTheme();
    final selected = AppLanguageCatalog.byCode(selectedCode);

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => showLanguageSheet(context, accent: accent),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.panelBlack,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: accent.withValues(alpha: 0.25)),
        ),
        child: Row(
          children: [
            Icon(Icons.translate, color: accent, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    t('target_language'),
                    style: theme.labelSmall?.copyWith(fontSize: 9.5),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    selected.displayName,
                    style: theme.titleSmall?.copyWith(fontSize: 14),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const Icon(Icons.expand_more, color: AppColors.textSecondary, size: 20),
          ],
        ),
      ),
    );
  }
}

/// Bottom sheet with search over every supported language.
Future<String?> showLanguageSheet(
  BuildContext context, {
  required Color accent,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.panelBlack,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (context) => _LanguageSheet(accent: accent),
  );
}

class _LanguageSheet extends ConsumerStatefulWidget {
  const _LanguageSheet({required this.accent});

  final Color accent;

  @override
  ConsumerState<_LanguageSheet> createState() => _LanguageSheetState();
}

class _LanguageSheetState extends ConsumerState<_LanguageSheet> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final theme = AppTypography.buildTextTheme();
    final results = AppLanguageCatalog.search(_query);
    final settings = ref.watch(settingsProvider).valueOrNull;
    final current = settings?.targetLanguageCode ?? 'ar';

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.92,
      minChildSize: 0.4,
      builder: (context, controller) {
        return Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.gridLine,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: TextField(
                controller: _search,
                onChanged: (value) => setState(() => _query = value),
                decoration: InputDecoration(
                  hintText: t('target_language_hint'),
                  prefixIcon: Icon(Icons.search, color: widget.accent, size: 20),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () {
                            _search.clear();
                            setState(() => _query = '');
                          },
                        ),
                ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                controller: controller,
                itemCount: results.length,
                itemBuilder: (context, index) {
                  final language = results[index];
                  final isSelected = language.code == current;
                  return ListTile(
                    dense: true,
                    selected: isSelected,
                    selectedTileColor: widget.accent.withValues(alpha: 0.08),
                    leading: SizedBox(
                      width: 38,
                      child: Text(
                        language.code.toUpperCase(),
                        style: theme.labelSmall?.copyWith(
                          color: isSelected ? widget.accent : AppColors.textDisabled,
                        ),
                      ),
                    ),
                    title: Text(
                      language.name,
                      style: theme.bodyMedium?.copyWith(
                        color: isSelected ? widget.accent : AppColors.textPrimary,
                      ),
                    ),
                    subtitle: Text(
                      language.nativeName,
                      style: theme.bodySmall,
                      textDirection:
                          language.rtl ? TextDirection.rtl : TextDirection.ltr,
                    ),
                    trailing: isSelected
                        ? Icon(Icons.check_circle, color: widget.accent, size: 18)
                        : null,
                    onTap: () {
                      unawaited(
                        ref
                            .read(settingsProvider.notifier)
                            .setTargetLanguage(language.code),
                      );
                      Navigator.of(context).pop(language.code);
                    },
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
