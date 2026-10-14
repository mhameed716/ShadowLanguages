import '../../../core/logging/log_entry.dart';
import '../../../core/utils/job_cancellation.dart';
import '../../../data/models/text_block.dart';
import '../gemini_client.dart'
    show BlockTranslation, LanguageDetection, TranslationErrorKind,
        TranslationException;
import '../rate_limiter.dart';
import '../translation_client.dart';
import '../translation_options.dart';
import 'flores.dart';
import 'nllb_engine.dart';
import 'offline_language_identifier.dart';

/// The on-device engine: NLLB-200 through ONNX Runtime.
///
/// Everything happens in the process — the text never leaves the phone, there
/// is no key, no quota and no network permission involved. What it does need is
/// discipline around **memory and heat**, so:
///
/// * every block is chunked into sentence sized windows before it is encoded —
///   a 4 000 character paragraph would otherwise build a 4 000² attention
///   matrix and stall a mid-range phone for a minute;
/// * requests are translated **sequentially**. Running two decoders in parallel
///   doubles the peak memory for almost no gain, and thermal throttling makes
///   it slower anyway;
/// * a short pause between blocks lets the CPU step down, which is the
///   difference between finishing a 300 page book and cooking the battery.
class NllbTranslationClient implements TranslationClient {
  NllbTranslationClient({
    required NllbEngine engine,
    required this.identifier,
    SmartChunker? chunker,
    LogBus? log,
    this.pauseBetweenBlocks = const Duration(milliseconds: 0),
    this.maxInputTokens = 320,
  })  : _engine = engine,
        // One encoder pass must fit in [maxInputTokens], so the chunker is
        // sized from the token budget — not from the API's 1 800 characters.
        _chunker = chunker ?? SmartChunker(maxCharacters: maxInputTokens * 3),
        _log = log;

  final NllbEngine _engine;
  final OfflineLanguageIdentifier identifier;
  final SmartChunker _chunker;
  final LogBus? _log;

  /// Cool-down between two blocks (0 by default; the settings screen can raise
  /// it for long books on weak phones).
  final Duration pauseBetweenBlocks;

  /// Characters per encoder pass — tuned so a chunk is one or two sentences.
  final int maxInputTokens;

  @override
  bool get isOffline => true;

  @override
  String get displayName => 'NLLB-200 (on-device)';

  /// How many characters fit in one encoder pass.
  ///
  /// A SentencePiece token is roughly 3.5 latin characters, but only ~2 for
  /// Arabic/Devanagari after the byte fallback, so we stay conservative.
  int get _charBudget => maxInputTokens * 3;

  NllbStats get stats => _engine.stats;

  // ---------------------------------------------------------------- detection

  @override
  Future<LanguageDetection> detectLanguage(String sample) async {
    final detection = identifier.identify(sample);
    if (detection.code == 'und') return detection;
    _log?.info('Neural core offline: language scored on device '
        '(${detection.name})');
    return detection;
  }

  // --------------------------------------------------------------- translate

  @override
  Future<List<BlockTranslation>> translateBatch({
    required List<TextBlock> blocks,
    required TranslationOptions options,
    String context = '',
    Map<String, String> glossary = const {},
    JobCancellation? cancellation,
  }) async {
    if (blocks.isEmpty) return const [];

    final target = _targetOf(options);
    final source = _sourceOf(options);

    final out = <BlockTranslation>[];
    for (final block in blocks) {
      cancellation?.throwIfCancelled();
      final text = block.text.trim();
      if (text.isEmpty) continue;

      try {
        final translated = await _translateOne(
          text,
          target: target,
          source: source,
          glossary: glossary,
          cancellation: cancellation,
        );
        out.add(BlockTranslation(id: block.id, text: translated));
      } on NllbException catch (e) {
        throw TranslationException(
            TranslationErrorKind.unknown, e.message);
      } catch (e) {
        rethrow;
      }

      if (pauseBetweenBlocks > Duration.zero) {
        await Future<void>.delayed(pauseBetweenBlocks);
      }
    }
    return out;
  }

  Future<String> _translateOne(
    String text, {
    required FloresLanguage target,
    FloresLanguage? source,
    required Map<String, String> glossary,
    JobCancellation? cancellation,
  }) async {
    // A long paragraph is split on sentence boundaries and translated piece by
    // piece; the pieces are stitched back with the original spacing.
    if (text.length <= _charBudget) {
      final withGlossary = _applyGlossary(text, glossary);
      return _post(
        await _engine.translate(
          withGlossary,
          target: target,
          source: source,
          cancellation: cancellation,
        ),
      );
    }

    final pieces = _chunker.chunk(text);
    final buffer = StringBuffer();
    for (final piece in pieces) {
      cancellation?.throwIfCancelled();
      final withGlossary = _applyGlossary(piece, glossary);
      final translated = await _engine.translate(
        withGlossary,
        target: target,
        source: source,
        cancellation: cancellation,
      );
      final cleaned = _post(translated);
      if (cleaned.isEmpty) continue;
      if (buffer.isNotEmpty) buffer.write(' ');
      buffer.write(cleaned);
    }
    final result = buffer.toString();
    return result.isEmpty ? _post(text) : result;
  }

  /// Nudges the decoder with the terminology we already agreed on.
  ///
  /// NLLB has no instruction channel, so the glossary is injected as a short
  /// “X = Y” preamble… which costs tokens and can leak into the output. We only
  /// do it when the block actually contains a known term, and we strip the
  /// preamble back out afterwards.
  String _applyGlossary(String text, Map<String, String> glossary) {
    if (glossary.isEmpty) return text;
    final hits = <String>[];
    for (final entry in glossary.entries) {
      if (text.contains(entry.key)) hits.add('${entry.key} = ${entry.value}');
    }
    if (hits.isEmpty) return text;
    return '${hits.take(6).join(' ; ')}\n$text';
  }

  /// Tidies the decoder output: drops the echoed glossary preamble and any
  /// stray language token, and normalises whitespace.
  String _post(String text) {
    var value = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final newline = value.indexOf('\n');
    if (newline >= 0 && newline < value.length - 1 && value.contains(' = ')) {
      value = value.substring(newline + 1).trim();
    }
    for (final language in FloresCatalog.languages) {
      if (value.startsWith('${language.code} ')) {
        value = value.substring(language.code.length).trim();
        break;
      }
    }
    return value;
  }

  FloresLanguage _targetOf(TranslationOptions options) {
    final code = options.targetLanguageCode;
    if (FloresCatalog.knows(code)) return FloresCatalog.byCode(code);
    return FloresCatalog.fromBcp47(code);
  }

  FloresLanguage? _sourceOf(TranslationOptions options) {
    final code = options.sourceLanguageCode;
    if (code == null || code.isEmpty || code == 'auto' || code == 'und') {
      return null;
    }
    if (FloresCatalog.knows(code)) return FloresCatalog.byCode(code);
    final mapped = FloresCatalog.fromBcp47(code);
    // `fromBcp47` falls back to English; better to let NLLB infer the source
    // than to force a wrong one.
    return mapped.code == 'eng_Latn' && code.toLowerCase() != 'en'
        ? null
        : mapped;
  }
}
