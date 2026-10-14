import 'dart:convert';
import 'dart:typed_data';

import 'pdf_object.dart';
import 'pdf_reader.dart';

/// Appends an **incremental update** to an existing PDF.
///
/// This is what makes ShadowLanguages lossless: every original byte — images,
/// fonts, vectors, annotations, metadata — stays exactly where it was. We only
/// append new objects at the end of the file and close with a fresh cross
/// reference section that points back at the original one through `/Prev`.
class PdfIncrementalWriter {
  PdfIncrementalWriter(this.reader) : _out = BytesBuilder(copy: false) {
    // Keep the original bytes verbatim; guarantee a newline so the first
    // appended object starts on a fresh line.
    _out.add(reader.data);
    if (reader.data.isEmpty || reader.data.last != 0x0A) {
      _out.addByte(0x0A);
    }
    _nextObjectNumber = reader.size + 1;
    if (_nextObjectNumber < 2) _nextObjectNumber = 2;
  }

  final PdfFileReader reader;
  final BytesBuilder _out;
  final Map<int, int> _offsets = {};
  late int _nextObjectNumber;

  /// Reserves [count] consecutive object numbers (they can be written later,
  /// in any order — handy when children reference their parents).
  List<PdfRef> reserve(int count) => [
        for (var i = 0; i < count; i++) PdfRef(_nextObjectNumber++),
      ];

  /// Writes an already reserved object.
  void write(PdfRef ref, String body) {
    _offsets[ref.objNum] = _out.length;
    _out.add(latin1.encode('${ref.objNum} 0 obj\n'));
    _out.add(latin1.encode(body));
    _out.add(latin1.encode('\nendobj\n'));
  }

  void writeBytes(PdfRef ref, Uint8List body) {
    _offsets[ref.objNum] = _out.length;
    _out.add(latin1.encode('${ref.objNum} 0 obj\n'));
    _out.add(body);
    _out.add(latin1.encode('\nendobj\n'));
  }

  /// Writes a stream object. [dictBody] must not contain `/Length`.
  void writeStream(PdfRef ref, String dictBody, Uint8List data) {
    final head = latin1.encode('<< $dictBody /Length ${data.length} >>\nstream\n');
    final tail = latin1.encode('\nendstream');
    final body = Uint8List(head.length + data.length + tail.length)
      ..setRange(0, head.length, head)
      ..setRange(head.length, head.length + data.length, data)
      ..setRange(head.length + data.length, head.length + data.length + tail.length,
          tail);
    writeBytes(ref, body);
  }

  /// Closes the update with a new xref table + trailer and returns the bytes.
  Uint8List finalize(PdfRef rootRef) {
    final startXref = _out.length;
    final numbers = _offsets.keys.toList()..sort();
    final groups = <List<int>>[];
    for (final n in numbers) {
      if (groups.isNotEmpty && n == groups.last[0] + groups.last[1]) {
        groups.last[1]++;
      } else {
        groups.add(<int>[n, 1]);
      }
    }
    final sb = StringBuffer('xref\n');
    for (final g in groups) {
      sb.write('${g[0]} ${g[1]}\n');
      for (var i = 0; i < g[1]; i++) {
        final offset = _offsets[g[0] + i]!;
        sb.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
      }
    }
    final prev = PdfFileReader.findStartXref(reader.data);
    sb.write('trailer\n');
    sb.write('<< /Size $_nextObjectNumber '
        '/Root ${rootRef.objNum} ${rootRef.gen} R /Prev $prev >>\n');
    sb.write('startxref\n$startXref\n%%EOF\n');
    _out.add(latin1.encode(sb.toString()));
    return _out.takeBytes();
  }
}
