import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/job_checkpoint.dart';

/// Durable "where did we stop?" store.
///
/// One JSON file per job inside the application support directory, plus a tiny
/// index so the terminal can offer to resume without asking which file.
class CheckpointRepository {
  CheckpointRepository(this._prefs);

  final SharedPreferences _prefs;

  static const String _indexKey = 'shadow_languages.checkpoints.v1';
  static const Duration maxAge = Duration(days: 14);

  Future<Directory> _directory() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'checkpoints'));
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> _file(String jobId) async =>
      File(p.join((await _directory()).path, '$jobId.json'));

  /// Stable id for a (file, language, model) triple.
  static String jobIdFor({
    required String sourcePath,
    required int sourceSizeBytes,
    required String targetLanguageCode,
    required String model,
  }) =>
      '${sourcePath.hashCode.abs()}_${sourceSizeBytes}_${targetLanguageCode}_${model.replaceAll(RegExp(r'[^a-z0-9]+'), '')}';

  Future<void> save(JobCheckpoint checkpoint) async {
    try {
      final file = await _file(checkpoint.jobId);
      await file.writeAsString(checkpoint.encode(), flush: true);
      await _index(checkpoint.jobId);
    } catch (_) {
      // A failed checkpoint must never break the job: worst case we translate
      // one page again.
    }
  }

  Future<void> _index(String jobId) async {
    final ids = await listIds();
    if (!ids.contains(jobId)) {
      await _prefs.setStringList(_indexKey, [...ids, jobId]);
    }
  }

  Future<List<String>> listIds() async {
    final ids = _prefs.getStringList(_indexKey) ?? const [];
    return ids.toList(growable: false);
  }

  Future<JobCheckpoint?> load(String jobId) async {
    try {
      final file = await _file(jobId);
      if (!file.existsSync()) return null;
      final decoded = jsonDecode(await file.readAsString());
      return JobCheckpoint.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  /// The most recent checkpoint for this exact file/language/model, if any.
  Future<JobCheckpoint?> findFor({
    required String sourcePath,
    required int sourceSizeBytes,
    required String targetLanguageCode,
    required String model,
  }) async {
    final id = jobIdFor(
      sourcePath: sourcePath,
      sourceSizeBytes: sourceSizeBytes,
      targetLanguageCode: targetLanguageCode,
      model: model,
    );
    final checkpoint = await load(id);
    if (checkpoint == null) return null;
    if (!checkpoint.matches(
      sourcePath: sourcePath,
      sourceSizeBytes: sourceSizeBytes,
      targetLanguageCode: targetLanguageCode,
      model: model,
    )) {
      return null;
    }
    if (checkpoint.isComplete) return null;
    if (DateTime.now().difference(checkpoint.updatedAt) > maxAge) return null;
    return checkpoint;
  }

  Future<void> delete(String jobId) async {
    try {
      final file = await _file(jobId);
      if (file.existsSync()) await file.delete();
      final ids = (await listIds()).where((id) => id != jobId).toList();
      await _prefs.setStringList(_indexKey, ids);
    } catch (_) {}
  }

  /// Drops finished and expired checkpoints.
  Future<int> clearStale() async {
    var removed = 0;
    try {
      for (final id in await listIds()) {
        final checkpoint = await load(id);
        final expired = checkpoint == null ||
            checkpoint.isComplete ||
            DateTime.now().difference(checkpoint.updatedAt) > maxAge;
        if (expired) {
          await delete(id);
          removed++;
        }
      }
    } catch (_) {}
    return removed;
  }
}
