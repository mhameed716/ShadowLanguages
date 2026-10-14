import 'dart:async';

import '../../core/logging/log_entry.dart';
import '../../core/utils/job_cancellation.dart';
import '../../data/models/book_layout.dart';
import '../../data/models/job_checkpoint.dart';
import '../../data/models/text_block.dart';
import 'gemini_client.dart';
import 'rate_limiter.dart';
import 'translation_options.dart';

/// Terminology memory: keeps the translation of repeated names stable across
/// the whole book.
class GlossaryMemory {
  final Map<String, String> _terms = {};

  int get length => _terms.length;

  Map<String, String> get terms => Map.unmodifiable(_terms);

  void learn(String source, String translated) {
    if (source.trim().length < 3 || translated.trim().isEmpty) return;
    if (source.trim().toLowerCase() == translated.trim().toLowerCase()) return;
    _terms[source.trim()] = translated.trim();
  }

  /// Extracts candidate proper nouns (capitalised tokens) from a pair.
  void learnFromPair(String source, String translated) {
    final sourceNames = _capitalisedTokens(source);
    if (sourceNames.isEmpty) return;
    for (final name in sourceNames) {
      final index = source.indexOf(name);
      if (index < 0) continue;
      // a rough counterpart: the first token of the translation that is not a
      // stop word — good enough to nudge the model towards consistency.
      final candidates = _capitalisedTokens(translated);
      if (candidates.isNotEmpty) {
        learn(name, candidates.first);
      }
    }
  }

  static final RegExp _token =
      RegExp("\\p{Lu}[\\p{L}\\-’']{2,}", unicode: true);

  List<String> _capitalisedTokens(String text) {
    final out = <String>[];
    for (final match in _token.allMatches(text)) {
      final value = match.group(0)!;
      if (out.contains(value)) continue;
      out.add(value);
    }
    return out;
  }
}

/// Progress snapshot emitted while a job runs.
class PipelineProgress {
  const PipelineProgress({
    required this.phase,
    required this.processedPages,
    required this.totalPages,
    required this.processedBlocks,
    required this.totalBlocks,
  });

  final PipelinePhase phase;
  final int processedPages;
  final int totalPages;
  final int processedBlocks;
  final int totalBlocks;

  double get ratio {
    if (totalBlocks <= 0) return 0;
    return (processedBlocks / totalBlocks).clamp(0.0, 1.0);
  }
}

enum PipelinePhase { extracting, detecting, translating, done }

/// Orchestrates detection + batched translation of a whole book.
class TranslationPipeline {
  TranslationPipeline({
    required GeminiClient client,
    required LogBus log,
    RateLimiter? limiter,
    SmartChunker? chunker,
  })  : _client = client,
        _log = log,
        _limiter = limiter ?? RateLimiter(),
        _chunker = chunker ?? const SmartChunker();

  final GeminiClient _client;
  final LogBus _log;

  /// Keeps the request rate inside the API limits.
  final RateLimiter _limiter;

  /// Splits paragraphs that are too big for a single request.
  final SmartChunker _chunker;

  GlossaryMemory glossary = GlossaryMemory();

  /// Refills the glossary with the terminology a previous (interrupted) run
  /// already established, so a resumed book keeps the same vocabulary.
  void restoreGlossary(Map<String, String> terms) {
    if (glossary.length > 0) return;
    for (final entry in terms.entries) {
      glossary.learn(entry.key, entry.value);
    }
  }

  /// Detects the source language from the most representative sample.
  Future<LanguageDetection> detectLanguage(BookLayout layout) async {
    final sample = _sampleText(layout, 1200);
    if (sample.trim().isEmpty) {
      return const LanguageDetection(code: 'und', name: 'Unknown', confidence: 0);
    }
    _log.info('Probing source language from ${sample.length} sampled characters…');
    final detection = await _client.detectLanguage(sample);
    _log.success(
      'Source language detected successfully: [${detection.name} - '
      '${detection.confidence.toStringAsFixed(1)}%]',
    );
    return detection;
  }

  /// Translates every block of the book.
  ///
  /// Blocks are grouped page by page (so the context stays coherent) and then
  /// split into batches small enough for one request.
  ///
  /// Resume: pass [resumeFrom] and every page it contains is restored from disk
  /// instead of being sent again. [onPageCompleted] is called after each page
  /// so the caller can checkpoint it immediately — an interrupted 50 page book
  /// then costs one page, not forty nine.
  Future<Map<String, String>> translate({
    required BookLayout layout,
    required TranslationOptions options,
    JobCancellation? cancellation,
    void Function(PipelineProgress progress)? onProgress,
    JobCheckpoint? resumeFrom,
    void Function(int pageIndex, Map<String, String> pageTranslations)?
        onPageCompleted,
    int? maxPages,
  }) async {
    final translations = <String, String>{};
    final totalBlocks = layout.blockCount;
    var processedBlocks = 0;
    var processedPages = 0;
    var context = '';
    var restoredPages = 0;

    final done = <int>{
      if (resumeFrom != null) ...resumeFrom.completedPages,
    };
    if (resumeFrom != null) {
      translations.addAll(resumeFrom.translations);
      restoreGlossary(resumeFrom.glossary);
      processedPages = resumeFrom.completedPages.length;
      processedBlocks = resumeFrom.translations.length;
    }

    for (final page in layout.pages) {
      cancellation?.throwIfCancelled();
      if (maxPages != null && processedPages >= maxPages) break;
      final blocks = page.blocks.where(_isTranslatable).toList(growable: false);
      if (blocks.isEmpty) {
        processedPages++;
        continue;
      }

      // ------------------------------------------------------- resume a page
      if (done.contains(page.index)) {
        final restored = <String, String>{
          for (final block in blocks)
            if (translations.containsKey(block.id)) block.id: translations[block.id]!,
        };
        restoredPages++;
        final pageText = blocks.map((b) => b.text).join(' ');
        context = _tail(context, pageText, options.contextCharacters);
        onProgress?.call(PipelineProgress(
          phase: PipelinePhase.translating,
          processedPages: processedPages,
          totalPages: layout.pageCount,
          processedBlocks: processedBlocks,
          totalBlocks: totalBlocks,
        ));
        if (restored.isNotEmpty) {
          _log.info('Page ${page.index + 1}: restored from checkpoint '
              '(${restored.length} blocks, no request sent)');
        }
        continue;
      }

      _log.info('Translating page ${page.index + 1} to '
          '${options.targetLanguageName} via Neural Core…');

      // A single monster paragraph must never blow the request up: split it
      // into sentence sized pieces and stitch the answer back together.
      final exploded = _explode(blocks, options);
      final batches = _batchOf(exploded.blocks, options);
      final results = <BlockTranslation>[];
      await _forEachWithConcurrency(
        batches,
        options.concurrency,
        (batch) async {
          cancellation?.throwIfCancelled();
          await _limiter.acquire();
          try {
            final translated = await _client.translateBatch(
              blocks: batch,
              options: options,
              context: context,
              glossary: options.useGlossary ? glossary.terms : const {},
              cancellation: cancellation,
            );
            _limiter.success();
            results.addAll(translated);
          } on TranslationException catch (e) {
            if (e.kind == TranslationErrorKind.quota ||
                e.kind == TranslationErrorKind.rateLimit) {
              final wait = _limiter.failure(retryAfter: e.retryAfter);
              _log.warning(
                  'API limit hit — cooling down ${wait.inSeconds}s before '
                  'continuing');
              // The page is simply retried by the caller/resume path.
            } else {
              _limiter.failure();
            }
            rethrow;
          } catch (_) {
            _limiter.failure();
            rethrow;
          }
        },
      );

      final byId = <String, String>{
        for (final t in results) t.id: t.text,
      };
      final pageTranslations = <String, String>{};
      for (final block in exploded.blocks) {
        final value = byId[block.id];
        if (value != null && value.trim().isNotEmpty) {
          final target = exploded.originalIdOf(block.id);
          final text = value.trim();
          exploded.mergeInto(pageTranslations, target, block.id, text);
          translations[target] = pageTranslations[target] ?? text;
          if (options.useGlossary && target == block.id) {
            glossary.learnFromPair(block.text, text);
          }
        }
        if (exploded.isPrimary(block.id)) processedBlocks++;
      }
      if (pageTranslations.isNotEmpty) {
        translations.addAll(pageTranslations);
        onPageCompleted?.call(page.index, pageTranslations);
      }

      final pageText = blocks.map((b) => b.text).join(' ');
      context = _tail(context, pageText, options.contextCharacters);
      processedPages++;

      _log.success(
        'Page ${page.index + 1}: ${blocks.length} blocks translated '
        '(${_charsIn(results)} chars)',
      );
      onProgress?.call(PipelineProgress(
        phase: PipelinePhase.translating,
        processedPages: processedPages,
        totalPages: layout.pageCount,
        processedBlocks: processedBlocks,
        totalBlocks: totalBlocks,
      ));
    }

    if (restoredPages > 0) {
      _log.info('Resumed: $restoredPages page(s) came from the checkpoint, '
          'no tokens spent on them');
    }

    return translations;
  }

  static String _tail(String previous, String pageText, int maxChars) {
    final combined = previous.isEmpty ? pageText : '$previous $pageText';
    return combined.length > maxChars
        ? combined.substring(combined.length - maxChars)
        : combined;
  }

  /// Splits blocks that are longer than one request may carry.
  _ExplodedBlocks _explode(
      List<TextBlock> blocks, TranslationOptions options) {
    final limit = options.maxCharactersPerRequest;
    final out = <TextBlock>[];
    final parents = <String, String>{};
    for (final block in blocks) {
      if (block.text.length <= limit) {
        out.add(block);
        continue;
      }
      final pieces = _chunker.chunk(block.text);
      if (pieces.length <= 1) {
        out.add(block);
        continue;
      }
      for (var i = 0; i < pieces.length; i++) {
        final id = '${block.id}#$i';
        parents[id] = block.id;
        out.add(block.copyWith(text: pieces[i]));
      }
      _log.info('Block ${block.id} split into ${pieces.length} pieces '
          '(too long for one request)');
    }
    return _ExplodedBlocks(out, parents);
  }

/// The result of splitting oversized blocks into request sized pieces.
class _ExplodedBlocks {
  _ExplodedBlocks(this.blocks, this._parents);

  /// Blocks as they are sent: originals plus the synthetic pieces, always in
  /// reading order so stitching the answers back together is deterministic.
  final List<TextBlock> blocks;

  /// `piece id → original block id`.
  final Map<String, String> _parents;

  bool isPrimary(String id) => !_parents.containsKey(id);

  String originalIdOf(String id) => _parents[id] ?? id;

  /// Appends [text] to [out] under [target], keeping the piece order.
  void mergeInto(
      Map<String, String> out, String target, String pieceId, String text) {
    if (pieceId == target) {
      out[target] = text;
      return;
    }
    final current = out[target];
    out[target] = current == null || current.isEmpty ? text : '$current $text';
  }
}

  static int _charsIn(List<BlockTranslation> items) =>
      items.fold<int>(0, (s, t) => s + t.text.length);

  bool _isTranslatable(TextBlock block) {
    final text = block.text.trim();
    if (text.length < 2) return false;
    // purely numeric blocks (page numbers, tables of figures) are left alone
    if (block.isNumeric) return false;
    return true;
  }

  List<List<TextBlock>> _batchOf(
    List<TextBlock> blocks,
    TranslationOptions options,
  ) {
    final batches = <List<TextBlock>>[];
    var current = <TextBlock>[];
    var chars = 0;
    for (final block in blocks) {
      final length = block.text.length;
      final tooLong = chars + length > options.maxCharactersPerRequest &&
          current.isNotEmpty;
      final tooMany = current.length >= options.maxBlocksPerRequest;
      if (tooLong || tooMany) {
        batches.add(current);
        current = <TextBlock>[];
        chars = 0;
      }
      current.add(block);
      chars += length;
    }
    if (current.isNotEmpty) batches.add(current);
    return batches;
  }

  Future<void> _forEachWithConcurrency<T>(
    List<T> items,
    int concurrency,
    Future<void> Function(T item) action,
  ) async {
    if (items.isEmpty) return;
    final limit = concurrency < 1 ? 1 : concurrency;
    var index = 0;
    final workers = <Future<void>>[];
    for (var w = 0; w < limit && w < items.length; w++) {
      workers.add(_worker(items, () => index++, action));
    }
    await Future.wait(workers);
  }

  Future<void> _worker<T>(
    List<T> items,
    int Function() nextIndex,
    Future<void> Function(T item) action,
  ) async {
    while (true) {
      final i = nextIndex();
      if (i >= items.length) return;
      await action(items[i]);
    }
  }

  static String _sampleText(BookLayout layout, int maxChars) {
    final buffer = StringBuffer();
    for (final page in layout.pages) {
      for (final block in page.blocks) {
        buffer.writeln(block.text);
        if (buffer.length > maxChars) {
          return buffer.toString().substring(0, maxChars);
        }
      }
    }
    return buffer.toString();
  }
}
