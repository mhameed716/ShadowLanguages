import 'dart:typed_data';

import 'package:pdfrx/pdfrx.dart';

import '../../core/error/failure.dart';
import '../../data/models/book_layout.dart';
import '../../data/models/text_block.dart';
import 'extraction/background_sampler.dart';
import 'extraction/content_scanner.dart';
import 'extraction/overlap_detector.dart';
import 'extraction/pdf_layout_extractor.dart';
import 'inject/embedded_font.dart';
import 'inject/page_overlay_painter.dart';
import 'inject/pdf_geometry.dart';
import 'inject/pdf_injection_session.dart';
import 'inject/pdf_object.dart';
import 'inject/pdf_reader.dart';
import 'layout/block_layout_engine.dart';
import 'layout/font_coverage.dart';
import 'layout/font_resolver.dart';
import 'pdf_validator.dart';
import 'shaping/text_shaper.dart';
import 'verification/layout_verifier.dart';

/// Per page collision analysis of a whole document.
class PlacementAnalysis {
  const PlacementAnalysis(this.plans);

  final List<PagePlacementPlan> plans;

  int get haloBlocks =>
      plans.fold<int>(0, (sum, page) => sum + page.haloCount);
  int get tightBlocks =>
      plans.fold<int>(0, (sum, page) => sum + page.tightCount);
  int get droppedBlocks =>
      plans.fold<int>(0, (sum, page) => sum + page.droppedCount);
  int get riskyBlocks => haloBlocks + tightBlocks + droppedBlocks;

  bool get hasRisks => riskyBlocks > 0;

  PlacementStrategy strategyFor(String blockId) {
    for (final plan in plans) {
      final strategy = plan.strategyFor(blockId);
      if (strategy != PlacementStrategy.cover) return strategy;
    }
    return PlacementStrategy.cover;
  }

  PagePlacementPlan? planForPage(int pageIndex) {
    for (final plan in plans) {
      if (plan.pageIndex == pageIndex) return plan;
    }
    return null;
  }
}

/// Report of an injection run.
class InjectionReport {
  const InjectionReport({
    required this.bytes,
    required this.pagesInjected,
    required this.blocksInjected,
    required this.skippedRotatedPages,
    required this.fontsEmbedded,
    this.haloBlocks = 0,
    this.tightBlocks = 0,
    this.droppedBlocks = 0,
    this.missingGlyphs = 0,
    this.verification,
  });

  final Uint8List bytes;
  final int pagesInjected;
  final int blocksInjected;
  final int skippedRotatedPages;
  final List<String> fontsEmbedded;

  /// Blocks drawn with a halo because artwork sits behind them.
  final int haloBlocks;

  /// Blocks covered without padding because rules sit around them.
  final int tightBlocks;

  /// Blocks left untouched: the risk of damaging the page was too high.
  final int droppedBlocks;

  /// Glyphs the bundled fonts do not contain (rendered as blank).
  final int missingGlyphs;

  /// Pixel diff between the original and the injected document.
  final VerificationReport? verification;

  bool get verified => verification?.passed ?? false;
}

/// The public face of the PDF core: validate → extract → analyse → inject →
/// verify.
///
/// Injection never rebuilds the document: it appends an incremental update, so
/// images, vectors, fonts, links, form fields and metadata are byte-identical
/// to the original. On top of that every block is checked for collisions with
/// artwork before anything is painted, and the result is verified by rendering
/// both documents and diffing the pixels outside the translated boxes.
class PdfEngine {
  PdfEngine({
    PdfLayoutExtractor? extractor,
    FontResolver? fonts,
    TextShaper? shaper,
    PdfValidator? validator,
    LayoutVerifier? verifier,
    OverlapDetector? overlapDetector,
  })  : _extractor = extractor,
        _fonts = fonts,
        _shaper = shaper,
        _validator = validator ?? PdfValidator(),
        _verifier = verifier ?? LayoutVerifier(),
        _overlap = overlapDetector ?? OverlapDetector();

  PdfLayoutExtractor? _extractor;
  FontResolver? _fonts;
  final TextShaper? _shaper;
  final PdfValidator _validator;
  final LayoutVerifier _verifier;
  final OverlapDetector _overlap;

  /// Loads the bundled fonts (cached after the first call).
  Future<FontResolver> fonts() async => _fonts ??= await FontResolver.load();

  // ----------------------------------------------------------------- step 0
  /// Pre-flight: is this file something we can work on at all?
  Future<PdfValidation> validate(String path) => _validator.validateFile(path);

  /// Tries a password (`null` = "is it protected?").
  Future<PdfUnlockResult> unlock(String path, String? password) =>
      _validator.tryUnlock(path, password);

  /// Can the bundled fonts render this language?
  Future<FontCoverageReport> fontCoverage({
    required String languageCode,
    required String languageName,
  }) async {
    final resolver = await fonts();
    final script = ScriptSamples.forLanguage(languageCode);
    final samples = ScriptSamples.of(script);
    var covered = 0;
    final missing = <String>[];
    for (final codePoint in samples) {
      final ok = resolver.fonts.any((font) => font.ttf.hasGlyph(codePoint));
      if (ok) {
        covered++;
      } else {
        missing.add('U+${codePoint.toRadixString(16).toUpperCase()}');
      }
    }
    return FontCoverageReport(
      languageCode: languageCode,
      languageName: languageName,
      script: script,
      sampledCharacters: samples.length,
      coveredCharacters: covered,
      missingSamples: missing,
      fontsChecked:
          resolver.fonts.map((f) => f.descriptor.familyName).toList(growable: false),
    );
  }

  // ----------------------------------------------------------------- step 1
  /// Maps the text layer of the document.
  Future<BookLayout> extractLayout({
    required String path,
    required String name,
    String? password,
    void Function(int pageIndex, int pageCount)? onProgress,
    void Function(String message)? onLog,
  }) {
    final extractor = _extractor ??= PdfLayoutExtractor();
    return extractor.extract(
      path: path,
      name: name,
      password: password,
      onProgress: onProgress,
      onLog: onLog,
    );
  }

  // ----------------------------------------------------------------- step 2
  /// Finds out — before writing anything — which blocks sit on top of artwork.
  ///
  /// Two signals are combined: the page content stream (exact image and vector
  /// placements) and the rendered pixels (tables, gradients, scans).
  Future<PlacementAnalysis> analyzePlacements({
    required Uint8List sourceBytes,
    required BookLayout layout,
    String? password,
    void Function(int pageIndex, int pageCount)? onProgress,
    void Function(String message)? onLog,
  }) async {
    final plans = <PagePlacementPlan>[];
    PdfDocument? document;
    try {
      document = await PdfDocument.openData(
        sourceBytes,
        passwordProvider: password == null
            ? null
            : createSimplePasswordProvider(password),
        firstAttemptByEmptyPassword: password == null,
      );
      final reader = PdfFileReader(sourceBytes);
      final scanner = ContentScanner(reader);
      final total = layout.pageCount;
      for (final page in layout.pages) {
        if (page.blocks.isEmpty) continue;
        if (page.rotation != 0) {
          // Rotated pages are skipped by the injector anyway.
          continue;
        }
        PageGraphics graphics;
        try {
          graphics = scanner.scanPage(page.index, onLog: onLog);
        } catch (e) {
          onLog?.call('page ${page.index + 1}: graphics scan skipped ($e)');
          graphics = PageGraphics(
            pageIndex: page.index,
            imageRects: const [],
            vectorRects: const [],
            shadingRects: const [],
            scanned: true,
          );
        }
        PdfPage? pdfPage;
        try {
          pdfPage = document.pages[page.index];
        } catch (_) {
          pdfPage = null;
        }
        late final PagePlacementPlan plan;
        if (pdfPage == null) {
          plan = PagePlacementPlan(
            pageIndex: page.index,
            blocks: [
              for (final block in page.blocks)
                BlockPlacement(
                  blockId: block.id,
                  strategy: PlacementStrategy.halo,
                  risk: RiskLevel.medium,
                  graphicsCoverage: 0,
                  onImage: false,
                  onVector: false,
                  textured: false,
                  ruleScore: 0,
                  reason: 'page could not be rendered → safe halo mode',
                ),
            ],
            graphics: graphics,
            renderFailed: true,
          );
        } else {
          plan = await _overlap.analyzePage(
            pdfPage,
            page.blocks,
            graphics,
            onLog: onLog,
          );
        }
        plans.add(plan);
        onProgress?.call(page.index, total);
      }
    } catch (e) {
      onLog?.call('placement analysis aborted: $e');
    } finally {
      await document?.dispose();
    }
    return PlacementAnalysis(plans);
  }

  // ----------------------------------------------------------------- step 3
  /// Writes the translations back into the original file.
  ///
  /// [translations] maps block ids (see [TextBlock.id]) to the translated text.
  /// Blocks without an entry keep their original text.
  ///
  /// [placements] decides, per block, whether the old glyphs may be covered or
  /// must be left alone; when it is `null` the engine computes it itself.
  Future<InjectionReport> injectTranslations({
    required Uint8List sourceBytes,
    required BookLayout layout,
    required Map<String, String> translations,
    bool cloak = true,
    bool shrinkToFit = true,
    double cloakPadding = 0.7,
    PlacementAnalysis? placements,
    bool verifyOutput = true,
    void Function(int pageIndex, int pageCount)? onProgress,
    void Function(String message)? onLog,
  }) async {
    final reader = PdfFileReader(sourceBytes);
    final session = PdfInjectionSession(reader);
    final resolver = await fonts();

    // Embed every bundled face; tags stay aligned with [ResolvedFont.tag].
    final embedded = <EmbeddedFont>[];
    for (final font in resolver.fonts) {
      embedded.add(session.addFont(font.ttf, font.descriptor.familyName));
    }

    final shaper = _shaper ?? TextShaper();
    final layoutEngine = BlockLayoutEngine(fonts: resolver, shaper: shaper);

    var injectedPages = 0;
    var injectedBlocks = 0;
    var skippedPages = 0;
    var haloBlocks = 0;
    var tightBlocks = 0;
    var droppedBlocks = 0;
    var missingGlyphs = 0;

    for (final page in layout.pages) {
      if (page.blocks.isEmpty) continue;
      // Rotated pages keep the author's text: the extracted coordinates live in
      // the rotated space and can not be mapped back reliably.
      if (page.rotation != 0) {
        skippedPages++;
        onLog?.call('page ${page.index + 1}: rotated page left untouched');
        continue;
      }

      final plan = placements?.planForPage(page.index);
      final painter = session.painterFor(page.index);
      final usedFonts = <int>{};

      for (final block in page.blocks) {
        final translated = translations[block.id];
        if (translated == null || translated.trim().isEmpty) continue;
        final text = translated.trim();

        final strategy = plan?.strategyFor(block.id) ??
            (cloak ? PlacementStrategy.cover : PlacementStrategy.halo);

        if (strategy == PlacementStrategy.keepOriginal) {
          droppedBlocks++;
          onLog?.call(
              'page ${page.index + 1}: block ${block.id} kept as authored '
              '(artwork collision)');
          continue;
        }

        final bool useHalo = strategy == PlacementStrategy.halo;
        final double padding = switch (strategy) {
          PlacementStrategy.tight => 0,
          PlacementStrategy.halo => 0,
          _ => cloak ? cloakPadding : 0,
        };

        // 1. cloak the original glyphs — only where it is provably safe.
        //
        // Over artwork we never paint: a rectangle there would erase pixels no
        // one can bring back. The translation is drawn with a halo instead.
        if (strategy != PlacementStrategy.halo) {
          painter.cover(
            padding == 0
                ? block.box
                : block.box.inflate(
                    left: padding,
                    right: padding,
                    top: padding * 1.6,
                    bottom: padding * 2.2,
                  ),
            cloak ? block.backgroundColor : const PdfColor(1, 1, 1),
          );
        } else {
          haloBlocks++;
        }
        if (strategy == PlacementStrategy.tight) tightBlocks++;

        // 2. lay the translation out inside the very same box
        final result = layoutEngine.layout(BlockLayoutRequest(
          box: block.box,
          text: text,
          preferredSize: block.fontSize,
          minSize: 4,
          maxSize: 48,
          align: _alignOf(block),
          vertical: PdfTextVertical.top,
          baseline: block.baseline,
          // Inside a table cell the text must fit: shrinking is mandatory.
          shrinkToFit: shrinkToFit || strategy == PlacementStrategy.tight,
          paragraphLevel: block.direction == BlockDirection.rtl ? 1 : null,
        ));

        if (result.overflowed) {
          onLog?.call(
              'page ${page.index + 1}: block ${block.id} needed shrinking '
              '(${result.usedSize.toStringAsFixed(1)}pt)');
        }

        // 3. draw it, glyph by glyph, with the font that covers each run
        final haloColor =
            block.textColor.isDark ? const PdfColor.white() : const PdfColor.black();
        for (final line in result.lines) {
          for (final chunk in line.chunks) {
            if (chunk.glyphIds.isEmpty) continue;
            missingGlyphs += chunk.glyphIds.where((g) => g == 0).length;
            usedFonts.add(chunk.fontTag);
            final font = embedded[chunk.fontTag - 1];
            font.record(chunk.glyphIds, chunk.codePointsPerGlyph);
          }
          painter.drawLine(
            x: line.left,
            baselineY: line.baseline,
            size: line.size,
            color: block.textColor,
            halo: useHalo,
            haloColor: haloColor,
            segments: [
              for (final chunk in line.chunks)
                PdfGlyphSegment(
                  fontTag: chunk.fontTag,
                  glyphIds: chunk.glyphIds,
                  offsetX: chunk.offsetX,
                ),
            ],
          );
        }
        injectedBlocks++;
      }

      if (painter.operationCount > 0) {
        session.commit(painter);
        injectedPages++;
      }
      onProgress?.call(page.index, layout.pageCount);
    }

    final bytes = session.finalize();

    VerificationReport? verification;
    if (verifyOutput && injectedBlocks > 0) {
      try {
        verification = await _verifier.verify(
          original: sourceBytes,
          translated: bytes,
          layout: layout,
          onLog: onLog,
        );
      } catch (e) {
        onLog?.call('verification failed: $e');
      }
    }

    return InjectionReport(
      bytes: bytes,
      pagesInjected: injectedPages,
      blocksInjected: injectedBlocks,
      skippedRotatedPages: skippedPages,
      fontsEmbedded:
          resolver.fonts.map((f) => f.descriptor.familyName).toList(growable: false),
      haloBlocks: haloBlocks,
      tightBlocks: tightBlocks,
      droppedBlocks: droppedBlocks,
      missingGlyphs: missingGlyphs,
      verification: verification,
    );
  }

  /// Renders both documents and diffs the pixels outside the text boxes.
  Future<VerificationReport> verify({
    required Uint8List original,
    required Uint8List translated,
    required BookLayout layout,
    void Function(String message)? onLog,
  }) =>
      _verifier.verify(
        original: original,
        translated: translated,
        layout: layout,
        onLog: onLog,
      );

  static PdfTextAlign _alignOf(TextBlock block) => switch (block.alignment) {
        BlockAlignment.left => PdfTextAlign.left,
        BlockAlignment.center => PdfTextAlign.center,
        BlockAlignment.right => PdfTextAlign.right,
        BlockAlignment.justify => PdfTextAlign.justify,
      };
}
