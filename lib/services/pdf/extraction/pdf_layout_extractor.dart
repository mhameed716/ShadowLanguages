import 'dart:math' as math;

import 'package:pdfrx/pdfrx.dart';

import '../../../data/models/book_layout.dart';
import '../../../data/models/text_block.dart';
import '../../../core/error/failure.dart';
import '../inject/pdf_geometry.dart';
import 'background_sampler.dart';

/// Reads the text layer of a PDF together with the exact coordinates of every
/// block, using PDFium through `pdfrx`.
///
/// Nothing is rasterised, resized or re-flown here — we only record where the
/// author put each paragraph so the translation can go back to the very same
/// rectangle.
class PdfLayoutExtractor {
  PdfLayoutExtractor({
    BackgroundSampler? sampler,
    this.sampleBackground = true,
  }) : _sampler = sampler ?? BackgroundSampler();

  final BackgroundSampler _sampler;
  final bool sampleBackground;

  /// Extracts the layout of every page.
  ///
  /// [onProgress] is called with (pageIndex, pageCount) as pages are analysed.
  Future<BookLayout> extract({
    required String path,
    required String name,
    String? password,
    void Function(int pageIndex, int pageCount)? onProgress,
    void Function(String message)? onLog,
  }) async {
    PdfDocument document;
    try {
      document = await PdfDocument.openFile(
        path,
        // createSimplePasswordProvider() returns the password once and then
        // null: a wrong password fails fast instead of looping forever.
        passwordProvider:
            password == null ? null : createSimplePasswordProvider(password),
        firstAttemptByEmptyPassword: password == null,
      );
    } on PdfPasswordException catch (e) {
      throw PdfShieldedException(e.message, encrypted: password == null);
    } on PdfException catch (e) {
      throw PdfParseException(e.message);
    }
    try {
      final pages = <PageLayout>[];
      final pageCount = document.pages.length;
      for (var i = 0; i < pageCount; i++) {
        final page = document.pages[i];
        final layout = await _extractPage(page, onLog: onLog);
        pages.add(layout);
        onProgress?.call(i, pageCount);
      }
      return BookLayout(
        sourcePath: path,
        sourceName: name,
        pageCount: pageCount,
        pages: pages,
        detectedLanguageCode: null,
        detectedLanguageName: null,
        detectionConfidence: 0,
      );
    } finally {
      await document.dispose();
    }
  }

  Future<PageLayout> _extractPage(
    PdfPage page, {
    void Function(String message)? onLog,
  }) async {
    final text = await page.loadStructuredText();
    final lines = _groupIntoLines(text.fragments);
    final blocks = _groupIntoBlocks(lines, pageIndex: page.pageNumber - 1);

    final boxes = blocks.map((b) => b.box).toList(growable: false);
    final colors = sampleBackground
        ? await _sampler.samplePage(page, boxes, onLog: onLog)
        : List<SampledColors>.generate(
            boxes.length,
            (_) => const SampledColors(
              background: PdfColor.white(),
              ink: PdfColor.black(),
            ),
          );

    final withColors = <TextBlock>[];
    for (var i = 0; i < blocks.length; i++) {
      withColors.add(blocks[i].copyWith(
        textColor: colors[i].ink,
        backgroundColor: colors[i].background,
      ));
    }

    return PageLayout(
      index: page.pageNumber - 1,
      width: page.width,
      height: page.height,
      rotation: _quarterTurns(page.rotation),
      blocks: withColors,
    );
  }

  static int _quarterTurns(PdfPageRotation rotation) => switch (rotation) {
        PdfPageRotation.none => 0,
        PdfPageRotation.clockwise90 => 90,
        PdfPageRotation.clockwise180 => 180,
        PdfPageRotation.clockwise270 => 270,
      };

  /// Groups fragments that share a baseline into lines.
  List<_Line> _groupIntoLines(List<PdfPageTextFragment> fragments) {
    final sorted = List<PdfPageTextFragment>.of(fragments)
      ..sort((a, b) {
        final byTop = b.bounds.top.compareTo(a.bounds.top);
        if (byTop != 0) return byTop;
        return a.bounds.left.compareTo(b.bounds.left);
      });

    final lines = <_Line>[];
    for (final fragment in sorted) {
      if (fragment.text.trim().isEmpty) continue;
      var placed = false;
      for (final line in lines) {
        if (_sameLine(line, fragment)) {
          line.fragments.add(fragment);
          placed = true;
          break;
        }
      }
      if (!placed) {
        lines.add(_Line()..fragments.add(fragment));
      }
    }
    for (final line in lines) {
      line.fragments.sort((a, b) => a.bounds.left.compareTo(b.bounds.left));
    }
    lines.sort((a, b) => b.top.compareTo(a.top)); // top-down reading order
    return lines;
  }

  bool _sameLine(_Line line, PdfPageTextFragment fragment) {
    final overlap = math.min(line.top, fragment.bounds.top) -
        math.max(line.bottom, fragment.bounds.bottom);
    final minHeight = math.min(line.height, fragment.bounds.height);
    if (minHeight <= 0) return false;
    if (overlap / minHeight > 0.45) return true;
    // very short fragments (single glyphs) snap to the closest baseline
    if (minHeight < 3) {
      return (line.centerY - fragment.bounds.center.y).abs() <
          math.max(line.height, fragment.bounds.height) * 0.6;
    }
    return false;
  }

  /// Merges consecutive lines into paragraphs / blocks.
  List<TextBlock> _groupIntoBlocks(List<_Line> lines, {required int pageIndex}) {
    final blocks = <TextBlock>[];
    _Line? current;
    final currentLines = <_Line>[];

    void flush() {
      if (currentLines.isEmpty) return;
      final block = _buildBlock(currentLines, pageIndex: pageIndex, index: blocks.length);
      if (block != null) blocks.add(block);
      currentLines.clear();
      current = null;
    }

    for (final line in lines) {
      if (current == null) {
        current = line;
        currentLines.add(line);
        continue;
      }
      final gap = current!.bottom - line.top; // vertical gap above `line`
      final tolerance = current!.height * 0.85 + 1.5;
      final overlapRatio = _horizontalOverlap(current!, line);
      final sameDirection = current!.direction == line.direction;
      final similarIndent = (current!.left - line.left).abs() <
          math.max(2.0, current!.height * 0.6);
      final similarSize = (current!.height - line.height).abs() <
          math.max(1.2, current!.height * 0.35);

      final continues = gap < tolerance &&
          overlapRatio > 0.35 &&
          sameDirection &&
          similarSize &&
          (similarIndent || overlapRatio > 0.75);
      if (continues) {
        currentLines.add(line);
        current = line;
      } else {
        flush();
        current = line;
        currentLines.add(line);
      }
    }
    flush();
    return blocks;
  }

  double _horizontalOverlap(_Line a, _Line b) {
    final overlap = math.min(a.right, b.right) - math.max(a.left, b.left);
    if (overlap <= 0) return 0;
    final minWidth = math.min(a.width, b.width);
    return minWidth <= 0 ? 0 : overlap / minWidth;
  }

  TextBlock? _buildBlock(
    List<_Line> lines, {
    required int pageIndex,
    required int index,
  }) {
    if (lines.isEmpty) return null;
    final left = lines.map((l) => l.left).reduce(math.min);
    final right = lines.map((l) => l.right).reduce(math.max);
    final top = lines.map((l) => l.top).reduce(math.max);
    final bottom = lines.map((l) => l.bottom).reduce(math.min);
    final text = lines
        .map((l) => l.text)
        .where((t) => t.trim().isNotEmpty)
        .join(' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (text.isEmpty) return null;

    final height = lines.map((l) => l.height).reduce(math.max);
    final fontSize = height / 1.18;
    final first = lines.first;
    final rtlCount = lines.where((l) => l.direction == BlockDirection.rtl).length;
    final direction = rtlCount * 2 > lines.length
        ? BlockDirection.rtl
        : (rtlCount == 0 ? BlockDirection.ltr : BlockDirection.unknown);

    // Alignment: compare how the line edges line up inside the block.
    final leftSpread = lines.map((l) => (l.left - left).abs()).reduce(math.max);
    final rightSpread = lines.map((l) => (right - l.right).abs()).reduce(math.max);
    final tolerances = math.max(1.0, fontSize * 0.4);
    final BlockAlignment alignment;
    if (lines.length == 1) {
      alignment = BlockAlignment.left;
    } else if (leftSpread <= tolerances && rightSpread <= tolerances) {
      alignment = BlockAlignment.justify;
    } else if (leftSpread <= tolerances) {
      alignment = BlockAlignment.left;
    } else if (rightSpread <= tolerances) {
      alignment = BlockAlignment.right;
    } else {
      alignment = BlockAlignment.center;
    }

    final isNumeric = RegExp(r'^[\d\s.,:/%+\-()]+$').hasMatch(text);

    return TextBlock(
      id: '${pageIndex}_$index',
      pageIndex: pageIndex,
      text: text,
      box: PdfBox.fromLTRB(left, bottom, right, top),
      fontSize: fontSize,
      baseline: first.baseline,
      direction: direction,
      alignment: alignment,
      textColor: const PdfColor.black(),
      backgroundColor: const PdfColor.white(),
      isHeading: fontSize > 14,
      isNumeric: isNumeric,
      lineCount: lines.length,
    );
  }
}

/// A visual line made of one or more PDFium fragments.
class _Line {
  final List<PdfPageTextFragment> fragments = [];

  PdfRect get bounds => fragments
      .map((f) => f.bounds)
      .reduce((a, b) => PdfRect(
            math.min(a.left, b.left),
            math.max(a.top, b.top),
            math.max(a.right, b.right),
            math.min(a.bottom, b.bottom),
          ));

  double get left => bounds.left;
  double get right => bounds.right;
  double get top => bounds.top;
  double get bottom => bounds.bottom;
  double get height => bounds.height;
  double get width => bounds.width;
  double get centerY => (top + bottom) / 2;

  /// Baseline estimate: PDFium char boxes include the descender.
  double get baseline => bottom + height * 0.19;

  BlockDirection get direction {
    var rtl = 0;
    var ltr = 0;
    for (final f in fragments) {
      switch (f.direction) {
        case PdfTextDirection.rtl:
        case PdfTextDirection.vrtl:
          rtl++;
          break;
        case PdfTextDirection.ltr:
          ltr++;
          break;
        case PdfTextDirection.unknown:
          break;
      }
    }
    if (rtl > ltr) return BlockDirection.rtl;
    if (ltr > rtl) return BlockDirection.ltr;
    return BlockDirection.unknown;
  }

  String get text => fragments.map((f) => f.text).join();
}
