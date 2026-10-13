/// Everything the neural core needs to know about a translation job.
class TranslationOptions {
  const TranslationOptions({
    required this.targetLanguageCode,
    required this.targetLanguageName,
    this.sourceLanguageCode,
    this.sourceLanguageName,
    this.model = 'gemini-2.5-flash',
    this.temperature = 0.2,
    this.keepNumbers = true,
    this.preserveMeaning = true,
    this.useGlossary = true,
    this.maxCharactersPerRequest = 1800,
    this.maxBlocksPerRequest = 14,
    this.concurrency = 3,
    this.contextCharacters = 420,
  });

  final String targetLanguageCode;
  final String targetLanguageName;
  final String? sourceLanguageCode;
  final String? sourceLanguageName;

  final String model;
  final double temperature;

  final bool keepNumbers;
  final bool preserveMeaning;

  /// Carry terminology across pages so names stay consistent.
  final bool useGlossary;

  final int maxCharactersPerRequest;
  final int maxBlocksPerRequest;
  final int concurrency;

  /// How many characters of the previous page to send as context.
  final int contextCharacters;

  TranslationOptions copyWith({
    String? targetLanguageCode,
    String? targetLanguageName,
    String? sourceLanguageCode,
    String? sourceLanguageName,
    String? model,
    double? temperature,
    bool? keepNumbers,
    bool? preserveMeaning,
    bool? useGlossary,
    int? maxCharactersPerRequest,
    int? maxBlocksPerRequest,
    int? concurrency,
    int? contextCharacters,
  }) =>
      TranslationOptions(
        targetLanguageCode: targetLanguageCode ?? this.targetLanguageCode,
        targetLanguageName: targetLanguageName ?? this.targetLanguageName,
        sourceLanguageCode: sourceLanguageCode ?? this.sourceLanguageCode,
        sourceLanguageName: sourceLanguageName ?? this.sourceLanguageName,
        model: model ?? this.model,
        temperature: temperature ?? this.temperature,
        keepNumbers: keepNumbers ?? this.keepNumbers,
        preserveMeaning: preserveMeaning ?? this.preserveMeaning,
        useGlossary: useGlossary ?? this.useGlossary,
        maxCharactersPerRequest:
            maxCharactersPerRequest ?? this.maxCharactersPerRequest,
        maxBlocksPerRequest: maxBlocksPerRequest ?? this.maxBlocksPerRequest,
        concurrency: concurrency ?? this.concurrency,
        contextCharacters: contextCharacters ?? this.contextCharacters,
      );

  /// Models offered in the config screen.
  static const List<String> availableModels = [
    'gemini-2.5-flash',
    'gemini-2.5-pro',
    'gemini-2.0-flash',
    'gemini-2.0-flash-lite',
  ];
}
