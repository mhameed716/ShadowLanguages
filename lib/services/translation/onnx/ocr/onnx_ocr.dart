import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import '../onnx_backend.dart';
import 'ocr_types.dart';

/// Offline OCR built on ONNX Runtime.
///
/// The pipeline is the classic two stage one, kept small enough for a phone:
///
/// ```
/// image ─▶ Otsu binarise ─▶ row ink profile ─▶ text line bands
///                                                    │
///                        ┌───────────────────────────┘
///                        ▼
///              crop + normalise to 48px ─▶ CRNN/CTC recogniser ─▶ text
/// ```
///
/// Line finding is done with an **ink profile** instead of a detection network:
/// a DBNet costs another 7 MB and a contour walk, while the projection profile
/// is a few microseconds and handles the horizontal text that dominates books,
/// manuals and slides. Text the segmenter cannot isolate is simply skipped —
/// the page keeps its original artwork rather than gaining a wrong caption.
class OnnxOcrEngine implements OcrEngine {
  OnnxOcrEngine({
    required OnnxBackend backend,
    required OrtSession recognizer,
    required List<String> charset,
    required this.inputName,
    required this.outputName,
    this.lineHeight = 48,
    this.maxLineWidth = 640,
    this.minLineHeight = 6,
    this.minConfidence = 0.25,
  })  : _backend = backend,
        _recognizer = recognizer,
        _charset = charset;

  final OnnxBackend _backend;
  final OrtSession _recognizer;
  final List<String> _charset;

  /// Tensor names, discovered from the session.
  final String inputName;
  final String outputName;

  /// The height the recognizer was trained on.
  final int lineHeight;

  /// Longer lines are squashed to this width so the tensor stays bounded.
  final int maxLineWidth;

  /// Bands thinner than this (in source pixels) are noise, not text.
  final int minLineHeight;

  /// Lines scoring below this are dropped.
  final double minConfidence;

  /// Used when the model ships without a charset file: digits, Latin,
  /// Arabic and the punctuation that actually shows up in page images.
  static const List<String> fallbackCharset = [
    ' ', '!', '"', '#', '\$', '%', '&', "'", '(', ')', '*', '+', ',', '-', '.',
    '/', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', ':', ';', '<', '=',
    '>', '?', '@', 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L',
    'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', '[',
    ']', '^', '_', '`', 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k',
    'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z',
    '{', '|', '}', '~', '،', '؛', '؟', 'ء', 'آ', 'أ', 'ؤ', 'إ', 'ئ', 'ا', 'ب',
    'ة', 'ت', 'ث', 'ج', 'ح', 'خ', 'د', 'ذ', 'ر', 'ز', 'س', 'ش', 'ص', 'ض', 'ط',
    'ظ', 'ع', 'غ', 'ف', 'ق', 'ك', 'ل', 'م', 'ن', 'ه', 'و', 'ى', 'ي', 'ً', 'ٌ',
    'ٍ', 'َ', 'ُ', 'ِ', 'ّ', 'ْ', '٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨',
    '٩', 'پ', 'چ', 'ژ', 'ک', 'گ', 'ی',
  ];

  OnnxBackend get backend => _backend;

  @override
  String get label => 'onnx-ocr';

  @override
  bool get isAvailable => true;

  @override
  Future<OcrResult> recognize(OcrImage image) async {
    final lines = <OcrLine>[];
    final bands = LineSegmenter.findLines(image, minHeight: minLineHeight);
    if (bands.isEmpty) {
      return OcrResult(
        lines: lines,
        sourceWidth: image.width,
        sourceHeight: image.height,
        engineLabel: label,
      );
    }

    for (final band in bands) {
      final crop = image.crop(band);
      final normalised = _normalise(crop);
      final value = await OrtValue.fromList(
        Float32List.fromList(normalised.$1),
        [1, 1, lineHeight, normalised.$2],
      );
      try {
        final outputs = await _recognizer.run({inputName: value});
        final logits = outputs[outputName];
        if (logits == null) continue;
        final flat = (await logits.asFlattenedList())
            .map((e) => (e as num).toDouble())
            .toList(growable: false);
        final decoded = _ctcGreedy(flat, normalised.$3);
        await logits.dispose();
        if (decoded.text.trim().isEmpty) continue;
        if (decoded.confidence < minConfidence) continue;
        lines.add(OcrLine(
          text: decoded.text,
          rect: band,
          confidence: decoded.confidence,
        ));
      } finally {
        await value.dispose();
      }
    }

    return OcrResult(
      lines: lines,
      sourceWidth: image.width,
      sourceHeight: image.height,
      engineLabel: label,
    );
  }

  /// Scales a line to [lineHeight], padding on the right, and returns
  /// `(pixels, width, steps)` — `steps` is the number of time frames the CTC
  /// head produced, i.e. how much of the width the network actually saw.
  (Float32List, int, int) _normalise(OcrImage crop) {
    final scale = lineHeight / crop.height;
    var targetWidth = (crop.width * scale).round();
    if (targetWidth < 8) targetWidth = 8;
    if (targetWidth > maxLineWidth) targetWidth = maxLineWidth;

    final out = Float32List(lineHeight * targetWidth);
    for (var y = 0; y < lineHeight; y++) {
      final sy = (y / scale).floor().clamp(0, crop.height - 1);
      for (var x = 0; x < targetWidth; x++) {
        final sx = (x / scale).floor().clamp(0, crop.width - 1);
        // 0 = black in the source, but CRNNs are trained on
        // "background = 0, ink = 1" normalised to [-1, 1].
        final ink = (255 - crop.pixels[sy * crop.width + sx]) / 255;
        out[y * targetWidth + x] = ink * 2 - 1;
      }
    }
    // CTC stride: conv stacks usually collapse the width by 4.
    final steps = math.max(1, targetWidth ~/ 4);
    return (out, targetWidth, steps);
  }

  /// CTC greedy decoding: take the argmax per frame, collapse repeats, drop the
  /// blank (last) class.
  ({String text, double confidence}) _ctcGreedy(List<double> flat, int steps) {
    if (flat.isEmpty || steps <= 0) return (text: '', confidence: 0);
    final classes = flat.length ~/ steps;
    if (classes < 2) return (text: '', confidence: 0);
    final blank = classes - 1;

    final buffer = StringBuffer();
    var previous = -1;
    var probability = 0.0;
    var frames = 0;

    for (var t = 0; t < steps; t++) {
      var best = 0;
      var bestValue = -double.infinity;
      // log-sum-exp over the classes of this frame; the largest logit is
      // factored out so exp() never overflows on a big vocabulary.
      var accumulator = 0.0;
      for (var c = 0; c < classes; c++) {
        final value = flat[t * classes + c];
        if (value > bestValue) {
          bestValue = value;
          best = c;
        }
      }
      for (var c = 0; c < classes; c++) {
        accumulator += math.exp(flat[t * classes + c] - bestValue);
      }
      probability += 1 / accumulator;
      frames++;

      if (best == blank) {
        previous = -1;
        continue;
      }
      if (best != previous) {
        final symbol = best < _charset.length ? _charset[best] : '';
        buffer.write(symbol);
      }
      previous = best;
    }

    final text = buffer.toString().trim();
    final confidence =
        frames == 0 ? 0.0 : (probability / frames).clamp(0.0, 1.0);
    return (text: text, confidence: confidence);
  }

  @override
  Future<void> dispose() async {
    // Sessions belong to the backend, which owns their lifetime.
  }
}

/// Finds text line bands with a horizontal ink projection profile.
class LineSegmenter {
  const LineSegmenter._();

  /// Threshold used to decide that a row contains ink.
  static const double rowInkThreshold = 0.02;

  static List<OcrRect> findLines(
    OcrImage image, {
    int minHeight = 6,
    int padding = 2,
  }) {
    if (image.width < 4 || image.height < 4) return const [];

    final threshold = Otsu.threshold(image);
    final rows = Uint8List(image.height);
    for (var y = 0; y < image.height; y++) {
      var ink = 0;
      final row = y * image.width;
      for (var x = 0; x < image.width; x++) {
        if (image.pixels[row + x] < threshold) ink++;
      }
      rows[y] = (ink / image.width) > rowInkThreshold ? 1 : 0;
    }

    final bands = <OcrRect>[];
    var start = -1;
    // A gap of a couple of blank rows inside a line (descenders vs. the next
    // line's ascenders) must not split it: close gaps shorter than 3 rows.
    var gap = 0;
    for (var y = 0; y < image.height; y++) {
      if (rows[y] == 1) {
        if (start < 0) start = y;
        gap = 0;
      } else if (start >= 0) {
        gap++;
        if (gap > 3) {
          _addBand(bands, image, start, y - gap + 1, minHeight, padding,
              threshold);
          start = -1;
          gap = 0;
        }
      }
    }
    if (start >= 0) {
      _addBand(bands, image, start, image.height - gap, minHeight, padding,
          threshold);
    }
    return bands;
  }

  static void _addBand(
    List<OcrRect> bands,
    OcrImage image,
    int start,
    int end,
    int minHeight,
    int padding,
    int threshold,
  ) {
    final top = (start - padding).clamp(0, image.height - 1);
    final bottom = (end + padding).clamp(top + 1, image.height);
    final height = bottom - top;
    if (height < minHeight) return;
    // Trim the sides: most page images have a white margin, and a tighter crop
    // gives the recognizer a better aspect ratio.
    var left = 0;
    var right = image.width;
    var found = false;
    for (var x = 0; x < image.width; x++) {
      var ink = false;
      for (var y = top; y < bottom; y++) {
        if (image.pixels[y * image.width + x] < threshold) {
          ink = true;
          break;
        }
      }
      if (ink) {
        if (!found) left = x;
        found = true;
        right = x + 1;
      }
    }
    if (right - left < 4) return;
    bands.add(OcrRect((left - padding).clamp(0, image.width - 1).toDouble(),
        top.toDouble(), (right - left + padding * 2).toDouble(), height.toDouble()));
  }
}

/// Otsu's between-class variance thresholding.
class Otsu {
  const Otsu._();

  static int threshold(OcrImage image) {
    final histogram = Int32List(256);
    for (final value in image.pixels) {
      histogram[value]++;
    }
    final total = image.pixels.length;
    if (total == 0) return 128;
    var sum = 0;
    for (var i = 0; i < 256; i++) {
      sum += i * histogram[i];
    }
    var sumB = 0;
    var weightB = 0;
    var best = 0.0;
    var threshold = 128;
    for (var t = 0; t < 256; t++) {
      weightB += histogram[t];
      if (weightB == 0) continue;
      final weightF = total - weightB;
      if (weightF == 0) break;
      sumB += t * histogram[t];
      final meanB = sumB / weightB;
      final meanF = (sum - sumB) / weightF;
      final between = weightB * weightF * (meanB - meanF) * (meanB - meanF);
      if (between > best) {
        best = between;
        threshold = t;
      }
    }
    return threshold;
  }
}
