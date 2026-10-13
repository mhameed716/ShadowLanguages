import 'dart:convert';
import 'dart:typed_data';

import 'pdf_lexer.dart';
import 'pdf_object.dart';

/// Entry of the merged cross reference table.
class _XrefEntry {
  const _XrefEntry({this.offset, this.gen = 0, this.objStm, this.index});

  /// Classic entry: absolute file offset of `N 0 obj`.
  final int? offset;

  /// Object stream entry: object number of the container stream.
  final int? objStm;
  final int? index;
  final int gen;

  bool get isInObjectStream => objStm != null;
}

/// Read-only view over an existing PDF file.
///
/// Supports classic cross reference tables, xref streams, hybrid files
/// (`/XRefStm`) and arbitrarily long `/Prev` chains — everything a real book
/// produced by any tool can throw at us.
class PdfFileReader {
  PdfFileReader(this.data) {
    _load();
  }

  final Uint8List data;

  /// object number -> xref entry (newest definition wins).
  final Map<int, _XrefEntry> _xref = {};
  final Map<int, Object?> _cache = {};

  late final PdfDict trailer;
  late final int startXrefOffset;

  static final RegExp _startXref = RegExp(r'startxref\s+(\d+)');
  static final RegExp _objHeader = RegExp(r'(\d+)\s+(\d+)\s+obj');
  static final RegExp _subsection = RegExp(r'(\d+)\s+(\d+)\s*');

  void _load() {
    final start = findStartXref(data);
    startXrefOffset = start;
    PdfDict? firstTrailer;
    final queue = <int>[start];
    final seen = <int>{};
    while (queue.isNotEmpty) {
      final offset = queue.removeAt(0);
      if (offset <= 0 || offset >= data.length || !seen.add(offset)) continue;
      final section = _readXrefSection(offset);
      if (section == null) continue;
      final (tr, entries) = section;
      for (final e in entries.entries) {
        _xref.putIfAbsent(e.key, () => e.value);
      }
      firstTrailer ??= tr;
      final xrefStm = _asInt(tr['XRefStm']);
      if (xrefStm != null && xrefStm > 0) queue.insert(0, xrefStm);
      final prev = _asInt(tr['Prev']);
      if (prev != null && prev > 0) queue.add(prev);
    }
    trailer = firstTrailer ?? <String, Object?>{};
  }

  /// Locates the `startxref` offset at the end of the file.
  static int findStartXref(Uint8List data) {
    final tailLength = data.length < 8192 ? data.length : 8192;
    final tail = latin1.decode(
      Uint8List.sublistView(data, data.length - tailLength),
      allowInvalid: true,
    );
    final idx = tail.lastIndexOf('startxref');
    if (idx < 0) {
      throw const PdfParseException('startxref not found — file is not a PDF');
    }
    final m = _startXref.firstMatch(tail.substring(idx));
    if (m == null) {
      throw const PdfParseException('malformed startxref');
    }
    return int.parse(m.group(1)!);
  }

  (PdfDict, Map<int, _XrefEntry>)? _readXrefSection(int offset) {
    if (offset + 4 <= data.length &&
        data[offset] == 0x78 /* x */ &&
        data[offset + 1] == 0x72 /* r */ &&
        data[offset + 2] == 0x65 /* e */ &&
        data[offset + 3] == 0x66 /* f */) {
      return _readClassicXref(offset);
    }
    return _readXrefStream(offset);
  }

  (PdfDict, Map<int, _XrefEntry>)? _readClassicXref(int offset) {
    final head = latin1.decode(
      Uint8List.sublistView(
          data, offset, (offset + 4096).clamp(0, data.length)),
      allowInvalid: true,
    );
    final entries = <int, _XrefEntry>{};
    var cursor = 4; // skip "xref"
    while (true) {
      final ws = RegExp(r'\s*').matchAsPrefix(head, cursor);
      cursor = ws?.end ?? cursor;
      final m = _subsection.matchAsPrefix(head, cursor);
      if (m == null) break;
      final start = int.parse(m.group(1)!);
      final count = int.parse(m.group(2)!);
      cursor = m.end;
      for (var i = 0; i < count; i++) {
        if (cursor + 20 > head.length) break;
        final rec = head.substring(cursor, cursor + 20);
        cursor += 20;
        final off = int.tryParse(rec.substring(0, 10).trim());
        final gen = int.tryParse(rec.substring(11, 16).trim());
        final type = rec.substring(17, 18);
        if (type == 'n' && off != null) {
          entries.putIfAbsent(
              start + i, () => _XrefEntry(offset: off, gen: gen ?? 0));
        }
      }
      final ws2 = RegExp(r'\s*').matchAsPrefix(head, cursor);
      cursor = ws2?.end ?? cursor;
      if (cursor + 7 <= head.length &&
          head.startsWith('trailer', cursor)) {
        cursor += 7;
        break;
      }
      if (cursor + 4 <= head.length && head.startsWith('xref', cursor)) {
        break;
      }
    }
    final lexer = PdfLexer(data, offset + cursor);
    final tr = lexer.readObject();
    return (tr is Map<String, Object?> ? tr : <String, Object?>{}, entries);
  }

  (PdfDict, Map<int, _XrefEntry>)? _readXrefStream(int offset) {
    final head = latin1.decode(
      Uint8List.sublistView(
          data, offset, (offset + 1024).clamp(0, data.length)),
      allowInvalid: true,
    );
    final m = _objHeader.firstMatch(head);
    if (m == null || m.start > 64) return null;
    final lexer = PdfLexer(data, offset + m.end);
    final dict = lexer.readObject();
    if (dict is! Map<String, Object?>) return null;
    final stream = _readStreamBody(dict, lexer);
    if (stream == null) return null;
    final decoded = stream.decode();

    final wRaw = dict['W'];
    if (wRaw is! List<Object?>) return (dict, {});
    final w = wRaw.map((e) => _asInt(e) ?? 0).toList();
    final indexRaw = dict['Index'];
    final index = indexRaw is List<Object?>
        ? indexRaw.map((e) => _asInt(e) ?? 0).toList()
        : <int>[0, _asInt(dict['Size']) ?? 0];

    final entries = <int, _XrefEntry>{};
    final rowLen = w.fold<int>(0, (a, b) => a + b);
    if (rowLen <= 0) return (dict, entries);
    var pos = 0;
    for (var k = 0; k + 1 < index.length; k += 2) {
      final start = index[k];
      final count = index[k + 1];
      for (var i = 0; i < count; i++) {
        if (pos + rowLen > decoded.length) break;
        var o = 0;
        int read(int width) {
          if (width <= 0) return 1;
          var v = 0;
          for (var b = 0; b < width; b++) {
            v = (v << 8) | decoded[pos + o + b];
          }
          o += width;
          return v;
        }

        final type = w[0] == 0 ? 1 : read(w[0]);
        final f2 = read(w[1]);
        final f3 = read(w[2]);
        if (type == 1) {
          entries.putIfAbsent(start + i, () => _XrefEntry(offset: f2, gen: f3));
        } else if (type == 2) {
          entries.putIfAbsent(
              start + i, () => _XrefEntry(objStm: f2, index: f3));
        }
        pos += rowLen;
      }
    }
    return (dict, entries);
  }

  PdfStreamObject? _readStreamBody(PdfDict dict, PdfLexer lexer) {
    lexer.skipWhiteSpace();
    final head = latin1.decode(
      Uint8List.sublistView(data, lexer.pos,
          (lexer.pos + 32).clamp(0, data.length)),
      allowInvalid: true,
    );
    if (!head.startsWith('stream')) return null;
    lexer.pos += 6;
    if (lexer.pos < data.length && data[lexer.pos] == 0x0D) lexer.pos++;
    if (lexer.pos < data.length && data[lexer.pos] == 0x0A) lexer.pos++;
    var length = _resolveInt(dict['Length']) ?? 0;
    if (length <= 0) {
      final end = PdfBytes.indexOf(data, utf8.encode('endstream'), lexer.pos);
      length = end < 0 ? 0 : end - lexer.pos;
    }
    var end = lexer.pos + length;
    if (end > data.length) end = data.length;
    // Heal producers that lie about /Length: stop at the real "endstream".
    final marker = PdfBytes.indexOf(data, utf8.encode('endstream'), lexer.pos);
    if (marker >= 0 && (marker < end - 2 || end == data.length)) {
      end = marker;
      // trim a trailing EOL before the marker
      while (end > lexer.pos && (data[end - 1] == 0x0A || data[end - 1] == 0x0D)) {
        end--;
      }
    }
    return PdfStreamObject(dict, Uint8List.sublistView(data, lexer.pos, end));
  }

  int? _resolveInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is PdfRef) {
      final v = getObject(value.objNum);
      return _resolveInt(v);
    }
    return null;
  }

  static int? _asInt(Object? value) => switch (value) {
        final int i => i,
        final double d => d.toInt(),
        final num n => n.toInt(),
        _ => null,
      };

  /// Resolves an indirect object (cached).
  Object? getObject(int objNum) {
    if (_cache.containsKey(objNum)) return _cache[objNum];
    final entry = _xref[objNum];
    if (entry == null) return null;
    Object? value;
    if (entry.isInObjectStream) {
      value = _fromObjectStream(entry);
    } else {
      final offset = entry.offset;
      if (offset == null || offset <= 0 || offset >= data.length) return null;
      final head = latin1.decode(
        Uint8List.sublistView(data, offset, (offset + 64).clamp(0, data.length)),
        allowInvalid: true,
      );
      final m = _objHeader.firstMatch(head);
      if (m == null || m.start > 16) {
        // tolerate a slightly wrong offset by scanning backwards
        final from = (offset - 64).clamp(0, data.length);
        final back = latin1.decode(
          Uint8List.sublistView(data, from, (offset + 64).clamp(0, data.length)),
          allowInvalid: true,
        );
        final m2 = _objHeader.firstMatch(back);
        if (m2 == null) return null;
        value = _parseObjectAt(from + m2.end);
      } else {
        value = _parseObjectAt(offset + m.end);
      }
    }
    _cache[objNum] = value;
    return value;
  }

  Object? _fromObjectStream(_XrefEntry entry) {
    final container = getObject(entry.objStm!);
    if (container is! PdfStreamObject) return null;
    final decoded = container.decode();
    final n = _asInt(container.dict['N']) ?? 0;
    final first = _asInt(container.dict['First']) ?? 0;
    final lexer = PdfLexer(decoded);
    // header: pairs of (objNum, offset) — we only need the offset list
    var target = -1;
    for (var i = 0; i < n; i++) {
      final a = lexer.readTokenBytes();
      final b = lexer.readTokenBytes();
      if (a == null || b == null) break;
      if (i == (entry.index ?? 0)) {
        target = int.tryParse(latin1.decode(b, allowInvalid: true)) ?? -1;
        break;
      }
    }
    if (target < 0) return null;
    final objLexer = PdfLexer(decoded, first + target);
    return objLexer.readObject();
  }

  Object? _parseObjectAt(int pos) {
    final lexer = PdfLexer(data, pos);
    final value = lexer.readObject();
    if (value is Map<String, Object?>) {
      final stream = _readStreamBody(value, lexer);
      if (stream != null) return stream;
    }
    return value;
  }

  /// The document catalog.
  PdfDict get catalog {
    final root = trailer['Root'];
    if (root is PdfRef) {
      final c = getObject(root.objNum);
      if (c is Map<String, Object?>) return c;
    }
    throw const PdfParseException('document catalog not found');
  }

  /// Total number of objects known to the file (upper bound).
  int get size => _xref.isEmpty ? 0 : _xref.keys.reduce((a, b) => a > b ? a : b) + 1;

  /// Resolves a dictionary that may be an indirect reference.
  PdfDict? dictOf(Object? value) {
    final v = value is PdfRef ? getObject(value.objNum) : value;
    return v is Map<String, Object?> ? v : null;
  }

  /// Walks the page tree and returns `(ancestors, pageRef)`.
  ///
  /// [ancestors] is ordered root → direct parent; each element is
  /// `(objectNumber, dictionary)`.
  ({List<({int objNum, PdfDict dict})> ancestors, PdfRef pageRef}) pagePath(
      int pageIndex) {
    final ancestors = <({int objNum, PdfDict dict})>[];
    final rootPages = catalog['Pages'];
    if (rootPages is! PdfRef) {
      throw const PdfParseException('page tree root missing');
    }
    var nodeRef = rootPages;
    var node = dictOf(nodeRef);
    var remaining = pageIndex;
    while (node != null) {
      final kidsRefs = node['Kids'];
      if (kidsRefs is! List<Object?>) {
        throw const PdfParseException('page node without /Kids');
      }
      var descended = false;
      for (final kidRef in kidsRefs) {
        if (kidRef is! PdfRef) continue;
        final kid = dictOf(kidRef);
        if (kid == null) continue;
        final type = kid['Type'] is PdfName
            ? (kid['Type']! as PdfName).value
            : 'Page';
        if (type == 'Pages') {
          final count = _asInt(kid['Count']) ?? 1;
          if (remaining < count) {
            ancestors.add((objNum: nodeRef.objNum, dict: node));
            nodeRef = kidRef;
            node = kid;
            descended = true;
            break;
          }
          remaining -= count;
        } else {
          if (remaining == 0) {
            ancestors.add((objNum: nodeRef.objNum, dict: node));
            return (ancestors: ancestors, pageRef: kidRef);
          }
          remaining--;
        }
      }
      if (!descended) break;
    }
    throw PdfParseException('page index $pageIndex out of range');
  }

  /// Number of pages declared by the page tree.
  int get pageCount {
    final pages = dictOf(catalog['Pages']);
    return _asInt(pages?['Count']) ?? 0;
  }
}

/// Raised when the file cannot be parsed at all.
class PdfParseException implements Exception {
  const PdfParseException(this.message);

  final String message;

  @override
  String toString() => 'PdfParseException: $message';
}
