import 'data/arabic_forms.dart';

/// One shaped letter plus everything that hangs off it.
class ArabicUnit {
  const ArabicUnit({
    required this.codePoint,
    required this.sourceCodePoints,
    this.joinsBefore = false,
    this.joinsAfter = false,
  });

  /// The code point to draw (usually a presentation form).
  final int codePoint;

  /// Original code points: the base letter first, then its combining marks.
  final List<int> sourceCodePoints;

  /// True when the glyph connects to the letter drawn before it.
  final bool joinsBefore;

  /// True when the glyph connects to the letter drawn after it.

  final bool joinsAfter;

  @override
  String toString() => 'ArabicUnit(U+${codePoint.toRadixString(16)})';
}

class _Entry {
  _Entry(this.letter, this.form) : harakat = <int>[];

  int letter;
  int form; // 0 isolated, 1 initial, 2 medial, 3 final, -1 unsupported
  List<int> harakat;
}

/// Contextual shaping for Arabic: picks the right presentation form of every
/// letter, folds the classic ligatures (Lam-Alef, “Allah”, …) and keeps the
/// combining marks attached to their base letter.
///
/// The tables come from the `arabic-reshaper` project (MIT); the pass order
/// follows the same, well tested algorithm.
class ArabicShaper {
  ArabicShaper({
    this.supportLigatures = true,
    this.deleteHarakat = false,
  });

  final bool supportLigatures;
  final bool deleteHarakat;

  static const int _isolated = 0;
  static const int _initial = 1;
  static const int _medial = 2;
  static const int _final = 3;
  static const int _unsupported = -1;

  static Map<int, List<({String sequence, List<int> forms})>>? _byFirstChar;

  static Map<int, List<({String sequence, List<int> forms})>> get _ligatureIndex {
    final cached = _byFirstChar;
    if (cached != null) return cached;
    final index = <int, List<({String sequence, List<int> forms})>>{};
    for (final lig in arabicLigatures) {
      final first = lig.sequence.runes.first;
      index.putIfAbsent(first, () => <({String sequence, List<int> forms})>[]).add(lig);
    }
    for (final list in index.values) {
      list.sort((a, b) => b.sequence.length.compareTo(a.sequence.length));
    }
    return _byFirstChar = index;
  }

  static bool isArabicCodePoint(int cp) =>
      (cp >= 0x0600 && cp <= 0x06FF) ||
      (cp >= 0x0750 && cp <= 0x077F) ||
      (cp >= 0xFB50 && cp <= 0xFDFF) ||
      (cp >= 0xFE70 && cp <= 0xFEFF);

  static bool isHarakat(int cp) {
    for (var i = 0; i < arabicHarakatRanges.length; i += 2) {
      if (cp >= arabicHarakatRanges[i] && cp <= arabicHarakatRanges[i + 1]) {
        return true;
      }
    }
    return false;
  }

  /// Shapes [text] (a run of Arabic script) and returns its units in logical
  /// (input) order. Call [Bidi.resolve] afterwards to get visual order.
  List<ArabicUnit> shape(String text) {
    final entries = <_Entry>[];
    final leadingHarakat = <int>[];

    for (final cp in text.runes) {
      if (isHarakat(cp)) {
        if (deleteHarakat) continue;
        if (entries.isEmpty) {
          leadingHarakat.add(cp);
        } else {
          entries.last.harakat.add(cp);
        }
        continue;
      }
      final forms = arabicLetterForms[cp];
      if (forms == null) {
        entries.add(_Entry(cp, _unsupported));
        continue;
      }
      if (entries.isEmpty) {
        entries.add(_Entry(cp, _isolated));
        continue;
      }
      final previous = entries.last;
      if (previous.form == _unsupported || !_connectsBefore(cp)) {
        entries.add(_Entry(cp, _isolated));
        continue;
      }
      if (!_connectsAfter(previous.letter)) {
        entries.add(_Entry(cp, _isolated));
        continue;
      }
      if (previous.form == _final && !_connectsBoth(previous.letter)) {
        entries.add(_Entry(cp, _isolated));
        continue;
      }
      if (previous.form == _isolated) {
        previous.form = _initial;
        entries.add(_Entry(cp, _final));
        continue;
      }
      previous.form = _medial;
      entries.add(_Entry(cp, _final));
    }

    if (supportLigatures) {
      _applyLigatures(entries);
    }

    final units = <ArabicUnit>[];
    if (leadingHarakat.isNotEmpty && entries.isNotEmpty) {
      entries.first.harakat.insertAll(0, leadingHarakat);
    }
    for (final e in entries) {
      final forms = e.form == _unsupported ? null : arabicLetterForms[e.letter];
      var cp = e.letter;
      if (forms != null && e.form >= 0 && e.form < forms.length && forms[e.form] != 0) {
        cp = forms[e.form];
      }
      units.add(ArabicUnit(
        codePoint: cp,
        sourceCodePoints: <int>[e.letter, ...e.harakat],
        joinsBefore: _formConnectsBefore(e.form),
        joinsAfter: _formConnectsAfter(e.form),
      ));
    }
    if (units.isEmpty && leadingHarakat.isNotEmpty) {
      units.add(ArabicUnit(
        codePoint: leadingHarakat.first,
        sourceCodePoints: leadingHarakat,
      ));
    }
    return units;
  }

  /// Convenience helper: shaped text (logical order) as a plain string.
  String reshape(String text) => shape(text)
      .map((u) => String.fromCharCodes([u.codePoint, ...u.sourceCodePoints.skip(1)]))
      .join();

  void _applyLigatures(List<_Entry> entries) {
    final index = _ligatureIndex;
    var i = 0;
    while (i < entries.length) {
      final candidates = index[entries[i].letter];
      var matched = false;
      if (candidates != null) {
        for (final lig in candidates) {
          final seq = lig.sequence.runes.toList();
          if (i + seq.length > entries.length) continue;
          var ok = true;
          for (var k = 0; k < seq.length; k++) {
            if (entries[i + k].letter != seq[k] ||
                entries[i + k].form == _unsupported) {
              ok = false;
              break;
            }
          }
          if (!ok) continue;

          final aForm = entries[i].form;
          final bForm = entries[i + seq.length - 1].form;
          final int ligForm;
          if (aForm == _isolated || aForm == _initial) {
            ligForm = (bForm == _isolated || bForm == _final) ? _isolated : _initial;
          } else {
            ligForm = (bForm == _isolated || bForm == _final) ? _final : _medial;
          }
          if (ligForm >= lig.forms.length || lig.forms[ligForm] == 0) continue;

          final merged = _Entry(lig.forms[ligForm], _unsupported);
          for (var k = 0; k < seq.length; k++) {
            merged.harakat.addAll(entries[i + k].harakat);
          }
          entries[i] = merged;
          entries.removeRange(i + 1, i + seq.length);
          matched = true;
          break;
        }
      }
      if (matched) {
        i++;
      } else {
        i++;
      }
    }
  }

  static bool _connectsBefore(int letter) {
    final forms = arabicLetterForms[letter];
    if (forms == null) return false;
    return forms[_final] != 0 || forms[_medial] != 0;
  }

  static bool _connectsAfter(int letter) {
    final forms = arabicLetterForms[letter];
    if (forms == null) return false;
    return forms[_initial] != 0 || forms[_medial] != 0;
  }

  static bool _connectsBoth(int letter) {
    final forms = arabicLetterForms[letter];
    if (forms == null) return false;
    return forms[_medial] != 0;
  }

  static bool _formConnectsBefore(int form) => form == _final || form == _medial;
  static bool _formConnectsAfter(int form) => form == _initial || form == _medial;
}
