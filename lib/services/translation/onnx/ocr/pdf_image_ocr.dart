import 'dart:math' as math;

import 'package:pdfrx/pdfrx.dart';

import '../../../../core/logging/log_entry.dart';
import '../../../../core/utils/job_cancellation.dart';
import '../../../../data/models/text_block.dart';
import '../../../pdf/extraction/content_scanner.dart';
import 'ocr_types.dart';

/// Finds the text that lives **inside the pictures** of a PDF page.
///
/// A lot of books, manuals and slide decks carry their words as pixels: a
/// scanned page, an exported figure, a diagram with labels. Those words are
/// invisible to the text layer, so without this step they would survive in the
/// translation as untranslated pictures.
///
/// The extractor:
///
/// 1. asks [ContentScanner] where the images are (or notices that the whole
///    page is a scan);
/// 2. renders just that rectangle at ~200 dpi — never the whole page at 600,
///    that is how phones run out of memory;
/// 3. runs the offline OCR engine over the crop;
/// 4. maps every recognised line back into **PDF user space**, so the injector
///    can treat it like any other block and the existing overlap rules decide
///    whether the translation goes over the picture or beside it.
class PdfImageOcrExtractor {
  PdfImageOcrExtractor({
    required OcrEngine engine,
    LogBus? log,
    this.targetDpi = 200,
    this.maxMegapixels = 4,
    this.minRegionArea = 2000,
    this.minLetters = 3,
    this.skipTextCoverage = 0.45,
  })  : _engine = engine,
        _log = log;

  final OcrEngine _engine;
  final LogBus? _log;

  /// Rendering resolution. 200 dpi is the sweet spot for a phone: enough for
  /// 8 pt print, small enough for the recognizer's 48 px input.
  final double targetDpi;

  /// Hard ceiling on one render, whatever the rectangle size.
  final double maxMegapixels;

  /// Regions smaller than this (in PDF points²) are icons, not figures.
  final double minRegionArea;

  /// A crop must yield at least this many letters to be worth translating.
  final int minLetters;

  /// When the page's own text layer already covers this fraction of a region,
  /// the picture is decoration and OCR is skipped.
  final double skipTextCoverage;

  bool get isAvailable => _engine.isAvailable;

  /// Reads one page and returns the blocks found in its images.
  Future<List<OcrTextBlock>> extractPage({
    required PdfPage page,
    required PageGraphics graphics,
    required int pageIndex,
    List<TextBlock> existingBlocks = const [],
    JobCancellation? cancellation,
  }) async {
    if (!_engine.isAvailable) return const [];

    final regions = _regionsFor(page, graphics, existingBlocks);
    if (regions.isEmpty) return const [];

    final found = <OcrTextBlock>[];
    var index = 0;
    for (final region in regions) {
      cancellation?.throwIfCancelled();
      final scale = _scaleFor(page, region);
      final cropLeft = (region.left * scale).floor();
      final cropWidth =
          math.max(1, (region.width * scale).round()).clamp(1, 4096);
      // pdfrx counts y from the top; PDF user space counts from the bottom.
      final cropTop = ((page.height - region.top) * scale).floor();
      final cropHeight =
          math.max(1, (region.height * scale).round()).clamp(1, 4096);

      PdfImage? image;
      try {
        image = await page.render(
          x: math.max(0, cropLeft),
          y: math.max(0, cropTop),
          width: cropWidth,
          height: cropHeight,
          fullWidth: page.width * scale,
          fullHeight: page.height * scale,
          backgroundColor: 0xFFFFFFFF,
          annotationRenderingMode: PdfAnnotationRenderingMode.none,
        );
        final pixels = image?.pixels;
        if (pixels == null) continue;

        final grey = OcrImage.fromBgra(pixels, image!.width, image.height);
        final result = await _engine.recognize(grey);
        if (result.isEmpty) continue;

        for (final paragraph in _group(result)) {
          final box = _toUserSpace(
            page: page,
            scale: scale,
            cropLeft: math.max(0, cropLeft),
            cropTop: math.max(0, cropTop),
            rect: paragraph.rect,
          );
          final text = paragraph.text.trim();
          if (_letters(text) < minLetters) continue;
          found.add(OcrTextBlock(
            id: OcrTextBlock.idFor(pageIndex, index++),
            text: text,
            box: box,
            pageIndex: pageIndex,
            confidence: paragraph.confidence,
          ));
        }
      } catch (e) {
        _log?.warning('page ${pageIndex + 1}: OCR of a picture failed ($e)');
      } finally {
        image?.dispose();
      }
    }

    if (found.isNotEmpty) {
      _log?.success('page ${pageIndex + 1}: OCR found ${found.length} '
          'text region(s) inside ${regions.length} image(s)');
    }
    return found;
  }

  /// Which rectangles deserve a look.
  List<PdfBox> _regionsFor(
    PdfPage page,
    PageGraphics graphics,
    List<TextBlock> existing,
  ) {
    final out = <PdfBox>[];
    final pageArea = page.width * page.height;

    if (graphics.scanned) {
      // The content stream was unreadable (or there is none): treat the page
      // as one big picture, in quarters so no single render is huge.
      final halfWidth = page.width / 2;
      final halfHeight = page.height / 2;
      for (final box in [
        PdfBox(0, halfHeight, halfWidth, halfHeight),
        PdfBox(halfWidth, halfHeight, halfWidth, halfHeight),
        PdfBox(0, 0, halfWidth, halfHeight),
        PdfBox(halfWidth, 0, halfWidth, halfHeight),
      ]) {
        if (_coverage(box, existing) < skipTextCoverage) out.add(box);
      }
      return out;
    }

    for (final rect in graphics.imageRects) {
      if (rect.width <= 0 || rect.height <= 0) continue;
      if (rect.width * rect.height < minRegionArea) continue;
      // A full page background photo is usually decoration; still worth a try
      // only when the page has almost no text at all.
      final isFullPage =
          rect.width * rect.height > pageArea * 0.9 && existing.isEmpty;
      if (rect.width * rect.height > pageArea * 0.9 && !isFullPage) continue;
      if (_coverage(rect, existing) >= skipTextCoverage) continue;
      out.add(rect);
    }
    return out;
  }

  /// Fraction of [box] already covered by real text blocks.
  double _coverage(PdfBox box, List<TextBlock> blocks) {
    if (blocks.isEmpty) return 0;
    var covered = 0.0;
    for (final block in blocks) {
      final w = math.min(box.right, block.box.right) -
          math.max(box.left, block.box.left);
      final h = math.min(box.top, block.box.top) -
          math.max(box.bottom, block.box.bottom);
      if (w > 0 && h > 0) covered += w * h;
    }
    return (covered / (box.width * box.height)).clamp(0.0, 1.0);
  }

  double _scaleFor(PdfPage page, PdfBox region) {
    var scale = targetDpi / 72.0;
    final projected = (region.width * scale) * (region.height * scale);
    final limit = maxMegapixels * 1000 * 1000;
    if (projected > limit) {
      scale *= math.sqrt(limit / projected);
    }
    return scale;
  }

  /// Joins lines that sit close together into one paragraph, which gives the
  /// translator a sentence instead of half a clause.
  List<OcrLine> _group(OcrResult result) {
    final lines = [...result.lines]
      ..sort((a, b) => a.rect.top.compareTo(b.rect.top));
    if (lines.isEmpty) return const [];

    final out = <OcrLine>[];
    var buffer = StringBuffer();
    OcrRect? current;
    var confidence = 0.0;
    var count = 0;

    void flush() {
      if (current != null && buffer.isNotEmpty) {
        out.add(OcrLine(
          text: buffer.toString().trim(),
          rect: current!,
          confidence: count == 0 ? 0 : confidence / count,
        ));
      }
      buffer = StringBuffer();
      current = null;
      confidence = 0;
      count = 0;
    }

    for (final line in lines) {
      if (current == null) {
        current = line.rect;
        buffer.write(line.text);
        confidence = line.confidence;
        count = 1;
        continue;
      }
      final gap = line.rect.top - current!.bottom;
      final tolerance = current!.height * 0.7 + 2;
      if (gap <= tolerance &&
          (line.rect.left - current!.left).abs() < current!.width * 0.5) {
        buffer.write(' ');
        buffer.write(line.text);
        current = OcrRect(
          math.min(current!.left, line.rect.left),
          current!.top,
          math.max(current!.right, line.rect.right) -
              math.min(current!.left, line.rect.left),
          line.rect.bottom - current!.top,
        );
        confidence += line.confidence;
        count++;
      } else {
        flush();
        current = line.rect;
        buffer.write(line.text);
        confidence = line.confidence;
        count = 1;
      }
    }
    flush();
    return out;
  }

  /// Pixel rectangle → PDF user space box (origin bottom-left).
  ({double x, double y, double width, double height}) _toUserSpace({
    required PdfPage page,
    required double scale,
    required int cropLeft,
    required int cropTop,
    required OcrRect rect,
  }) {
    final left = (cropLeft + rect.left) / scale;
    final width = rect.width / scale;
    final height = rect.height / scale;
    final topInPage = (cropTop + rect.top) / scale;
    final bottom = page.height - topInPage - height;
    return (
      x: left.clamp(0.0, page.width),
      y: bottom.clamp(0.0, page.height),
      width: width.clamp(0.0, page.width),
      height: height.clamp(0.0, page.height),
    );
  }

  static int _letters(String text) => text
      .runes
      .where((rune) =>
          (rune >= 65 && rune <= 90) ||
          (rune >= 97 && rune <= 122) ||
          (rune >= 0x0600 && rune <= 0x06FF) ||
          (rune >= 0x0900 && rune <= 0x097F))
      .length;
}
