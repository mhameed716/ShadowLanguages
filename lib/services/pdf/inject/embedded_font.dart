import 'dart:convert';
import 'dart:typed_data';

import 'pdf_filters.dart';
import 'pdf_object.dart';
import 'pdf_writer.dart';
import 'ttf_font.dart';

/// A TrueType face embedded in the output PDF as a CIDFontType2 with
/// `Identity-H` encoding.
///
/// Because we address glyphs directly (`/CIDToGIDMap /Identity`) we keep full
/// control over Arabic shaping: the shaper hands us presentation-form code
/// points, we translate them to glyph ids and write them straight into the
/// content stream. `/ToUnicode` guarantees the result stays searchable and
/// copy-pasteable for every reader.
class EmbeddedFont {
  EmbeddedFont(this._writer, this.font, this.name, this.tag) {
    _build();
  }

  final PdfIncrementalWriter _writer;
  final TtfFont font;
  final String name;
  final int tag;

  late final PdfRef _fileRef;
  late final PdfRef _descriptorRef;
  late final PdfRef _cidFontRef;
  late final PdfRef _toUnicodeRef;
  late final PdfRef type0Ref;

  /// glyph id -> unicode code point(s) seen so far (for the /ToUnicode CMap).
  final Map<int, List<int>> _used = {};

  /// Resource name resolved when the page is written (`/SLF1`, `/SLF1_1`, ...).
  String resourceName = '';

  double get scale => 1000.0 / font.unitsPerEm;

  void _build() {
    final raw = PdfFilters.deflate(font.bytes);
    _fileRef = _writer.reserve(1).first;
    _descriptorRef = _writer.reserve(1).first;
    _cidFontRef = _writer.reserve(1).first;
    _toUnicodeRef = _writer.reserve(1).first;
    type0Ref = _writer.reserve(1).first;

    _writer.writeStream(
      _fileRef,
      '/Filter /FlateDecode /Length1 ${font.bytes.length} /Length2 0 /Length3 0',
      raw,
    );

    final s = scale;
    final bbox = <int>[
      -1000,
      (font.descent * s).round(),
      (font.unitsPerEm * s).round(),
      (font.ascent * s).round(),
    ];
    _writer.write(
      _descriptorRef,
      '<< /Type /FontDescriptor /FontName /$_safeName /Flags 4 '
          '/FontBBox [ ${bbox.join(' ')} ] /ItalicAngle 0 '
          '/Ascent ${(font.ascent * s).round()} '
          '/Descent ${(font.descent * s).round()} '
          '/CapHeight ${(font.ascent * 0.7 * s).round()} '
          '/StemV 80 /FontFile2 ${_fileRef.objNum} 0 R >>',
    );

    _writer.write(
      _cidFontRef,
      '<< /Type /Font /Subtype /CIDFontType2 /BaseFont /$_safeName '
          '/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> '
          '/CIDToGIDMap /Identity '
          '/FontDescriptor ${_descriptorRef.objNum} 0 R '
          '/DW $_defaultWidth /W [ ${_widths()} ] >>',
    );
  }

  String get _safeName {
    final cleaned = name.replaceAll(RegExp(r'[^A-Za-z0-9+\-]'), '');
    return 'SLX$tag+${cleaned.isEmpty ? 'ShadowFont' : cleaned}';
  }

  late final int _defaultWidth = _computeDefaultWidth();

  int _computeDefaultWidth() {
    final histogram = <int, int>{};
    for (var g = 0; g < font.numGlyphs; g++) {
      final w = (font.advanceWidth(g) * scale).round();
      histogram[w] = (histogram[w] ?? 0) + 1;
    }
    var best = 0;
    var bestCount = -1;
    for (final e in histogram.entries) {
      if (e.value > bestCount) {
        bestCount = e.value;
        best = e.key;
      }
    }
    return best;
  }

  /// `/W` array: only the glyphs whose width differs from `/DW`.
  String _widths() {
    final out = StringBuffer();
    var i = 0;
    final n = font.numGlyphs;
    while (i < n) {
      final w = (font.advanceWidth(i) * scale).round();
      if (w == _defaultWidth) {
        i++;
        continue;
      }
      final start = i;
      final run = <int>[];
      while (i < n) {
        final wi = (font.advanceWidth(i) * scale).round();
        if (wi == _defaultWidth) {
          // bridges short gaps so we emit a handful of /W entries, not one per glyph
          var gap = 0;
          while (i + gap < n &&
              gap < 4 &&
              (font.advanceWidth(i + gap) * scale).round() == _defaultWidth) {
            gap++;
          }
          final beyond = i + gap;
          final resumes = beyond < n &&
              (font.advanceWidth(beyond) * scale).round() != _defaultWidth;
          if (!resumes) break;
          for (var k = 0; k < gap; k++) {
            run.add(_defaultWidth);
          }
          i += gap;
          continue;
        }
        run.add(wi);
        i++;
      }
      if (run.isNotEmpty) {
        out.write('$start [ ${run.join(' ')} ] ');
      }
    }
    return out.toString().trim();
  }

  /// Encodes [text] to glyph ids, recording the reverse mapping for /ToUnicode.
  ///
  /// [codeUnits] optionally provides the original code points when [text] is
  /// already shaped (a ligature maps to several code points).
  List<int> encode(String text, {List<int>? codeUnits}) {
    final gids = <int>[];
    final runes = text.runes.toList();
    for (var i = 0; i < runes.length; i++) {
      final gid = font.glyphFor(runes[i]);
      gids.add(gid);
      if (gid != 0) {
        final mapping = codeUnits ?? <int>[runes[i]];
        _used.putIfAbsent(gid, () => mapping);
      }
    }
    return gids;
  }

  /// Registers glyph → unicode mappings that were resolved elsewhere (the
  /// layout engine resolves glyph ids itself).
  void record(List<int> glyphIds, List<List<int>> codePointsPerGlyph) {
    for (var i = 0; i < glyphIds.length; i++) {
      final gid = glyphIds[i];
      if (gid == 0) continue;
      final cps = i < codePointsPerGlyph.length ? codePointsPerGlyph[i] : const <int>[];
      if (cps.isEmpty) continue;
      _used.putIfAbsent(gid, () => cps);
    }
  }

  /// Encodes pre-shaped runs: each element is (glyphId, sourceCodePoints).
  List<int> encodeRuns(List<({int glyph, List<int> codePoints})> runs) {
    final gids = <int>[];
    for (final r in runs) {
      gids.add(r.glyph);
      if (r.glyph != 0 && r.codePoints.isNotEmpty) {
        _used.putIfAbsent(r.glyph, () => r.codePoints);
      }
    }
    return gids;
  }

  /// Writes the /ToUnicode CMap and the Type0 font object. Must run after all
  /// text has been encoded.
  void finish() {
    final entries = StringBuffer();
    final sorted = _used.keys.toList()..sort();
    for (final gid in sorted) {
      final cps = _used[gid]!;
      final gidHex = gid.toRadixString(16).padLeft(4, '0').toUpperCase();
      if (cps.length == 1) {
        entries.writeln('<$gidHex> <${_hex(cps.first)}>');
      } else {
        entries.writeln(
            '<$gidHex> [ ${cps.map(_hex).map((h) => '<$h>').join(' ')} ]');
      }
    }
    final count = sorted.length;
    final cmap = '''/CIDInit /ProcSet findresource begin
12 dict begin
begincmap
/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
/CMapName /Adobe-Identity-UCS def
/CMapType 2 def
1 begincodespacerange
<0000> <FFFF>
endcodespacerange
$count beginbfchar
$entries
endbfchar
endcmap
CMapName currentdict /CMap defineresource pop
end
end''';
    _writer.writeStream(
        _toUnicodeRef, '', latin1.encode(cmap));
    _writer.write(
      type0Ref,
      '<< /Type /Font /Subtype /Type0 /BaseFont /$_safeName '
          '/Encoding /Identity-H '
          '/DescendantFonts [ ${_cidFontRef.objNum} 0 R ] '
          '/ToUnicode ${_toUnicodeRef.objNum} 0 R >>',
    );
  }

  static String _hex(int codePoint) =>
      codePoint.toRadixString(16).padLeft(4, '0').toUpperCase();
}
