import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/logging/log_entry.dart';
import 'flores.dart';
import 'nllb_engine.dart';
import 'ocr/ocr_types.dart';
import 'ocr/onnx_ocr.dart';
import 'onnx_backend.dart';
import 'sentencepiece.dart';

/// What a file is for.
enum ModelKind {
  nllbEncoder,
  nllbDecoder,
  tokenizer,
  ocrRecognizer,
  ocrCharset,
}

/// How a model file is recognised on disk.
class ModelSpec {
  const ModelSpec({
    required this.kind,
    required this.labelArabic,
    required this.labelEnglish,
    required this.fileNames,
    required this.minBytes,
    this.extensions = const ['.onnx'],
  });

  final ModelKind kind;
  final String labelArabic;
  final String labelEnglish;
  final List<String> fileNames;

  /// Below this the file is a stub or a Git LFS pointer, not a model.
  final int minBytes;
  final List<String> extensions;

  static const List<ModelSpec> all = [
    ModelSpec(
      kind: ModelKind.nllbEncoder,
      labelArabic: 'مُرمِّز NLLB-200',
      labelEnglish: 'NLLB-200 encoder',
      fileNames: [
        'nllb-encoder.onnx',
        'encoder_model.onnx',
        'nllb200-distilled-600M-encoder.onnx',
        'encoder.onnx',
      ],
      minBytes: 20 * 1024 * 1024,
    ),
    ModelSpec(
      kind: ModelKind.nllbDecoder,
      labelArabic: 'فاكّ ترميز NLLB-200',
      labelEnglish: 'NLLB-200 decoder',
      fileNames: [
        'nllb-decoder.onnx',
        'decoder_model.onnx',
        'nllb200-distilled-600M-decoder.onnx',
        'decoder.onnx',
      ],
      minBytes: 40 * 1024 * 1024,
    ),
    ModelSpec(
      kind: ModelKind.tokenizer,
      labelArabic: 'مُقطِّع الكلمات (SentencePiece)',
      labelEnglish: 'SentencePiece tokenizer',
      fileNames: ['tokenizer.model', 'sentencepiece.model', 'spiece.model'],
      minBytes: 200 * 1024,
      extensions: ['.model'],
    ),
    ModelSpec(
      kind: ModelKind.ocrRecognizer,
      labelArabic: 'مُعرِّف النصوص داخل الصور (OCR)',
      labelEnglish: 'OCR text recognizer',
      fileNames: ['ocr-rec.onnx', 'rec.onnx', 'text_recognition.onnx'],
      minBytes: 2 * 1024 * 1024,
    ),
    ModelSpec(
      kind: ModelKind.ocrCharset,
      labelArabic: 'أبجدية الـ OCR',
      labelEnglish: 'OCR charset',
      fileNames: ['ocr_charset.txt', 'charset.txt', 'keys.txt'],
      minBytes: 64,
      extensions: ['.txt'],
    ),
  ];

  static ModelSpec of(ModelKind kind) =>
      all.firstWhere((spec) => spec.kind == kind);

  bool matches(String name) {
    final lower = name.toLowerCase();
    if (fileNames.any((candidate) => lower == candidate.toLowerCase())) {
      return true;
    }
    return extensions.any((extension) => lower.endsWith(extension)) &&
        _keyword.every(lower.contains);
  }

  /// Every keyword must appear, otherwise `nllb-decoder.onnx` would satisfy
  /// the encoder rule through the shared `nllb` substring.
  List<String> get _keyword => switch (kind) {
        ModelKind.nllbEncoder => const ['encoder'],
        ModelKind.nllbDecoder => const ['decoder'],
        ModelKind.tokenizer => const ['tokenizer'],
        ModelKind.ocrRecognizer => const ['rec'],
        ModelKind.ocrCharset => const ['charset'],
      };
}

/// One file, found or missing.
class ModelStatus {
  const ModelStatus({
    required this.kind,
    required this.present,
    this.path,
    this.sizeBytes = 0,
    this.note,
  });

  final ModelKind kind;
  final bool present;
  final String? path;
  final int sizeBytes;
  final String? note;

  ModelSpec get spec => ModelSpec.of(kind);

  String label(String languageCode) =>
      languageCode == 'ar' ? spec.labelArabic : spec.labelEnglish;
}

/// The state of every model the app can use.
class ModelInventory {
  const ModelInventory(this.items);

  final List<ModelStatus> items;

  ModelStatus? statusOf(ModelKind kind) {
    for (final item in items) {
      if (item.kind == kind) return item;
    }
    return null;
  }

  bool isPresent(ModelKind kind) => statusOf(kind)?.present ?? false;

  /// Translation needs encoder + decoder + tokenizer.
  bool get translationReady =>
      isPresent(ModelKind.nllbEncoder) &&
      isPresent(ModelKind.nllbDecoder) &&
      isPresent(ModelKind.tokenizer);

  /// OCR needs the recognizer; the charset is optional (a built in fallback
  /// covers the Latin + Arabic + digit range).
  bool get ocrReady => isPresent(ModelKind.ocrRecognizer);

  int get totalBytes => items.fold<int>(
      0, (sum, item) => sum + (item.present ? item.sizeBytes : 0));

  List<ModelKind> get missing => [
        for (final item in items)
          if (!item.present) item.kind,
      ];
}

/// Finds, imports, validates and loads the on-device models.
///
/// The models are hundreds of megabytes, so they are deliberately **not** part
/// of the repository and not bundled in the APK. The app keeps them in its own
/// support directory and this class is the only place that knows where:
///
/// * `<app support>/models` — the canonical home;
/// * `<app documents>/ShadowLanguages/models` — where a file manager can see it;
/// * `<external storage>/ShadowLanguages/models`, `<external>/Download` — so a
///   user can drop the files from a PC and import them in one tap.
class ModelManager {
  ModelManager({LogBus? log, this.threads = 2}) : _log = log;

  final LogBus? _log;
  final int threads;

  OnnxBackend? _backend;
  NllbEngine? _engine;
  OcrEngine? _ocr;

  NllbEngine? get engine => _engine;
  OcrEngine? get ocr => _ocr;

  // -------------------------------------------------------------- directories

  Future<Directory> modelsDirectory() async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory(p.join(support.path, 'models'));
    if (!directory.existsSync()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  /// Everywhere a model file could legitimately live.
  Future<List<Directory>> searchDirectories() async {
    final out = <Directory>[await modelsDirectory()];
    try {
      final documents = await getApplicationDocumentsDirectory();
      out.add(Directory(p.join(documents.path, 'ShadowLanguages', 'models')));
    } catch (_) {}
    try {
      final external = await getExternalStorageDirectories();
      for (final directory in external ?? const <Directory>[]) {
        out.add(Directory(p.join(directory.path, 'ShadowLanguages', 'models')));
        out.add(Directory(p.join(directory.path, 'Download')));
      }
    } catch (_) {}
    return out;
  }

  // ----------------------------------------------------------------- scanning

  /// Looks for every model we know about.
  Future<ModelInventory> scan() async {
    final directories = await searchDirectories();
    final found = <ModelKind, ModelStatus>{};

    for (final spec in ModelSpec.all) {
      for (final directory in directories) {
        if (!directory.existsSync()) continue;
        File? best;
        try {
          for (final entity in directory.listSync()) {
            if (entity is! File) continue;
            if (!spec.matches(p.basename(entity.path))) continue;
            final length = entity.lengthSync();
            if (length < spec.minBytes) {
              found.putIfAbsent(
                spec.kind,
                () => ModelStatus(
                  kind: spec.kind,
                  present: false,
                  path: entity.path,
                  sizeBytes: length,
                  note: 'the file is too small — it is probably not complete',
                ),
              );
              continue;
            }
            if (best == null || length > best.lengthSync()) best = entity;
          }
        } catch (_) {
          // A directory we cannot read (missing permission) is simply skipped.
        }
        if (best != null) {
          found[spec.kind] = ModelStatus(
            kind: spec.kind,
            present: true,
            path: best.path,
            sizeBytes: best.lengthSync(),
          );
          break;
        }
      }
      found.putIfAbsent(
          spec.kind, () => ModelStatus(kind: spec.kind, present: false));
    }

    return ModelInventory(ModelSpec.all
        .map((spec) => found[spec.kind]!)
        .toList(growable: false));
  }

  // ------------------------------------------------------------------ import

  /// Copies [sourcePath] into the models directory, under the canonical name.
  ///
  /// Returns the status of the imported file. Progress is reported as
  /// `(bytesCopied, bytesTotal)`.
  Future<ModelStatus> importFile(
    String sourcePath, {
    void Function(int copied, int total)? onProgress,
  }) async {
    final source = File(sourcePath);
    if (!source.existsSync()) {
      throw ModelException('the file does not exist: $sourcePath');
    }
    final spec = _specFor(p.basename(sourcePath));
    if (spec == null) {
      throw ModelException(
          'unrecognised file name: ${p.basename(sourcePath)}. Expected one of '
          'the model files (encoder, decoder, tokenizer, ocr-rec, charset).');
    }
    final length = source.lengthSync();
    if (length < spec.minBytes) {
      throw ModelException(
          '${p.basename(sourcePath)} is only ${_humanSize(length)} — the real '
          'file is much bigger. The download was probably interrupted.');
    }

    final directory = await modelsDirectory();
    final target = File(p.join(directory.path, spec.fileNames.first));
    if (target.existsSync()) {
      await target.delete();
    }

    final input = source.openSync();
    final output = target.openSync(mode: FileMode.writeOnly);
    try {
      const chunkSize = 1024 * 1024;
      var copied = 0;
      while (true) {
        final chunk = input.readSync(chunkSize);
        if (chunk.isEmpty) break;
        output.writeFromSync(chunk);
        copied += chunk.length;
        onProgress?.call(copied, length);
      }
    } finally {
      await input.close();
      await output.flush();
      await output.close();
    }

    await _validate(spec, target);
    _log?.success('Model imported: ${spec.labelEnglish} '
        '(${_humanSize(target.lengthSync())})');
    return ModelStatus(
      kind: spec.kind,
      present: true,
      path: target.path,
      sizeBytes: target.lengthSync(),
    );
  }

  /// Copies models that ship inside the APK (optional, for small builds).
  Future<int> installBundled({String assetPrefix = 'assets/models/'}) async {
    var installed = 0;
    for (final spec in ModelSpec.all) {
      for (final name in spec.fileNames) {
        try {
          final data = await rootBundle.load('$assetPrefix$name');
          if (data.lengthInBytes < spec.minBytes) continue;
          final directory = await modelsDirectory();
          final target = File(p.join(directory.path, spec.fileNames.first));
          await target.writeAsBytes(data.buffer.asUint8List(
              data.offsetInBytes, data.lengthInBytes));
          installed++;
          break;
        } catch (_) {
          // not bundled: nothing to do
        }
      }
    }
    return installed;
  }

  Future<void> delete(ModelKind kind) async {
    final inventory = await scan();
    final status = inventory.statusOf(kind);
    final path = status?.path;
    if (path != null && File(path).existsSync()) {
      await File(path).delete();
    }
  }

  ModelSpec? _specFor(String fileName) {
    for (final spec in ModelSpec.all) {
      if (spec.fileNames
          .any((name) => name.toLowerCase() == fileName.toLowerCase())) {
        return spec;
      }
    }
    for (final spec in ModelSpec.all) {
      if (spec.matches(fileName)) return spec;
    }
    return null;
  }

  // --------------------------------------------------------------- validation

  Future<void> _validate(ModelSpec spec, File file) async {
    final bytes = file.lengthSync();
    if (bytes < spec.minBytes) {
      throw ModelException('${spec.labelEnglish} is incomplete');
    }
    switch (spec.kind) {
      case ModelKind.nllbEncoder:
      case ModelKind.nllbDecoder:
      case ModelKind.ocrRecognizer:
        final head = await _head(file, 8);
        if (head.length < 2 || head[0] != 0x08) {
          throw ModelException(
              '${p.basename(file.path)} is not an ONNX file (bad header)');
        }
        break;
      case ModelKind.tokenizer:
        final data = await file.readAsBytes();
        try {
          final tokenizer = SentencePieceTokenizer(data);
          if (tokenizer.pieceToId('<s>') < 0 ||
              tokenizer.pieceToId('arb_Arab') < 0) {
            throw const FormatException('missing NLLB tokens');
          }
        } on FormatException catch (e) {
          throw ModelException('the tokenizer file is not usable: ${e.message}');
        }
        break;
      case ModelKind.ocrCharset:
        final text = await file.readAsString(encoding: utf8);
        if (text.trim().isEmpty) {
          throw ModelException('the charset file is empty');
        }
        break;
    }
  }

  Future<Uint8List> _head(File file, int count) async {
    final handle = file.openSync();
    try {
      return handle.readSync(count);
    } finally {
      await handle.close();
    }
  }

  // -------------------------------------------------------------------- load

  /// Opens the NLLB sessions and returns a ready engine.
  ///
  /// The sessions stay cached in the backend, so calling this twice is cheap.
  Future<NllbEngine> createEngine({
    int beamSize = 1,
    int maxInputTokens = 384,
    int maxNewTokens = 400,
  }) async {
    final existing = _engine;
    if (existing != null) return existing;

    final inventory = await scan();
    if (!inventory.translationReady) {
      throw ModelException(
        'the translation model is not installed yet — copy the NLLB encoder, '
        'decoder and tokenizer into the model folder first',
      );
    }
    final encoderPath = inventory.statusOf(ModelKind.nllbEncoder)!.path!;
    final decoderPath = inventory.statusOf(ModelKind.nllbDecoder)!.path!;
    final tokenizerPath = inventory.statusOf(ModelKind.tokenizer)!.path!;

    _log?.info('Loading NLLB-200 on ${Platform.numberOfProcessors} cores…');
    final backend = _backend ??= OnnxBackend(threads: threads);
    final encoderSession = await backend.session(encoderPath, key: 'nllb-enc');
    final decoderSession = await backend.session(decoderPath, key: 'nllb-dec');

    final decoderInputs = await decoderSession.getInputInfo();
    final tokenizer =
        SentencePieceTokenizer(await File(tokenizerPath).readAsBytes());
    final io = Seq2SeqIo.discover(
      encoderInputs: _names(await encoderSession.getInputInfo()),
      encoderOutputs: _names(await encoderSession.getOutputInfo()),
      decoderInputs: _names(decoderInputs),
      decoderOutputs: _names(await decoderSession.getOutputInfo()),
      decoderInputShapes: _shapes(decoderInputs),
    );
    _log?.info('Model graph: ${io.layers} layers, '
        '${io.usesMergedCache ? 'merged' : 'per-layer'} KV cache, '
        '${io.tensorsPerStep} tensors per step');

    final engine = NllbEngine(
      backend: backend,
      tokenizer: tokenizer,
      io: io,
      encoder: encoderSession,
      decoder: decoderSession,
      maxInputTokens: maxInputTokens,
      maxNewTokens: maxNewTokens,
      beamSize: beamSize,
      threads: threads,
    );
    _engine = engine;
    _log?.success('NLLB-200 ready — ${FloresCatalog.languages.length} languages, '
        'no network needed');
    return engine;
  }

  /// Opens the OCR recognizer, or returns a no-op engine when it is missing.
  Future<OcrEngine> createOcrEngine() async {
    final existing = _ocr;
    if (existing != null) return existing;

    final inventory = await scan();
    if (!inventory.ocrReady) {
      _log?.warning('OCR model not installed — text inside images will be '
          'left as it is');
      return _ocr = const OcrUnavailableEngine();
    }
    final recPath = inventory.statusOf(ModelKind.ocrRecognizer)!.path!;
    final backend = _backend ??= OnnxBackend(threads: 1);
    final session = await backend.session(recPath, key: 'ocr-rec');
    final inputs = _names(await session.getInputInfo());
    final outputs = _names(await session.getOutputInfo());
    if (inputs.isEmpty || outputs.isEmpty) {
      throw ModelException('the OCR model reports no inputs or outputs');
    }

    final charset = await _loadCharset(inventory);
    final engine = OnnxOcrEngine(
      backend: backend,
      recognizer: session,
      charset: charset,
      inputName: inputs.first,
      outputName: outputs.first,
    );
    _ocr = engine;
    _log?.success('Offline OCR ready (${charset.length} symbols)');
    return engine;
  }

  Future<List<String>> _loadCharset(ModelInventory inventory) async {
    final status = inventory.statusOf(ModelKind.ocrCharset);
    final path = status?.path;
    if (path != null && File(path).existsSync()) {
      try {
        final text = await File(path).readAsString(encoding: utf8);
        final symbols = text
            .split('\n')
            .map((line) => line.replaceAll('\r', ''))
            .where((line) => line.isNotEmpty)
            .toList(growable: false);
        if (symbols.isNotEmpty) return symbols;
      } catch (_) {
        // fall through to the built in set
      }
    }
    return OnnxOcrEngine.fallbackCharset;
  }

  List<String> _names(List<Map<String, dynamic>> info) => [
        for (final entry in info)
          if (entry['name'] is String) entry['name'] as String,
      ];

  /// `name → declared shape`, used to build the empty KV cache the decoder may
  /// ask for on its first step.
  Map<String, List<dynamic>> _shapes(List<Map<String, dynamic>> info) => {
        for (final entry in info)
          if (entry['name'] is String && entry['shape'] is List)
            entry['name'] as String: (entry['shape'] as List).toList(),
      };

  /// Releases every session. Call this when the app goes to the background.
  Future<void> dispose() async {
    await _ocr?.dispose();
    _ocr = null;
    _engine = null;
    await _backend?.dispose();
    _backend = null;
  }

  static String _humanSize(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }
}

/// Raised when a model file is missing, incomplete or unusable.
class ModelException implements Exception {
  const ModelException(this.message);

  final String message;

  @override
  String toString() => 'ModelException: $message';
}
