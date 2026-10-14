import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pdfrx/pdfrx.dart';

import '../inject/pdf_geometry.dart';

/// Colours sampled from the rendered page underneath a text block.
class SampledColors {
  const SampledColors({required this.background, required this.ink});

  final PdfColor background;
  final PdfColor ink;
}

/// Samples the real page colours under a text block.
///
/// This is what makes the cloak invisible: instead of painting a hard white
/// rectangle over the original glyphs we paint the exact colour the page has
/// there (paper, tinted panel, coloured banner, ...), so the translated text
/// looks like it was printed by the author.
class BackgroundSampler {
  BackgroundSampler({
    this.maxRenderWidth = 1400,
    this.maxRenderHeight = 2000,
  });

  final int maxRenderWidth;
  final int maxRenderHeight;

  /// Renders [page] once and samples every [boxes] on it.
  ///
  /// Returns one [SampledColors] per box, in the same order.
  Future<List<SampledColors>> samplePage(
    PdfPage page,
    List<PdfBox> boxes, {
    void Function(String message)? onLog,
  }) async {
    if (boxes.isEmpty) return const [];
    final scale = math.min(
      maxRenderWidth / page.width,
      maxRenderHeight / page.height,
    );
    final renderWidth = math.max(1, (page.width * scale).round());
    final renderHeight = math.max(1, (page.height * scale).round());

    PdfImage? image;
    try {
      image = await page.render(
        width: renderWidth,
        height: renderHeight,
        backgroundColor: 0xFFFFFFFF,
        annotationRenderingMode: PdfAnnotationRenderingMode.none,
      );
      final pixels = image?.pixels;
      if (image == null || pixels == null) {
        return List.generate(
          boxes.length,
          (_) => const SampledColors(
            background: PdfColor.white(),
            ink: PdfColor.black(),
          ),
        );
      }
      return boxes
          .map((box) => _sampleBox(
                pixels: pixels,
                imageWidth: image!.width,
                imageHeight: image!.height,
                pageWidth: page.width,
                pageHeight: page.height,
                box: box,
              ))
          .toList(growable: false);
    } catch (e) {
      onLog?.call('background sampling failed: $e');
      return List.generate(
        boxes.length,
        (_) => const SampledColors(
          background: PdfColor.white(),
          ink: PdfColor.black(),
        ),
      );
    } finally {
      image?.dispose();
    }
  }

  SampledColors _sampleBox({
    required Uint8List pixels,
    required int imageWidth,
    required int imageHeight,
    required double pageWidth,
    required double pageHeight,
    required PdfBox box,
  }) {
    final sx = imageWidth / (pageWidth <= 0 ? 1 : pageWidth);
    final sy = imageHeight / (pageHeight <= 0 ? 1 : pageHeight);

    var x0 = (box.left * sx).floor();
    var x1 = (box.right * sx).ceil();
    var y0 = ((pageHeight - box.top) * sy).floor();
    var y1 = ((pageHeight - box.bottom) * sy).ceil();
    x0 = x0.clamp(0, imageWidth - 1);
    x1 = x1.clamp(x0 + 1, imageWidth);
    y0 = y0.clamp(0, imageHeight - 1);
    y1 = y1.clamp(y0 + 1, imageHeight);

    final histogram = <int, int>{};
    for (var y = y0; y < y1; y++) {
      final rowStart = y * imageWidth * 4;
      for (var x = x0; x < x1; x++) {
        final o = rowStart + x * 4;
        if (o + 2 >= pixels.length) continue;
        // BGRA (PDFium native order)
        final b = pixels[o];
        final g = pixels[o + 1];
        final r = pixels[o + 2];
        final key = ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3);
        histogram[key] = (histogram[key] ?? 0) + 1;
      }
    }
    if (histogram.isEmpty) {
      return const SampledColors(
          background: PdfColor.white(), ink: PdfColor.black());
    }
    final ranked = histogram.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final background = _decode(ranked.first.key);
    var ink = background.contrasting(background);
    for (final entry in ranked.skip(1)) {
      final candidate = _decode(entry.key);
      if (candidate.distanceTo(background) > 0.6) {
        ink = candidate;
        break;
      }
    }
    return SampledColors(background: background, ink: ink);
  }

  static PdfColor _decode(int key) {
    final r = ((key >> 10) & 0x1F) << 3;
    final g = ((key >> 5) & 0x1F) << 3;
    final b = (key & 0x1F) << 3;
    return PdfColor(r / 255.0, g / 255.0, b / 255.0);
  }
}
