import 'package:flutter/services.dart' show AssetBundle, rootBundle;

import '../inject/ttf_font.dart';
import '../shaping/text_shaper.dart';

/// Description of a font bundled inside the app.
class FontAssetDescriptor {
  const FontAssetDescriptor({
    required this.assetPath,
    required this.familyName,
    required this.scripts,
  });

  final String assetPath;
  final String familyName;
  final List<TextScript> scripts;

  /// Faces we ship by default (≈ 660 KB together).
  ///
  /// Latin/Greek/Cyrillic come from a subsetted Noto Sans; Arabic (including
  /// the presentation forms needed for shaping) from Noto Naskh Arabic. Any
  /// other script falls back to whichever face covers the code point.
  static const List<FontAssetDescriptor> bundled = [
    FontAssetDescriptor(
      assetPath: 'assets/fonts/pdf/NotoSans-Regular.ttf',
      familyName: 'NotoSans',
      scripts: <TextScript>[TextScript.latin, TextScript.other],
    ),
    FontAssetDescriptor(
      assetPath: 'assets/fonts/pdf/NotoNaskhArabic-Regular.ttf',
      familyName: 'NotoNaskhArabic',
      scripts: <TextScript>[TextScript.arabic],
    ),
  ];
}

/// A loaded font face: the parsed TrueType metrics used for measuring text.
///
/// The matching [EmbeddedFont] is created later, by the injection session,
/// using the same [tag].
class ResolvedFont {
  const ResolvedFont({
    required this.tag,
    required this.descriptor,
    required this.ttf,
  });

  final int tag;
  final FontAssetDescriptor descriptor;
  final TtfFont ttf;

  bool hasGlyph(int codePoint) => ttf.hasGlyph(codePoint);

  int glyphFor(int codePoint) => ttf.glyphFor(codePoint);

  double measureGlyph(int glyphId, double size) =>
      ttf.advanceWidth(glyphId) * size / ttf.unitsPerEm;

  double measureRun(List<int> glyphIds, double size) =>
      ttf.measureRun(glyphIds, size);

  double lineHeight(double size) => ttf.lineHeight(size);

  double ascent(double size) => ttf.scaledAscent(size);
}

/// Loads the bundled faces and routes every shaped unit to the face that can
/// actually draw it.
class FontResolver {
  FontResolver._(this._fonts);

  static FontResolver? _instance;

  final List<ResolvedFont> _fonts;

  List<ResolvedFont> get fonts => List.unmodifiable(_fonts);

  /// Loads (and caches) the bundled faces.
  static Future<FontResolver> load({AssetBundle? bundle}) async {
    final cached = _instance;
    if (cached != null) return cached;
    final assets = bundle ?? rootBundle;
    final resolved = <ResolvedFont>[];
    var tag = 1;
    for (final descriptor in FontAssetDescriptor.bundled) {
      final data = await assets.load(descriptor.assetPath);
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      resolved.add(ResolvedFont(
        tag: tag++,
        descriptor: descriptor,
        ttf: TtfFont(bytes),
      ));
    }
    return _instance = FontResolver._(resolved);
  }

  /// Test / preview helper: build a resolver from already parsed faces.
  factory FontResolver.fromFonts(List<ResolvedFont> fonts) =>
      FontResolver._(List<ResolvedFont>.of(fonts));

  ResolvedFont get defaultFont => _fonts.first;

  /// Picks the best font for a single code point.
  ResolvedFont pickFor(int codePoint, {TextScript? script}) {
    if (script != null) {
      for (final f in _fonts) {
        if (f.descriptor.scripts.contains(script) && f.hasGlyph(codePoint)) {
          return f;
        }
      }
    }
    for (final f in _fonts) {
      if (f.hasGlyph(codePoint)) return f;
    }
    return _fonts.first;
  }

  /// Picks the font that covers most of a line (so we switch fonts as rarely
  /// as possible while still drawing every glyph).
  ResolvedFont pickForUnits(List<ShapedUnit> units) {
    final counts = <int, ({ResolvedFont font, int count})>{};
    for (final u in units) {
      final f = pickFor(u.codePoint, script: u.script);
      final previous = counts[f.tag];
      counts[f.tag] = (font: f, count: (previous?.count ?? 0) + 1);
    }
    ResolvedFont? best;
    var bestCount = -1;
    for (final e in counts.values) {
      if (e.count > bestCount) {
        bestCount = e.count;
        best = e.font;
      }
    }
    return best ?? _fonts.first;
  }

  /// True when at least one bundled face can draw every character of [text].
  bool canRender(String text) {
    for (final rune in text.runes) {
      var ok = false;
      for (final f in _fonts) {
        if (f.hasGlyph(rune)) {
          ok = true;
          break;
        }
      }
      if (!ok) return false;
    }
    return true;
  }

  /// Fraction of [text] the bundled faces can draw (0..1).
  double coverageOf(String text) {
    final runes = text.runes.toList();
    if (runes.isEmpty) return 1;
    var covered = 0;
    for (final rune in runes) {
      for (final f in _fonts) {
        if (f.hasGlyph(rune)) {
          covered++;
          break;
        }
      }
    }
    return covered / runes.length;
  }
}
