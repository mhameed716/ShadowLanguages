import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/utils/formatters.dart';
import '../models/saved_book.dart';

/// Stores finished books in the app's private documents directory and keeps a
/// small index of them.
class LibraryRepository {
  LibraryRepository(this._prefs);

  static const String _indexKey = 'shadow_languages.library.v1';
  static const String _booksDir = 'books';
  static const String _cacheDir = 'cache';

  final SharedPreferences _prefs;

  Future<Directory> get _documents async => await getApplicationDocumentsDirectory();

  Future<Directory> booksDirectory() async {
    final dir = Directory(p.join((await _documents).path, _booksDir));
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }

  Future<Directory> cacheDirectory() async {
    final dir = Directory(p.join((await _documents).path, _cacheDir));
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }

  /// Writes the translated payload as `shadow_translated_<book>.pdf`.
  Future<SavedBook> saveTranslatedBook({
    required List<int> bytes,
    required String sourceName,
    String? sourcePath,
    required int pageCount,
    required String targetLanguageCode,
  }) async {
    final dir = await booksDirectory();
    var fileName = Formatters.translatedFileName(sourceName);
    var target = File(p.join(dir.path, fileName));
    var counter = 1;
    while (target.existsSync()) {
      final base = fileName.replaceAll(RegExp(r'\.pdf$'), '');
      target = File(p.join(dir.path, '${base}_$counter.pdf'));
      counter++;
    }
    await target.writeAsBytes(bytes, flush: true);
    final book = SavedBook(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: p.basename(target.path),
      path: target.path,
      sourceName: sourceName,
      sourcePath: sourcePath,
      sizeBytes: await target.length(),
      createdAt: DateTime.now(),
      pageCount: pageCount,
      targetLanguageCode: targetLanguageCode,
    );
    await _addToIndex(book);
    return book;
  }

  Future<List<SavedBook>> listBooks() async {
    final raw = _prefs.getString(_indexKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = (jsonDecode(raw) as List).cast<Object?>();
      final books = <SavedBook>[];
      for (final item in list) {
        if (item is! Map) continue;
        final book = SavedBook.fromJson(item.cast<String, Object?>());
        if (File(book.path).existsSync()) books.add(book);
      }
      books.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return books;
    } catch (_) {
      return const [];
    }
  }

  Future<void> deleteBook(SavedBook book) async {
    final file = File(book.path);
    if (file.existsSync()) await file.delete();
    final books = await listBooks();
    books.removeWhere((b) => b.id == book.id);
    await _writeIndex(books);
  }

  Future<void> renameBook(SavedBook book, String newName) async {
    final books = await listBooks();
    final index = books.indexWhere((b) => b.id == book.id);
    if (index < 0) return;
    final dir = await booksDirectory();
    final newPath = p.join(dir.path, newName);
    final file = File(book.path);
    if (file.existsSync() && book.path != newPath) {
      await file.rename(newPath);
    }
    books[index] = SavedBook(
      id: book.id,
      name: newName,
      path: newPath,
      sourceName: book.sourceName,
      sourcePath: book.sourcePath,
      sizeBytes: book.sizeBytes,
      createdAt: book.createdAt,
      pageCount: book.pageCount,
      targetLanguageCode: book.targetLanguageCode,
    );
    await _writeIndex(books);
  }

  /// Copies a book into a folder the user can reach with a file manager
  /// (Android: `Downloads`). Silently ignored when the platform forbids it.
  Future<String?> exportToDownloads(SavedBook book) async {
    Directory? downloads;
    try {
      downloads = await getDownloadsDirectory();
    } catch (_) {
      downloads = null;
    }
    downloads ??= await getExternalStorageDirectory();
    if (downloads == null) return null;
    final target = File(p.join(downloads.path, book.name));
    await target.writeAsBytes(await File(book.path).readAsBytes());
    return target.path;
  }

  /// Deletes every temporary artefact (extracted layouts, previews).
  Future<int> clearCache() async {
    var freed = 0;
    final dir = await cacheDirectory();
    if (dir.existsSync()) {
      await for (final entity in dir.list(recursive: true)) {
        if (entity is File) {
          freed += await entity.length();
          await entity.delete();
        }
      }
    }
    return freed;
  }

  Future<void> _addToIndex(SavedBook book) async {
    final books = await listBooks();
    books.removeWhere((b) => b.id == book.id);
    books.insert(0, book);
    await _writeIndex(books);
  }

  Future<void> _writeIndex(List<SavedBook> books) async {
    final encoded = jsonEncode(books.map((b) => b.toJson()).toList());
    await _prefs.setString(_indexKey, encoded);
  }
}
