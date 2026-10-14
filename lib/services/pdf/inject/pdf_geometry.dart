import 'dart:math' as math;

/// A rectangle in PDF page coordinates: origin bottom-left, Y pointing up.
///
/// This is exactly the space `pdfrx` reports for text boxes, so values can be
/// handed over to the injector without any conversion.
class PdfBox {
  const PdfBox(this.left, this.bottom, this.width, this.height);

  PdfBox.fromLTRB(double left, double bottom, double right, double top)
      : left = left,
        bottom = bottom,
        width = right - left,
        height = top - bottom;

  static const PdfBox zero = PdfBox(0, 0, 0, 0);

  final double left;
  final double bottom;
  final double width;
  final double height;

  double get right => left + width;
  double get top => bottom + height;

  /// Vertical centre, useful when re-centring translated text.
  double get centerY => bottom + height / 2;
  double get centerX => left + width / 2;

  PdfBox expand(double by) =>
      PdfBox(left - by, bottom - by, width + by * 2, height + by * 2);

  PdfBox inflate({double left = 0, double bottom = 0, double right = 0, double top = 0}) =>
      PdfBox(this.left - left, this.bottom - bottom,
          width + left + right, height + bottom + top);

  bool get isEmpty => width <= 0 || height <= 0;

  PdfBox copyWith({
    double? left,
    double? bottom,
    double? width,
    double? height,
  }) =>
      PdfBox(
        left ?? this.left,
        bottom ?? this.bottom,
        width ?? this.width,
        height ?? this.height,
      );

  @override
  String toString() =>
      'PdfBox(l:${left.toStringAsFixed(2)} b:${bottom.toStringAsFixed(2)} '
      'w:${width.toStringAsFixed(2)} h:${height.toStringAsFixed(2)})';
}

/// RGB in PDF components (0..1 each).
class PdfColor {
  const PdfColor(this.r, this.g, this.b);

  const PdfColor.white()
      : r = 1,
        g = 1,
        b = 1;

  const PdfColor.black()
      : r = 0,
        g = 0,
        b = 0;

  final double r;
  final double g;
  final double b;

  double get luminance => 0.299 * r + 0.587 * g + 0.114 * b;

  bool get isDark => luminance < 0.5;

  /// Manhattan distance to another colour (0..3).
  double distanceTo(PdfColor other) =>
      (r - other.r).abs() + (g - other.g).abs() + (b - other.b).abs();

  /// A colour with enough contrast to be readable on [background].
  PdfColor contrasting(PdfColor background) {
    final light = const PdfColor.white();
    final dark = const PdfColor.black();
    return background.isDark ? light : dark;
  }

  /// Blends toward [other] (0..1).
  PdfColor mix(PdfColor other, double t) => PdfColor(
        r + (other.r - r) * t,
        g + (other.g - g) * t,
        b + (other.b - b) * t,
      );

  PdfColor clamp01() => PdfColor(
        r.clamp(0.0, 1.0),
        g.clamp(0.0, 1.0),
        b.clamp(0.0, 1.0),
      );

  /// `0.12 0.34 0.56` — the operand order PDF graphics operators expect.
  String get operands =>
      '${_f(r)} ${_f(g)} ${_f(b)}';

  static String _f(double v) => v.toStringAsFixed(4);

  @override
  String toString() => 'PdfColor(${_f(r)}, ${_f(g)}, ${_f(b)})';
}

/// Horizontal alignment inside the original block box.
enum PdfTextAlign { left, center, right, justify }

/// Vertical placement inside the original block box.
enum PdfTextVertical { top, middle, bottom }

/// maths helper kept local so the geometry file stays dependency free.
double clampDouble(double value, double min, double max) =>
    math.min(math.max(value, min), max);
