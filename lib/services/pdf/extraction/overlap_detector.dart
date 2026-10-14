import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pdfrx/pdfrx.dart';

import '../../../data/models/text_block.dart';
import '../inject/pdf_geometry.dart';
import 'content_scanner.dart';

/// How the injector is allowed to place the translation of one block.
enum PlacementStrategy {
  /// Flat paper behind the text: paint the sampled background colour over the
  /// old glyphs and draw the translation on top. This is the default and it is
  /// pixel perfect on ordinary book pages.
  cover,

  /// There is artwork behind the text (photo, diagram, gradient, tinted
  /// banner): **never** paint a rectangle there — the original pixels would be
  /// destroyed. Instead the text is stroked with a contrasting halo so it stays
  /// readable while the artwork shows through.
  halo,

  /// The block sits inside a ruled area (table cell, boxed sidebar): cover, but
  /// with zero padding so the surrounding rules survive, and shrink the text
  /// until it fits the cell.
  tight,

  /// Too dangerous: keep the author's text and report it.
  keepOriginal,
}

/// How risky the placement is.
enum RiskLevel { none, low, medium, high }

/// The decision taken for one block.
class BlockPlacement {
  const BlockPlacement({
    required this.blockId,
    required this.strategy,
    required this.risk,
    required this.graphicsCoverage,
    required this.onImage,
    required this.onVector,
    required this.textured,
    required this.ruleScore,
    required this.reason,
  });

  final String blockId;
  final PlacementStrategy strategy;
  final RiskLevel risk;

  /// Share of the block box covered by image/vector graphics (0..1).
  final double graphicsCoverage;
  final bool onImage;
  final bool onVector;

  /// The pixels behind the text are not a flat colour.
  final bool textured;

  /// How much of the box looks like table rules / underlines (0..1).
  final double ruleScore;

  /// Human readable explanation, goes to the log stream.
  final String reason;

  bool get needsHalo => strategy == PlacementStrategy.halo;
  bool get skipCover =>
      strategy == PlacementStrategy.halo ||
      strategy == PlacementStrategy.keepOriginal;
  bool get dropped => strategy == PlacementStrategy.keepOriginal;
}

/// Per page summary of the collision analysis.
class PagePlacementPlan {
  const PagePlacementPlan({
    required this.pageIndex,
    required this.blocks,
    required this.graphics,
    this.renderFailed = false,
  });

  final int pageIndex;
  final List<BlockPlacement> blocks;
  final PageGraphics graphics;
  final bool renderFailed;

  PlacementStrategy strategyFor(String blockId) {
    for (final placement in blocks) {
      if (placement.blockId == blockId) return placement.strategy;
    }
    return PlacementStrategy.cover;
  }

  int get haloCount =>
      blocks.where((b) => b.strategy == PlacementStrategy.halo).length;
  int get tightCount =>
      blocks.where((b) => b.strategy == PlacementStrategy.tight).length;
  int get droppedCount =>
      blocks.where((b) => b.strategy == PlacementStrategy.keepOriginal).length;
}

/// Answers, before a single byte is written:
///
/// > “if I paint the translation inside the original box, will I damage a
/// > picture, a rule or a gradient?”
///
/// Two independent signals are combined:
///
/// 1. **Exact geometry** — [PageGraphics] comes from replaying the page content
///    stream, so image and vector placements are known in page coordinates.
/// 2. **Rendered pixels** — the page is rendered once and each block box is
///    inspected for ink density, long straight runs (tables) and texture
///    (photos/gradients), which catches artwork drawn by form XObjects,
///    annotations or patterns the scanner could not resolve.
///
/// The rule the injector then follows is simple and safe: **never erase pixels
/// you cannot reproduce** — over artwork we switch from "cover" to "halo".
class OverlapDetector {
  OverlapDetector({this.renderWidth = 900});

  final int renderWidth;

  /// Above this share of the box covered by image/vector art we stop covering.
  static const double _graphicsThreshold = 0.12;

  /// Above this rule score the block is treated as a table cell.
  static const double _ruleThreshold = 0.45;

  /// Above this texture score the background is not a flat colour.
  static const double _textureThreshold = 0.22;

  Future<PagePlacementPlan> analyzePage(
    PdfPage page,
    List<TextBlock> blocks,
    PageGraphics graphics, {
    void Function(String message)? onLog,
  }) async {
    if (blocks.isEmpty) {
      return PagePlacementPlan(
        pageIndex: page.pageNumber - 1,
        blocks: const [],
        graphics: graphics,
      );
    }

    _Rendered? rendered;
    try {
      rendered = await _render(page);
    } catch (e) {
      onLog?.call('page ${page.pageNumber}: collision render failed ($e)');
    }

    final placements = <BlockPlacement>[];
    for (final block in blocks) {
      placements.add(_decide(block, graphics, rendered));
    }

    return PagePlacementPlan(
      pageIndex: page.pageNumber - 1,
      blocks: placements,
      graphics: graphics,
      renderFailed: rendered == null,
    );
  }

  BlockPlacement _decide(
    TextBlock block,
    PageGraphics graphics,
    _Rendered? rendered,
  ) {
    final box = block.box;
    final coverage = graphics.graphicsCoverage(box);
    final onImage = graphics.imageRects.any((r) => _overlap(box, r) > 0.02);
    final onVector = graphics.vectorRects.any((r) => _overlap(box, r) > 0.02);

    double texture = 0;
    double rules = 0;
    double ink = 0;
    if (rendered != null) {
      final stats = rendered.inspect(box);
      texture = stats.texture;
      rules = stats.ruleScore;
      ink = stats.inkRatio;
    }

    // 1. The scan failed to decode the page AND the box is full of ink that is
    //    not the text we measured: assume artwork.
    final suspicious =
        graphics.scanned && ink > 0.55 && block.text.trim().length * 8 < box.width;

    if (coverage >= _graphicsThreshold || onImage || suspicious) {
      return BlockPlacement(
        blockId: block.id,
        strategy: PlacementStrategy.halo,
        risk: coverage > 0.5 ? RiskLevel.high : RiskLevel.medium,
        graphicsCoverage: coverage,
        onImage: onImage,
        onVector: onVector,
        textured: texture > _textureThreshold,
        ruleScore: rules,
        reason: onImage
            ? 'image behind text → halo, original pixels kept'
            : 'vector artwork behind text → halo',
      );
    }

    if (texture > _textureThreshold) {
      return BlockPlacement(
        blockId: block.id,
        strategy: PlacementStrategy.halo,
        risk: RiskLevel.medium,
        graphicsCoverage: coverage,
        onImage: onImage,
        onVector: onVector,
        textured: true,
        ruleScore: rules,
        reason: 'gradient/photo background → halo',
      );
    }

    if (rules > _ruleThreshold) {
      return BlockPlacement(
        blockId: block.id,
        strategy: PlacementStrategy.tight,
        risk: RiskLevel.low,
        graphicsCoverage: coverage,
        onImage: onImage,
        onVector: onVector,
        textured: texture > _textureThreshold,
        ruleScore: rules,
        reason: 'ruled area (table/box) → tight cover, no padding',
      );
    }

    if (onVector && coverage > 0.02) {
      return BlockPlacement(
        blockId: block.id,
        strategy: PlacementStrategy.tight,
        risk: RiskLevel.low,
        graphicsCoverage: coverage,
        onImage: onImage,
        onVector: true,
        textured: false,
        ruleScore: rules,
        reason: 'near a rule/border → tight cover',
      );
    }

    return BlockPlacement(
      blockId: block.id,
      strategy: PlacementStrategy.cover,
      risk: RiskLevel.none,
      graphicsCoverage: coverage,
      onImage: false,
      onVector: onVector,
      textured: false,
      ruleScore: rules,
      reason: 'flat background → cover',
    );
  }

  static double _overlap(PdfBox box, PdfBox other) {
    final x0 = box.left > other.left ? box.left : other.left;
    final y0 = box.bottom > other.bottom ? box.bottom : other.bottom;
    final x1 = box.right < other.right ? box.right : other.right;
    final y1 = box.top < other.top ? box.top : other.top;
    final w = x1 - x0;
    final h = y1 - y0;
    if (w <= 0 || h <= 0) return 0;
    final area = box.width * box.height;
    if (area <= 0) return 0;
    return (w * h) / area;
  }

  Future<_Rendered?> _render(PdfPage page) async {
    final scale = renderWidth / page.width;
    final width = math.max(1, (page.width * scale).round());
    final height = math.max(1, (page.height * scale).round());
    final image = await page.render(
      width: width,
      height: height,
      backgroundColor: 0xFFFFFFFF,
      annotationRenderingMode: PdfAnnotationRenderingMode.none,
    );
    final pixels = image?.pixels;
    if (pixels == null) {
      image?.dispose();
      return null;
    }
    final copy = Uint8List.fromList(pixels);
    image?.dispose();
    return _Rendered(
      pixels: copy,
      width: width,
      height: height,
      pageWidth: page.width,
      pageHeight: page.height,
    );
  }
}

/// Pixel statistics of one block box on the rendered page.
class _BoxStats {
  const _BoxStats({
    required this.inkRatio,
    required this.texture,
    required this.ruleScore,
  });

  /// Share of pixels that differ from the dominant colour.
  final double inkRatio;

  /// Share of mid-tone pixels: gradients and photos, not flat paper.
  final double texture;

  /// Share of rows/columns that are almost fully dark: rules and borders.
  final double ruleScore;
}

class _Rendered {
  _Rendered({
    required this.pixels,
    required this.width,
    required this.height,
    required this.pageWidth,
    required this.pageHeight,
  });

  final Uint8List pixels; // BGRA8888
  final int width;
  final int height;
  final double pageWidth;
  final double pageHeight;

  double _lum(int index) {
    final b = pixels[index];
    final g = pixels[index + 1];
    final r = pixels[index + 2];
    return (0.299 * r + 0.587 * g + 0.114 * b) / 255.0;
  }

  _BoxStats inspect(PdfBox box) {
    var x0 = (box.left / pageWidth * width).floor();
    var x1 = (box.right / pageWidth * width).ceil();
    var y0 = ((pageHeight - box.top) / pageHeight * height).floor();
    var y1 = ((pageHeight - box.bottom) / pageHeight * height).ceil();
    x0 = x0.clamp(0, width - 1);
    x1 = x1.clamp(0, width);
    y0 = y0.clamp(0, height - 1);
    y1 = y1.clamp(0, height);
    final w = x1 - x0;
    final h = y1 - y0;
    if (w <= 1 || h <= 1) {
      return const _BoxStats(inkRatio: 0, texture: 0, ruleScore: 0);
    }

    // 1. dominant colour (quantised histogram) = the paper colour
    final histogram = <int, int>{};
    var total = 0;
    for (var y = y0; y < y1; y++) {
      for (var x = x0; x < x1; x++) {
        final lum = _lum((y * width + x) * 4);
        final key = (lum * 16).round();
        histogram[key] = (histogram[key] ?? 0) + 1;
        total++;
      }
    }
    if (total == 0) {
      return const _BoxStats(inkRatio: 0, texture: 0, ruleScore: 0);
    }
    var dominantKey = 0;
    var dominantCount = -1;
    for (final entry in histogram.entries) {
      if (entry.value > dominantCount) {
        dominantCount = entry.value;
        dominantKey = entry.key;
      }
    }
    final background = dominantKey / 16.0;

    // 2. ink / texture
    var ink = 0;
    var midtone = 0;
    for (var y = y0; y < y1; y++) {
      for (var x = x0; x < x1; x++) {
        final lum = _lum((y * width + x) * 4);
        final delta = (lum - background).abs();
        if (delta > 0.28) ink++;
        if (delta > 0.05 && delta <= 0.28) midtone++;
      }
    }

    // 3. rules: rows/columns that are mostly dark
    var ruleRows = 0;
    for (var y = y0; y < y1; y++) {
      var dark = 0;
      for (var x = x0; x < x1; x++) {
        if (background - _lum((y * width + x) * 4) > 0.28) dark++;
      }
      if (w > 8 && dark > w * 0.75) ruleRows++;
    }
    var ruleCols = 0;
    for (var x = x0; x < x1; x++) {
      var dark = 0;
      for (var y = y0; y < y1; y++) {
        if (background - _lum((y * width + x) * 4) > 0.28) dark++;
      }
      if (h > 8 && dark > h * 0.75) ruleCols++;
    }
    final ruleScore = ((ruleRows / h) + (ruleCols / w)) / 2;

    return _BoxStats(
      inkRatio: ink / total,
      texture: midtone / total,
      ruleScore: ruleScore.clamp(0.0, 1.0),
    );
  }
}
