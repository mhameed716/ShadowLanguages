import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/providers.dart';
import '../../core/error/failure.dart';
import '../../core/localization/strings.dart';
import '../../core/logging/log_entry.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/job_cancellation.dart';
import '../../data/models/app_settings.dart';
import '../../data/models/book_layout.dart';
import '../../data/models/job_checkpoint.dart';
import '../../data/models/saved_book.dart';
import '../../data/repositories/checkpoint_repository.dart';
import '../../services/pdf/extraction/overlap_detector.dart';
import '../../services/pdf/layout/font_coverage.dart';
import '../../services/pdf/pdf_engine.dart';
import '../../services/pdf/pdf_validator.dart';
import '../../services/pdf/verification/layout_verifier.dart';
import '../../services/translation/gemini_client.dart';
import '../../services/translation/language_catalog.dart';
import '../../services/translation/translation_pipeline.dart';

/// Where the job currently is.
enum JobStage {
  idle,
  validating,
  scanning,
  detecting,
  translating,
  injecting,
  verifying,
  saving,
  done,
  failed,
  cancelled,
}

extension JobStageX on JobStage {
  bool get isBusy => switch (this) {
        JobStage.validating ||
        JobStage.scanning ||
        JobStage.detecting ||
        JobStage.translating ||
        JobStage.injecting ||
        JobStage.verifying ||
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
        JobStage.validating => t('progress_validating'),
        JobStage.scanning => t('progress_extracting'),
        JobStage.detecting => t('progress_detecting'),
        JobStage.translating => t('progress_translating'),
        JobStage.injecting => t('progress_injecting'),
        JobStage.verifying => t('progress_verifying'),
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
    this.password,
  });

  final String path;
  final String name;
  final int sizeBytes;

  /// Password for an encrypted document (kept in memory only).
  final String? password;

  bool get exists => File(path).existsSync();

  PickedFile copyWith({String? password}) => PickedFile(
        path: path,
        name: name,
        sizeBytes: sizeBytes,
        password: password ?? this.password,
      );
}

/// What the pre-flight found out about the book before spending a token.
class PreflightReport {
  const PreflightReport({
    required this.pages,
    required this.blocks,
    required this.characters,
    required this.estimatedRequests,
    required this.font,
    this.placements,
    this.warnings = const [],
  });

  final int pages;
  final int blocks;
  final int characters;
  final int estimatedRequests;
  final FontCoverageReport font;
  final PlacementAnalysis? placements;

  /// Human readable cautions (partial font coverage, artwork collisions…).
  final List<String> warnings;

  bool get hasWarnings => warnings.isNotEmpty;
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
    this.failure,
    this.output,
    this.usage = const TokenUsage(),
    this.startedAt,
    this.finishedAt,
    this.glossarySize = 0,
    this.validation,
    this.askingPassword = false,
    this.preflight,
    this.checkpoint,
    this.verification,
    this.offline = false,
    this.ocrBlocks = 0,
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

  /// The last failure, already mapped to a localised message + recovery.
  final Failure? failure;

  final SavedBook? output;
  final TokenUsage usage;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final int glossarySize;

  /// Result of the file pre-flight check.
  final PdfValidation? validation;

  /// The document is protected and we are waiting for the password.
  final bool askingPassword;

  /// Cost / risk estimate computed before the first request.
  final PreflightReport? preflight;

  /// Saved progress of an interrupted job, if any.
  final JobCheckpoint? checkpoint;

  /// Pixel diff between the original and the translated document.
  final VerificationReport? verification;

  /// The device had no usable connection when the job was started.
  final bool offline;

  /// Text regions the offline OCR found inside page images.
  final int ocrBlocks;

  bool get isBusy => stage.isBusy;
  bool get hasFile => file != null;
  bool get hasOutput => output != null;
  bool get hasFailure => failure != null;
  bool get canResume =>
      failure != null && checkpoint != null && (checkpoint?.completedCount ?? 0) > 0;

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
    Failure? failure,
    SavedBook? output,
    TokenUsage? usage,
    DateTime? startedAt,
    DateTime? finishedAt,
    int? glossarySize,
    PdfValidation? validation,
    bool? askingPassword,
    PreflightReport? preflight,
    JobCheckpoint? checkpoint,
    VerificationReport? verification,
    bool? offline,
    int? ocrBlocks,
    bool clearFailure = false,
    bool clearFile = false,
    bool clearLayout = false,
    bool clearOutput = false,
    bool clearDetection = false,
    bool clearValidation = false,
    bool clearPreflight = false,
    bool clearCheckpoint = false,
    bool clearVerification = false,
  }) =>
      TerminalState(
        stage: stage ?? this.stage,
        file: clearFile ? null : (file ?? this.file),
        layout: clearLayout ? null : (layout ?? this.layout),
        detection: clearDetection ? null : (detection ?? this.detection),
        progress: progress ?? this.progress,
        processedBlocks: processedBlocks ?? this.processedBlocks,
        totalBlocks: totalBlocks ?? this.totalBlocks,
        processedPages: processedPages ?? this.processedPages,
        totalPages: totalPages ?? this.totalPages,
        failure: clearFailure ? null : (failure ?? this.failure),
        output: clearOutput ? null : (output ?? this.output),
        usage: usage ?? this.usage,
        startedAt: startedAt ?? this.startedAt,
        finishedAt: finishedAt ?? this.finishedAt,
        glossarySize: glossarySize ?? this.glossarySize,
        validation: clearValidation ? null : (validation ?? this.validation),
        askingPassword: askingPassword ?? this.askingPassword,
        preflight: clearPreflight ? null : (preflight ?? this.preflight),
        checkpoint: clearCheckpoint ? null : (checkpoint ?? this.checkpoint),
        verification:
            clearVerification ? null : (verification ?? this.verification),
        offline: offline ?? this.offline,
        ocrBlocks: ocrBlocks ?? this.ocrBlocks,
      );
}

/// Drives the operations hub:
///
/// pick → **validate** → scan → detect → **pre-flight** → translate →
/// **analyse collisions** → inject → **verify** → save.
///
/// Every step is guarded: a failure becomes a [Failure] with a localised
/// message, a log entry and the recovery actions that make sense (retry,
/// resume from the checkpoint, enter a password…). No step can throw into the
/// UI.
class TerminalController extends Notifier<TerminalState> {
  @override
  TerminalState build() => const TerminalState();

  JobCancellation? _cancellation;
  Uint8List? _sourceBytes;

  LogBus get _log => ref.read(logBusProvider);

  /// Identity of the engine, so a checkpoint made with NLLB is never reused by
  /// the cloud engine (and the other way round).
  String get _engineName {
    final settings = ref.read(settingsProvider).valueOrNull ?? const AppSettings();
    return settings.useOfflineEngine ? 'nllb-200-distilled-600M' : settings.model;
  }
  Strings get _t => ref.read(stringsProvider);
  PdfEngine get _engine => ref.read(pdfEngineProvider);
  CheckpointRepository get _checkpoints =>
      ref.read(checkpointRepositoryProvider);

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
        _fail(Failure(FailureKind.fileMissing, messageKey: 'err_file_missing'));
        return;
      }
      final file = PickedFile(
        path: path,
        name: picked.name,
        sizeBytes: picked.size,
      );
      state = state.copyWith(
        file: file,
        clearFailure: true,
        clearLayout: true,
        clearOutput: true,
        clearDetection: true,
        clearPreflight: true,
        clearVerification: true,
        clearCheckpoint: true,
        progress: 0,
        processedBlocks: 0,
        totalBlocks: 0,
        processedPages: 0,
        totalPages: 0,
        stage: JobStage.validating,
      );
      _log.system(
        'Payload mounted: ${file.name} (${Formatters.bytes(file.sizeBytes)})',
      );
      await _validate(file);
    } on Exception catch (e, st) {
      _fail(Failure.from(e, stack: st));
    }
  }

  /// Step 0 — refuse broken, empty, huge or protected files immediately.
  Future<void> _validate(PickedFile file) async {
    try {
      _log.info('Verifying integrity of the payload…');
      final validation = await _engine.validate(file.path);
      state = state.copyWith(validation: validation);

      if (validation.isFatal) {
        if (validation.needsPassword) {
          _log.warning('Document is password protected — operator input needed');
          state = state.copyWith(
            stage: JobStage.idle,
            askingPassword: true,
            failure: Failure(
              FailureKind.pdfEncrypted,
              messageKey: 'err_pdf_encrypted',
            ),
          );
          return;
        }
        _log.error(_t(validation.messageKey, {'message': validation.detail ?? ''}));
        state = state.copyWith(
          stage: JobStage.failed,
          failure: validation.toFailure(),
          finishedAt: DateTime.now(),
        );
        return;
      }
      if (validation.status == PdfValidationStatus.repairable) {
        _log.warning(
            '${_t(validation.messageKey)} — continuing with the recovered copy');
      }
      _log.success(
        '${_t('log_valid')} ${validation.version ?? ''} · '
        '${validation.pageCount} pages',
      );
      state = state.copyWith(stage: JobStage.scanning);
      await _scan(file);
    } on Exception catch (e, st) {
      _fail(Failure.from(e, stack: st));
    }
  }

  /// Called by the UI when the user submits the password of a locked file.
  Future<bool> submitPassword(String password) async {
    final file = state.file;
    if (file == null) return false;
    state = state.copyWith(stage: JobStage.validating);
    _log.info('Trying password…');
    try {
      final result = await _engine.unlock(file.path, password);
      if (result != PdfUnlockResult.opened) {
        _log.error(_t('err_pdf_password'));
        state = state.copyWith(
          stage: JobStage.idle,
          askingPassword: true,
          failure: Failure(
            FailureKind.pdfWrongPassword,
            messageKey: 'err_pdf_password',
            canRetry: true,
          ),
        );
        return false;
      }
      _log.success('Document unlocked');
      state = state.copyWith(
        file: file.copyWith(password: password),
        askingPassword: false,
        clearFailure: true,
        stage: JobStage.scanning,
      );
      await _scan(file.copyWith(password: password));
      return true;
    } on Exception catch (e, st) {
      _fail(Failure.from(e, stack: st));
      return false;
    }
  }

  /// Re-opens the password prompt (used by the error card).
  void requestPassword() {
    state = state.copyWith(askingPassword: true);
  }

  void cancelPassword() {
    state = state.copyWith(
      askingPassword: false,
      stage: JobStage.idle,
      clearFailure: true,
    );
  }

  void clearFile() {
    if (state.isBusy) return;
    _sourceBytes = null;
    state = const TerminalState();
    _log.system('Payload detached');
  }

  // ------------------------------------------------------------------- scan
  Future<void> _scan(PickedFile file) async {
    try {
      _log.info('Analyzing PDF layout & extracting text blocks…');
      final layout = await _engine.extractLayout(
        path: file.path,
        name: file.name,
        password: file.password,
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
        clearFailure: true,
      );

      if (layout.isEmpty) {
        _log.warning('No text layer found — is this a scanned book?');
        _fail(Failure(
          FailureKind.pdfNoText,
          messageKey: 'err_pdf_no_text',
        ));
        return;
      }
      _log.success(
        'Document parsed: ${layout.pageCount} pages, '
        '${layout.blockCount} translatable blocks',
      );

      final withImages = await _readImages(file, layout);
      await _loadCheckpoint(file, withImages);
      await _detect(withImages);
      unawaited(_buildPreflight(file, withImages));
    } on Exception catch (e, st) {
      _log.error('Layout extraction failed: $e');
      _fail(Failure.from(e, stack: st));
    }
  }

  /// Runs the offline OCR pass so the words inside page images are translated
  /// too. Failures are logged, never fatal: the book still gets translated,
  /// only the picture captions stay in their original language.
  Future<BookLayout> _readImages(PickedFile file, BookLayout layout) async {
    final settings = ref.read(settingsProvider).valueOrNull ?? const AppSettings();
    if (!settings.enableOcr) return layout;
    try {
      _log.info(_t('ocr_scanning'));
      Uint8List bytes;
      try {
        bytes = _sourceBytes ??= await File(file.path).readAsBytes();
      } catch (e) {
        _log.warning('OCR skipped: the source could not be cached ($e)');
        return layout;
      }
      final pipeline = ref.read(translationPipelineProvider);
      final result = await pipeline.readImagesInPages(
        sourceBytes: bytes,
        layout: layout,
        password: file.password,
        onProgress: (index, total) {
          if (index % 10 == 0) {
            _log.info('  · image scan ${index + 1}/$total');
          }
        },
      );
      if (result.blocksFound == 0) return layout;
      state = state.copyWith(
        layout: result.layout,
        totalBlocks: result.layout.blockCount,
        ocrBlocks: result.blocksFound,
      );
      _log.success(
        'OCR: ${result.blocksFound} text region(s) recovered from images '
        '(${result.pagesScanned} page(s) scanned) — they are drawn over the '
        'picture with a halo so the artwork stays visible',
      );
      return result.layout;
    } on JobCancelledException {
      rethrow;
    } catch (e) {
      _log.warning('OCR pass skipped: $e');
      return layout;
    }
  }

  Future<void> _loadCheckpoint(PickedFile file, BookLayout layout) async {
    final settings = ref.read(settingsProvider).valueOrNull ?? const AppSettings();
    try {
      final checkpoint = await _checkpoints.findFor(
        sourcePath: file.path,
        sourceSizeBytes: file.sizeBytes,
        targetLanguageCode: settings.targetLanguageCode,
        model: _engineName,
      );
      if (checkpoint == null) return;
      state = state.copyWith(checkpoint: checkpoint);
      _log.warning(
        'Recovered checkpoint: ${checkpoint.completedCount}/${checkpoint.pageCount} '
        'pages already translated (${Formatters.percent(checkpoint.ratio)})',
      );
    } catch (_) {
      // A missing checkpoint is not an error: we simply start from scratch.
    }
  }

  Future<void> _detect(BookLayout layout) async {
    final settings = ref.read(settingsProvider).valueOrNull ?? const AppSettings();
    // The on-device engine needs no key: it identifies the language itself.
    if (!settings.useOfflineEngine && !settings.hasApiKey) {
      _log.warning('No API key configured — open CONFIG to add one');
      return;
    }
    state = state.copyWith(stage: JobStage.detecting);
    try {
      final pipeline = ref.read(translationPipelineProvider);
      final detection = await pipeline.detectLanguage(layout);
      state = state.copyWith(stage: JobStage.idle, detection: detection);
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

  // --------------------------------------------------------------- preflight
  /// Cost, font coverage and collision risk — before the first token is spent.
  Future<void> _buildPreflight(PickedFile file, BookLayout layout) async {
    try {
      final settings =
          ref.read(settingsProvider).valueOrNull ?? const AppSettings();
      final target = AppLanguageCatalog.byCode(settings.targetLanguageCode);

      final font = await _engine.fontCoverage(
        languageCode: target.code,
        languageName: target.name,
      );
      if (font.isCritical) {
        _log.error(
          'Font coverage ${(font.ratio * 100).toStringAsFixed(0)}% — '
          'the bundled faces cannot render ${target.name}',
        );
      } else if (font.isPartial) {
        _log.warning(font.describe());
      } else {
        _log.success(font.describe());
      }

      Uint8List bytes;
      try {
        bytes = _sourceBytes ??= await File(file.path).readAsBytes();
      } catch (e) {
        _log.warning('Pre-flight skipped: source could not be cached ($e)');
        return;
      }

      final placements = await _engine.analyzePlacements(
        sourceBytes: bytes,
        layout: layout,
        password: file.password,
        onLog: _log.warning,
      );

      final characters = layout.characterCount;
      final estimatedRequests =
          (characters / settings.maxCharactersPerRequest).ceil() + layout.pageCount;

      final warnings = <String>[];
      if (font.isCritical) {
        warnings.add(_t('warn_font_critical', {'language': target.name}));
      } else if (font.isPartial) {
        warnings.add(_t('warn_font_partial', {'language': target.name}));
      }
      if (placements.haloBlocks > 0) {
        warnings.add(_t('warn_halo', {'count': '${placements.haloBlocks}'}));
      }
      if (placements.tightBlocks > 0) {
        warnings.add(_t('warn_tight', {'count': '${placements.tightBlocks}'}));
      }
      if (placements.droppedBlocks > 0) {
        warnings.add(_t('warn_dropped', {'count': '${placements.droppedBlocks}'}));
      }
      if (state.checkpoint != null) {
        warnings.add(_t('warn_resume_available'));
      }

      for (final warning in warnings) {
        _log.warning(warning);
      }

      state = state.copyWith(
        preflight: PreflightReport(
          pages: layout.pageCount,
          blocks: layout.blockCount,
          characters: characters,
          estimatedRequests: estimatedRequests < 1 ? 1 : estimatedRequests,
          font: font,
          placements: placements,
          warnings: warnings,
        ),
      );
    } catch (e) {
      _log.warning('Pre-flight incomplete: $e');
    }
  }

  // -------------------------------------------------------------- translate
  /// Runs (or continues) the whole job.
  ///
  /// `resume: true` restarts from the saved checkpoint instead of page 1.
  Future<void> start({bool resume = false}) async {
    final file = state.file;
    final layout = state.layout;
    final settings = ref.read(settingsProvider).valueOrNull ?? const AppSettings();

    if (state.isBusy) return;
    if (file == null) {
      _fail(Failure(FailureKind.fileMissing, messageKey: 'err_no_file'));
      return;
    }
    // The on-device engine needs no key and no network: only the optional
    // cloud path is gated on them.
    if (!settings.useOfflineEngine && !settings.hasApiKey) {
      _fail(Failure(FailureKind.missingKey, messageKey: 'err_no_api_key'));
      return;
    }
    if (layout == null || layout.isEmpty) {
      _fail(Failure(FailureKind.pdfNoText, messageKey: 'err_pdf_no_text'));
      return;
    }

    if (settings.useOfflineEngine) {
      _log.system('Engine: NLLB-200 on this device — no network is used');
      if (state.offline) state = state.copyWith(offline: false);
    } else {
      // Cloud path only: no point burning pages into a dead socket.
      final online = await _hasNetwork();
      if (!online) {
        state = state.copyWith(offline: true);
        _fail(Failure(
          FailureKind.network,
          messageKey: 'err_network',
          argument: _t('err_network_hint'),
          canRetry: true,
          canResume: resume,
        ));
        return;
      }
      if (state.offline) state = state.copyWith(offline: false);
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
      'Injection profile ready: ${target.name} · '
      '${settings.useOfflineEngine ? 'NLLB-200 (on-device)' : settings.model} · '
      '${settings.useOfflineEngine ? 1 : options.concurrency} parallel streams',
    );

    JobCheckpoint? checkpoint;
    if (resume) {
      checkpoint = state.checkpoint ??
          await _checkpoints.findFor(
            sourcePath: file.path,
            sourceSizeBytes: file.sizeBytes,
            targetLanguageCode: settings.targetLanguageCode,
            model: _engineName,
          );
      if (checkpoint != null) {
        _log.system(
          'Resuming at page ${checkpoint.completedCount + 1} of '
          '${checkpoint.pageCount} — ${checkpoint.translations.length} blocks '
          'already translated',
        );
      }
    }

    final jobId = CheckpointRepository.jobIdFor(
      sourcePath: file.path,
      sourceSizeBytes: file.sizeBytes,
      targetLanguageCode: settings.targetLanguageCode,
      model: _engineName,
    );

    final savedPages = <int>{
      if (checkpoint != null) ...checkpoint.completedPages,
    };
    var savedTranslations = <String, String>{
      if (checkpoint != null) ...checkpoint.translations,
    };

    state = state.copyWith(
      stage: JobStage.translating,
      clearFailure: true,
      clearOutput: true,
      clearVerification: true,
      progress: 0,
      processedBlocks: 0,
      processedPages: savedPages.length,
      startedAt: DateTime.now(),
      finishedAt: null,
      usage: const TokenUsage(),
      checkpoint: checkpoint,
      clearCheckpoint: checkpoint == null,
    );

    try {
      final pipeline = ref.read(translationPipelineProvider);

      Future<void> checkpointPage(int pageIndex, Map<String, String> page) async {
        savedPages.add(pageIndex);
        savedTranslations = {...savedTranslations, ...page};
        final snapshot = JobCheckpoint(
          jobId: jobId,
          sourcePath: file.path,
          sourceName: file.name,
          sourceSizeBytes: file.sizeBytes,
          targetLanguageCode: settings.targetLanguageCode,
          model: _engineName,
          pageCount: layout.pageCount,
          completedPages: savedPages.toList()..sort(),
          translations: savedTranslations,
          glossary: pipeline.glossary.terms,
          updatedAt: DateTime.now(),
          detectedLanguageCode: state.detection?.code,
          detectedLanguageName: state.detection?.name,
          confidence: state.detection?.confidence ?? 0,
        );
        await _checkpoints.save(snapshot);
        state = state.copyWith(checkpoint: snapshot);
        _log.info(
          'Checkpoint saved — page ${pageIndex + 1} (${savedPages.length}/'
          '${layout.pageCount})',
        );
      }

      final translations = await pipeline.translate(
        layout: layout,
        options: options,
        cancellation: cancellation,
        resumeFrom: resume ? checkpoint : null,
        onPageCompleted: (pageIndex, page) {
          // Fire and forget: a lost checkpoint costs one page at most, and we
          // never block the pipeline on disk I/O.
          unawaited(checkpointPage(pageIndex, page));
        },
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

      Uint8List sourceBytes;
      try {
        sourceBytes = _sourceBytes ??= await File(file.path).readAsBytes();
      } on Exception catch (e, st) {
        throw Failure.from(e, stack: st);
      }

      final placements = state.preflight?.placements ??
          await _engine.analyzePlacements(
            sourceBytes: sourceBytes,
            layout: layout,
            password: file.password,
            onLog: _log.warning,
          );

      if (placements.haloBlocks > 0) {
        _log.warning(
          '${placements.haloBlocks} block(s) sit on artwork: they are drawn '
          'with a halo, no pixel of the original is erased',
        );
      }
      if (placements.tightBlocks > 0) {
        _log.warning(
          '${placements.tightBlocks} block(s) inside ruled areas: covered '
          'without padding so the rules survive',
        );
      }

      final report = await _engine.injectTranslations(
        sourceBytes: sourceBytes,
        layout: layout,
        translations: translations,
        cloak: settings.cloak,
        shrinkToFit: settings.shrinkToFit,
        placements: placements,
        verifyOutput: true,
        onProgress: (index, total) {
          state = state.copyWith(
            processedPages: index + 1,
            totalPages: total,
          );
        },
        onLog: _log.warning,
      );

      _log.success('Embedded profiles: ${report.fontsEmbedded.join(', ')}');
      if (report.missingGlyphs > 0) {
        _log.warning(
          '${report.missingGlyphs} glyph(s) are missing from the bundled '
          'fonts and were rendered blank',
        );
      }
      cancellation.throwIfCancelled();

      // ------------------------------------------------------------ verify
      state = state.copyWith(stage: JobStage.verifying);
      final verification = report.verification;
      state = state.copyWith(verification: verification);
      if (verification == null) {
        _log.warning('Verification skipped');
      } else if (verification.passed) {
        _log.success(
          'Layout verified: ${verification.totalChanged} changed pixel(s) '
          'outside the translated boxes (${verification.checkedPages} page(s) '
          'checked at ${verification.renderWidth}px)',
        );
      } else {
        _log.error(
          'Layout verification FAILED: page '
          '${verification.pages.reduce((a, b) => a.changeRatio > b.changeRatio ? a : b).pageIndex + 1} '
          'differs by ${(verification.worstRatio * 100).toStringAsFixed(2)}% '
          'outside the text boxes',
        );
      }

      // ------------------------------------------------------------- saving
      state = state.copyWith(stage: JobStage.saving);
      _log.info('Writing shadow_translated payload to device storage…');
      final library = ref.read(libraryRepositoryProvider);
      SavedBook book;
      try {
        book = await library.saveTranslatedBook(
          bytes: report.bytes,
          sourceName: file.name,
          sourcePath: file.path,
          pageCount: layout.pageCount,
          targetLanguageCode: settings.targetLanguageCode,
        );
      } on Exception catch (e, st) {
        // The translation is still in the checkpoint: nothing is lost.
        throw Failure.from(e, stack: st);
      }
      ref.invalidate(libraryProvider);

      await _checkpoints.delete(jobId);

      final usage = ref.read(geminiClientProvider).usage;
      final elapsed = state.elapsed ?? Duration.zero;
      state = state.copyWith(
        stage: JobStage.done,
        output: book,
        usage: usage,
        progress: 1,
        finishedAt: DateTime.now(),
        clearCheckpoint: true,
      );
      _log.success(
        'Translation complete // ${layout.pageCount} pages // '
        'elapsed ${Formatters.duration(elapsed)}',
      );
      _log.system('Output: ${book.name} (${Formatters.bytes(book.sizeBytes)})');
    } on Failure catch (failure) {
      _fail(failure.copyWithResume(savedPages.isNotEmpty));
    } on JobCancelledException {
      state = state.copyWith(
        stage: JobStage.cancelled,
        finishedAt: DateTime.now(),
      );
      _log.warning('Job aborted by operator');
      if (savedPages.isNotEmpty) {
        _log.info('Progress kept: ${savedPages.length} page(s) — RESUME picks '
            'up where you stopped');
      }
    } on TranslationException catch (e, st) {
      _log.error('${e.message}');
      _log.info('$st');
      _fail(Failure.from(e, stack: st).copyWithResume(savedPages.isNotEmpty));
    } catch (e, st) {
      _log.error('Unexpected fault: $e');
      _log.info('$st');
      _fail(Failure.from(e, stack: st).copyWithResume(savedPages.isNotEmpty));
    } finally {
      _cancellation = null;
    }
  }

  /// Continues the job from the last checkpointed page.
  Future<void> resume() => start(resume: true);

  /// Throws the saved progress away and starts from page 1.
  Future<void> discardCheckpoint() async {
    final checkpoint = state.checkpoint;
    if (checkpoint == null) return;
    await _checkpoints.delete(checkpoint.jobId);
    state = state.copyWith(
      clearCheckpoint: true,
      clearFailure: true,
      stage: JobStage.idle,
    );
    _log.system('Checkpoint discarded — the next run starts from page 1');
  }

  /// Re-runs the last failed job from scratch.
  Future<void> retry() => start(resume: false);

  void cancel() {
    _cancellation?.cancel();
  }

  Future<void> setTargetLanguage(String code) async {
    await ref.read(settingsProvider.notifier).setTargetLanguage(code);
    _log.system('Target lock set: ${AppLanguageCatalog.byCode(code).name}');
    // The pre-flight depends on the target language (font coverage).
    state = state.copyWith(clearPreflight: true);
    final layout = state.layout;
    final file = state.file;
    if (file != null && layout != null) {
      unawaited(_buildPreflight(file, layout));
    }
  }

  // ------------------------------------------------------------------ helpers

  /// Cheap, permission free connectivity probe.
  Future<bool> _hasNetwork() async {
    try {
      final result = await InternetAddress.lookup('generativelanguage.googleapis.com')
          .timeout(const Duration(seconds: 6));
      return result.isNotEmpty && result.first.rawAddress.isNotEmpty;
    } catch (_) {
      try {
        final fallback =
            await InternetAddress.lookup('example.com').timeout(
          const Duration(seconds: 4),
        );
        return fallback.isNotEmpty;
      } catch (_) {
        return false;
      }
    }
  }

  void _fail(Failure failure) {
    _log.error(_t(failure.messageKey, {'message': failure.argument ?? ''}));
    state = state.copyWith(
      stage: failure.isCancelled ? JobStage.cancelled : JobStage.failed,
      failure: failure,
      finishedAt: DateTime.now(),
    );
  }
}

/// Adds recovery information to a failure once we know whether progress was
/// checkpointed.
extension _FailureResume on Failure {
  Failure copyWithResume(bool hasProgress) => Failure(
        kind,
        messageKey: messageKey,
        argument: argument,
        technical: technical,
        canRetry: canRetry || isTransient,
        canResume: canResume || (hasProgress && !isCancelled),
      );
}

final terminalControllerProvider =
    NotifierProvider<TerminalController, TerminalState>(TerminalController.new);
