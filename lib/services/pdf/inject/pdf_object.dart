import 'dart:typed_data';

import 'pdf_filters.dart';

/// A PDF name object (`/Type`, `/Identity-H`, ...).
class PdfName {
  const PdfName(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      other is PdfName ? other.value == value : other == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => '/$value';
}

/// An indirect reference (`12 0 R`).
class PdfRef {
  const PdfRef(this.objNum, [this.gen = 0]);

  final int objNum;
  final int gen;

  @override
  bool operator ==(Object other) =>
      other is PdfRef ? other.objNum == objNum && other.gen == gen : false;

  @override
  int get hashCode => Object.hash(objNum, gen);

  @override
  String toString() => '$objNum $gen R';
}

/// A stream object: a dictionary plus the raw (still encoded) bytes.
class PdfStreamObject {
  PdfStreamObject(this.dict, this.raw);

  final Map<String, Object?> dict;
  final Uint8List raw;

  Uint8List? _decoded;

  /// Lazily decodes the stream according to its `/Filter` chain.
  Uint8List decode() => _decoded ??= PdfFilters.decode(dict, raw);

  Object? operator [](String key) => dict[key];
}

/// Type aliases that keep the parser readable.
typedef PdfDict = Map<String, Object?>;
typedef PdfArray = List<Object?>;

/// Serialises Dart objects back to PDF syntax.
abstract final class PdfSerializer {
  static String write(Object? value) {
    if (value == null) return 'null';
    if (value is PdfRef) return value.toString();
    if (value is PdfName) return value.toString();
    if (value is bool) return value ? 'true' : 'false';
    if (value is int) return '$value';
    if (value is double) return _num(value);
    if (value is num) return _num(value.toDouble());
    if (value is String) return _string(value);
    if (value is Uint8List) return '<${_hex(value)}>';
    if (value is List<Object?>) {
      return '[ ${value.map(write).join(' ')} ]';
    }
    if (value is Map<String, Object?>) {
      return '<< ${value.entries.map((e) => '/${e.key} ${write(e.value)}').join(' ')} >>';
    }
    throw ArgumentError('Cannot serialise ${value.runtimeType} to PDF syntax');
  }

  /// Compact but never scientific-notation number formatting.
  static String _num(num value) {
    if (value is int) return '$value';
    final d = value.toDouble();
    if (d.isNaN || d.isInfinite) return '0';
    if (d == d.roundToDouble() && d.abs() < 1e15) return '${d.toInt()}';
    final s = d.toStringAsFixed(6);
    return s.contains('.')
        ? s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '')
        : s;
  }

  /// Escapes a literal PDF string.
  static String _string(String value) {
    final sb = StringBuffer('(');
    for (final unit in value.codeUnits) {
      if (unit == 0x28 || unit == 0x29 || unit == 0x5C) {
        sb.writeCharCode(0x5C);
        sb.writeCharCode(unit);
      } else if (unit < 32 || unit > 126) {
        sb.write('\\${unit.toRadixString(8).padLeft(3, '0')}');
      } else {
        sb.writeCharCode(unit);
      }
    }
    sb.write(')');
    return sb.toString();
  }

  static String _hex(Uint8List data) {
    final sb = StringBuffer();
    for (final b in data) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}
