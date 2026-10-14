import 'dart:convert';
import 'dart:typed_data';

import '../inject/pdf_geometry.dart';
import '../inject/pdf_lexer.dart';
import '../inject/pdf_object.dart';
import '../inject/pdf_reader.dart';

/// Everything a page draws that is **not** text.
///
/// We need this to answer the only question that matters for layout fidelity:
/// "would a translated line, painted inside the original box, sit on top of a
/// photo, a diagram or a table rule?" Images and vectors are collected by
/// replaying the page content stream with a matrix stack, which is exactly what
/// a PDF viewer does.
class PageGraphics {
  const PageGraphics({
    required this.pageIndex,
    required this.imageRects,
    required this.vectorRects,
    required this.shadingRects,
    this.hasFormXObjects = false,
    this.scanned = false,
  });

  final int pageIndex;

  /// Rectangles covered by image XObjects (photos, scans, logos…).
  final List<PdfBox> imageRects;

  /// Rectangles covered by vector paths (rules, table borders, fills…).
  final List<PdfBox> vectorRects;

  /// Rectangles covered by shadings / patterns (graded backgrounds…).
  final List<PdfBox> shadingRects;

  /// The page pulls in form XObjects: their content is scanned too, but nested
  /// clipping may hide part of it — worth a warning.
  final bool hasFormXObjects;

  /// The content stream could not be decoded: fall back to a conservative
  /// "assume everything is graphics" mode.
  final bool scanned;

  bool get isEmpty =>
      imageRects.isEmpty && vectorRects.isEmpty && shadingRects.isEmpty;

  /// True when [box] overlaps any graphics at least by [tolerance] of its area.
  bool overlapsGraphics(PdfBox box, {double tolerance = 0.02}) {
    for (final rect in imageRects) {
      if (_overlapRatio(box, rect) > tolerance) return true;
    }
    for (final rect in vectorRects) {
      if (_overlapRatio(box, rect) > tolerance) return true;
    }
    for (final rect in shadingRects) {
      if (_overlapRatio(box, rect) > tolerance) return true;
    }
    return false;
  }

  /// Share of [box] covered by graphics (0..1).
  double graphicsCoverage(PdfBox box) {
    var best = 0.0;
    for (final rect in imageRects) {
      final r = _overlapRatio(box, rect);
      if (r > best) best = r;
    }
    for (final rect in vectorRects) {
      final r = _overlapRatio(box, rect);
      if (r > best) best = r;
    }
    return best.clamp(0.0, 1.0);
  }

  /// Fraction of the box area that intersects [other].
  static double _overlapRatio(PdfBox box, PdfBox other) {
    final x0 = box.left > other.left ? box.left : other.left;
    final y0 = box.bottom > other.bottom ? box.bottom : other.bottom;
    final x1 = box.right < other.right ? box.right : other.right;
    final y1 = box.top < other.top ? box.top : other.top;
    final w = x1 - x0;
    final h = y1 - y0;
    if (w <= 0 || h <= 0) return 0;
    final area = box.width * box.height;
    if (area <= 0) return 0;
    return ((w * h) / area).clamp(0.0, 1.0);
  }
}

/// Replays page content streams to find where images and vectors are painted.
///
/// Only the operators that matter for collision detection are interpreted;
/// everything else is skipped. Text operators (`BT`/`Tj`) are ignored on
/// purpose — text is what we replace.
class ContentScanner {
  ContentScanner(this._reader);

  final PdfFileReader _reader;

  static const int _maxRecursion = 6;

  /// Scans one page and returns everything non-textual drawn on it.
  PageGraphics scanPage(
    int pageIndex, {
    void Function(String message)? onLog,
  }) {
    final images = <PdfBox>[];
    final vectors = <PdfBox>[];
    final shadings = <PdfBox>[];
    var formXObjects = false;
    var failed = false;

    try {
      final path = _reader.pagePath(pageIndex);
      final page = _reader.dictOf(path.pageRef);
      if (page == null) {
        return PageGraphics(
          pageIndex: pageIndex,
          imageRects: const [],
          vectorRects: const [],
          shadingRects: const [],
          scanned: true,
        );
      }

      final inherited = _collectResources(path.ancestors);
      final own = _reader.dictOf(page['Resources']);
      final resources = <String, Object?>{
        ...?inherited,
        ...?own,
      };

      final xobjects = _reader.dictOf(resources['XObject']) ?? const {};
      double width = _number(page['MediaBox']?[2]) ?? 612;
      double height = _number(page['MediaBox']?[3]) ?? 792;
      if (width <= 0 || height <= 0) {
        width = 612;
        height = 792;
      }

      for (final content in _contentStreams(page)) {
        if (content.isEmpty) continue;
        final state = _ScanState(
          baseMatrix: _Matrix.identity,
          xobjects: xobjects,
          images: images,
          vectors: vectors,
          shadings: shadings,
          pageHeight: height,
          reader: _reader,
          depth: 0,
        );
        state.run(content, onForm: () => formXObjects = true);
      }
    } catch (e) {
      failed = true;
      onLog?.call('page ${pageIndex + 1}: graphics scan failed ($e)');
    }

    return PageGraphics(
      pageIndex: pageIndex,
      imageRects: images,
      vectorRects: _merge(vectors),
      shadingRects: shadings,
      hasFormXObjects: formXObjects,
      scanned: failed,
    );
  }

  /// All content streams of a page (a single stream or an array of streams).
  List<Uint8List> _contentStreams(Map<String, Object?> page) {
    final contents = page['Contents'];
    if (contents == null) return const [];
    final out = <Uint8List>[];
    final direct = contents is PdfStreamObject ? contents : null;
    if (direct != null) {
      out.add(_decodeSafe(direct));
      return out;
    }
    final resolved = contents is PdfRef ? _reader.getObject(contents.objNum) : contents;
    if (resolved is PdfStreamObject) {
      out.add(_decodeSafe(resolved));
    } else if (resolved is List<Object?>) {
      for (final item in resolved) {
        final value = item is PdfRef ? _reader.getObject(item.objNum) : item;
        if (value is PdfStreamObject) out.add(_decodeSafe(value));
      }
    }
    return out;
  }

  Uint8List _decodeSafe(PdfStreamObject stream) {
    try {
      return stream.decode();
    } catch (_) {
      return Uint8List(0);
    }
  }

  Map<String, Object?> _collectResources(
      List<({int objNum, Map<String, Object?> dict})> ancestors) {
    final out = <String, Object?>{};
    // Inherited resources: the nearest ancestor wins, so walk root → parent.
    for (final node in ancestors) {
      final res = _reader.dictOf(node.dict['Resources']);
      if (res != null) out.addAll(res);
    }
    return out;
  }

  static double? _number(Object? value) => switch (value) {
        final num n => n.toDouble(),
        _ => null,
      };

  /// Merges overlapping vector rectangles so a table grid becomes one box.
  static List<PdfBox> _merge(List<PdfBox> boxes) {
    if (boxes.length < 24) return boxes;
    final merged = <PdfBox>[];
    for (final box in boxes) {
      var hit = false;
      for (var i = 0; i < merged.length; i++) {
        final a = merged[i];
        final ix0 = box.left > a.left ? box.left : a.left;
        final iy0 = box.bottom > a.bottom ? box.bottom : a.bottom;
        final ix1 = box.right < a.right ? box.right : a.right;
        final iy1 = box.top < a.top ? box.top : a.top;
        if (ix1 - ix0 > 0 && iy1 - iy0 > 0) {
          merged[i] = PdfBox.fromLTRB(
            a.left < box.left ? a.left : box.left,
            a.bottom < box.bottom ? a.bottom : box.bottom,
            a.right > box.right ? a.right : box.right,
            a.top > box.top ? a.top : box.top,
          );
          hit = true;
          break;
        }
      }
      if (!hit) merged.add(box);
    }
    return merged;
  }
}

/// Mutable state of one content-stream replay.
///
/// Content streams are written in postfix notation (operands first, operator
/// last), so the scanner keeps a rolling operand buffer and reacts to the
/// operators that matter for collision detection:
///
/// * `q`/`Q`  – graphics state stack (we only need the CTM),
/// * `cm`     – concatenate matrix,
/// * `Do`     – draw an XObject (image / form),
/// * `re`     – rectangle (panel fill or table cell border),
/// * `m`/`l`  – path points (rules, underlines, diagram strokes),
/// * `BI…EI`  – inline image.
class _ScanState {
  _ScanState({
    required this.baseMatrix,
    required this.xobjects,
    required this.images,
    required this.vectors,
    required this.shadings,
    required this.pageHeight,
    required this.reader,
    required this.depth,
  });

  _Matrix baseMatrix;
  final Map<String, Object?> xobjects;
  final List<PdfBox> images;
  final List<PdfBox> vectors;
  final List<PdfBox> shadings;
  final double pageHeight;
  final PdfFileReader reader;
  final int depth;

  final List<_Matrix> _stack = [];

  void run(Uint8List content, {void Function()? onForm}) {
    final lexer = PdfLexer(content);
    final numbers = <double>[];
    String? name;

    while (true) {
      final token = lexer.readTokenBytes();
      if (token == null) break;
      final text = latin1.decode(token, allowInvalid: true);

      // ---------------------------------------------------------- operands
      if (text == '/') {
        name = lexer.readNameBody();
        continue;
      }
      final number = double.tryParse(text);
      if (number != null) {
        numbers.add(number);
        continue;
      }
      if (text == '(') {
        _skipLiteralString(lexer);
        continue;
      }
      if (text == '<') {
        _skipHexString(lexer);
        continue;
      }
      if (text == '[') {
        _skipArray(lexer);
        continue;
      }
      if (text == ']' || text == '>' || text == ')' || text == '{' || text == '}') {
        continue;
      }

      // --------------------------------------------------------- operators
      switch (text) {
        case 'q':
          _stack.add(baseMatrix);
          break;
        case 'Q':
          if (_stack.isNotEmpty) baseMatrix = _stack.removeLast();
          break;
        case 'cm':
          if (numbers.length >= 6) {
            final n = numbers.sublist(numbers.length - 6);
            baseMatrix = baseMatrix
                .multiply(_Matrix(n[0], n[1], n[2], n[3], n[4], n[5]));
          }
          break;
        case 'Do':
          final target = name;
          if (target != null) _drawXObject(target, onForm: onForm);
          break;
        case 're':
          if (numbers.length >= 4) {
            final n = numbers.sublist(numbers.length - 4);
            final box = _transformRect(n[0], n[1], n[2], n[3]);
            if (!box.isEmpty) vectors.add(box);
          }
          break;
        case 'm':
        case 'l':
          if (numbers.length >= 2) {
            final n = numbers.sublist(numbers.length - 2);
            final p = baseMatrix.transform(n[0], n[1]);
            vectors.add(PdfBox(p.$1, p.$2, 0.6, 0.6));
          }
          break;
        case 'BI':
          // Inline image: record the current placement and jump to `EI`.
          images.add(_transformRect(0, 0, 1, 1));
          _skipInlineImage(lexer);
          break;
        case 'sh':
          shadings.add(_transformRect(0, 0, 1, 1));
          break;
        default:
          break; // text, colour, clipping, curves… irrelevant here
      }

      numbers.clear();
      name = null;
    }
  }

  void _drawXObject(String name, {void Function()? onForm}) {
    final object = xobjects[name];
    final resolved =
        object is PdfRef ? reader.getObject(object.objNum) : object;
    if (resolved is! PdfStreamObject) return;
    final subtype = resolved.dict['Subtype'];
    final type = subtype is PdfName ? subtype.value : '';
    final box = _transformRect(0, 0, 1, 1);

    if (type == 'Image') {
      images.add(box);
      return;
    }
    if (type == 'Form') {
      onForm?.call();
      if (depth >= ContentScanner._maxRecursion) {
        // Better a false positive than an erased picture.
        images.add(box);
        return;
      }
      final matrix = resolved.dict['Matrix'];
      _Matrix? saved;
      if (matrix is List<Object?> && matrix.length == 6) {
        final m = matrix
            .map((e) => e is num ? e.toDouble() : 0.0)
            .toList(growable: false);
        saved = baseMatrix;
        baseMatrix = baseMatrix.multiply(
          _Matrix(m[0], m[1], m[2], m[3], m[4], m[5]),
        );
      }
      final formResources = reader.dictOf(resolved.dict['Resources']);
      final childXObjects = formResources == null
          ? xobjects
          : (reader.dictOf(formResources['XObject']) ?? xobjects);
      _ScanState(
        baseMatrix: baseMatrix,
        xobjects: childXObjects,
        images: images,
        vectors: vectors,
        shadings: shadings,
        pageHeight: pageHeight,
        reader: reader,
        depth: depth + 1,
      ).run(resolved.decode(), onForm: onForm);
      if (saved != null) baseMatrix = saved;
      return;
    }
    shadings.add(box);
  }

  PdfBox _transformRect(double x, double y, double w, double h) {
    final p0 = baseMatrix.transform(x, y);
    final p1 = baseMatrix.transform(x + w, y + h);
    final left = p0.$1 < p1.$1 ? p0.$1 : p1.$1;
    final right = p0.$1 > p1.$1 ? p0.$1 : p1.$1;
    final bottom = p0.$2 < p1.$2 ? p0.$2 : p1.$2;
    final top = p0.$2 > p1.$2 ? p0.$2 : p1.$2;
    final width = (right - left).abs();
    final height = (top - bottom).abs();
    if (width < 0.2 || height < 0.2) return PdfBox.zero;
    return PdfBox(left, bottom, width, height);
  }

  static void _skipLiteralString(PdfLexer lexer) {
    var depth = 1;
    while (true) {
      final token = lexer.readTokenBytes();
      if (token == null) return;
      final text = latin1.decode(token, allowInvalid: true);
      if (text == '(') depth++;
      if (text == ')') {
        depth--;
        if (depth <= 0) return;
      }
    }
  }

  static void _skipHexString(PdfLexer lexer) {
    while (true) {
      final token = lexer.readTokenBytes();
      if (token == null) return;
      if (latin1.decode(token, allowInvalid: true) == '>') return;
    }
  }

  static void _skipArray(PdfLexer lexer) {
    var depth = 1;
    while (true) {
      final token = lexer.readTokenBytes();
      if (token == null) return;
      final text = latin1.decode(token, allowInvalid: true);
      if (text == '[') depth++;
      if (text == ']') {
        depth--;
        if (depth <= 0) return;
      }
    }
  }

  static void _skipInlineImage(PdfLexer lexer) {
    while (true) {
      final token = lexer.readTokenBytes();
      if (token == null) return;
      final text = latin1.decode(token, allowInvalid: true);
      if (text == 'EI') return;
      if (text == '<') _skipHexString(lexer);
    }
  }
}

/// A 2D affine matrix (PDF `a b c d e f`).
class _Matrix {
  const _Matrix(this.a, this.b, this.c, this.d, this.e, this.f);

  final double a, b, c, d, e, f;

  static const _Matrix identity = _Matrix(1, 0, 0, 1, 0, 0);

  _Matrix multiply(_Matrix other) => _Matrix(
        a * other.a + b * other.c,
        a * other.b + b * other.d,
        c * other.a + d * other.c,
        c * other.b + d * other.d,
        e * other.a + f * other.c + other.e,
        e * other.b + f * other.d + other.f,
      );

  (double, double) transform(double x, double y) => (
        a * x + c * y + e,
        b * x + d * y + f,
      );
}
