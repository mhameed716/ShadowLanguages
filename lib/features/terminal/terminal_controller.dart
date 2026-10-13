import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/providers.dart';
import '../../core/localization/strings.dart';
import '../../core/logging/log_entry.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/job_cancellation.dart';
import '../../data/models/app_settings.dart';
import '../../data/models/book_layout.dart';
import '../../data/models/saved_book.dart';
import '../../services/pdf/pdf_engine.dart';
import '../../services/translation/gemini_client.dart';
import '../../services/translation/language_catalog.dart';
import '../../services/translation/translation_options.dart';
import '../../services/translation/translation_pipeline.dart';

/// Where the job currently is.
enum JobStage {
  idle,
  scanning,
  detecting,
  translating,
  injecting,
  saving,
  done,
  failed,
  cancelled,
}

extension JobStageX on JobStage {
  bool get isBusy => switch (this) {
        JobStage.scanning ||
        JobStage.detecting ||
        JobStage.translating ||
        JobStage.injecting ||
        JobStage.saving =>
          true,
        _ => false,
      };

  bool get isTerminal => switch (this) {
        JobStage.done || JobStage.failed || JobStage.cancelled => true,
        _ => false,
      };

  String label(Strings t) => switch (this) {
        JobStage.idle => t('progress_idle'),
        JobStage.scanning => t('progress_extracting'),
        JobStage.detecting => t('progress_detecting'),
        JobStage.translating => t('progress_translating'),
        JobStage.injecting => t('progress_injecting'),
        JobStage.saving => t('progress_saving'),
        JobStage.done => t('progress_done'),
        JobStage.failed => t('progress_failed'),
        JobStage.cancelled => t('progress_cancelled'),
      };
}

/// The document selected by the user.
class PickedFile {
  const PickedFile({
    required this.path,
    required this.name,
    required this.sizeBytes,
  });

  final String path;
  final String name;
  final int sizeBytes;

  bool get exists => File(path).existsSync();
}

/// Everything the terminal screen renders.
class TerminalState {
  const TerminalState({
    this.stage = JobStage.idle,
    this.file,
    this.layout,
    this.detection,
    this.progress = 0,
    this.processedBlocks = 0,
    this.totalBlocks = 0,
    this.processedPages = 0,
    this.totalPages = 0,
    this.errorKey,
    this.errorArgument,
    this.output,
    this.usage = const TokenUsage(),
    this.startedAt,
    this.finishedAt,
    this.glossarySize = 0,
  });

  final JobStage stage;
  final PickedFile? file;
  final BookLayout? layout;
  final LanguageDetection? detection;

  final double progress;
  final int processedBlocks;
  final int totalBlocks;
  final int processedPages;
  final int totalPages;

  /// Key (and optional `{arg}`) of the localised error message.
  final String? errorKey;
  final String? errorArgument;

  final SavedBook? output;
  final TokenUsage usage;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final int glossarySize;

  bool get isBusy => stage.isBusy;
  bool get hasFile => file != null;
  bool get hasOutput => output != null;

  Duration? get elapsed {
    final start = startedAt;
    if (start == null) return null;
    return (finishedAt ?? DateTime.now()).difference(start);
  }

  TerminalState copyWith({
    JobStage? stage,
    PickedFile? file,
    BookLayout? layout,
    LanguageDetection? detection,
    double? progress,
    int? processedBlocks,
    int? totalBlocks,
    int? processedPages,
    int? totalPages,
    String? errorKey,
    String? errorArgument,
    SavedBook? output,
    TokenUsage? usage,
    DateTime? startedAt,
    DateTime? finishedAt,
    int? glossarySize,
    bool clearError = false,
    bool clearFile = false,
    bool clearLayout = false,
    bool clearOutput = false,
  }) =>
      TerminalState(
        stage: stage ?? this.stage,
        file: clearFile ? null : (file ?? this.file),
        layout: clearLayout ? null : (layout ?? this.layout),
        detection: detection ?? this.detection,
        progress: progress ?? this.progress,
        processedBlocks: processedBlocks ?? this.processedBlocks,
        totalBlocks: totalBlocks ?? this.totalBlocks,
        processedPages: processedPages ?? this.processedPages,
        totalPages: totalPages ?? this.totalPages,
        errorKey: clearError ? null : (errorKey ?? this.errorKey),
        errorArgument: clearError ? null : (errorArgument ?? this.errorArgument),
        output: clearOutput ? null : (output ?? this.output),
        usage: usage ?? this.usage,
        startedAt: startedAt ?? this.startedAt,
        finishedAt: finishedAt ?? this.finishedAt,
        glossarySize: glossarySize ?? this.glossarySize,
      );
}

/// Drives the operations hub: pick → scan → detect → translate → inject → save.
class TerminalController extends Notifier<TerminalState> {
  @override
  TerminalState build() => const TerminalState();

  JobCancellation? _cancellation;

  LogBus get _log => ref.read(logBusProvider);
  Strings get _t => ref.read(stringsProvider);

  // ------------------------------------------------------------ file picking
  Future<void> pickFile() async {
    if (state.isBusy) return;
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['pdf'],
        withData: false,
        allowMultiple: false,
      );
      if (result == null || result.files.isEmpty) return;
      final picked = result.files.single;
      final path = picked.path;
      if (path == null) {
        _fail('err_file_missing');
        return;
      }
      final file = PickedFile(
        path: path,
        name: picked.name,
        sizeBytes: picked.size,
      );
      state = state.copyWith(
        file: file,
        clearError: true,
        clearLayout: true,
        clearOutput: true,
        detection: null,
        progress: 0,
        processedBlocks: 0,
        totalBlocks: 0,
        processedPages: 0,
        totalPages: 0,
        stage: JobStage.scanning,
      );
      _log.system(
        'Payload mounted: ${file.name} (${Formatters.bytes(file.sizeBytes)})',
      );
      await _scan(file);
    } on Exception catch (e) {
      _log.error('File picker failed: $e');
    }
  }

  void clearFile() {
    if (state.isBusy) return;
    state = TerminalState();
    _log.system('Payload detached');
  }

  // ------------------------------------------------------------------- scan
  Future<void> _scan(PickedFile file) async {
    try {
      _log.info('Analyzing PDF layout & extracting text blocks…');
      final engine = ref.read(pdfEngineProvider);
      final layout = await engine.extractLayout(
        path: file.path,
        name: file.name,
        onProgress: (index, total) {
          if (index % 10 == 0 || index == total - 1) {
            _log.info('  · parsing page ${index + 1}/$total');
          }
        },
        onLog: _log.warning,
      );

      state = state.copyWith(
        stage: JobStage.idle,
        layout: layout,
        totalBlocks: layout.blockCount,
        totalPages: layout.pageCount,
        clearError: true,
      );

      if (layout.isEmpty) {
        _log.warning('No text layer found — is this a scanned book?');
        _fail('err_pdf_no_text');
        return;
      }
      _log.success(
        'Document parsed: ${layout.pageCount} pages, '
        '${layout.blockCount} translatable blocks',
      );
      await _detect(layout);
    } catch (e, st) {
      _log.error('Layout extraction failed: $e');
      _log.info('$st');
      _fail('err_pdf_invalid');
    }
  }

  Future<void> _detect(BookLayout layout) async {
    final settings = ref.read(settingsProvider).valueOrNull ?? const AppSettings();
    if (!settings.hasApiKey) {
      _log.warning('No API key configured — open CONFIG to add one');
      return;
    }
    state = state.copyWith(stage: JobStage.detecting);
    try {
      final pipeline = ref.read(translationPipelineProvider);
      final detection = await pipeline.detectLanguage(layout);
      state = state.copyWith(
        stage: JobStage.idle,
        detection: detection,
      );
    } on TranslationException catch (e) {
      _log.warning('Language detection failed: ${e.message}');
      state = state.copyWith(stage: JobStage.idle);
    } catch (e) {
      state = state.copyWith(stage: JobStage.idle);
      _log.warning('Language detection skipped: $e');
    }
  }

  Future<void> retryDetection() async {
    final layout = state.layout;
    if (layout == null) return;
    await _detect(layout);
  }

  // -------------------------------------------------------------- translate
  Future<void> start() async {
    final file = state.file;
    final layout = state.layout;
    final settings = ref.read(settingsProvider).valueOrNull ?? const AppSettings();
    if (state.isBusy) return;
    if (file == null) {
      _fail('err_no_file');
      return;
    }
    if (!settings.hasApiKey) {
      _fail('err_no_api_key');
      return;
    }
    if (layout == null || layout.isEmpty) {
      _fail('err_pdf_no_text');
      return;
    }

    final cancellation = JobCancellation();
    _cancellation = cancellation;

    final target = AppLanguageCatalog.byCode(settings.targetLanguageCode);
    final options = settings.toTranslationOptions(
      targetLanguageName: target.name,
      sourceLanguageCode: state.detection?.code,
      sourceLanguageName: state.detection?.name,
    );

    _log.system(
      'Injection profile ready: ${target.name} · ${settings.model} · '
      '${options.concurrency} parallel streams',
    );

    state = state.copyWith(
      stage: JobStage.translating,
      clearError: true,
      clearOutput: true,
      progress: 0,
      processedBlocks: 0,
      processedPages: 0,
      startedAt: DateTime.now(),
      finishedAt: null,
      usage: const TokenUsage(),
    );

    try {
      final pipeline = ref.read(translationPipelineProvider);
      final translations = await pipeline.translate(
        layout: layout,
        options: options,
        cancellation: cancellation,
        onProgress: (progress) {
          state = state.copyWith(
            progress: progress.ratio,
            processedBlocks: progress.processedBlocks,
            processedPages: progress.processedPages,
          );
        },
      );

      if (translations.isEmpty) {
        throw const TranslationException(
            TranslationErrorKind.parse, 'no blocks came back');
      }
      state = state.copyWith(glossarySize: pipeline.glossary.length);

      cancellation.throwIfCancelled();

      // ------------------------------------------------------------ inject
      state = state.copyWith(stage: JobStage.injecting, progress: 1);
      _log.info('Injecting translated text into original coordinates…');
      final engine = ref.read(pdfEngineProvider);
      final sourceBytes = await File(file.path).readAsBytes();
      final report = await engine.injectTranslations(
        sourceBytes: sourceBytes,
        layout: layout,
        translations: translations,
        cloak: settings.cloak,
        shrinkToFit: settings.shrinkToFit,
        onProgress: (index, total) {
          state = state.copyWith(
            processedPages: index + 1,
            totalPages: total,
          );
        },
        onLog: _log.warning,
      );
      _log.success(
        'Embedded profiles: ${report.fontsEmbedded.join(", ")}',
      );

      cancellation.throwIfCancelled();

      // ------------------------------------------------------------- saving
      state = state.copyWith(stage: JobStage.saving);
      _log.info('Writing shadow_translated payload to device storage…');
      final library = ref.read(libraryRepositoryProvider);
      final book = await library.saveTranslatedBook(
        bytes: report.bytes,
        sourceName: file.name,
        sourcePath: file.path,
        pageCount: layout.pageCount,
        targetLanguageCode: settings.targetLanguageCode,
      );
      ref.invalidate(libraryProvider);

      final usage = ref.read(geminiClientProvider).usage;
      final elapsed = state.elapsed ?? Duration.zero;
      state = state.copyWith(
        stage: JobStage.done,
        output: book,
        usage: usage,
        progress: 1,
        finishedAt: DateTime.now(),
      );
      _log.success(
        'Translation complete // ${layout.pageCount} pages // '
        'elapsed ${Formatters.duration(elapsed)}',
      );
      _log.system('Output: ${book.name} (${Formatters.bytes(book.sizeBytes)})');
    } on JobCancelledException {
      state = state.copyWith(stage: JobStage.cancelled, finishedAt: DateTime.now());
      _log.warning('Job aborted by operator');
    } on TranslationException catch (e) {
      _log.error('${e.message}');
      state = state.copyWith(
        stage: JobStage.failed,
        errorKey: _errorKeyFor(e.kind),
        errorArgument: e.statusCode?.toString(),
        finishedAt: DateTime.now(),
      );
    } catch (e, st) {
      _log.error('Unexpected fault: $e');
      _log.info('$st');
      state = state.copyWith(
        stage: JobStage.failed,
        errorKey: 'err_unknown',
        errorArgument: '$e',
        finishedAt: DateTime.now(),
      );
    } finally {
      _cancellation = null;
    }
  }

  void cancel() {
    _cancellation?.cancel();
  }

  Future<void> setTargetLanguage(String code) async {
    await ref.read(settingsProvider.notifier).setTargetLanguage(code);
    _log.system('Target lock set: ${AppLanguageCatalog.byCode(code).name}');
  }

  void _fail(String key) {
    state = state.copyWith(stage: JobStage.failed, errorKey: key, clearError: false);
    _log.error(_t(key));
  }

  static String _errorKeyFor(TranslationErrorKind kind) => switch (kind) {
        TranslationErrorKind.missingKey => 'err_no_api_key',
        TranslationErrorKind.invalidKey => 'err_invalid_key',
        TranslationErrorKind.quota => 'err_quota',
        TranslationErrorKind.server => 'err_server',
        TranslationErrorKind.network => 'err_network',
        TranslationErrorKind.timeout => 'err_timeout',
        TranslationErrorKind.parse => 'err_parse',
        TranslationErrorKind.cancelled => 'err_unknown',
        TranslationErrorKind.unknown => 'err_unknown',
      };
}

final terminalControllerProvider =
    NotifierProvider<TerminalController, TerminalState>(TerminalController.new);
