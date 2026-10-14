import 'text_block.dart';

/// Layout information of a single page.
class PageLayout {
  const PageLayout({
    required this.index,
    required this.width,
    required this.height,
    required this.rotation,
    required this.blocks,
  });

  /// Zero based page index.
  final int index;
  final double width;
  final double height;

  /// `/Rotate` value in degrees (0/90/180/270).
  final int rotation;
  final List<TextBlock> blocks;

  int get blockCount => blocks.length;

  /// Returns the page with [extra] blocks appended (used by the OCR step to add
  /// the words it found inside the page images).
  PageLayout withExtraBlocks(List<TextBlock> extra) => PageLayout(
        index: index,
        width: width,
        height: height,
        rotation: rotation,
        blocks: [...blocks, ...extra],
      );

  PageLayout copyWith({List<TextBlock>? blocks}) => PageLayout(
        index: index,
        width: width,
        height: height,
        rotation: rotation,
        blocks: blocks ?? this.blocks,
      );

  int get characterCount =>
      blocks.fold<int>(0, (sum, b) => sum + b.length);
}

/// The full text-layer map of a document.
class BookLayout {
  const BookLayout({
    required this.sourcePath,
    required this.sourceName,
    required this.pageCount,
    required this.pages,
    required this.detectedLanguageCode,
    required this.detectedLanguageName,
    required this.detectionConfidence,
  });

  final String sourcePath;
  final String sourceName;
  final int pageCount;
  final List<PageLayout> pages;

  final String? detectedLanguageCode;
  final String? detectedLanguageName;

  /// 0..1 confidence reported by the neural core.
  final double detectionConfidence;

  List<TextBlock> get allBlocks =>
      pages.expand((p) => p.blocks).toList(growable: false);

  int get blockCount => pages.fold<int>(0, (s, p) => s + p.blockCount);

  BookLayout copyWith({List<PageLayout>? pages}) => BookLayout(
        sourcePath: sourcePath,
        sourceName: sourceName,
        pageCount: pageCount,
        pages: pages ?? this.pages,
        detectedLanguageCode: detectedLanguageCode,
        detectedLanguageName: detectedLanguageName,
        detectionConfidence: detectionConfidence,
      );

  int get characterCount => pages.fold<int>(0, (s, p) => s + p.characterCount);

  bool get isEmpty => blockCount == 0;

  /// Blocks grouped by page index.
  Map<int, List<TextBlock>> get blocksByPage => {
        for (final page in pages) page.index: page.blocks,
      };

  @override
  String toString() =>
      'BookLayout($sourceName, $pageCount pages, $blockCount blocks)';
}
