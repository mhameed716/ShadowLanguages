import 'dart:convert';
import 'dart:typed_data';

import '../../pdf/shaping/data/arabic_forms.dart';

/// A minimal, dependency free SentencePiece (BPE) tokenizer.
///
/// NLLB-200 ships a `tokenizer.model` in the SentencePiece protobuf format.
/// Parsing it directly avoids bundling a second native library and lets us run
/// the exact vocabulary the model was trained with — the language codes
/// (`arb_Arab`, `eng_Latn`, …) are ordinary pieces in it.
class SentencePieceTokenizer {
  SentencePieceTokenizer._(this._pieces, this._scores, this._types, this._index);

  final List<String> _pieces;
  final Float32List _scores;
  final Int8List _types;
  final Map<String, int> _index;

  static const int _typeNormal = 1;
  static const int _typeUnknown = 2;
  static const int _typeControl = 3;
  static const int _typeUserDefined = 4;
  static const int _typeByte = 5;
  static const int _typeUnused = 6;

  int get size => _pieces.length;

  int pieceToId(String piece) => _index[piece] ?? -1;

  String idToPiece(int id) =>
      id >= 0 && id < _pieces.length ? _pieces[id] : '';

  /// Special ids the decoder needs.
  int get bosId => _index['<s>'] ?? 0;
  int get padId => _index['<pad>'] ?? 1;
  int get eosId => _index['</s>'] ?? 2;
  int get unkId => _index['<unk>'] ?? 3;

  // ------------------------------------------------------------------ parsing

  /// Parses a `.model` file.
  factory SentencePieceTokenizer(Uint8List bytes) {
    final pieces = <String>[];
    final scores = <double>[];
    final types = <int>[];

    var pos = 0;
    while (pos < bytes.length) {
      final header = _readVarint(bytes, pos);
      if (header == null) break;
      pos = header.$2;
      final fieldNumber = header.$1 >> 3;
      final wireType = header.$1 & 7;
      if (wireType != 2) break; // we only need the repeated `pieces` (field 1)
      final lengthResult = _readVarint(bytes, pos);
      if (lengthResult == null) break;
      pos = lengthResult.$2;
      final length = lengthResult.$1;
      final end = pos + length;
      if (fieldNumber == 1) {
        final piece = _parsePiece(Uint8List.sublistView(bytes, pos, end));
        pieces.add(piece.$1);
        scores.add(piece.$2);
        types.add(piece.$3);
      }
      pos = end;
    }

    if (pieces.isEmpty) {
      throw const FormatException('empty sentencepiece model');
    }
    final index = <String, int>{
      for (var i = 0; i < pieces.length; i++) pieces[i]: i,
    };
    return SentencePieceTokenizer._(
      pieces,
      Float32List.fromList(scores),
      Int8List.fromList(types),
      index,
    );
  }

  static (String, double, int) _parsePiece(Uint8List data) {
    var pos = 0;
    String piece = '';
    double score = 0;
    var type = _typeNormal;
    while (pos < data.length) {
      final header = _readVarint(data, pos);
      if (header == null) break;
      pos = header.$2;
      final field = header.$1 >> 3;
      final wire = header.$1 & 7;
      switch (wire) {
        case 0:
          final value = _readVarint(data, pos);
          if (value == null) {
            pos = data.length;
            break;
          }
          pos = value.$2;
          if (field == 3) type = value.$1;
          break;
        case 2:
          final lengthResult = _readVarint(data, pos);
          if (lengthResult == null) {
            pos = data.length;
            break;
          }
          pos = lengthResult.$2;
          final length = lengthResult.$1;
          if (field == 1) {
            piece = utf8.decode(
              Uint8List.sublistView(data, pos, pos + length),
              allowMalformed: true,
            );
          }
          pos += length;
          break;
        case 5:
          if (field == 2 && pos + 4 <= data.length) {
            score = ByteData.sublistView(data, pos, pos + 4)
                .getFloat32(0, Endian.little);
          }
          pos += 4;
          break;
        default:
          // unsupported wire type: stop decoding this piece
          pos = data.length;
      }
    }
    return (piece, score, type);
  }

  static (int, int)? _readVarint(Uint8List data, int pos) {
    var result = 0;
    var shift = 0;
    while (pos < data.length) {
      final byte = data[pos++];
      result |= (byte & 0x7F) << shift;
      if ((byte & 0x80) == 0) return (result, pos);
      shift += 7;
      if (shift > 63) return null;
    }
    return null;
  }

  // ----------------------------------------------------------------- encoding

  /// Encodes [text] into token ids (no special tokens added).
  List<int> encode(String text) {
    final out = <int>[];
    for (final word in _normalise(text).split(' ')) {
      if (word.isEmpty) continue;
      final symbol = word.startsWith(kSpaceMarker)
          ? word
          : (out.isEmpty ? kSpaceMarker : '') + word;
      final padded = out.isEmpty && !symbol.startsWith(kSpaceMarker)
          ? '$kSpaceMarker$symbol'
          : symbol;
      for (final piece in _bpe(padded)) {
        final id = _index[piece];
        if (id == null) {
          final byteId = _byteFallback(piece);
          if (byteId != null) {
            out.add(byteId);
          } else {
            out.add(unkId);
          }
        } else {
          out.add(id);
        }
      }
    }
    return out;
  }

  /// SentencePiece BPE: merge the best scoring adjacent pair, repeatedly.
  List<String> _bpe(String token) {
    if (token.isEmpty) return const [];
    if (_index.containsKey(token)) return [token];
    var symbols = token.split('');
    while (symbols.length > 1) {
      var bestScore = -1e9;
      var bestIndex = -1;
      String? bestPiece;
      for (var i = 0; i < symbols.length - 1; i++) {
        final merged = symbols[i] + symbols[i + 1];
        final id = _index[merged];
        if (id == null) continue;
        final score = _scores[id];
        if (score > bestScore) {
          bestScore = score;
          bestIndex = i;
          bestPiece = merged;
        }
      }
      if (bestIndex < 0 || bestPiece == null) break;
      symbols = [
        ...symbols.sublist(0, bestIndex),
        bestPiece,
        ...symbols.sublist(bestIndex + 2),
      ];
    }
    return symbols;
  }

  int? _byteFallback(String piece) {
    if (piece.length == 6 && piece.startsWith('<0x') && piece.endsWith('>')) {
      final value = int.tryParse(piece.substring(3, 5), radix: 16);
      if (value != null) {
        return pieceToId('<0x${value.toRadixString(16).padLeft(2, '0')}>') >= 0
            ? pieceToId('<0x${value.toRadixString(16).padLeft(2, '0')}>')
            : null;
      }
    }
    // byte fallback pieces look like `<0x41>`; when the model has them we map
    // raw bytes through them.
    final bytes = utf8.encode(piece);
    if (bytes.length == 1) {
      final id = pieceToId('<0x${bytes.first.toRadixString(16).padLeft(2, '0').toUpperCase()}>');
      if (id >= 0) return id;
    }
    return null;
  }

  /// Decodes ids back to text.
  String decode(List<int> ids, {bool skipSpecialTokens = true}) {
    final buffer = StringBuffer();
    final bytes = <int>[];
    for (final id in ids) {
      if (id < 0 || id >= _pieces.length) continue;
      final type = _types[id];
      if (skipSpecialTokens &&
          (type == _typeControl || type == _typeUnused)) {
        continue;
      }
      final piece = _pieces[id];
      if (type == _typeByte) {
        final match = RegExp(r'<0x([0-9A-Fa-f]{2})>').firstMatch(piece);
        if (match != null) {
          bytes.add(int.parse(match.group(1)!, radix: 16));
          continue;
        }
      }
      if (bytes.isNotEmpty) {
        buffer.write(_flushBytes(bytes));
      }
      buffer.write(piece.replaceAll(kSpaceMarker, ' '));
    }
    if (bytes.isNotEmpty) buffer.write(_flushBytes(bytes));
    return buffer.toString().trim();
  }

  String _flushBytes(List<int> bytes) {
    final text = utf8.decode(Uint8List.fromList(bytes), allowMalformed: true);
    bytes.clear();
    return text;
  }

  /// The space marker used by SentencePiece.
  static const String kSpaceMarker = '▁';

  // ------------------------------------------------------------- normalisation

  /// A pragmatic NFKC subset.
  ///
  /// Dart has no Unicode normaliser in the standard library, so we cover the
  /// transformations that actually matter for book text: collapsing whitespace,
  /// folding full width ASCII, folding Arabic presentation forms back to their
  /// base letters and dropping control characters.
  static String _normalise(String text) {
    final buffer = StringBuffer();
    var lastWasSpace = true; // no leading marker
    for (final rune in text.runes) {
      if (rune == 0x20 || rune == 0x09 || rune == 0x0A || rune == 0x0D) {
        if (!lastWasSpace) {
          buffer.write(' ');
          lastWasSpace = true;
        }
        continue;
      }
      lastWasSpace = false;
      if (rune < 0x20 || rune == 0x7F) continue;
      if (rune >= 0xFF01 && rune <= 0xFF5E) {
        buffer.writeCharCode(rune - 0xFEE0);
        continue;
      }
      if (rune == 0x3000) {
        buffer.writeCharCode(0x20);
        continue;
      }
      final folded = _arabicFold(rune);
      buffer.writeCharCode(folded);
    }
    return buffer.toString();
  }

  static int _arabicFold(int rune) {
    final mapping = _arabicPresentationFold;
    return mapping[rune] ?? rune;
  }

  /// `presentation form → base letter`, derived from the shaping table we
  /// already ship for the PDF writer.
  static final Map<int, int> _arabicPresentationFold = () {
    final map = <int, int>{};
    for (final entry in arabicLetterForms.entries) {
      for (final form in entry.value) {
        if (form != 0) map[form] = entry.key;
      }
    }
    for (final ligature in arabicLigatures) {
      for (final form in ligature.forms) {
        map[form] = ligature.sequence.runes.first;
      }
    }
    return map;
  }();
}
