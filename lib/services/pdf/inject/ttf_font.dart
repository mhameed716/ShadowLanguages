import 'dart:typed_data';

/// Just enough TrueType parsing to embed a font in a PDF:
/// `cmap` (unicode → glyph id), `hmtx` (advance widths) and the metrics in
/// `head` / `hhea` / `maxp`.
class TtfFont {
  TtfFont(this.bytes) {
    _read();
  }

  final Uint8List bytes;

  final Map<String, _Table> tables = {};
  late final int unitsPerEm;
  late final int numberOfHMetrics;
  late final int ascent;
  late final int descent;
  late final int lineGap;
  late final int numGlyphs;

  late final Map<int, int> _cmap;
  late final List<int> _advanceWidths;

  bool get isCff => tables.containsKey('CFF ') || tables.containsKey('CFF2');

  void _read() {
    final bd = ByteData.sublistView(bytes);
    final numTables = bd.getUint16(4);
    for (var i = 0; i < numTables; i++) {
      final off = 12 + i * 16;
      final tag = String.fromCharCodes([
        bytes[off],
        bytes[off + 1],
        bytes[off + 2],
        bytes[off + 3],
      ]);
      final tableOffset = bd.getUint32(off + 8);
      final length = bd.getUint32(off + 12);
      tables[tag] = _Table(tableOffset, length);
    }
    final head = _table('head');
    final headData = ByteData.sublistView(head);
    unitsPerEm = headData.getUint16(18);
    final hhea = ByteData.sublistView(_table('hhea'));
    ascent = hhea.getInt16(4);
    descent = hhea.getInt16(6);
    lineGap = hhea.getInt16(8);
    numberOfHMetrics = hhea.getUint16(34);
    final maxp = ByteData.sublistView(_table('maxp'));
    numGlyphs = maxp.getUint16(4);
    _cmap = _readCmap();
    _advanceWidths = _readHMtx();
  }

  Uint8List _table(String tag) {
    final t = tables[tag];
    if (t == null) {
      throw TtfException('font is missing the "$tag" table');
    }
    return Uint8List.sublistView(bytes, t.offset, t.offset + t.length);
  }

  Map<int, int> _readCmap() {
    final data = _table('cmap');
    final bd = ByteData.sublistView(data);
    final count = bd.getUint16(2);
    var bestOffset = -1;
    var bestScore = -1;
    for (var i = 0; i < count; i++) {
      final platform = bd.getUint16(4 + i * 8);
      final encoding = bd.getUint16(6 + i * 8);
      final offset = bd.getUint32(8 + i * 8);
      final score = switch ((platform, encoding)) {
        (3, 10) => 10, // UCS-4
        (0, 6) => 9,
        (0, 4) => 8,
        (0, 3) => 7,
        (3, 1) => 6, // BMP
        (0, 0) => 5,
        (0, 1) => 4,
        (0, 2) => 3,
        (1, 0) => 2,
        (3, 0) => 1,
        _ => 0,
      };
      if (score > bestScore && offset + 4 <= data.length) {
        bestScore = score;
        bestOffset = offset;
      }
    }
    if (bestOffset < 0) return const <int, int>{};
    return _readCmapSubtable(data, bestOffset);
  }

  Map<int, int> _readCmapSubtable(Uint8List data, int offset) {
    final bd = ByteData.sublistView(data);
    final format = bd.getUint16(offset);
    final map = <int, int>{};
    switch (format) {
      case 0:
        for (var c = 0; c < 256; c++) {
          final g = data[offset + 6 + c];
          if (g != 0) map[c] = g;
        }
      case 4:
        final segCountX2 = bd.getUint16(offset + 6);
        final segCount = segCountX2 ~/ 2;
        final endBase = offset + 14;
        final startBase = endBase + segCountX2 + 2;
        final deltaBase = startBase + segCountX2;
        final rangeBase = deltaBase + segCountX2;
        for (var s = 0; s < segCount; s++) {
          final end = bd.getUint16(endBase + s * 2);
          final start = bd.getUint16(startBase + s * 2);
          final delta = bd.getInt16(deltaBase + s * 2);
          final rangeOffset = bd.getUint16(rangeBase + s * 2);
          if (start == 0xFFFF) continue;
          for (var c = start; c <= (end > 0xFFFE ? 0xFFFE : end); c++) {
            if (rangeOffset == 0) {
              final g = (c + delta) & 0xFFFF;
              if (g != 0) map[c] = g;
            } else {
              final gi = rangeBase + s * 2 + rangeOffset + (c - start) * 2;
              if (gi + 2 > data.length) continue;
              final raw = bd.getUint16(gi);
              if (raw != 0) map[c] = (raw + delta) & 0xFFFF;
            }
          }
        }
      case 6:
        final first = bd.getUint16(offset + 6);
        final count = bd.getUint16(offset + 8);
        for (var i = 0; i < count; i++) {
          map[first + i] = bd.getUint16(offset + 10 + i * 2);
        }
      case 12:
        final nGroups = bd.getUint32(offset + 12);
        for (var i = 0; i < nGroups; i++) {
          final p = offset + 16 + i * 12;
          if (p + 12 > data.length) break;
          final start = bd.getUint32(p);
          var end = bd.getUint32(p + 4);
          final startGid = bd.getUint32(p + 8);
          if (end - start > 0x1FFFF) end = start + 0x1FFFF;
          for (var c = start; c <= end; c++) {
            map[c] = startGid + (c - start);
          }
        }
      default:
        throw TtfException('unsupported cmap format $format');
    }
    return map;
  }

  List<int> _readHMtx() {
    final hmtx = _table('hmtx');
    final bd = ByteData.sublistView(hmtx);
    final widths = <int>[];
    for (var g = 0; g < numGlyphs; g++) {
      final idx = g < numberOfHMetrics ? g : (numberOfHMetrics - 1).clamp(0, 1 << 30);
      final at = idx * 4;
      widths.add(at + 2 <= hmtx.length ? bd.getUint16(at) : 0);
    }
    return widths;
  }

  /// Glyph id for [codePoint] (0 = .notdef / unsupported).
  int glyphFor(int codePoint) => _cmap[codePoint] ?? 0;

  bool hasGlyph(int codePoint) => glyphFor(codePoint) != 0;

  /// Raw advance width of a glyph, in font units.
  int advanceWidth(int glyphId) =>
      glyphId >= 0 && glyphId < _advanceWidths.length ? _advanceWidths[glyphId] : 0;

  /// Advance width of a glyph run, in text space units for [size].
  double measureRun(List<int> glyphIds, double size) {
    var total = 0;
    for (final g in glyphIds) {
      total += advanceWidth(g);
    }
    return total * size / unitsPerEm;
  }

  /// How many code points of [text] this font can actually draw.
  int coverage(String text) {
    var covered = 0;
    for (final rune in text.runes) {
      if (hasGlyph(rune)) covered++;
    }
    return covered;
  }

  /// Font metrics scaled to a given text size (in points).
  double scaledAscent(double size) => ascent * size / unitsPerEm;
  double scaledDescent(double size) => descent * size / unitsPerEm;
  double lineHeight(double size) => (ascent - descent + lineGap) * size / unitsPerEm;
}

class _Table {
  const _Table(this.offset, this.length);

  final int offset;
  final int length;
}

class TtfException implements Exception {
  TtfException(this.message);

  final String message;

  @override
  String toString() => 'TtfException: $message';
}
