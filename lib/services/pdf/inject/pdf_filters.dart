import 'dart:io' show ZLibDecoder, ZLibEncoder;
import 'dart:typed_data';

import 'pdf_object.dart';

/// Decoders for the stream filters we can meet while walking a real-world PDF.
abstract final class PdfFilters {
  /// Applies the `/Filter` chain of [dict] to [raw].
  static Uint8List decode(Map<String, Object?> dict, Uint8List raw) {
    final filter = dict['Filter'];
    if (filter == null) return raw;

    final List<Object?> filters = filter is List<Object?> ? filter : <Object?>[filter];
    var decodeParms = dict['DecodeParms'] ?? dict['DP'];
    List<Object?> parms;
    if (decodeParms is List<Object?>) {
      parms = decodeParms;
    } else {
      parms = List<Object?>.filled(filters.length, decodeParms);
    }

    var data = raw;
    for (var i = 0; i < filters.length; i++) {
      final name = filters[i] is PdfName
          ? (filters[i]! as PdfName).value
          : filters[i].toString().replaceAll('/', '');
      final p = i < parms.length && parms[i] is Map
          ? (parms[i]! as Map).cast<String, Object?>()
          : null;
      data = switch (name) {
        'FlateDecode' || 'Fl' => flate(data, p),
        'LZWDecode' || 'LZW' => lzw(data, p),
        'ASCIIHexDecode' || 'AHx' => asciiHex(data),
        'ASCII85Decode' || 'A85' => ascii85(data),
        'RunLengthDecode' || 'RL' => runLength(data),
        _ => data, // image codecs (DCTDecode, JPXDecode, CCITTFaxDecode) are
                   // irrelevant for text: the bytes are simply left encoded.
      };
    }
    return data;
  }

  static Uint8List flate(Uint8List data, Map<String, Object?>? parms) {
    Uint8List out;
    try {
      out = inflate(data);
    } catch (_) {
      // Some producers emit broken streams: salvage whatever inflates.
      out = _lenientInflate(data);
    }
    final predictor = _int(parms?['Predictor']) ?? 1;
    if (predictor > 1) {
      final colors = _int(parms?['Colors']) ?? 1;
      final bpc = _int(parms?['BitsPerComponent']) ?? 8;
      final columns = _int(parms?['Columns']) ?? 1;
      if (predictor >= 10) {
        out = pngPrediction(out, columns, colors, bpc);
      } else if (predictor == 2) {
        out = tiffPrediction(out, columns, colors, bpc);
      }
    }
    return out;
  }

  static int? _int(Object? v) => switch (v) {
        final int i => i,
        final double d => d.toInt(),
        final num n => n.toInt(),
        _ => null,
      };

  /// Inflate a raw (zlib, no header) stream.
  static Uint8List inflate(Uint8List data) =>
      Uint8List.fromList(const ZLibDecoder(raw: true).convert(data));

  /// Saves truncated / double-compressed streams by inflating chunk by chunk.
  static Uint8List _lenientInflate(Uint8List data) {
    var offset = 0;
    while (offset < data.length && offset <= 64) {
      try {
        return inflate(Uint8List.sublistView(data, offset));
      } catch (_) {
        // drop the first byte and retry (skips a bogus header byte)
        offset++;
      }
    }
    return data;
  }

  /// PNG (sub/up/average/paeth) predictors used by xref and object streams.
  static Uint8List pngPrediction(
    Uint8List data,
    int columns,
    int colors,
    int bitsPerComponent,
  ) {
    final bpp = ((colors * bitsPerComponent) + 7) ~/ 8;
    final rowLen = (columns * colors * bitsPerComponent + 7) ~/ 8;
    if (rowLen <= 0) return data;
    final out = Uint8List((data.length ~/ (rowLen + 1)) * rowLen);
    var prev = Uint8List(rowLen);
    var pos = 0;
    var outPos = 0;
    while (pos + 1 + rowLen <= data.length && outPos + rowLen <= out.length) {
      final filterType = data[pos];
      pos++;
      final row = Uint8List(rowLen)..setRange(0, rowLen, data, pos);
      pos += rowLen;
      switch (filterType) {
        case 0:
          break;
        case 1:
          for (var i = bpp; i < rowLen; i++) {
            row[i] = (row[i] + row[i - bpp]) & 0xFF;
          }
          break;
        case 2:
          for (var i = 0; i < rowLen; i++) {
            row[i] = (row[i] + prev[i]) & 0xFF;
          }
          break;
        case 3:
          for (var i = 0; i < rowLen; i++) {
            final left = i >= bpp ? row[i - bpp] : 0;
            row[i] = (row[i] + ((left + prev[i]) >> 1)) & 0xFF;
          }
          break;
        case 4:
          for (var i = 0; i < rowLen; i++) {
            final a = i >= bpp ? row[i - bpp] : 0;
            final b = prev[i];
            final c = i >= bpp ? prev[i - bpp] : 0;
            final p = a + b - c;
            final pa = (p - a).abs();
            final pb = (p - b).abs();
            final pc = (p - c).abs();
            final int pr;
            if (pa <= pb && pa <= pc) {
              pr = a;
            } else if (pb <= pc) {
              pr = b;
            } else {
              pr = c;
            }
            row[i] = (row[i] + pr) & 0xFF;
          }
          break;
        default:
          break;
      }
      out.setRange(outPos, outPos + rowLen, row);
      outPos += rowLen;
      prev = row;
    }
    return outPos == out.length ? out : Uint8List.sublistView(out, 0, outPos);
  }

  /// TIFF predictor (predictor 2), rare but legal.
  static Uint8List tiffPrediction(
    Uint8List data,
    int columns,
    int colors,
    int bitsPerComponent,
  ) {
    if (bitsPerComponent != 8) return data;
    final bpp = colors;
    final rowLen = columns * colors;
    if (rowLen <= 0) return data;
    final out = Uint8List(data.length);
    for (var row = 0; row + rowLen <= data.length; row += rowLen) {
      var carry = 0;
      for (var i = 0; i < rowLen; i++) {
        final value = data[row + i] + (i >= bpp ? out[row + i - bpp] : 0) + carry;
        out[row + i] = value & 0xFF;
        carry = value > 255 ? 1 : 0;
      }
    }
    return out;
  }

  static Uint8List asciiHex(Uint8List data) {
    final sb = StringBuffer();
    for (final b in data) {
      final c = b;
      if (c == 0x3E /* > */) break;
      if (_isHexDigit(c)) sb.writeCharCode(c);
    }
    var hex = sb.toString();
    if (hex.length.isOdd) hex = '${hex}0';
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  static bool _isHexDigit(int c) =>
      (c >= 0x30 && c <= 0x39) ||
      (c >= 0x41 && c <= 0x46) ||
      (c >= 0x61 && c <= 0x66);

  static Uint8List ascii85(Uint8List data) {
    final out = BytesBuilder(copy: false);
    var tuple = 0;
    var count = 0;
    for (final b in data) {
      if (b == 0x7E /* ~ */) break;
      if (b >= 0x21 && b <= 0x75) {
        tuple = tuple * 85 + (b - 0x21);
        count++;
        if (count == 5) {
          out.add(Uint8List.fromList([
            (tuple >> 24) & 0xFF,
            (tuple >> 16) & 0xFF,
            (tuple >> 8) & 0xFF,
            tuple & 0xFF,
          ]));
          tuple = 0;
          count = 0;
        }
      } else if (b == 0x7A /* z */ && count == 0) {
        out.add(Uint8List(4));
      }
    }
    if (count > 1) {
      for (var i = count; i < 5; i++) {
        tuple = tuple * 85 + 84;
      }
      final bytes = <int>[];
      for (var i = 3; i >= 0; i--) {
        bytes.add((tuple >> (8 * i)) & 0xFF);
      }
      out.add(Uint8List.fromList(bytes.sublist(0, count - 1)));
    }
    return out.takeBytes();
  }

  static Uint8List runLength(Uint8List data) {
    final out = BytesBuilder(copy: false);
    var i = 0;
    while (i < data.length) {
      final len = data[i];
      i++;
      if (len == 128) break;
      if (len < 128) {
        if (i + len + 1 > data.length) break;
        out.add(Uint8List.sublistView(data, i, i + len + 1));
        i += len + 1;
      } else {
        if (i + 1 > data.length) break;
        out.add(Uint8List.filled(257 - len, data[i]));
        i++;
      }
    }
    return out.takeBytes();
  }

  /// Compresses with zlib (used when writing new content streams).
  static Uint8List deflate(Uint8List data, {int level = 9}) =>
      Uint8List.fromList(ZLibEncoder(raw: true, level: level).convert(data));
}
