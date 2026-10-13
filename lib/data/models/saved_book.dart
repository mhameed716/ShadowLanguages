/// A finished, translated document stored on the device.
class SavedBook {
  const SavedBook({
    required this.id,
    required this.name,
    required this.path,
    required this.sourceName,
    this.sourcePath,
    required this.sizeBytes,
    required this.createdAt,
    required this.pageCount,
    required this.targetLanguageCode,
  });

  final String id;
  final String name;
  final String path;
  final String sourceName;

  /// Path of the untranslated original, when it is still on the device.
  final String? sourcePath;
  final int sizeBytes;
  final DateTime createdAt;
  final int pageCount;
  final String targetLanguageCode;

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'path': path,
        'sourceName': sourceName,
        'sourcePath': sourcePath,
        'sizeBytes': sizeBytes,
        'createdAt': createdAt.toIso8601String(),
        'pageCount': pageCount,
        'targetLanguageCode': targetLanguageCode,
      };

  factory SavedBook.fromJson(Map<String, Object?> json) => SavedBook(
        id: '${json['id']}',
        name: '${json['name']}',
        path: '${json['path']}',
        sourceName: '${json['sourceName']}',
        sourcePath: json['sourcePath'] as String?,
        sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
        createdAt: DateTime.tryParse('${json['createdAt']}') ?? DateTime.now(),
        pageCount: (json['pageCount'] as num?)?.toInt() ?? 0,
        targetLanguageCode: '${json['targetLanguageCode']}',
      );
}
