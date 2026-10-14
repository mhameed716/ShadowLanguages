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
    this.halo = false,
    this.haloColor,
  });

  final double x;
  final double baselineY;
  final double size;
  final PdfColor color;
  final List<PdfGlyphSegment> segments;

  /// Draw the glyphs in "fill + stroke" mode with a contrasting outline.
  ///
  /// Used when the translation sits on top of artwork: stroking in the page
  /// colour keeps the text readable **without** erasing a single original pixel
  /// (a cover rectangle would destroy the picture underneath).
  final bool halo;

  /// Outline colour (usually the sampled page colour, or its inverse).
  final PdfColor? haloColor;
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
  ///
  /// [halo] switches the text to fill+stroke mode so it stays legible over
  /// images, gradients and tinted panels where a cover rectangle is forbidden.
  void drawLine({
    required double x,
    required double baselineY,
    required double size,
    required PdfColor color,
    required List<PdfGlyphSegment> segments,
    bool halo = false,
    PdfColor? haloColor,
  }) {
    if (segments.isEmpty) return;
    _ops.add(_TextOp(
      x: x,
      baselineY: baselineY,
      size: size,
      color: color,
      segments: segments,
      halo: halo,
      haloColor: haloColor,
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
            :final halo,
            :final haloColor,
          ):
          sb.writeln('BT');
          if (halo) {
            // 2 Tr = fill then stroke. The stroke paints a thin outline in the
            // page colour around every glyph: the artwork stays visible behind
            // the letters, the letters stay readable on top of it.
            final outline = haloColor ?? _fallbackHalo(color);
            sb.writeln('2 Tr');
            sb.writeln('${_n((size * 0.075).clamp(0.25, 1.2))} w');
            sb.writeln('1 J 1 j');
            sb.writeln('${outline.operands} RG');
          } else {
            sb.writeln('0 Tr');
          }
          for (final seg in segments) {
            final name = fontResourceNames[seg.fontTag];
            if (name == null || seg.glyphIds.isEmpty) continue;
            sb.writeln('/$name ${_n(size)} Tf');
            sb.writeln('${color.operands} rg');
            sb.writeln('1 0 0 1 ${_n(x + seg.offsetX)} ${_n(baselineY)} Tm');
            sb.writeln('<${_hex(seg.glyphIds)}> Tj');
          }
          if (halo) sb.writeln('0 Tr');
          sb.writeln('ET');
      }
    }
    sb.write('Q\n');
    return PdfFilters.deflate(Uint8List.fromList(latin1.encode(sb.toString())));
  }

  /// Outline colour used when no page colour could be sampled: the inverse of
  /// the ink, so dark text gets a light halo and light text a dark one.
  static PdfColor _fallbackHalo(PdfColor ink) =>
      ink.luminance > 0.5 ? const PdfColor.black() : const PdfColor.white();

  static String _n(double v) => v.toStringAsFixed(4);

  static String _hex(List<int> glyphIds) {
    final sb = StringBuffer();
    for (final g in glyphIds) {
      sb.write(g.toRadixString(16).padLeft(4, '0').toUpperCase());
    }
    return sb.toString();
  }
}
