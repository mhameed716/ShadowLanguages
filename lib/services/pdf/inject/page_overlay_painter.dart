import 'dart:convert';
import 'dart:typed_data';

import 'pdf_filters.dart';
import 'pdf_geometry.dart';

/// One chunk of a drawn line that shares a font (used for mixed scripts).
class PdfGlyphSegment {
  const PdfGlyphSegment({
    required this.fontTag,
    required this.glyphIds,
    required this.offsetX,
  });

  /// Index of the [EmbeddedFont] that owns these glyphs.
  final int fontTag;

  /// Glyph ids, in visual order.
  final List<int> glyphIds;

  /// Horizontal offset from the line origin, in points.
  final double offsetX;
}

/// Drawing primitives collected for a single page.
sealed class _DrawOp {
  const _DrawOp();
}

final class _CoverOp extends _DrawOp {
  const _CoverOp(this.box, this.color);

  final PdfBox box;
  final PdfColor color;
}

final class _TextOp extends _DrawOp {
  const _TextOp({
    required this.x,
    required this.baselineY,
    required this.size,
    required this.color,
    required this.segments,
  });

  final double x;
  final double baselineY;
  final double size;
  final PdfColor color;
  final List<PdfGlyphSegment> segments;
}

/// Collects the operations that redraw one page:
///
/// 1. a "cloak" rectangle painted with the sampled page background colour over
///    the original text box,
/// 2. the translated line, drawn at the very same baseline.
class PageOverlayPainter {
  PageOverlayPainter(this._pageIndex);

  final int _pageIndex;
  final List<_DrawOp> _ops = [];

  int get pageIndex => _pageIndex;
  int get operationCount => _ops.length;

  /// Paints over the original glyphs with the sampled page colour.
  void cover(PdfBox box, PdfColor color) {
    _ops.add(_CoverOp(box, color));
  }

  /// Draws one visual line of translated text.
  void drawLine({
    required double x,
    required double baselineY,
    required double size,
    required PdfColor color,
    required List<PdfGlyphSegment> segments,
  }) {
    if (segments.isEmpty) return;
    _ops.add(_TextOp(
      x: x,
      baselineY: baselineY,
      size: size,
      color: color,
      segments: segments,
    ));
  }

  /// Renders the operations to a PDF content stream (graphics state isolated
  /// inside `q`/`Q` so the rest of the page is untouched).
  Uint8List buildContentStream(Map<int, String> fontResourceNames) {
    final sb = StringBuffer('q\n');
    for (final op in _ops) {
      switch (op) {
        case _CoverOp(:final box, :final color):
          sb.writeln(
              '${color.operands} rg ${_n(box.left)} ${_n(box.bottom)} '
              '${_n(box.width)} ${_n(box.height)} re f');
        case _TextOp(
            :final x,
            :final baselineY,
            :final size,
            :final color,
            :final segments,
          ):
          sb.writeln('BT');
          for (final seg in segments) {
            final name = fontResourceNames[seg.fontTag];
            if (name == null || seg.glyphIds.isEmpty) continue;
            sb.writeln('/$name ${_n(size)} Tf');
            sb.writeln('${color.operands} rg');
            sb.writeln('1 0 0 1 ${_n(x + seg.offsetX)} ${_n(baselineY)} Tm');
            sb.writeln('<${_hex(seg.glyphIds)}> Tj');
          }
          sb.writeln('ET');
      }
    }
    sb.write('Q\n');
    return PdfFilters.deflate(Uint8List.fromList(latin1.encode(sb.toString())));
  }

  static String _n(double v) => v.toStringAsFixed(4);

  static String _hex(List<int> glyphIds) {
    final sb = StringBuffer();
    for (final g in glyphIds) {
      sb.write(g.toRadixString(16).padLeft(4, '0').toUpperCase());
    }
    return sb.toString();
  }
}
