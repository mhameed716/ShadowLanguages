import 'dart:typed_data';

/// A rectangle in **image pixel** space.
class OcrRect {
  const OcrRect(this.left, this.top, this.width, this.height);

  final double left;
  final double top;
  final double width;
  final double height;

  double get right => left + width;
  double get bottom => top + height;

  OcrRect scaled(double factor) =>
      OcrRect(left * factor, top * factor, width * factor, height * factor);

  @override
  String toString() =>
      'OcrRect($left, $top, ${width.toStringAsFixed(0)}x${height.toStringAsFixed(0)})';
}

/// One recognised text line.
class OcrLine {
  const OcrLine({
    required this.text,
    required this.rect,
    this.confidence = 1,
  });

  final String text;
  final OcrRect rect;
  final double confidence;

  bool get isEmpty => text.trim().isEmpty;
}

/// What one image returned.
class OcrResult {
  const OcrResult({
    required this.lines,
    required this.sourceWidth,
    required this.sourceHeight,
    this.engineLabel = 'offline',
  });

  final List<OcrLine> lines;

  /// Size of the image that was read, in pixels (needed to map the boxes back
  /// onto PDF coordinates).
  final int sourceWidth;
  final int sourceHeight;

  final String engineLabel;

  bool get isEmpty => lines.isEmpty;

  /// Every line joined with spaces, in reading order.
  String get text => lines.map((line) => line.text).join(' ');

  double get averageConfidence => lines.isEmpty
      ? 0
      : lines.fold<double>(0, (sum, line) => sum + line.confidence) /
          lines.length;
}

/// A block of text that was found inside an image of a PDF page.
///
/// These are carried alongside the ordinary text blocks so the injector can
/// place the translation over (or beside) the picture without touching the
/// picture itself.
class OcrTextBlock {
  const OcrTextBlock({
    required this.id,
    required this.text,
    required this.box,
    required this.pageIndex,
    this.confidence = 1,
  });

  /// Stable id: `ocr-p{page}-i{index}`.
  final String id;
  final String text;

  /// Box in **PDF user space** (same coordinate system as [TextBlock]).
  final ({double x, double y, double width, double height}) box;

  final int pageIndex;
  final double confidence;

  static String idFor(int pageIndex, int index) => 'ocr-p$pageIndex-i$index';
}

/// Contract for an offline OCR engine.
abstract interface class OcrEngine {
  /// Human readable name for the log.
  String get label;

  /// True when the model files are present and the session is loaded.
  bool get isAvailable;

  /// Reads [image] (grayscale, 8 bit) and returns the text lines it contains.
  Future<OcrResult> recognize(OcrImage image);

  Future<void> dispose();
}

/// A grayscale image handed to the recognizer.
class OcrImage {
  const OcrImage(this.pixels, this.width, this.height);

  /// Row major, one byte per pixel, 0 = black.
  final Uint8List pixels;
  final int width;
  final int height;

  int get length => pixels.length;

  /// Converts BGRA8888 pixels (what `PdfPage.render` returns) to grayscale.
  factory OcrImage.fromBgra(Uint8List bgra, int width, int height) {
    final grey = Uint8List(width * height);
    for (var i = 0; i < grey.length; i++) {
      final o = i * 4;
      final b = bgra[o];
      final g = bgra[o + 1];
      final r = bgra[o + 2];
      // Rec. 601 luma; the alpha channel is ignored (pages are opaque).
      grey[i] = (0.299 * r + 0.587 * g + 0.114 * b).round().clamp(0, 255);
    }
    return OcrImage(grey, width, height);
  }

  /// Crops a region, clamped to the image bounds.
  OcrImage crop(OcrRect rect) {
    final x0 = rect.left.floor().clamp(0, width - 1);
    final y0 = rect.top.floor().clamp(0, height - 1);
    final x1 = rect.right.ceil().clamp(x0 + 1, width);
    final y1 = rect.bottom.ceil().clamp(y0 + 1, height);
    final w = x1 - x0;
    final h = y1 - y0;
    final out = Uint8List(w * h);
    for (var y = 0; y < h; y++) {
      final src = (y0 + y) * width + x0;
      out.setRange(y * w, y * w + w, pixels, src);
    }
    return OcrImage(out, w, h);
  }
}

/// Used when no OCR model is installed: every call reports “nothing found”
/// instead of crashing the job.
class OcrUnavailableEngine implements OcrEngine {
  const OcrUnavailableEngine();

  @override
  String get label => 'none';

  @override
  bool get isAvailable => false;

  @override
  Future<OcrResult> recognize(OcrImage image) async =>
      OcrResult(lines: const [], sourceWidth: image.width,
          sourceHeight: image.height, engineLabel: label);

  @override
  Future<void> dispose() async {}
}
