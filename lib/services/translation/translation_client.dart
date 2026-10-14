import '../../core/utils/job_cancellation.dart';
import '../../data/models/text_block.dart';
import 'gemini_client.dart' show BlockTranslation, LanguageDetection;
import 'translation_options.dart';

/// The contract the pipeline talks to.
///
/// Two engines implement it:
///
/// * [NllbTranslationClient] — the **default**, runs NLLB-200 on the phone with
///   ONNX Runtime. No network, no key, no quota.
/// * `GeminiClient` — optional, kept for users who explicitly enable the cloud
///   engine in the settings.
///
/// The pipeline must not know which one it holds: everything below this
/// interface (chunking, paging, checkpoints, glossary) behaves identically.
abstract interface class TranslationClient {
  /// True when the engine never touches the network.
  bool get isOffline;

  /// Short name for the log lines, e.g. `NLLB-200 (on-device)`.
  String get displayName;

  /// Identifies the language of [sample].
  Future<LanguageDetection> detectLanguage(String sample);

  /// Translates one batch of blocks.
  ///
  /// [context] is the tail of the previous page (coherence), [glossary] the
  /// terminology learned so far.
  Future<List<BlockTranslation>> translateBatch({
    required List<TextBlock> blocks,
    required TranslationOptions options,
    String context,
    Map<String, String> glossary,
    JobCancellation? cancellation,
  });
}
