import 'data/bidi_classes.dart';
import 'data/bidi_mirrored.dart';

/// Bidirectional class ids (must stay in sync with `bidi_classes.dart`).
abstract final class BidiClass {
  static const int l = 0;
  static const int r = 1;
  static const int al = 2;
  static const int en = 3;
  static const int es = 4;
  static const int et = 5;
  static const int an = 6;
  static const int cs = 7;
  static const int nsm = 8;
  static const int bn = 9;
  static const int b = 10;
  static const int s = 11;
  static const int ws = 12;
  static const int on = 13;
}

/// Internal work item of the UAX#9 resolver.
class _Item<T> {
  _Item(this.type, this.level, this.value);

  int type;
  int level;
  final T value;
}

/// Result of the bidi resolution.
class BidiResult<T> {
  const BidiResult({
    required this.visualOrder,
    required this.levels,
    required this.paragraphLevel,
  });

  /// Items in visual (display) order.
  final List<T> visualOrder;

  /// Embedding level of each item, aligned with [visualOrder].
  final List<int> levels;

  /// Paragraph embedding level: 0 = LTR, 1 = RTL.
  final int paragraphLevel;
}

/// A compact implementation of the Unicode Bidirectional Algorithm (UAX#9).
///
/// Supports the levels and rules that matter for translated book text
/// (P2/P3, X1-X9, W1-W7, N1/N2, I1/I2, L1, L2, L4). Explicit embeddings
/// (LRE/RLE/PDF) are stripped rather than honoured, which is the right call
/// for freshly generated translation output.
abstract final class Bidi {
  /// Bidi class of a single code point (defaults to L for CJK/Latin letters).
  static int typeOf(int codePoint) {
    var lo = 0;
    var hi = bidiClassRanges.length ~/ 3 - 1;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      final start = bidiClassRanges[mid * 3];
      final end = bidiClassRanges[mid * 3 + 1];
      if (codePoint < start) {
        hi = mid - 1;
      } else if (codePoint > end) {
        lo = mid + 1;
      } else {
        return bidiClassRanges[mid * 3 + 2];
      }
    }
    return BidiClass.l;
  }

  /// The mirrored counterpart of a paired punctuation mark (UAX#9 rule L4).
  static int? mirrored(int codePoint) {
    var lo = 0;
    var hi = bidiMirroredPairs.length ~/ 2 - 1;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      final value = bidiMirroredPairs[mid * 2];
      if (value == codePoint) {
        return bidiMirroredPairs[mid * 2 + 1];
      } else if (value < codePoint) {
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return null;
  }

  /// True when [text] is predominantly right-to-left.
  static bool isRtlDominant(String text) => paragraphLevelOf(text) == 1;

  /// Resolves the paragraph level (rules P2/P3) of a string.
  static int paragraphLevelOf(String text, {int? fallback}) {
    for (final rune in text.runes) {
      final t = typeOf(rune);
      if (t == BidiClass.l) return 0;
      if (t == BidiClass.r || t == BidiClass.al) return 1;
    }
    return fallback ?? 0;
  }

  /// Reorders [values] into visual order.
  ///
  /// [typeOfValue] returns the bidi class of each item; [onMirror] is called
  /// for every item that ends up at an odd (RTL) level so paired punctuation
  /// can be mirrored.
  static BidiResult<T> resolve<T>(
    List<T> values, {
    required int Function(T value) typeOfValue,
    int? paragraphLevel,
    void Function(T value)? onMirror,
  }) {
    if (values.isEmpty) {
      return BidiResult<T>(visualOrder: const [], levels: const [], paragraphLevel: 0);
    }
    final base = paragraphLevel ??
        _paragraphLevel(values.map(typeOfValue).toList(), paragraphLevel);

    final items = <_Item<T>>[];
    for (final v in values) {
      var level = base;
      final t = typeOfValue(v);
      if (t == BidiClass.l && base % 2 == 1) {
        level = base + 1;
      } else if ((t == BidiClass.r || t == BidiClass.al) && base % 2 == 0) {
        level = base + 1;
      }
      items.add(_Item<T>(t, level, v));
    }

    // X9: drop boundary neutrals (formatting controls, ZWJ, ...)
    items.removeWhere((i) => i.type == BidiClass.bn);
    if (items.isEmpty) {
      return BidiResult<T>(visualOrder: const [], levels: const [], paragraphLevel: base);
    }
    final n = items.length;

    // W1: NSM takes the type of the previous character.
    for (var i = 0; i < n; i++) {
      if (items[i].type == BidiClass.nsm) {
        items[i].type = i == 0 ? BidiClass.on : items[i - 1].type;
      }
    }

    // W2: EN becomes AN after Arabic letters.
    var prevStrong = -1;
    for (var i = 0; i < n; i++) {
      final t = items[i].type;
      if (_isStrong(t)) {
        prevStrong = t;
      } else if (t == BidiClass.en && prevStrong == BidiClass.al) {
        items[i].type = BidiClass.an;
      }
    }

    // W3: AL becomes R.
    for (var i = 0; i < n; i++) {
      if (items[i].type == BidiClass.al) items[i].type = BidiClass.r;
    }

    // W4: a single separator between two numbers joins them.
    for (var i = 1; i < n - 1; i++) {
      final t = items[i].type;
      if (t != BidiClass.es && t != BidiClass.cs) continue;
      final prev = items[i - 1].type;
      final next = items[i + 1].type;
      if (t == BidiClass.es && prev == BidiClass.en && next == BidiClass.en) {
        items[i].type = BidiClass.en;
      } else if (t == BidiClass.cs) {
        final bothNumbers = _isNumber(prev) && _isNumber(next);
        if (bothNumbers) {
          items[i].type =
              (prev == BidiClass.an || next == BidiClass.an) ? BidiClass.an : BidiClass.en;
        }
      }
    }

    // W5: an ET run touching a European number becomes EN.
    var i = 0;
    while (i < n) {
      if (items[i].type != BidiClass.et) {
        i++;
        continue;
      }
      var j = i;
      while (j < n && items[j].type == BidiClass.et) {
        j++;
      }
      final prevEn = i > 0 && items[i - 1].type == BidiClass.en;
      final nextEn = j < n && items[j].type == BidiClass.en;
      if (prevEn || nextEn) {
        for (var k = i; k < j; k++) {
          items[k].type = BidiClass.en;
        }
      }
      i = j;
    }

    // W6: remaining separators become ON.
    for (var k = 0; k < n; k++) {
      final t = items[k].type;
      if (t == BidiClass.et || t == BidiClass.es || t == BidiClass.cs) {
        items[k].type = BidiClass.on;
      }
    }

    // W7: EN becomes L when the closest preceding strong type is L.
    for (var k = 0; k < n; k++) {
      if (items[k].type != BidiClass.en) continue;
      var j = k - 1;
      while (j >= 0 && !_isStrong(items[j].type)) {
        j--;
      }
      if (j >= 0 && items[j].type == BidiClass.l) {
        items[k].type = BidiClass.l;
      }
    }

    // N1/N2: neutrals take the surrounding strong direction, else the
    // paragraph direction.
    final paragraphType = base % 2 == 1 ? BidiClass.r : BidiClass.l;
    i = 0;
    while (i < n) {
      if (!_isNeutral(items[i].type)) {
        i++;
        continue;
      }
      var j = i;
      while (j < n && _isNeutral(items[j].type)) {
        j++;
      }
      final before = i > 0 ? items[i - 1].type : null;
      final after = j < n ? items[j].type : null;
      final int resolved;
      if (before != null && after != null && before == after) {
        resolved = before;
      } else {
        resolved = paragraphType;
      }
      for (var k = i; k < j; k++) {
        items[k].type = resolved;
      }
      i = j;
    }

    // I1/I2: implicit embedding levels.
    for (var k = 0; k < n; k++) {
      final level = items[k].level;
      final t = items[k].type;
      if (level % 2 == 0) {
        if (t == BidiClass.r) {
          items[k].level = level + 1;
        } else if (t == BidiClass.an || t == BidiClass.en) {
          items[k].level = level + 2;
        }
      } else if (t == BidiClass.l || t == BidiClass.en || t == BidiClass.an) {
        items[k].level = level + 1;
      }
    }

    // L1: whitespace and separators go back to the paragraph level.
    for (var k = 0; k < n; k++) {
      final t = items[k].type;
      if (t == BidiClass.ws || t == BidiClass.b || t == BidiClass.s) {
        items[k].level = base;
      }
    }

    // L2: reverse every run, from the highest level down to level 1.
    var maxLevel = 0;
    for (final item in items) {
      if (item.level > maxLevel) maxLevel = item.level;
    }
    for (var level = maxLevel; level >= 1; level--) {
      var k = 0;
      while (k < n) {
        if (items[k].level < level) {
          k++;
          continue;
        }
        var j = k;
        while (j + 1 < n && items[j + 1].level >= level) {
          j++;
        }
        _reverse(items, k, j);
        k = j + 1;
      }
    }

    // L4: mirror paired punctuation that landed on an RTL level.
    if (onMirror != null) {
      for (final item in items) {
        if (item.level % 2 == 1) onMirror(item.value);
      }
    }

    return BidiResult<T>(
      visualOrder: items.map((e) => e.value).toList(growable: false),
      levels: items.map((e) => e.level).toList(growable: false),
      paragraphLevel: base,
    );
  }

  static int _paragraphLevel(List<int> types, int? fallback) {
    for (final t in types) {
      if (t == BidiClass.l) return 0;
      if (t == BidiClass.r || t == BidiClass.al) return 1;
    }
    return fallback ?? 0;
  }

  static bool _isStrong(int t) =>
      t == BidiClass.l || t == BidiClass.r || t == BidiClass.al;

  static bool _isNumber(int t) => t == BidiClass.en || t == BidiClass.an;

  static bool _isNeutral(int t) =>
      t == BidiClass.ws || t == BidiClass.on || t == BidiClass.b || t == BidiClass.s;

  static void _reverse(List<_Item<Object?>> items, int a, int b) {
    while (a < b) {
      final tmp = items[a];
      items[a] = items[b];
      items[b] = tmp;
      a++;
      b--;
    }
  }
}
