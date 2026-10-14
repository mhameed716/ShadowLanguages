import 'dart:convert';

/// A saved, resumable translation job.
///
/// Losing 40 pages of work because the train went into a tunnel is not
/// acceptable, so every finished page is written to disk as soon as it comes
/// back from the neural core. A crash, a 429 or a dead battery then costs at
/// most one page.
class JobCheckpoint {
  const JobCheckpoint({
    required this.jobId,
    required this.sourcePath,
    required this.sourceName,
    required this.sourceSizeBytes,
    required this.targetLanguageCode,
    required this.model,
    required this.pageCount,
    required this.completedPages,
    required this.translations,
    required this.glossary,
    required this.updatedAt,
    this.detectedLanguageCode,
    this.detectedLanguageName,
    this.confidence = 0,
    this.promptTokens = 0,
    this.responseTokens = 0,
  });

  final String jobId;
  final String sourcePath;
  final String sourceName;
  final int sourceSizeBytes;
  final String targetLanguageCode;
  final String model;
  final int pageCount;

  /// Page indices already translated (0 based).
  final List<int> completedPages;

  /// `blockId → translated text` for every completed page.
  final Map<String, String> translations;

  /// Terminology learned so far, so a resumed job keeps the same vocabulary.
  final Map<String, String> glossary;

  final DateTime updatedAt;
  final String? detectedLanguageCode;
  final String? detectedLanguageName;
  final double confidence;
  final int promptTokens;
  final int responseTokens;

  int get completedCount => completedPages.length;

  double get ratio =>
      pageCount <= 0 ? 0 : (completedCount / pageCount).clamp(0.0, 1.0);

  bool get isComplete => pageCount > 0 && completedCount >= pageCount;

  bool matches({
    required String sourcePath,
    required int sourceSizeBytes,
    required String targetLanguageCode,
    required String model,
  }) =>
      this.sourcePath == sourcePath &&
      this.sourceSizeBytes == sourceSizeBytes &&
      this.targetLanguageCode == targetLanguageCode &&
      this.model == model;

  JobCheckpoint copyWith({
    List<int>? completedPages,
    Map<String, String>? translations,
    Map<String, String>? glossary,
    DateTime? updatedAt,
    String? detectedLanguageCode,
    String? detectedLanguageName,
    double? confidence,
    int? promptTokens,
    int? responseTokens,
  }) =>
      JobCheckpoint(
        jobId: jobId,
        sourcePath: sourcePath,
        sourceName: sourceName,
        sourceSizeBytes: sourceSizeBytes,
        targetLanguageCode: targetLanguageCode,
        model: model,
        pageCount: pageCount,
        completedPages: completedPages ?? this.completedPages,
        translations: translations ?? this.translations,
        glossary: glossary ?? this.glossary,
        updatedAt: updatedAt ?? this.updatedAt,
        detectedLanguageCode: detectedLanguageCode ?? this.detectedLanguageCode,
        detectedLanguageName: detectedLanguageName ?? this.detectedLanguageName,
        confidence: confidence ?? this.confidence,
        promptTokens: promptTokens ?? this.promptTokens,
        responseTokens: responseTokens ?? this.responseTokens,
      );

  Map<String, Object?> toJson() => {
        'jobId': jobId,
        'sourcePath': sourcePath,
        'sourceName': sourceName,
        'sourceSizeBytes': sourceSizeBytes,
        'targetLanguageCode': targetLanguageCode,
        'model': model,
        'pageCount': pageCount,
        'completedPages': completedPages,
        'translations': translations,
        'glossary': glossary,
        'updatedAt': updatedAt.toIso8601String(),
        'detectedLanguageCode': detectedLanguageCode,
        'detectedLanguageName': detectedLanguageName,
        'confidence': confidence,
        'promptTokens': promptTokens,
        'responseTokens': responseTokens,
      };

  static JobCheckpoint? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final map = raw.cast<String, Object?>();
    final jobId = map['jobId'];
    if (jobId is! String) return null;
    final pages = map['completedPages'];
    return JobCheckpoint(
      jobId: jobId,
      sourcePath: '${map['sourcePath'] ?? ''}',
      sourceName: '${map['sourceName'] ?? ''}',
      sourceSizeBytes: map['sourceSizeBytes'] is num
          ? (map['sourceSizeBytes']! as num).toInt()
          : 0,
      targetLanguageCode: '${map['targetLanguageCode'] ?? 'ar'}',
      model: '${map['model'] ?? ''}',
      pageCount:
          map['pageCount'] is num ? (map['pageCount']! as num).toInt() : 0,
      completedPages: [
        if (pages is List)
          for (final page in pages)
            if (page is num) page.toInt(),
      ],
      translations: {
        if (map['translations'] is Map)
          for (final entry in (map['translations']! as Map).entries)
            '${entry.key}': '${entry.value}',
      },
      glossary: {
        if (map['glossary'] is Map)
          for (final entry in (map['glossary']! as Map).entries)
            '${entry.key}': '${entry.value}',
      },
      updatedAt: DateTime.tryParse('${map['updatedAt']}') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      detectedLanguageCode: map['detectedLanguageCode']?.toString(),
      detectedLanguageName: map['detectedLanguageName']?.toString(),
      confidence:
          map['confidence'] is num ? (map['confidence']! as num).toDouble() : 0,
      promptTokens:
          map['promptTokens'] is num ? (map['promptTokens']! as num).toInt() : 0,
      responseTokens: map['responseTokens'] is num
          ? (map['responseTokens']! as num).toInt()
          : 0,
    );
  }

  String encode() => jsonEncode(toJson());
}
