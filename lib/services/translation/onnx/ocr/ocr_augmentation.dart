import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pdfrx/pdfrx.dart';

import '../../../../core/utils/job_cancellation.dart';
import '../../../../data/models/book_layout.dart';
import '../../../../data/models/text_block.dart';
import '../../../pdf/extraction/content_scanner.dart';
import '../../../pdf/inject/pdf_geometry.dart';
import '../../../pdf/inject/pdf_reader.dart';
import 'ocr_types.dart';
import 'pdf_image_ocr.dart';

/// What the OCR pass added to a book.
class OcrAugmentation {
  const OcrAugmentation({
    required this.layout,
    required this.pagesScanned,
    required this.blocksFound,
    this.skipped = false,
    this.note,
  });

  /// The original layout plus one block per recognised text region. Their ids
  /// start with `ocr-`, so every later stage (translation, checkpointing,
  /// injection) treats them exactly like ordinary text.
  final BookLayout layout;

  final int pagesScanned;
  final int blocksFound;

  /// True when the pass could not run at all (no OCR model, unreadable file).
  final bool skipped;
  final String? note;

  bool get isEmpty => blocksFound == 0;
}

/// Adds the text hidden inside page images to the book map.
///
/// This is the piece that turns OCR from a demo into part of the pipeline: the
/// recognised regions become ordinary [TextBlock]s with real PDF coordinates,
/// so:
///
/// * the translation engine translates them like any paragraph;
/// * `OverlapDetector` sees that they sit **on an image** and switches them to
///   the `halo` strategy — the translation is drawn over the picture with an
///   outline instead of a filled box, so the artwork stays visible;
/// * the verifier proves afterwards that the picture itself did not change.
class OcrAugmenter {
  OcrAugmenter({
    required PdfImageOcrExtractor extractor,
    this.maxPages = -1,
    void Function(String message)? onLog,
  })  : _extractor = extractor,
        _onLog = onLog;

  final PdfImageOcrExtractor _extractor;
  final void Function(String message)? _onLog;

  /// `-1` = every page. Useful as a safety valve on very long documents.
  final int maxPages;

  Future<OcrAugmentation> augment({
    required Uint8List sourceBytes,
    required BookLayout layout,
    String? password,
    JobCancellation? cancellation,
    void Function(int pageIndex, int pageCount)? onProgress,
  }) async {
    if (!_extractor.isAvailable) {
      _onLog?.call('OCR skipped: no recognition model installed');
      return OcrAugmentation(
        layout: layout,
        pagesScanned: 0,
        blocksFound: 0,
        skipped: true,
        note: 'no OCR model',
      );
    }

    PdfDocument? document;
    var pagesScanned = 0;
    var blocksFound = 0;
    final pages = <PageLayout>[];

    try {
      document = await PdfDocument.openData(
        sourceBytes,
        passwordProvider: password == null
            ? null
            : createSimplePasswordProvider(password),
        firstAttemptByEmptyPassword: password == null,
      );
      final scanner = ContentScanner(PdfFileReader(sourceBytes));

      for (final page in layout.pages) {
        cancellation?.throwIfCancelled();
        if (maxPages >= 0 && pagesScanned >= maxPages) {
          pages.add(page);
          continue;
        }
        if (page.rotation != 0) {
          // The injector skips rotated pages; no point reading them.
          pages.add(page);
          continue;
        }

        PdfPage? pdfPage;
        try {
          pdfPage = document.pages[page.index];
        } catch (_) {
          pdfPage = null;
        }

        PageGraphics graphics;
        try {
          graphics = scanner.scanPage(page.index, onLog: _onLog);
        } catch (e) {
          _onLog?.call('page ${page.index + 1}: graphics scan failed ($e)');
          graphics = PageGraphics(
            pageIndex: page.index,
            imageRects: const [],
            vectorRects: const [],
            shadingRects: const [],
            scanned: true,
          );
        }

        var augmented = page;
        if (pdfPage != null &&
            (graphics.imageRects.isNotEmpty || graphics.scanned)) {
          final blocks = await _extractor.extractPage(
            page: pdfPage,
            graphics: graphics,
            pageIndex: page.index,
            existingBlocks: page.blocks,
            cancellation: cancellation,
          );
          if (blocks.isNotEmpty) {
            augmented = page.withExtraBlocks([
              for (final block in blocks) _toTextBlock(block, page.index),
            ]);
            blocksFound += blocks.length;
          }
          pagesScanned++;
        }
        pages.add(augmented);
        onProgress?.call(page.index, layout.pageCount);
      }
    } catch (e) {
      _onLog?.call('OCR pass aborted: $e');
      return OcrAugmentation(
        layout: layout,
        pagesScanned: pagesScanned,
        blocksFound: blocksFound,
        skipped: blocksFound == 0,
        note: '$e',
      );
    } finally {
      await document?.dispose();
    }

    if (blocksFound > 0) {
      _onLog?.call('OCR: $blocksFound text region(s) found inside images on '
          '$pagesScanned page(s)');
    } else {
      _onLog?.call('OCR: no text found inside the page images');
    }
    return OcrAugmentation(
      layout: layout.copyWith(pages: pages),
      pagesScanned: pagesScanned,
      blocksFound: blocksFound,
    );
  }

  /// Turns an OCR region into a block the injector understands.
  ///
  /// The important part is the geometry: the box is in PDF user space and
  /// covers exactly the pixels the text occupied, so `OverlapDetector` will
  /// report `onImage = true` and pick the halo strategy. The font size is
  /// estimated from the box height, and the colour is taken as black on white
  /// because we are measuring ink on a rendered page, not a text layer.
  TextBlock _toTextBlock(OcrTextBlock block, int pageIndex) {
    final box = PdfBox(block.box.x, block.box.y, block.box.width, block.box.height);
    final fontSize = (box.height * 0.72).clamp(5.0, 48.0);
    final letters = block.text.runes
        .where((rune) => rune >= 0x0590 && rune <= 0x08FF)
        .length;
    final rtl = letters * 2 > block.text.length;
    final digits = block.text.runes.where((rune) => rune >= 48 && rune <= 57).length;
    final alnum = block.text.runes
        .where((rune) =>
            (rune >= 48 && rune <= 57) ||
            (rune >= 65 && rune <= 90) ||
            (rune >= 97 && rune <= 122))
        .length;
    return TextBlock(
      id: block.id,
      pageIndex: pageIndex,
      text: block.text,
      box: box,
      fontSize: fontSize,
      baseline: box.bottom + box.height * 0.18,
      direction: rtl ? BlockDirection.rtl : BlockDirection.ltr,
      alignment: BlockAlignment.left,
      textColor: const PdfColor.black(),
      backgroundColor: const PdfColor.white(),
      isHeading: false,
      isNumeric: alnum > 0 && digits * 3 > alnum * 2,
      lineCount: math.max(1, (box.height / (fontSize * 1.25)).round()),
    );
  }
}
