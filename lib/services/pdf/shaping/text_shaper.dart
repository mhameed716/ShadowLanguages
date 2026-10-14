import 'arabic_shaper.dart';
import 'bidi.dart';

/// Script buckets used to pick the right embedded font for a run.
enum TextScript { latin, arabic, other }

/// A drawable unit: one base glyph plus the combining marks that follow it.
class ShapedUnit {
  ShapedUnit({
    required this.codePoint,
    required this.sourceCodePoints,
    required this.script,
  });

  /// Code point to draw (may be a presentation form or a mirrored pair).
  int codePoint;

  /// Original code points — base first, then combining marks.
  final List<int> sourceCodePoints;

  final TextScript script;

  /// Code point used for bidi classification (the unshaped original).
  int get bidiCodePoint =>
      sourceCodePoints.isEmpty ? codePoint : sourceCodePoints.first;

  /// All code points the embedded /ToUnicode CMap must map this glyph back to.
  List<int> get unicodeMapping => sourceCodePoints;

  void mirror() {
    final m = Bidi.mirrored(codePoint);
    if (m != null) codePoint = m;
  }

  @override
  String toString() =>
      'ShapedUnit(U+${codePoint.toRadixString(16)}, ${sourceCodePoints.length} cps)';
}

/// A line of text resolved to visual (display) order.
class ShapedLine {
  const ShapedLine({
    required this.units,
    required this.paragraphLevel,
    required this.sourceText,
  });

  /// Units in visual order — draw them left to right, exactly in this order.
  final List<ShapedUnit> units;

  /// 0 = the line flows left to right, 1 = right to left.
  final int paragraphLevel;

  final String sourceText;

  bool get isRightToLeft => paragraphLevel == 1;

  bool get isEmpty => units.isEmpty;
}

/// Turns logical text into visual, drawn-ready units:
///
///   1. split the string into script runs,
///   2. shape the Arabic runs (contextual forms + ligatures),
///   3. run the bidi algorithm and mirror paired punctuation.
class TextShaper {
  TextShaper({ArabicShaper? arabicShaper, this.shapeArabic = true})
      : _arabic = arabicShaper ?? ArabicShaper();

  final ArabicShaper _arabic;
  final bool shapeArabic;

  /// Shapes a paragraph. Line breaking happens later, in the text fitter.
  ShapedLine shape(String text, {int? paragraphLevel}) {
    final units = <ShapedUnit>[];
    if (text.isEmpty) {
      return ShapedLine(
        units: units,
        paragraphLevel: paragraphLevel ?? 0,
        sourceText: text,
      );
    }
    final runes = text.runes.toList();
    var i = 0;
    while (i < runes.length) {
      final isArabicRun = _isArabicRune(runes[i]);
      var j = i;
      while (j < runes.length && _isArabicRune(runes[j]) == isArabicRun) {
        // combining marks never start a run of their own
        if (j > i && _isMark(runes[j])) break;
        j++;
      }
      final chunk = String.fromCharCodes(runes.sublist(i, j));
      units.addAll(isArabicRun && shapeArabic
          ? _shapeArabicRun(chunk)
          : _shapePlainRun(chunk));
      i = j;
    }

    final resolved = Bidi.resolve<ShapedUnit>(
      units,
      typeOfValue: (u) => Bidi.typeOf(u.bidiCodePoint),
      paragraphLevel: paragraphLevel,
      onMirror: (u) => u.mirror(),
    );

    return ShapedLine(
      units: resolved.visualOrder,
      paragraphLevel: resolved.paragraphLevel,
      sourceText: text,
    );
  }

  List<ShapedUnit> _shapeArabicRun(String chunk) {
    return _arabic.shape(chunk).map((u) {
      return ShapedUnit(
        codePoint: u.codePoint,
        sourceCodePoints: u.sourceCodePoints,
        script: TextScript.arabic,
      );
    }).toList();
  }

  List<ShapedUnit> _shapePlainRun(String chunk) {
    final units = <ShapedUnit>[];
    for (final cp in chunk.runes) {
      if (_isMark(cp) && units.isNotEmpty) {
        units.last.sourceCodePoints.add(cp);
        continue;
      }
      units.add(ShapedUnit(
        codePoint: cp,
        sourceCodePoints: <int>[cp],
        script: _scriptOf(cp),
      ));
    }
    return units;
  }

  static bool _isArabicRune(int cp) =>
      ArabicShaper.isArabicCodePoint(cp) || ArabicShaper.isHarakat(cp);

  static bool _isMark(int cp) {
    // Mn / Me / Mc, plus the Arabic harakat ranges already handled upstream.
    final cls = Bidi.typeOf(cp);
    return cls == BidiClass.nsm;
  }

  static TextScript _scriptOf(int cp) {
    if (cp < 0x0590) return TextScript.latin;
    if (ArabicShaper.isArabicCodePoint(cp)) return TextScript.arabic;
    if (cp >= 0x0590 && cp <= 0x08FF) return TextScript.arabic;
    return TextScript.other;
  }
}

/// Splits a paragraph into lines that fit [maxWidth] using the real advance
/// widths of the embedded fonts.
class LineBreaker {
  LineBreaker({required this.measureUnit, required this.measureBreak});

  /// Advance width of a single unit at [size].
  final double Function(ShapedUnit unit, double size) measureUnit;

  /// Width of the space that would be inserted between two words.
  final double Function(double size) measureBreak;

  /// Greedy word wrap: unit indices are grouped into lines.
  List<List<ShapedUnit>> wrap(List<ShapedUnit> units, double maxWidth, double size) {
    if (units.isEmpty) return const [];
    final lines = <List<ShapedUnit>>[];
    var current = <ShapedUnit>[];
    var currentWidth = 0.0;
    var pendingBreak = 0.0;

    for (final unit in units) {
      final isSpace = unit.codePoint == 0x20 || unit.codePoint == 0x00A0;
      if (isSpace && current.isEmpty) {
        pendingBreak = 0;
        continue;
      }
      final width = measureUnit(unit, size);
      if (current.isNotEmpty && currentWidth + pendingBreak + width > maxWidth) {
        lines.add(current);
        current = <ShapedUnit>[unit];
        currentWidth = width;
        pendingBreak = 0;
        continue;
      }
      if (current.isNotEmpty) {
        currentWidth += pendingBreak;
      }
      current.add(unit);
      currentWidth += width;
      pendingBreak = isSpace ? measureBreak(size) : 0;
    }
    if (current.isNotEmpty) lines.add(current);
    return lines;
  }
}

/// Small helper: finds the last break opportunity (space) in a list.
int lastSpaceIndex(List<ShapedUnit> units) =>
    units.lastIndexWhere((u) => u.codePoint == 0x20);
