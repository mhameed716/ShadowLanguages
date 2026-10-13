import '../../services/pdf/inject/pdf_geometry.dart';

/// Which way the original block was written.
enum BlockDirection { ltr, rtl, unknown }

/// Horizontal alignment deduced from the original line geometry.
enum BlockAlignment { left, center, right, justify }

/// A translatable chunk of a page: a paragraph, a heading, a table cell…
///
/// Carries everything the injector needs to put the translation back exactly
/// where the original was: coordinates, size, baseline, direction and ink.
class TextBlock {
  const TextBlock({
    required this.id,
    required this.pageIndex,
    required this.text,
    required this.box,
    required this.fontSize,
    required this.baseline,
    required this.direction,
    required this.alignment,
    required this.textColor,
    required this.backgroundColor,
    this.isHeading = false,
    this.isNumeric = false,
    this.lineCount = 1,
  });

  /// Stable, document-wide unique id (`page * 10000 + index`).
  final String id;
  final int pageIndex;

  /// Original text (logical order).
  final String text;

  /// Bounding box in PDF page coordinates (origin bottom-left).
  final PdfBox box;

  /// Estimated original font size in points.
  final double fontSize;

  /// Baseline of the first line, in PDF page coordinates.
  final double baseline;

  final BlockDirection direction;
  final BlockAlignment alignment;

  /// Sampled ink colour of the original glyphs.
  final PdfColor textColor;

  /// Sampled page colour behind the block (used for the cloak rectangle).
  final PdfColor backgroundColor;

  final bool isHeading;

  /// True when the block is made only of digits / punctuation: worth keeping
  /// verbatim instead of translating.
  final bool isNumeric;

  /// Number of source lines merged into this block.
  final int lineCount;

  /// Character count, used to size translation batches.
  int get length => text.length;

  double get lineHeight => box.height / (lineCount == 0 ? 1 : lineCount);

  TextBlock copyWith({
    String? text,
    PdfBox? box,
    double? fontSize,
    double? baseline,
    BlockDirection? direction,
    BlockAlignment? alignment,
    PdfColor? textColor,
    PdfColor? backgroundColor,
    bool? isHeading,
    bool? isNumeric,
    int? lineCount,
  }) =>
      TextBlock(
        id: id,
        pageIndex: pageIndex,
        text: text ?? this.text,
        box: box ?? this.box,
        fontSize: fontSize ?? this.fontSize,
        baseline: baseline ?? this.baseline,
        direction: direction ?? this.direction,
        alignment: alignment ?? this.alignment,
        textColor: textColor ?? this.textColor,
        backgroundColor: backgroundColor ?? this.backgroundColor,
        isHeading: isHeading ?? this.isHeading,
        isNumeric: isNumeric ?? this.isNumeric,
        lineCount: lineCount ?? this.lineCount,
      );

  @override
  String toString() =>
      'TextBlock($id p${pageIndex + 1} "${text.length > 24 ? '${text.substring(0, 24)}…' : text}")';
}
