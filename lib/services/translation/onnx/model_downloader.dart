import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../../core/utils/job_cancellation.dart';
import 'model_manager.dart';

/// Where one model file comes from.
class ModelDownloadSpec {
  const ModelDownloadSpec({
    required this.kind,
    required this.fileName,
    required this.url,
    required this.sizeBytes,
    this.sha256,
  });

  final ModelKind kind;
  final String fileName;

  /// Direct file URL. `null` = the user has to supply it by hand.
  final String? url;
  final int sizeBytes;

  /// Optional integrity check; when present the file is rejected on mismatch.
  final String? sha256;

  bool get downloadable => url != null;

  ModelSpec get spec => ModelSpec.of(kind);
}

/// The files the "download once" button fetches.
///
/// The models are hundreds of megabytes: they are **not** in the repository and
/// not in the APK, and this is the only place that knows where they live. The
/// URLs point at public ONNX exports of `facebook/nllb-200-distilled-600M`;
/// verify them once against your own mirror before shipping a release — a wrong
/// URL fails here with a clear message, it never corrupts a translation.
abstract final class ModelDownloadCatalog {
  static const String nllbBase =
      'https://huggingface.co/facebook/nllb-200-distilled-600M/resolve/main';

  static const List<ModelDownloadSpec> defaults = [
    ModelDownloadSpec(
      kind: ModelKind.nllbEncoder,
      fileName: 'nllb-encoder.onnx',
      url: '$nllbBase/onnx/encoder_model.onnx',
      sizeBytes: 279 * 1024 * 1024,
    ),
    ModelDownloadSpec(
      kind: ModelKind.nllbDecoder,
      fileName: 'nllb-decoder.onnx',
      // The merged export carries the KV cache, which is what makes decoding
      // fast on a phone; the engine also accepts per-layer exports.
      url: '$nllbBase/onnx/decoder_model_merged.onnx',
      sizeBytes: 366 * 1024 * 1024,
    ),
    ModelDownloadSpec(
      kind: ModelKind.tokenizer,
      fileName: 'tokenizer.model',
      url: '$nllbBase/sentencepiece.bpe.model',
      sizeBytes: 5 * 1024 * 1024,
    ),
    // The OCR recognizer is deliberately left to the user: public CRNN exports
    // differ in alphabet and input shape, so shipping a fixed URL would break
    // more than it helps. Drop `ocr-rec.onnx` (+ `ocr_charset.txt`) into the
    // model folder to switch it on.
    ModelDownloadSpec(
      kind: ModelKind.ocrRecognizer,
      fileName: 'ocr-rec.onnx',
      url: null,
      sizeBytes: 0,
    ),
  ];

  static int totalBytes(Iterable<ModelDownloadSpec> specs) =>
      specs.fold<int>(0, (sum, spec) => sum + spec.sizeBytes);
}

/// Progress of one download, and of the batch.
class ModelDownloadProgress {
  const ModelDownloadProgress({
    required this.kind,
    required this.received,
    required this.total,
    this.fileIndex = 0,
    this.fileCount = 1,
    this.done = false,
    this.error,
  });

  final ModelKind kind;
  final int received;
  final int total;

  final int fileIndex;
  final int fileCount;

  final bool done;
  final String? error;

  double get ratio => total <= 0 ? 0 : (received / total).clamp(0.0, 1.0);

  String get label => ModelSpec.of(kind).labelEnglish;
}

/// Downloads the model files **once**, with resume, then hands them to
/// [ModelManager] for validation.
///
/// Nothing else in the app touches the network: after this finishes once, the
/// device can stay in airplane mode forever.
class ModelDownloader {
  ModelDownloader({
    required ModelManager manager,
    HttpClient? client,
    void Function(String message)? onLog,
  })  : _manager = manager,
        _client = client ?? HttpClient(),
        _onLog = onLog;

  final ModelManager _manager;
  final HttpClient _client;
  final void Function(String message)? _onLog;

  bool _cancelled = false;

  void cancel() => _cancelled = true;

  /// Downloads everything that is missing (or incomplete).
  ///
  /// Partial files are kept, so an interrupted download resumes instead of
  /// starting over — important when the file is 300 MB and the lift drops.
  Future<List<ModelStatus>> downloadMissing({
    required ModelInventory inventory,
    List<ModelDownloadSpec> specs = ModelDownloadCatalog.defaults,
    void Function(ModelDownloadProgress progress)? onProgress,
    JobCancellation? cancellation,
  }) async {
    _cancelled = false;
    final pending = specs.where((spec) {
      final status = inventory.statusOf(spec.kind);
      return status == null || !status.present;
    }).toList(growable: false);

    final out = <ModelStatus>[];
    for (var i = 0; i < pending.length; i++) {
      cancellation?.throwIfCancelled();
      if (_cancelled) break;
      final spec = pending[i];
      if (!spec.downloadable) {
        _onLog?.call('${spec.spec.labelEnglish}: no download URL — copy the '
            'file into the model folder to enable it');
        continue;
      }
      final status = await _download(
        spec,
        index: i,
        count: pending.length,
        onProgress: onProgress,
        cancellation: cancellation,
      );
      if (status != null) out.add(status);
    }
    return out;
  }

  Future<ModelStatus?> _download(
    ModelDownloadSpec spec, {
    required int index,
    required int count,
    void Function(ModelDownloadProgress progress)? onProgress,
    JobCancellation? cancellation,
  }) async {
    final directory = await _manager.modelsDirectory();
    final target = File(p.join(directory.path, spec.fileName));
    final part = File('${target.path}.part');

    var received = part.existsSync() ? part.lengthSync() : 0;
    final total = spec.sizeBytes;

    HttpClientRequest? request;
    HttpClientResponse? response;
    RandomAccessFile? sink;
    try {
      final uri = Uri.parse(spec.url!);
      request = await _client.getUrl(uri);
      if (received > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$received-');
      }
      response = await request.close();

      if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
        // The partial file is longer than the real file: start over.
        received = 0;
        if (part.existsSync()) await part.delete();
        response = await (await _client.getUrl(uri)).close();
      }
      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.partialContent) {
        throw ModelException(
            '${spec.spec.labelEnglish}: the server answered '
            '${response.statusCode} for ${spec.url}');
      }

      final contentLength = response.contentLength;
      final grandTotal = contentLength > 0
          ? received + contentLength
          : (total > 0 ? total : 0);

      sink = await part.open(mode: FileMode.writeOnlyAppend);
      await for (final chunk in response.timeout(const Duration(minutes: 5))) {
        cancellation?.throwIfCancelled();
        if (_cancelled) break;
        sink.writeFromSync(chunk);
        received += chunk.length;
        onProgress?.call(ModelDownloadProgress(
          kind: spec.kind,
          received: received,
          total: grandTotal,
          fileIndex: index,
          fileCount: count,
        ));
      }
      await sink.flush();
      await sink.close();
      sink = null;

      if (_cancelled) {
        onProgress?.call(ModelDownloadProgress(
          kind: spec.kind,
          received: received,
          total: grandTotal,
          fileIndex: index,
          fileCount: count,
          done: true,
          error: 'cancelled',
        ));
        return null;
      }

      if (total > 0 && received < total) {
        throw ModelException(
            '${spec.spec.labelEnglish}: download stopped at '
            '${(received / (1024 * 1024)).toStringAsFixed(1)} MB of '
            '${(total / (1024 * 1024)).toStringAsFixed(1)} MB');
      }

      if (spec.sha256 != null && spec.sha256!.isNotEmpty) {
        final actual = await _sha256(part);
        if (actual.toLowerCase() != spec.sha256!.toLowerCase()) {
          await part.delete();
          throw ModelException(
              '${spec.spec.labelEnglish}: checksum mismatch — the file was '
              'deleted, please download again');
        }
      }

      if (target.existsSync()) await target.delete();
      await part.rename(target.path);

      await _manager.validateFile(target, spec.spec);
      _onLog?.call('${spec.spec.labelEnglish}: ready');
      onProgress?.call(ModelDownloadProgress(
        kind: spec.kind,
        received: received,
        total: received,
        fileIndex: index,
        fileCount: count,
        done: true,
      ));
      return ModelStatus(
        kind: spec.kind,
        present: true,
        path: target.path,
        sizeBytes: received,
      );
    } on ModelException catch (e) {
      onProgress?.call(ModelDownloadProgress(
        kind: spec.kind,
        received: received,
        total: total,
        fileIndex: index,
        fileCount: count,
        done: true,
        error: e.message,
      ));
      return null;
    } catch (e) {
      onProgress?.call(ModelDownloadProgress(
        kind: spec.kind,
        received: received,
        total: total,
        fileIndex: index,
        fileCount: count,
        done: true,
        error: '$e',
      ));
      return null;
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
    }
  }

  /// Streams the file through a SHA-256 without loading it into memory.
  Future<String> _sha256(File file) async {
    final digest = await _Sha256.of(file);
    return digest;
  }

  void dispose() => _client.close(force: true);
}

/// A tiny SHA-256 (the models are big; dart:crypto streams are not exposed).
abstract final class _Sha256 {
  static Future<String> of(File file) async {
    const k = [
      0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
      0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
      0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
      0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
      0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
      0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
      0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
      0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
      0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
      0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
      0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ];
    var h0 = 0x6a09e667,
        h1 = 0xbb67ae85,
        h2 = 0x3c6ef372,
        h3 = 0xa54ff53a,
        h4 = 0x510e527f,
        h5 = 0x9b05688c,
        h6 = 0x1f83d9ab,
        h7 = 0x5be0cd19;

    int rotr(int x, int n) =>
        ((x >> n) | (x << (32 - n))) & 0xFFFFFFFF;

    final w = Uint32List(64);
    final stream = file.openRead();
    var leftover = Uint8List(0);
    var bitLength = 0;

    void compress(Uint8List block) {
      final view = ByteData.view(block.buffer, block.offsetInBytes, 64);
      for (var i = 0; i < 16; i++) {
        w[i] = view.getUint32(i * 4);
      }
      for (var i = 16; i < 64; i++) {
        final s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
        final s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xFFFFFFFF;
      }
      var a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7;
      for (var i = 0; i < 64; i++) {
        final s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
        final ch = (e & f) ^ (~e & 0xFFFFFFFF & g);
        final temp1 = (h + s1 + ch + k[i] + w[i]) & 0xFFFFFFFF;
        final s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
        final maj = (a & b) ^ (a & c) ^ (b & c);
        final temp2 = (s0 + maj) & 0xFFFFFFFF;
        h = g;
        g = f;
        f = e;
        e = (d + temp1) & 0xFFFFFFFF;
        d = c;
        c = b;
        b = a;
        a = (temp1 + temp2) & 0xFFFFFFFF;
      }
      h0 = (h0 + a) & 0xFFFFFFFF;
      h1 = (h1 + b) & 0xFFFFFFFF;
      h2 = (h2 + c) & 0xFFFFFFFF;
      h3 = (h3 + d) & 0xFFFFFFFF;
      h4 = (h4 + e) & 0xFFFFFFFF;
      h5 = (h5 + f) & 0xFFFFFFFF;
      h6 = (h6 + g) & 0xFFFFFFFF;
      h7 = (h7 + h) & 0xFFFFFFFF;
    }

    await for (final chunk in stream) {
      bitLength += chunk.length * 8;
      final Uint8List data;
      if (leftover.isEmpty) {
        data = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
      } else {
        data = Uint8List(leftover.length + chunk.length)
          ..setRange(0, leftover.length, leftover)
          ..setRange(leftover.length, leftover.length + chunk.length, chunk);
      }
      var offset = 0;
      while (data.length - offset >= 64) {
        compress(Uint8List.sublistView(data, offset, offset + 64));
        offset += 64;
      }
      leftover = Uint8List.sublistView(data, offset);
    }

    // Padding: 0x80, zeros, then the 8-byte big-endian bit length. The
    // `+ 63` rounds up: a 55 byte tail needs exactly one block (55 + 1 + 8),
    // not two.
    final tail = leftover;
    final padded = Uint8List(((tail.length + 9 + 63) ~/ 64) * 64);
    padded.setRange(0, tail.length, tail);
    padded[tail.length] = 0x80;
    final lengthBytes = ByteData(8)..setUint64(0, bitLength);
    padded.setRange(padded.length - 8, padded.length,
        lengthBytes.buffer.asUint8List());
    for (var i = 0; i < padded.length; i += 64) {
      compress(Uint8List.sublistView(padded, i, i + 64));
    }

    return [
      h0, h1, h2, h3, h4, h5, h6, h7
    ].map((value) => value.toRadixString(16).padLeft(8, '0')).join();
  }
}
