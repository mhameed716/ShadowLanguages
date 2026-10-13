import 'dart:typed_data';

import 'package:pdfrx/pdfrx.dart';

import '../../data/models/book_layout.dart';
import '../../data/models/text_block.dart';
import 'extraction/background_sampler.dart';
import 'extraction/pdf_layout_extractor.dart';
import 'inject/embedded_font.dart';
import 'inject/page_overlay_painter.dart';
import 'inject/pdf_geometry.dart';
import 'inject/pdf_injection_session.dart';
import 'inject/pdf_object.dart';
import 'inject/pdf_reader.dart';
import 'layout/block_layout_engine.dart';
import 'layout/font_resolver.dart';
import 'shaping/text_shaper.dart';

/// Report of an injection run.
class InjectionReport {
  const InjectionReport({
    required this.bytes,
    required this.pagesInjected,
    required this.blocksInjected,
    required this.skippedRotatedPages,
    required this.fontsEmbedded,
  });

  final Uint8List bytes;
  final int pagesInjected;
  final int blocksInjected;
  final int skippedRotatedPages;
  final List<String> fontsEmbedded;
}

/// The public face of the PDF core: extract → translate (elsewhere) → inject.
///
/// Injection never rebuilds the document: it appends an incremental update, so
/// images, vectors, fonts, links, form fields and metadata are byte-identical
/// to the original.
class PdfEngine {
  PdfEngine({
    PdfLayoutExtractor? extractor,
    FontResolver? fonts,
    TextShaper? shaper,
  })  : _extractor = extractor,
        _fonts = fonts,
        _shaper = shaper;

  PdfLayoutExtractor? _extractor;
  FontResolver? _fonts;
  final TextShaper? _shaper;

  /// Loads the bundled fonts (cached after the first call).
  Future<FontResolver> fonts() async => _fonts ??= await FontResolver.load();

  /// Step 1 — map the text layer of the document.
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

  /// Step 3 — write the translations back into the original file.
  ///
  /// [translations] maps block ids (see [TextBlock.id]) to the translated text.
  /// Blocks without an entry keep their original text.
  Future<InjectionReport> injectTranslations({
    required Uint8List sourceBytes,
    required BookLayout layout,
    required Map<String, String> translations,
    bool cloak = true,
    bool shrinkToFit = true,
    double cloakPadding = 0.7,
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

    for (final page in layout.pages) {
      if (page.blocks.isEmpty) continue;
      // Rotated pages keep the author's text: the extracted coordinates live in
      // the rotated space and can not be mapped back reliably.
      if (page.rotation != 0) {
        skippedPages++;
        onLog?.call('page ${page.index + 1}: rotated page left untouched');
        continue;
      }

      final painter = session.painterFor(page.index);
      final usedFonts = <int>{};

      for (final block in page.blocks) {
        final translated = translations[block.id];
        if (translated == null || translated.trim().isEmpty) continue;
        final text = translated.trim();

        // 1. cloak the original glyphs with the sampled page colour
        painter.cover(
          block.box.inflate(
            left: cloakPadding,
            right: cloakPadding,
            top: cloakPadding * 1.6,
            bottom: cloakPadding * 2.2,
          ),
          cloak
              ? block.backgroundColor
              : const PdfColor(1, 1, 1),
        );

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
          shrinkToFit: shrinkToFit,
          paragraphLevel: block.direction == BlockDirection.rtl ? 1 : null,
        ));

        if (result.overflowed) {
          onLog?.call(
              'page ${page.index + 1}: block ${block.id} needed shrinking '
              '(${result.usedSize.toStringAsFixed(1)}pt)');
        }

        // 3. draw it, glyph by glyph, with the font that covers each run
        for (final line in result.lines) {
          for (final chunk in line.chunks) {
            if (chunk.glyphIds.isEmpty) continue;
            usedFonts.add(chunk.fontTag);
            final font = embedded[chunk.fontTag - 1];
            font.record(chunk.glyphIds, chunk.codePointsPerGlyph);
          }
          painter.drawLine(
            x: line.left,
            baselineY: line.baseline,
            size: line.size,
            color: block.textColor,
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
    return InjectionReport(
      bytes: bytes,
      pagesInjected: injectedPages,
      blocksInjected: injectedBlocks,
      skippedRotatedPages: skippedPages,
      fontsEmbedded: resolver.fonts.map((f) => f.descriptor.familyName).toList(),
    );
  }

  static PdfTextAlign _alignOf(TextBlock block) => switch (block.alignment) {
        BlockAlignment.left => block.direction == BlockDirection.rtl
            ? PdfTextAlign.right
            : PdfTextAlign.left,
        BlockAlignment.right => block.direction == BlockDirection.rtl
            ? PdfTextAlign.left
            : PdfTextAlign.right,
        BlockAlignment.center => PdfTextAlign.center,
        BlockAlignment.justify => PdfTextAlign.justify,
      };
}
