import '../inject/pdf_geometry.dart';
import '../shaping/text_shaper.dart';
import 'font_resolver.dart';

/// How a translated block should sit inside the box the author left for it.
class BlockLayoutRequest {
  const BlockLayoutRequest({
    required this.box,
    required this.text,
    required this.preferredSize,
    this.minSize = 4.0,
    this.maxSize = 72.0,
    this.lineSpacing = 1.22,
    this.align = PdfTextAlign.left,
    this.vertical = PdfTextVertical.top,
    this.shrinkToFit = true,
    this.paragraphLevel,
    this.baseline,
  });

  final PdfBox box;
  final String text;
  final double preferredSize;
  final double minSize;
  final double maxSize;
  final double lineSpacing;

  final PdfTextAlign align;

  /// Where the first baseline sits: [PdfTextVertical.top] puts it one ascent
  /// below the top edge, which is what the original line did.
  final PdfTextVertical vertical;

  final bool shrinkToFit;
  final int? paragraphLevel;

  /// Explicit first baseline (PDF coordinates). Overrides [vertical].
  final double? baseline;
}

/// One laid-out line, ready to be drawn.
class LaidOutLine {
  const LaidOutLine({
    required this.size,
    required this.baseline,
    required this.left,
    required this.width,
    required this.chunks,
  });

  final double size;
  final double baseline;
  final double left;
  final double width;

  /// Groups of consecutive units sharing a font.
  final List<LineChunk> chunks;
}

/// A run of units drawn with one font.
class LineChunk {
  const LineChunk({
    required this.fontTag,
    required this.glyphIds,
    required this.codePointsPerGlyph,
    required this.offsetX,
    required this.width,
  });

  final int fontTag;
  final List<int> glyphIds;

  /// Source code points of each glyph (for /ToUnicode).
  final List<List<int>> codePointsPerGlyph;
  final double offsetX;
  final double width;
}

/// Result of fitting one translated block.
class BlockLayoutResult {
  const BlockLayoutResult({
    required this.lines,
    required this.usedSize,
    required this.fitsExactly,
    required this.overflowed,
    required this.isRightToLeft,
  });

  final List<LaidOutLine> lines;
  final double usedSize;
  final bool fitsExactly;
  final bool overflowed;
  final bool isRightToLeft;
}

/// Turns translated text into positioned, wrapped, font-switched lines that
/// fit the original block box.
class BlockLayoutEngine {
  BlockLayoutEngine({
    required FontResolver fonts,
    required TextShaper shaper,
  })  : _fonts = fonts,
        _shaper = shaper;

  final FontResolver _fonts;
  final TextShaper _shaper;

  /// Measures and wraps [request], shrinking the size when asked to.
  BlockLayoutResult layout(BlockLayoutRequest request) {
    final shaped = _shaper.shape(request.text, paragraphLevel: request.paragraphLevel);
    if (shaped.isEmpty) {
      return BlockLayoutResult(
        lines: const [],
        usedSize: request.preferredSize,
        fitsExactly: true,
        overflowed: false,
        isRightToLeft: false,
      );
    }

    final box = request.box;
    var size = request.preferredSize.clamp(request.minSize, request.maxSize);
    var lines = _wrap(shaped.units, box.width, size, request.lineSpacing);
    var needed = _heightOf(lines, size, request.lineSpacing);

    if (request.shrinkToFit && needed > box.height) {
      while (size > request.minSize && needed > box.height) {
        size = (size - 0.25).clamp(request.minSize, request.maxSize);
        lines = _wrap(shaped.units, box.width, size, request.lineSpacing);
        needed = _heightOf(lines, size, request.lineSpacing);
        if (size <= request.minSize) break;
      }
    }

    // tighten the block to the first baseline
    final firstFont = _fonts.pickForUnits(shaped.units);
    final ascent = firstFont.ascent(size).abs();
    final double firstBaseline;
    if (request.baseline != null) {
      firstBaseline = request.baseline!;
    } else if (request.vertical == PdfTextVertical.middle) {
      firstBaseline = box.centerY + needed / 2 - ascent;
    } else if (request.vertical == PdfTextVertical.bottom) {
      firstBaseline = box.bottom + needed - ascent;
    } else {
      firstBaseline = box.top - ascent;
    }

    final laidOut = <LaidOutLine>[];
    var baseline = firstBaseline;
    final step = size * request.lineSpacing;
    for (final line in lines) {
      final chunks = _chunksFor(line, size);
      final width = chunks.isEmpty ? 0.0 : chunks.last.offsetX + chunks.last.width;
      final double left;
      switch (request.align) {
        case PdfTextAlign.left:
          left = box.left;
        case PdfTextAlign.right:
          left = box.right - width;
        case PdfTextAlign.center:
          left = box.left + (box.width - width) / 2;
        case PdfTextAlign.justify:
          left = box.left;
      }
      laidOut.add(LaidOutLine(
        size: size,
        baseline: baseline,
        left: left,
        width: width,
        chunks: chunks,
      ));
      baseline -= step;
    }

    return BlockLayoutResult(
      lines: laidOut,
      usedSize: size,
      fitsExactly: needed <= box.height + 0.5,
      overflowed: needed > box.height + 0.5,
      isRightToLeft: shaped.isRightToLeft,
    );
  }

  List<List<ShapedUnit>> _wrap(
    List<ShapedUnit> units,
    double maxWidth,
    double size,
    double lineSpacing,
  ) {
    final breaker = LineBreaker(
      measureUnit: (unit, s) {
        final font = _fonts.pickFor(unit.codePoint, script: unit.script);
        return font.measureGlyph(font.glyphFor(unit.codePoint), s);
      },
      measureBreak: (s) => _fonts.defaultFont.measureGlyph(
        _fonts.defaultFont.glyphFor(0x20),
        s,
      ),
    );
    return breaker.wrap(units, maxWidth, size);
  }

  double _heightOf(List<List<ShapedUnit>> lines, double size, double lineSpacing) {
    if (lines.isEmpty) return 0;
    return lines.length * size * lineSpacing;
  }

  /// Groups a line into per-font chunks and resolves glyph ids.
  List<LineChunk> _chunksFor(List<ShapedUnit> units, double size) {
    final chunks = <LineChunk>[];
    ResolvedFont? currentFont;
    var glyphIds = <int>[];
    var codePoints = <List<int>>[];
    var offset = 0.0;
    var chunkStart = 0.0;

    void flush(double width) {
      if (glyphIds.isNotEmpty && currentFont != null) {
        chunks.add(LineChunk(
          fontTag: currentFont!.tag,
          glyphIds: List<int>.of(glyphIds),
          codePointsPerGlyph: List<List<int>>.of(codePoints),
          offsetX: chunkStart,
          width: width,
        ));
      }
      glyphIds = <int>[];
      codePoints = <List<int>>[];
      chunkStart = offset;
    }

    for (final unit in units) {
      final font = _resolveFont(unit);
      if (font == null) {
        continue; // no bundled face can draw this glyph
      }
      final glyph = font.glyphFor(unit.codePoint);
      final width = font.measureGlyph(glyph, size);
      if (currentFont != null && font.tag != currentFont!.tag) {
        flush(offset - chunkStart);
      }
      currentFont ??= font;
      if (font.tag != currentFont!.tag) {
        currentFont = font;
      }
      glyphIds.add(glyph);
      codePoints.add(unit.unicodeMapping);
      offset += width;
    }
    flush(offset - chunkStart);
    return chunks;
  }

  ResolvedFont? _resolveFont(ShapedUnit unit) {
    var font = _fonts.pickFor(unit.codePoint, script: unit.script);
    if (font.hasGlyph(unit.codePoint)) return font;
    for (final f in _fonts.fonts) {
      if (f.hasGlyph(unit.codePoint)) return f;
    }
    return null;
  }
}
