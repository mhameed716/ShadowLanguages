import '../../services/translation/translation_options.dart';

/// Persisted application settings.
class AppSettings {
  const AppSettings({
    this.apiKey = '',
    this.model = 'gemini-2.5-flash',
    this.temperature = 0.2,
    this.targetLanguageCode = 'ar',
    // The app ships Arabic first: the UI, the default target language and the
    // layout direction all follow this value.
    this.interfaceLanguageCode = 'ar',
    this.accent = 'green',
    this.keepNumbers = true,
    this.preserveMeaning = true,
    this.useGlossary = true,
    this.cloak = true,
    this.shrinkToFit = true,
    this.concurrency = 3,
    this.maxCharactersPerRequest = 1800,
    this.readerTheme = 'night',
    this.onboardingDone = false,
  });

  /// Never serialised — lives in the Android Keystore only.
  final String apiKey;
  final String model;
  final double temperature;
  final String targetLanguageCode;
  final String interfaceLanguageCode;
  final String accent;
  final bool keepNumbers;
  final bool preserveMeaning;
  final bool useGlossary;
  final bool cloak;
  final bool shrinkToFit;
  final int concurrency;
  final int maxCharactersPerRequest;
  final String readerTheme;
  final bool onboardingDone;

  bool get hasApiKey => apiKey.trim().isNotEmpty;

  String get apiKeyHint {
    final key = apiKey.trim();
    if (key.length < 4) return '';
    return key.substring(key.length - 4);
  }

  AppSettings copyWith({
    String? apiKey,
    String? model,
    double? temperature,
    String? targetLanguageCode,
    String? interfaceLanguageCode,
    String? accent,
    bool? keepNumbers,
    bool? preserveMeaning,
    bool? useGlossary,
    bool? cloak,
    bool? shrinkToFit,
    int? concurrency,
    int? maxCharactersPerRequest,
    String? readerTheme,
    bool? onboardingDone,
  }) =>
      AppSettings(
        apiKey: apiKey ?? this.apiKey,
        model: model ?? this.model,
        temperature: temperature ?? this.temperature,
        targetLanguageCode: targetLanguageCode ?? this.targetLanguageCode,
        interfaceLanguageCode: interfaceLanguageCode ?? this.interfaceLanguageCode,
        accent: accent ?? this.accent,
        keepNumbers: keepNumbers ?? this.keepNumbers,
        preserveMeaning: preserveMeaning ?? this.preserveMeaning,
        useGlossary: useGlossary ?? this.useGlossary,
        cloak: cloak ?? this.cloak,
        shrinkToFit: shrinkToFit ?? this.shrinkToFit,
        concurrency: concurrency ?? this.concurrency,
        maxCharactersPerRequest:
            maxCharactersPerRequest ?? this.maxCharactersPerRequest,
        readerTheme: readerTheme ?? this.readerTheme,
        onboardingDone: onboardingDone ?? this.onboardingDone,
      );

  /// Builds the [TranslationOptions] handed to the pipeline.
  TranslationOptions toTranslationOptions({
    required String targetLanguageName,
    String? sourceLanguageCode,
    String? sourceLanguageName,
  }) =>
      TranslationOptions(
        targetLanguageCode: targetLanguageCode,
        targetLanguageName: targetLanguageName,
        sourceLanguageCode: sourceLanguageCode,
        sourceLanguageName: sourceLanguageName,
        model: model,
        temperature: temperature,
        keepNumbers: keepNumbers,
        preserveMeaning: preserveMeaning,
        useGlossary: useGlossary,
        concurrency: concurrency,
        maxCharactersPerRequest: maxCharactersPerRequest,
      );

  Map<String, Object?> toJson() => {
        'model': model,
        'temperature': temperature,
        'targetLanguageCode': targetLanguageCode,
        'interfaceLanguageCode': interfaceLanguageCode,
        'accent': accent,
        'keepNumbers': keepNumbers,
        'preserveMeaning': preserveMeaning,
        'useGlossary': useGlossary,
        'cloak': cloak,
        'shrinkToFit': shrinkToFit,
        'concurrency': concurrency,
        'maxCharactersPerRequest': maxCharactersPerRequest,
        'readerTheme': readerTheme,
        'onboardingDone': onboardingDone,
      };

  factory AppSettings.fromJson(Map<String, Object?> json, {String apiKey = ''}) =>
      AppSettings(
        apiKey: apiKey,
        model: '${json['model'] ?? 'gemini-2.5-flash'}',
        temperature: (json['temperature'] as num?)?.toDouble() ?? 0.2,
        targetLanguageCode: '${json['targetLanguageCode'] ?? 'ar'}',
        interfaceLanguageCode: '${json['interfaceLanguageCode'] ?? 'ar'}',
        accent: '${json['accent'] ?? 'green'}',
        keepNumbers: json['keepNumbers'] as bool? ?? true,
        preserveMeaning: json['preserveMeaning'] as bool? ?? true,
        useGlossary: json['useGlossary'] as bool? ?? true,
        cloak: json['cloak'] as bool? ?? true,
        shrinkToFit: json['shrinkToFit'] as bool? ?? true,
        concurrency: (json['concurrency'] as num?)?.toInt() ?? 3,
        maxCharactersPerRequest:
            (json['maxCharactersPerRequest'] as num?)?.toInt() ?? 1800,
        readerTheme: '${json['readerTheme'] ?? 'night'}',
        onboardingDone: json['onboardingDone'] as bool? ?? false,
      );
}
