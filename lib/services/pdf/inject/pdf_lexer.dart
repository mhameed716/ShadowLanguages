import 'dart:convert';
import 'dart:typed_data';

import 'pdf_object.dart';

/// A hand written PDF object lexer.
///
/// Working on raw bytes (not decoded strings) keeps us lossless: binary
/// strings, weird encodings and broken producers all survive the round trip.
class PdfLexer {
  PdfLexer(this.data, [this.pos = 0]);

  final Uint8List data;
  int pos;

  static const int _nul = 0x00;
  static const int _tab = 0x09;
  static const int _lf = 0x0A;
  static const int _ff = 0x0C;
  static const int _cr = 0x0D;
  static const int _space = 0x20;
  static const int _percent = 0x25;
  static const int _lparen = 0x28;
  static const int _rparen = 0x29;
  static const int _lt = 0x3C;
  static const int _gt = 0x3E;
  static const int _slash = 0x2F;

  bool _isWhiteSpace(int c) =>
      c == _nul || c == _tab || c == _lf || c == _ff || c == _cr || c == _space;

  bool _isDelimiter(int c) =>
      c == _lparen ||
      c == _rparen ||
      c == _lt ||
      c == _gt ||
      c == 0x5B || // [
      c == 0x5D || // ]
      c == 0x7B || // {
      c == 0x7D || // }
      c == _slash ||
      c == _percent;

  void skipWhiteSpace() {
    while (pos < data.length) {
      final c = data[pos];
      if (_isWhiteSpace(c)) {
        pos++;
      } else if (c == _percent) {
        while (pos < data.length && data[pos] != _lf && data[pos] != _cr) {
          pos++;
        }
      } else {
        return;
      }
    }
  }

  /// Reads the next raw token, advancing [pos]. Returns `null` at EOF.
  Uint8List? readTokenBytes() {
    skipWhiteSpace();
    if (pos >= data.length) return null;
    final c = data[pos];
    if (_isDelimiter(c)) {
      if (c == _lt && pos + 1 < data.length && data[pos + 1] == _lt) {
        pos += 2;
        return Uint8List.fromList([_lt, _lt]);
      }
      if (c == _gt && pos + 1 < data.length && data[pos + 1] == _gt) {
        pos += 2;
        return Uint8List.fromList([_gt, _gt]);
      }
      pos++;
      return Uint8List.fromList([c]);
    }
    final start = pos;
    while (pos < data.length &&
        !_isWhiteSpace(data[pos]) &&
        !_isDelimiter(data[pos])) {
      pos++;
    }
    return Uint8List.sublistView(data, start, pos);
  }

  /// Reads the next object from the stream.
  Object? readObject() {
    skipWhiteSpace();
    final save = pos;
    final token = readTokenBytes();
    if (token == null) return null;
    if (token.length == 2 && token[0] == _lt && token[1] == _lt) {
      return readDict();
    }
    if (token.length == 2 && token[0] == _gt && token[1] == _gt) {
      pos = save; // caller's responsibility
      return null;
    }
    if (token.length == 1) {
      switch (token[0]) {
        case 0x5B: // [
          return readArray();
        case _slash:
          return PdfName(readNameBody());
        case _lparen:
          return readLiteralString();
        case _lt:
          return readHexString();
        case _gt:
          return null;
      }
    }
    final text = latin1.decode(token, allowInvalid: true);
    switch (text) {
      case 'true':
        return true;
      case 'false':
        return false;
      case 'null':
        return null;
    }
    if (_looksNumeric(token)) {
      // `12 0 R` reference?
      final save2 = pos;
      final t2 = readTokenBytes();
      if (t2 != null && _isDigits(t2)) {
        final t3 = readTokenBytes();
        if (t3 != null && t3.length == 1 && t3[0] == 0x52 /* R */) {
          return PdfRef(int.parse(text), int.parse(latin1.decode(t2)));
        }
      }
      pos = save2;
      final n = num.tryParse(text);
      if (n == null) return PdfName(text);
      return n;
    }
    return PdfName(text);
  }

  bool _isDigits(Uint8List t) {
    for (final b in t) {
      if (b < 0x30 || b > 0x39) return false;
    }
    return t.isNotEmpty;
  }

  bool _looksNumeric(Uint8List t) {
    if (t.isEmpty) return false;
    var i = 0;
    if (t[0] == 0x2B || t[0] == 0x2D) i = 1;
    var seen = false;
    for (; i < t.length; i++) {
      final c = t[i];
      if (c >= 0x30 && c <= 0x39) {
        seen = true;
      } else if (c == 0x2E) {
        // dot
      } else {
        return false;
      }
    }
    return seen;
  }

  String readNameBody() {
    final start = pos;
    while (pos < data.length &&
        !_isWhiteSpace(data[pos]) &&
        !_isDelimiter(data[pos])) {
      pos++;
    }
    return latin1.decode(Uint8List.sublistView(data, start, pos),
        allowInvalid: true);
  }

  PdfDict readDict() {
    final dict = <String, Object?>{};
    while (true) {
      skipWhiteSpace();
      if (pos >= data.length) return dict;
      if (pos + 1 < data.length && data[pos] == _gt && data[pos + 1] == _gt) {
        pos += 2;
        return dict;
      }
      final token = readTokenBytes();
      if (token == null) return dict;
      if (!(token.length == 1 && token[0] == _slash)) {
        // Not a key: bail out gracefully instead of corrupting the walk.
        if (token.length == 2 && token[0] == _gt && token[1] == _gt) {
          return dict;
        }
        continue;
      }
      final key = readNameBody();
      dict[key] = readObject();
    }
  }

  PdfArray readArray() {
    final array = <Object?>[];
    while (true) {
      skipWhiteSpace();
      if (pos >= data.length) return array;
      if (data[pos] == 0x5D /* ] */) {
        pos++;
        return array;
      }
      final value = readObject();
      if (value == null &&
          pos < data.length &&
          data[pos] == 0x5D /* ] */) {
        pos++;
        return array;
      }
      array.add(value);
    }
  }

  Uint8List readLiteralString() {
    final out = BytesBuilder(copy: false);
    var depth = 1;
    while (pos < data.length) {
      final c = data[pos];
      if (c == 0x5C /* \ */) {
        pos++;
        if (pos >= data.length) break;
        final e = data[pos];
        switch (e) {
          case 0x6E: // n
            out.addByte(_lf);
            pos++;
          case 0x72: // r
            out.addByte(_cr);
            pos++;
          case 0x74: // t
            out.addByte(_tab);
            pos++;
          case 0x62: // b
            out.addByte(0x08);
            pos++;
          case 0x66: // f
            out.addByte(_ff);
            pos++;
          case 0x0A: // line continuation
            pos++;
          default:
            if (e >= 0x30 && e <= 0x37) {
              var oct = '';
              for (var i = 0; i < 3; i++) {
                if (pos < data.length && data[pos] >= 0x30 && data[pos] <= 0x37) {
                  oct += String.fromCharCode(data[pos]);
                  pos++;
                } else {
                  break;
                }
              }
              out.addByte(int.parse(oct, radix: 8) & 0xFF);
            } else {
              out.addByte(e);
              pos++;
            }
        }
        continue;
      }
      if (c == _lparen) depth++;
      if (c == _rparen) {
        depth--;
        if (depth == 0) {
          pos++;
          break;
        }
      }
      out.addByte(c);
      pos++;
    }
    return out.takeBytes();
  }

  Uint8List readHexString() {
    final start = pos;
    while (pos < data.length && data[pos] != _gt) {
      pos++;
    }
    final raw = latin1.decode(Uint8List.sublistView(data, start, pos));
    if (pos < data.length) pos++;
    var hex = raw.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
    if (hex.length.isOdd) hex = '${hex}0';
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}

/// Byte helpers shared by the reader.
abstract final class PdfBytes {
  /// Finds `needle` starting at [from]; returns -1 when absent.
  static int indexOf(Uint8List data, List<int> needle, int from) {
    outer:
    for (var i = from; i <= data.length - needle.length; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (data[i + j] != needle[j]) continue outer;
      }
      return i;
    }
    return -1;
  }
}
