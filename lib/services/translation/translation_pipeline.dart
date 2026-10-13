import 'dart:async';

import '../../core/logging/log_entry.dart';
import '../../core/utils/job_cancellation.dart';
import '../../data/models/book_layout.dart';
import '../../data/models/text_block.dart';
import 'gemini_client.dart';
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

  static final RegExp _token = RegExp(r'\p{Lu}[\p{L}\-’\']{2,}', unicode: true);

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
  })  : _client = client,
        _log = log;

  final GeminiClient _client;
  final LogBus _log;

  GlossaryMemory glossary = GlossaryMemory();

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
  Future<Map<String, String>> translate({
    required BookLayout layout,
    required TranslationOptions options,
    required JobCancellation cancellation,
    void Function(PipelineProgress progress)? onProgress,
  }) async {
    final translations = <String, String>{};
    final totalBlocks = layout.blockCount;
    var processedBlocks = 0;
    var processedPages = 0;
    var context = '';

    for (final page in layout.pages) {
      cancellation.throwIfCancelled();
      final blocks = page.blocks.where(_isTranslatable).toList(growable: false);
      if (blocks.isEmpty) {
        processedPages++;
        continue;
      }

      _log.info('Translating page ${page.index + 1} to '
          '${options.targetLanguageName} via Neural Core…');

      final batches = _batchOf(blocks, options);
      final results = <BlockTranslation>[];
      await _forEachWithConcurrency(
        batches,
        options.concurrency,
        (batch) async {
          cancellation.throwIfCancelled();
          final translated = await _client.translateBatch(
            blocks: batch,
            options: options,
            context: context,
            glossary: options.useGlossary ? glossary.terms : const {},
            cancellation: cancellation,
          );
          results.addAll(translated);
        },
      );

      final byId = <String, String>{
        for (final t in results) t.id: t.text,
      };
      for (final block in blocks) {
        final value = byId[block.id];
        if (value != null && value.trim().isNotEmpty) {
          translations[block.id] = value.trim();
          if (options.useGlossary) {
            glossary.learnFromPair(block.text, value);
          }
        }
        processedBlocks++;
      }

      final pageText = blocks.map((b) => b.text).join(' ');
      context = pageText.length > options.contextCharacters
          ? pageText.substring(pageText.length - options.contextCharacters)
          : pageText;
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

    return translations;
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
