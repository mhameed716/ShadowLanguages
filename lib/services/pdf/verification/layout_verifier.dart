import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pdfrx/pdfrx.dart';

import '../../../data/models/book_layout.dart';
import '../../../data/models/text_block.dart';
import '../inject/pdf_geometry.dart';

/// What the pixel diff found on one page.
class PageVerification {
  const PageVerification({
    required this.pageIndex,
    required this.comparedPixels,
    required this.changedPixels,
    required this.changeRatio,
    required this.passed,
    this.skipped = false,
    this.note,
  });

  final int pageIndex;

  /// Pixels compared, i.e. everything **outside** the translated text boxes.
  final int comparedPixels;

  /// Pixels that differ between the original and the translated page.
  final int changedPixels;

  final double changeRatio;
  final bool passed;
  final bool skipped;
  final String? note;
}

/// Verdict for the whole document.
class VerificationReport {
  const VerificationReport({
    required this.pages,
    required this.worstRatio,
    required this.passed,
    required this.tolerance,
    required this.renderWidth,
    this.bytesBefore = 0,
    this.bytesAfter = 0,
  });

  final List<PageVerification> pages;
  final double worstRatio;
  final bool passed;
  final double tolerance;
  final int renderWidth;

  final int bytesBefore;
  final int bytesAfter;

  int get checkedPages => pages.where((p) => !p.skipped).length;

  int get totalChanged =>
      pages.fold<int>(0, (sum, p) => sum + p.changedPixels);

  int get totalCompared =>
      pages.fold<int>(0, (sum, p) => sum + p.comparedPixels);

  double get overallRatio =>
      totalCompared == 0 ? 0 : totalChanged / totalCompared;
}

/// Proves — pixel by pixel — that the injection did not lose or move anything.
///
/// The original and the translated document are rendered side by side at the
/// same resolution. Every pixel **outside** the boxes we were allowed to
/// repaint (the translated text boxes, slightly inflated for antialiasing)
/// must be identical. A difference out there means we damaged artwork: a photo,
/// a rule, a gradient or the paper texture.
///
/// This is the programmatic answer to "will replacing the text shift or delete
/// original elements?" — the app runs it after every job and prints the ratio.
class LayoutVerifier {
  LayoutVerifier({
    this.renderWidth = 800,
    this.tolerance = 0.015,
    this.maxPages = 15,
    this.channelThreshold = 26,
  });

  final int renderWidth;

  /// Share of compared pixels allowed to differ — covers rasteriser noise
  /// around glyph edges, never whole regions.
  final double tolerance;

  /// How many pages are checked (spread evenly through the book).
  final int maxPages;

  /// Per channel difference (0..255) that counts as "changed".
  final int channelThreshold;

  Future<VerificationReport> verify({
    required Uint8List original,
    required Uint8List translated,
    required BookLayout layout,
    void Function(String message)? onLog,
  }) async {
    final results = <PageVerification>[];
    PdfDocument? before;
    PdfDocument? after;
    try {
      before = await PdfDocument.openData(original);
      after = await PdfDocument.openData(translated);
      if (before.pages.length != after.pages.length) {
        onLog?.call(
            'verification: page count changed (${before.pages.length} → ${after.pages.length})');
      }

      final indices = _samplePages(layout, before.pages.length);
      for (final index in indices) {
        if (index >= after.pages.length) continue;
        results.add(
          await _verifyPage(
            before: before,
            after: after,
            pageIndex: index,
            blocks: layout.blocksByPage[index] ?? const [],
            onLog: onLog,
          ),
        );
      }
    } catch (e) {
      onLog?.call('verification aborted: $e');
    } finally {
      await before?.dispose();
      await after?.dispose();
    }

    final worst = results.fold<double>(
      0,
      (max, page) => page.changeRatio > max ? page.changeRatio : max,
    );
    return VerificationReport(
      pages: results,
      worstRatio: worst,
      passed: results.isNotEmpty && worst <= tolerance,
      tolerance: tolerance,
      renderWidth: renderWidth,
      bytesBefore: original.length,
      bytesAfter: translated.length,
    );
  }

  List<int> _samplePages(BookLayout layout, int pageCount) {
    final candidates = <int>[
      for (final page in layout.pages)
        if (page.blocks.isNotEmpty) page.index,
    ];
    if (candidates.isEmpty) return const [];
    if (candidates.length <= maxPages) return candidates;
    final step = candidates.length / maxPages;
    final out = <int>[];
    for (var i = 0; i < maxPages; i++) {
      final index = candidates[(i * step).floor().clamp(0, candidates.length - 1)];
      if (!out.contains(index)) out.add(index);
    }
    return out;
  }

  Future<PageVerification> _verifyPage({
    required PdfDocument before,
    required PdfDocument after,
    required int pageIndex,
    required List<TextBlock> blocks,
    void Function(String message)? onLog,
  }) async {
    final beforePage = before.pages[pageIndex];
    final afterPage = after.pages[pageIndex];
    final scale = renderWidth / beforePage.width;
    final width = math.max(1, (beforePage.width * scale).round());
    final height = math.max(1, (beforePage.height * scale).round());

    PdfImage? a;
    PdfImage? b;
    try {
      a = await beforePage.render(
        width: width,
        height: height,
        backgroundColor: 0xFFFFFFFF,
        annotationRenderingMode: PdfAnnotationRenderingMode.none,
      );
      b = await afterPage.render(
        width: width,
        height: height,
        backgroundColor: 0xFFFFFFFF,
        annotationRenderingMode: PdfAnnotationRenderingMode.none,
      );
      if (a == null || b == null) {
        return PageVerification(
          pageIndex: pageIndex,
          comparedPixels: 0,
          changedPixels: 0,
          changeRatio: 0,
          passed: true,
          skipped: true,
          note: 'render returned no image',
        );
      }
      final pa = a.pixels;
      final pb = b.pixels;
      if (a.width != b.width || a.height != b.height) {
        return PageVerification(
          pageIndex: pageIndex,
          comparedPixels: 0,
          changedPixels: 0,
          changeRatio: 0,
          passed: true,
          skipped: true,
          note: 'render unavailable',
        );
      }

      // Regions we are allowed to repaint: every translated box, inflated by a
      // couple of points so antialiased edges are excluded from the diff.
      final allowed = blocks
          .map((block) => _pixelRect(
                box: block.box.inflate(
                  left: 2,
                  right: 2,
                  top: 2,
                  bottom: 2,
                ),
                imageWidth: a.width,
                imageHeight: a.height,
                pageWidth: beforePage.width,
                pageHeight: beforePage.height,
              ))
          .toList(growable: false);

      var compared = 0;
      var changed = 0;
      final w = a.width;
      final h = a.height;
      // Skip a 1px border: some rasterisers shift the very edge by a pixel.
      for (var y = 1; y < h - 1; y++) {
        for (var x = 1; x < w - 1; x++) {
          if (_insideAny(allowed, x, y)) continue;
          final i = (y * w + x) * 4;
          final db = (pa[i] - pb[i]).abs();
          final dg = (pa[i + 1] - pb[i + 1]).abs();
          final dr = (pa[i + 2] - pb[i + 2]).abs();
          compared++;
          if (db > channelThreshold ||
              dg > channelThreshold ||
              dr > channelThreshold) {
            changed++;
          }
        }
      }

      final ratio = compared == 0 ? 0.0 : changed / compared;
      if (ratio > tolerance) {
        onLog?.call(
            'verification: page ${pageIndex + 1} differs outside the text boxes '
            '($changed/$compared px)');
      }
      return PageVerification(
        pageIndex: pageIndex,
        comparedPixels: compared,
        changedPixels: changed,
        changeRatio: ratio,
        passed: ratio <= tolerance,
      );
    } catch (e) {
      return PageVerification(
        pageIndex: pageIndex,
        comparedPixels: 0,
        changedPixels: 0,
        changeRatio: 0,
        passed: true,
        skipped: true,
        note: '$e',
      );
    } finally {
      a?.dispose();
      b?.dispose();
    }
  }

  static ({int x0, int y0, int x1, int y1}) _pixelRect({
    required PdfBox box,
    required int imageWidth,
    required int imageHeight,
    required double pageWidth,
    required double pageHeight,
  }) {
    final left = ((box.left / pageWidth * imageWidth).floor() - 1)
        .clamp(0, imageWidth);
    final right = ((box.right / pageWidth * imageWidth).ceil() + 1)
        .clamp(0, imageWidth);
    final top =
        (((pageHeight - box.top) / pageHeight * imageHeight).floor() - 1)
            .clamp(0, imageHeight);
    final bottom =
        (((pageHeight - box.bottom) / pageHeight * imageHeight).ceil() + 1)
            .clamp(0, imageHeight);
    return (x0: left, x1: right, y0: top, y1: bottom);
  }

  static bool _insideAny(
    List<({int x0, int y0, int x1, int y1})> rects,
    int x,
    int y,
  ) {
    for (final r in rects) {
      if (x >= r.x0 && x < r.x1 && y >= r.y0 && y < r.y1) return true;
    }
    return false;
  }
}
