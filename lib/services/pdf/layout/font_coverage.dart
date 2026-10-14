/// How well the bundled fonts can render a target language.
///
/// PDF readers do **not** apply font substitution the way a browser does: with
/// `Identity-H` / `CIDToGIDMap /Identity` the glyph id we write is the glyph the
/// reader shows. A missing glyph is therefore a visible hole (or a tofu box) in
/// the finished book — so we measure coverage *before* the job starts and
/// again, per run, while laying the text out.
class FontCoverageReport {
  const FontCoverageReport({
    required this.languageCode,
    required this.languageName,
    required this.script,
    required this.sampledCharacters,
    required this.coveredCharacters,
    required this.missingSamples,
    required this.fontsChecked,
  });

  final String languageCode;
  final String languageName;
  final String script;

  final int sampledCharacters;
  final int coveredCharacters;
  final List<String> missingSamples;
  final List<String> fontsChecked;

  double get ratio =>
      sampledCharacters == 0 ? 1 : coveredCharacters / sampledCharacters;

  bool get isComplete => missingSamples.isEmpty;

  /// Below this, the translated book would be visibly broken.
  bool get isCritical => ratio < 0.6;

  bool get isPartial => !isComplete && ratio >= 0.6;

  String describe() =>
      '$languageName: ${(ratio * 100).toStringAsFixed(0)}% of the '
      '$script alphabet is covered by ${fontsChecked.join(', ')}';
}

/// Representative alphabets used to probe a font before translating.
///
/// Deliberately small (a few dozen code points) so the check is instant, but
/// broad enough to catch the classic failure: a Latin-only face asked to render
/// Arabic, Cyrillic, Devanagari or CJK.
class ScriptSamples {
  const ScriptSamples._();

  static const Map<String, List<int>> alphabets = {
    'latin': [
      0x41, 0x42, 0x58, 0x61, 0x62, 0x78, 0xE9, 0xE8, 0xFC, 0xF1, 0xE7,
      0xDF, 0x2019, 0x201C, 0x201D, 0x2014, 0x2026,
    ],
    'cyrillic': [
      0x410, 0x411, 0x414, 0x416, 0x417, 0x418, 0x41A, 0x41B, 0x41F,
      0x420, 0x421, 0x422, 0x424, 0x426, 0x427, 0x428, 0x429, 0x42D,
      0x42E, 0x42F, 0x430, 0x431, 0x434, 0x436, 0x43A, 0x43C, 0x43D,
      0x43F, 0x440, 0x441, 0x442, 0x444, 0x446, 0x447, 0x448, 0x44F,
    ],
    'greek': [
      0x391, 0x392, 0x393, 0x394, 0x3A9, 0x3B1, 0x3B2, 0x3B3, 0x3B4,
      0x3BB, 0x3BC, 0x3C0, 0x3C3, 0x3C6, 0x3C9,
    ],
    'arabic': [
      0x0627, 0x0628, 0x062A, 0x062B, 0x062C, 0x062D, 0x062E, 0x062F,
      0x0630, 0x0631, 0x0632, 0x0633, 0x0634, 0x0635, 0x0636, 0x0637,
      0x0638, 0x0639, 0x063A, 0x0641, 0x0642, 0x0643, 0x0644, 0x0645,
      0x0646, 0x0647, 0x0648, 0x0649, 0x064A, 0x0629, 0x0621, 0x0623,
      0x0625, 0x0627, 0x0640, 0x060C, 0x061B, 0x061F, 0x0660, 0x0661,
      0x0662, 0x0663, 0x0664, 0x0665,
    ],
    'hebrew': [
      0x05D0, 0x05D1, 0x05D2, 0x05D3, 0x05D4, 0x05D5, 0x05D6, 0x05D7,
      0x05D8, 0x05D9, 0x05DB, 0x05DC, 0x05DE, 0x05E0, 0x05E1, 0x05E2,
      0x05E4, 0x05E6, 0x05E7, 0x05E8, 0x05E9, 0x05EA,
    ],
    'devanagari': [
      0x0905, 0x0906, 0x0907, 0x0908, 0x0915, 0x0916, 0x0917, 0x091C,
      0x0924, 0x0928, 0x092A, 0x092C, 0x092E, 0x092F, 0x0930, 0x0932,
      0x0935, 0x0939, 0x093F, 0x0940, 0x094D,
    ],
    'cjk': [
      0x4E00, 0x4E2D, 0x6587, 0x5B57, 0x672C, 0x8A9E, 0x5B66, 0x751F,
      0x65E5, 0x672C, 0x8A9E, 0x4E16, 0x754C, 0x4EBA, 0x53E3, 0x624B,
    ],
    'thai': [
      0x0E01, 0x0E02, 0x0E04, 0x0E07, 0x0E08, 0x0E19, 0x0E1A, 0x0E21,
      0x0E23, 0x0E25, 0x0E2A, 0x0E2D, 0x0E31, 0x0E34, 0x0E38, 0x0E41,
    ],
    'korean': [
      0xD55C, 0xAD6D, 0xC5B4, 0xC0AC, 0xB78C, 0xD559, 0xC0DD, 0xBC1F,
      0xAC00, 0xB098,
    ],
  };

  /// Which alphabet a language needs.
  ///
  /// Anything not listed falls back to Latin (the bundled Noto Sans covers
  /// Latin, Greek and Cyrillic, so most European languages are safe).
  static String forLanguage(String code) {
    final lower = code.toLowerCase();
    const arabic = {'ar', 'fa', 'ur', 'ps', 'sd', 'ku', 'ckb'};
    const cyrillic = {
      'ru', 'uk', 'be', 'bg', 'sr', 'mk', 'kk', 'ky', 'uz', 'tg', 'mn'
    };
    const greek = {'el'};
    const hebrew = {'he', 'yi'};
    const devanagari = {'hi', 'mr', 'ne', 'sa', 'bn', 'gu', 'pa', 'ta', 'te'};
    const cjk = {'zh', 'ja', 'yue', 'nan'};
    const thai = {'th', 'lo'};
    const korean = {'ko'};
    if (arabic.contains(lower)) return 'arabic';
    if (cyrillic.contains(lower)) return 'cyrillic';
    if (greek.contains(lower)) return 'greek';
    if (hebrew.contains(lower)) return 'hebrew';
    if (devanagari.contains(lower)) return 'devanagari';
    if (cjk.contains(lower)) return 'cjk';
    if (thai.contains(lower)) return 'thai';
    if (korean.contains(lower)) return 'korean';
    return 'latin';
  }

  static List<int> of(String script) =>
      alphabets[script] ?? alphabets['latin']!;
}
