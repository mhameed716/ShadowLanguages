import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/app_settings.dart';
import '../../data/models/saved_book.dart';
import '../../data/repositories/checkpoint_repository.dart';
import '../../data/repositories/library_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../services/pdf/pdf_engine.dart';
import '../../services/translation/gemini_client.dart';
import '../../services/translation/onnx/model_manager.dart';
import '../../services/translation/onnx/nllb_translation_client.dart';
import '../../services/translation/onnx/offline_language_identifier.dart';
import '../../services/translation/onnx/ocr/ocr_augmentation.dart';
import '../../services/translation/onnx/ocr/ocr_types.dart';
import '../../services/translation/onnx/ocr/pdf_image_ocr.dart';
import '../../services/translation/rate_limiter.dart';
import '../../services/translation/translation_client.dart';
import '../../services/translation/translation_pipeline.dart';
import '../localization/strings.dart';
import '../logging/log_entry.dart';

// --------------------------------------------------------------- platform
final sharedPreferencesProvider =
    Provider<SharedPreferences>((ref) => throw UnimplementedError('override in main()'));

final secureStorageProvider =
    Provider<FlutterSecureStorage>((ref) => throw UnimplementedError('override in main()'));

// ------------------------------------------------------------ repositories
final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  return SettingsRepository(
    ref.watch(sharedPreferencesProvider),
    ref.watch(secureStorageProvider),
  );
});

final libraryRepositoryProvider = Provider<LibraryRepository>((ref) {
  return LibraryRepository(ref.watch(sharedPreferencesProvider));
});

/// Stores the progress of interrupted jobs so they can be resumed.
final checkpointRepositoryProvider = Provider<CheckpointRepository>((ref) {
  return CheckpointRepository(ref.watch(sharedPreferencesProvider));
});

// ----------------------------------------------------------------- services
final logBusProvider = Provider<LogBus>((ref) => LogBus());

final pdfEngineProvider = Provider<PdfEngine>((ref) => PdfEngine());

final settingsProvider =
    AsyncNotifierProvider<SettingsController, AppSettings>(SettingsController.new);

final geminiClientProvider = Provider<GeminiClient>((ref) {
  final settings = ref.watch(settingsProvider).valueOrNull ?? const AppSettings();
  return GeminiClient(
    apiKey: settings.apiKey,
    model: settings.model,
    temperature: settings.temperature,
  );
});

// ------------------------------------------------------- on-device inference
/// Owns the ONNX sessions: NLLB-200 plus the OCR recognizer.
final modelManagerProvider = Provider<ModelManager>((ref) {
  final settings = ref.watch(settingsProvider).valueOrNull ?? const AppSettings();
  final threads = settings.inferenceThreads.clamp(1, 4);
  final manager = ModelManager(
    log: ref.watch(logBusProvider),
    threads: threads,
  );
  ref.onDispose(manager.dispose);
  return manager;
});

/// Which model files are present right now.
final modelInventoryProvider = FutureProvider<ModelInventory>((ref) async {
  return ref.watch(modelManagerProvider).scan();
});

/// The offline OCR engine (a no-op one when the model is not installed).
final ocrEngineProvider = FutureProvider<OcrEngine>((ref) async {
  return ref.watch(modelManagerProvider).createOcrEngine();
});

final ocrExtractorProvider = FutureProvider<PdfImageOcrExtractor?>((ref) async {
  final settings = ref.watch(settingsProvider).valueOrNull ?? const AppSettings();
  if (!settings.enableOcr) return null;
  final engine = await ref.watch(ocrEngineProvider.future);
  if (!engine.isAvailable) return null;
  return PdfImageOcrExtractor(engine: engine, log: ref.watch(logBusProvider));
});

/// Resolves the engine: on-device NLLB-200 by default, cloud only if the user
/// explicitly switches it on **and** has a key.
final translationClientProvider = FutureProvider<TranslationClient>((ref) async {
  final settings = ref.watch(settingsProvider).valueOrNull ?? const AppSettings();
  final log = ref.watch(logBusProvider);

  if (settings.useOfflineEngine) {
    final manager = ref.watch(modelManagerProvider);
    final engine = await manager.createEngine(
      beamSize: settings.beamSize.clamp(1, 4),
      maxInputTokens: (settings.maxCharactersPerRequest ~/ 4).clamp(64, 448),
    );
    return NllbTranslationClient(
      engine: engine,
      identifier: OfflineLanguageIdentifier(
        uiLanguageCode: settings.interfaceLanguageCode,
      ),
      log: log,
      pauseBetweenBlocks:
          Duration(milliseconds: settings.pauseBetweenBlocksMs.clamp(0, 2000)),
    );
  }

  if (!settings.hasApiKey) {
    throw const TranslationException(
      TranslationErrorKind.missingKey,
      'the cloud engine is switched on but no API key is configured',
    );
  }
  return ref.watch(geminiClientProvider);
});

/// One limiter for the whole app: every worker of every job shares it, so a
/// big book can not flood the API.
final rateLimiterProvider = Provider<RateLimiter>((ref) => RateLimiter());

final translationPipelineProvider = Provider<TranslationPipeline>((ref) {
  final pipeline = TranslationPipeline(
    client: () async {
      final client = await ref.read(translationClientProvider.future);
      await _attachOcr(ref, pipeline);
      return client;
    },
    log: ref.watch(logBusProvider),
    limiter: ref.watch(rateLimiterProvider),
  );
  return pipeline;
});

/// Hooks the offline OCR pass onto the pipeline once the engine is known.
///
/// The OCR engine is only useful together with an on-device translator: sending
/// pixels to a cloud API would break the “nothing leaves the phone” promise.
Future<void> _attachOcr(Ref ref, TranslationPipeline pipeline) async {
  final settings = ref.read(settingsProvider).valueOrNull ?? const AppSettings();
  if (!settings.enableOcr) return;
  final extractor = await ref.read(ocrExtractorProvider.future);
  if (extractor == null) return;
  final augmenter = OcrAugmenter(
    extractor: extractor,
    onLog: ref.read(logBusProvider).info,
  );
  pipeline.ocrAugmenter = augmenter;
}

// -------------------------------------------------------------- localisation
final stringsProvider = Provider<Strings>((ref) {
  final settings = ref.watch(settingsProvider).valueOrNull;
  return Strings(settings?.interfaceLanguageCode ?? 'ar');
});

// ------------------------------------------------------------------ library
final libraryProvider = FutureProvider<List<SavedBook>>((ref) async {
  return ref.watch(libraryRepositoryProvider).listBooks();
});

/// Settings store with optimistic in-memory updates.
class SettingsController extends AsyncNotifier<AppSettings> {
  @override
  Future<AppSettings> build() => ref.read(settingsRepositoryProvider).load();

  /// Applies [updater] and persists the result.
  Future<void> update(AppSettings Function(AppSettings current) updater) async {
    final current = state.valueOrNull ?? const AppSettings();
    final next = updater(current);
    state = AsyncData(next);
    await ref.read(settingsRepositoryProvider).save(next);
  }

  Future<void> setApiKey(String key) => update((s) => s.copyWith(apiKey: key.trim()));

  Future<void> clearApiKey() => update((s) => s.copyWith(apiKey: ''));

  Future<void> setModel(String model) => update((s) => s.copyWith(model: model));

  Future<void> setTemperature(double value) =>
      update((s) => s.copyWith(temperature: value));

  Future<void> setTargetLanguage(String code) =>
      update((s) => s.copyWith(targetLanguageCode: code));

  Future<void> setInterfaceLanguage(String code) =>
      update((s) => s.copyWith(interfaceLanguageCode: code));

  Future<void> setAccent(String accent) => update((s) => s.copyWith(accent: accent));

  Future<void> setReaderTheme(String theme) =>
      update((s) => s.copyWith(readerTheme: theme));

  Future<void> toggle({
    bool? keepNumbers,
    bool? preserveMeaning,
    bool? useGlossary,
    bool? cloak,
    bool? shrinkToFit,
  }) =>
      update((s) => s.copyWith(
            keepNumbers: keepNumbers,
            preserveMeaning: preserveMeaning,
            useGlossary: useGlossary,
            cloak: cloak,
            shrinkToFit: shrinkToFit,
          ));

  Future<void> setConcurrency(int value) =>
      update((s) => s.copyWith(concurrency: value));

  // ------------------------------------------------------- offline engine
  Future<void> setOfflineEngine(bool value) =>
      update((s) => s.copyWith(useOfflineEngine: value));

  Future<void> setOcr(bool value) => update((s) => s.copyWith(enableOcr: value));

  Future<void> setInferenceThreads(int value) =>
      update((s) => s.copyWith(inferenceThreads: value.clamp(1, 4)));

  Future<void> setBeamSize(int value) =>
      update((s) => s.copyWith(beamSize: value.clamp(1, 4)));

  Future<void> setBlockPause(int milliseconds) => update(
      (s) => s.copyWith(pauseBetweenBlocksMs: milliseconds.clamp(0, 2000)));

  Future<void> setMaxCharacters(int value) =>
      update((s) => s.copyWith(maxCharactersPerRequest: value));

  Future<void> completeOnboarding() =>
      update((s) => s.copyWith(onboardingDone: true));
}
