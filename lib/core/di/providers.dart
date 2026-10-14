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
import '../../services/translation/rate_limiter.dart';
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

/// One limiter for the whole app: every worker of every job shares it, so a
/// big book can not flood the API.
final rateLimiterProvider = Provider<RateLimiter>((ref) => RateLimiter());

final translationPipelineProvider = Provider<TranslationPipeline>((ref) {
  return TranslationPipeline(
    client: ref.watch(geminiClientProvider),
    log: ref.watch(logBusProvider),
    limiter: ref.watch(rateLimiterProvider),
  );
});

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

  Future<void> setMaxCharacters(int value) =>
      update((s) => s.copyWith(maxCharactersPerRequest: value));

  Future<void> completeOnboarding() =>
      update((s) => s.copyWith(onboardingDone: true));
}
