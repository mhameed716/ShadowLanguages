import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/di/providers.dart';
import '../../core/localization/strings.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/formatters.dart';
import '../../data/models/saved_book.dart';

/// Which document the viewer shows.
enum ReaderMode { translated, original, split }

/// Screen 2 — the dark, comfortable reader for the finished payload.
class ReaderScreen extends ConsumerStatefulWidget {
  const ReaderScreen({
    super.key,
    required this.accent,
    this.initialBook,
    this.onOpenTerminal,
  });

  final Color accent;
  final SavedBook? initialBook;
  final VoidCallback? onOpenTerminal;

  @override
  ConsumerState<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends ConsumerState<ReaderScreen> {
  final PdfViewerController _controller = PdfViewerController();
  late final PdfTextSearcher _searcher = PdfTextSearcher(_controller);
  final TextEditingController _searchField = TextEditingController();

  SavedBook? _book;
  ReaderMode _mode = ReaderMode.translated;
  bool _searchVisible = false;
  int _pageNumber = 1;
  int _pageCount = 0;

  @override
  void initState() {
    super.initState();
    _book = widget.initialBook;
    _searcher.addListener(_onSearchChanged);
  }

  @override
  void didUpdateWidget(covariant ReaderScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialBook != null && widget.initialBook != _book) {
      setState(() => _book = widget.initialBook);
    }
  }

  @override
  void dispose() {
    _searcher.removeListener(_onSearchChanged);
    _searcher.dispose();
    _searchField.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(stringsProvider);
    final booksAsync = ref.watch(libraryProvider);
    final books = booksAsync.valueOrNull ?? const <SavedBook>[];
    final book = _book ?? (books.isEmpty ? null : books.first);

    if (book == null) {
      return _EmptyReader(
        accent: widget.accent,
        loading: booksAsync.isLoading,
        onOpenTerminal: widget.onOpenTerminal,
      );
    }
    if (book != _book) {
      _book = book;
    }

    final originalPath = book.sourcePath;
    final canCompare = originalPath != null && File(originalPath).existsSync();

    return Column(
      children: [
        _ReaderToolbar(
          accent: widget.accent,
          book: book,
          mode: _mode,
          canCompare: canCompare,
          pageNumber: _pageNumber,
          pageCount: _pageCount,
          onModeChanged: (mode) => setState(() => _mode = mode),
          onSearch: () {
            setState(() => _searchVisible = !_searchVisible);
            if (!_searchVisible) {
              _searcher.resetTextSearch();
              _searchField.clear();
            }
          },
          onLibrary: () => _pickBook(booksAsync.valueOrNull ?? const []),
          onExport: () => _export(book),
        ),
        if (_searchVisible)
          _SearchBar(
            accent: widget.accent,
            controller: _searchField,
            searcher: _searcher,
            onClose: () {
              setState(() => _searchVisible = false);
              _searcher.resetTextSearch();
              _searchField.clear();
            },
          ),
        Expanded(
          child: _buildBody(book, canCompare),
        ),
      ],
    );
  }

  Widget _buildBody(SavedBook book, bool canCompare) {
    Widget viewer(String path, {PdfViewerController? controller, Key? key}) =>
        PdfViewer.file(
          key: key,
          path,
          controller: controller,
          params: PdfViewerParams(
            backgroundColor: AppColors.carbonBlack,
            margin: 8,
            // no shadow: the page sits on pure carbon black
            pageDropShadow: null,
            enableKeyboardNavigation: true,
            textSelectionParams: const PdfTextSelectionParams(enabled: true),
            onPageChanged: controller == null
                ? null
                : (pageNumber) =>
                    setState(() => _pageNumber = pageNumber ?? _pageNumber),
            onDocumentChanged: controller == null
                ? null
                : (document) => setState(
                      () => _pageCount = document?.pages.length ?? 0),
          ),
        );

    switch (_mode) {
      case ReaderMode.translated:
        return viewer(book.path, controller: _controller);
      case ReaderMode.original:
        return canCompare
            ? viewer(book.sourcePath!, controller: _controller)
            : viewer(book.path, controller: _controller);
      case ReaderMode.split:
        if (!canCompare) return viewer(book.path, controller: _controller);
        return Column(
          children: [
            _SplitLabel(
              label: ref.read(stringsProvider)('view_original'),
              accent: AppColors.neonCyan,
            ),
            Expanded(child: viewer(book.sourcePath!)),
            _SplitLabel(
              label: ref.read(stringsProvider)('view_translated'),
              accent: widget.accent,
            ),
            Expanded(child: viewer(book.path, controller: _controller)),
          ],
        );
    }
  }

  void _pickBook(List<SavedBook> books) async {
    if (books.isEmpty) return;
    final t = ref.read(stringsProvider);
    final picked = await showModalBottomSheet<SavedBook>(
      context: context,
      backgroundColor: AppColors.panelBlack,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
              child: Row(
                children: [
                  Icon(Icons.collections_bookmark, color: widget.accent, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    t('library_title'),
                    style: AppTypography.buildTextTheme().titleSmall,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: books.length,
                itemBuilder: (context, index) {
                  final book = books[index];
                  return ListTile(
                    leading: Icon(Icons.picture_as_pdf_outlined,
                        color: widget.accent, size: 20),
                    title: Text(
                      book.name,
                      style: AppTypography.buildTextTheme().bodyMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${Formatters.bytes(book.sizeBytes)} · ${book.pageCount} pages',
                      style: AppTypography.buildTextTheme().bodySmall,
                    ),
                    onTap: () => Navigator.of(context).pop(book),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    if (picked != null && mounted) {
      setState(() {
        _book = picked;
        _mode = ReaderMode.translated;
      });
    }
  }

  Future<void> _export(SavedBook book) async {
    final t = ref.read(stringsProvider);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final path = await ref.read(libraryRepositoryProvider).exportToDownloads(book);
      if (path != null) {
        messenger.showSnackBar(
          SnackBar(content: Text(t('export_saved_to', {'path': path}))),
        );
      }
      await Share.shareXFiles(
        [XFile(book.path)],
        subject: book.name,
        text: 'ShadowLanguages — ${book.name}',
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(t('export_failed', {'message': '$e'}))),
      );
    }
  }
}

class _ReaderToolbar extends StatelessWidget {
  const _ReaderToolbar({
    required this.accent,
    required this.book,
    required this.mode,
    required this.canCompare,
    required this.pageNumber,
    required this.pageCount,
    required this.onModeChanged,
    required this.onSearch,
    required this.onLibrary,
    required this.onExport,
  });

  final Color accent;
  final SavedBook book;
  final ReaderMode mode;
  final bool canCompare;
  final int pageNumber;
  final int pageCount;
  final ValueChanged<ReaderMode> onModeChanged;
  final VoidCallback onSearch;
  final VoidCallback onLibrary;
  final VoidCallback onExport;

  @override
  Widget build(BuildContext context) {
    final t = Strings(Localizations.localeOf(context).languageCode);
    final theme = AppTypography.buildTextTheme();
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: const BoxDecoration(
        color: AppColors.carbonBlack,
        border: Border(bottom: BorderSide(color: AppColors.gridLine)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.menu_book, color: accent, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  book.name,
                  style: theme.titleSmall?.copyWith(fontSize: 13),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: t('library_title'),
                icon: const Icon(Icons.folder_open, size: 18),
                color: AppColors.textSecondary,
                onPressed: onLibrary,
              ),
              IconButton(
                tooltip: t('export_share'),
                icon: const Icon(Icons.ios_share, size: 18),
                color: accent,
                onPressed: onExport,
              ),
            ],
          ),
          Row(
            children: [
              _ModeChip(
                label: t('view_translated'),
                active: mode == ReaderMode.translated,
                accent: accent,
                onTap: () => onModeChanged(ReaderMode.translated),
              ),
              const SizedBox(width: 6),
              _ModeChip(
                label: t('view_original'),
                active: mode == ReaderMode.original,
                accent: AppColors.neonCyan,
                enabled: canCompare,
                onTap: () => onModeChanged(ReaderMode.original),
              ),
              const SizedBox(width: 6),
              _ModeChip(
                label: t('view_split'),
                active: mode == ReaderMode.split,
                accent: AppColors.neonPurple,
                enabled: canCompare,
                onTap: () => onModeChanged(ReaderMode.split),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.search, size: 18),
                color: AppColors.textSecondary,
                tooltip: t('search_hint'),
                onPressed: onSearch,
              ),
              if (pageCount > 0)
                Text(
                  '$pageNumber/$pageCount',
                  style: theme.labelSmall,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({
    required this.label,
    required this.active,
    required this.accent,
    required this.onTap,
    this.enabled = true,
  });

  final String label;
  final bool active;
  final Color accent;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final color = enabled ? accent : AppColors.textDisabled;
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: active ? color.withValues(alpha: 0.16) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: active ? color : AppColors.gridLine),
        ),
        child: Text(
          label,
          style: AppTypography.buildTextTheme().labelSmall?.copyWith(
                color: active ? color : AppColors.textDisabled,
              ),
        ),
      ),
    );
  }
}

class _SearchBar extends StatelessWidget {
  const _SearchBar({
    required this.accent,
    required this.controller,
    required this.searcher,
    required this.onClose,
  });

  final Color accent;
  final TextEditingController controller;
  final PdfTextSearcher searcher;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final t = Strings(Localizations.localeOf(context).languageCode);
    final theme = AppTypography.buildTextTheme();
    final matches = searcher.matches.length;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      color: AppColors.panelBlack,
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              autofocus: true,
              style: theme.bodyMedium?.copyWith(color: AppColors.textPrimary),
              onSubmitted: (value) =>
                  searcher.startTextSearch(value, searchImmediately: true),
              onChanged: (value) => searcher.startTextSearch(value),
              decoration: InputDecoration(
                isDense: true,
                hintText: t('search_hint'),
                prefixIcon: Icon(Icons.search, size: 18, color: accent),
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (searcher.isSearching)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (matches > 0)
            Text(
              t('search_of', {
                'index': '${searcher.currentIndex ?? 0}',
                'count': '$matches',
              }),
              style: theme.labelSmall?.copyWith(color: accent),
            )
          else if (controller.text.isNotEmpty)
            Text(t('search_empty'), style: theme.labelSmall),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_up, size: 20),
            color: AppColors.textSecondary,
            onPressed: matches > 0 ? () => searcher.goToPrevMatch() : null,
          ),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down, size: 20),
            color: AppColors.textSecondary,
            onPressed: matches > 0 ? () => searcher.goToNextMatch() : null,
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            color: AppColors.textDisabled,
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

class _SplitLabel extends StatelessWidget {
  const _SplitLabel({required this.label, required this.accent});

  final String label;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: accent.withValues(alpha: 0.08),
      child: Text(
        label,
        style: AppTypography.buildTextTheme().labelSmall?.copyWith(color: accent),
      ),
    );
  }
}

class _EmptyReader extends ConsumerWidget {
  const _EmptyReader({
    required this.accent,
    required this.loading,
    this.onOpenTerminal,
  });

  final Color accent;
  final bool loading;
  final VoidCallback? onOpenTerminal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final theme = AppTypography.buildTextTheme();
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_stories_outlined, size: 56, color: accent.withValues(alpha: 0.7)),
            const SizedBox(height: 18),
            Text(
              t('reader_empty'),
              textAlign: TextAlign.center,
              style: theme.bodyMedium,
            ),
            const SizedBox(height: 18),
            if (loading)
              const CircularProgressIndicator()
            else if (onOpenTerminal != null)
              FilledButton.icon(
                onPressed: onOpenTerminal,
                icon: const Icon(Icons.terminal, size: 18),
                label: Text(t('terminal_title')),
              ),
          ],
        ),
      ),
    );
  }
}
