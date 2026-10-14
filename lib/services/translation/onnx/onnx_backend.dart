import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

/// Thin, defensive wrapper around ONNX Runtime.
///
/// Everything that can be tuned for a phone lives here: thread counts, arena
/// behaviour, and — most importantly — **every intermediate tensor is disposed
/// as soon as it is consumed**. A 600M parameter decoder leaks megabytes per
/// token if the OrtValues are left to the GC.
class OnnxBackend {
  OnnxBackend({int threads = 2}) : _threads = threads;

  final int _threads;
  final OnnxRuntime _runtime = OnnxRuntime();
  final Map<String, OrtSession> _sessions = {};

  int get threads => _threads;

  bool get isDisposed => _sessions.isEmpty;

  /// Loads (and caches) a session from a file on disk.
  Future<OrtSession> session(String path, {String? key}) async {
    final id = key ?? path;
    final existing = _sessions[id];
    if (existing != null) return existing;
    if (!File(path).existsSync()) {
      throw OnnxException('model file not found: $path');
    }
    final options = OrtSessionOptions(
      intraOpNumThreads: _threads,
      interOpNumThreads: 1,
      // The default arena keeps memory around between runs; with hundreds of
      // decoder steps per page that adds up to hundreds of MB.
      useArena: false,
    );
    final session = await _runtime.createSession(path, options: options);
    _sessions[id] = session;
    return session;
  }

  bool hasSession(String key) => _sessions.containsKey(key);

  /// Closes one session.
  Future<void> close(String key) async {
    final session = _sessions.remove(key);
    await session?.close();
  }

  /// Closes everything — call this when the job ends or the app is backgrounded.
  Future<void> dispose() async {
    for (final session in _sessions.values) {
      try {
        await session.close();
      } catch (_) {}
    }
    _sessions.clear();
  }
}

/// Raised when a model file is missing, corrupt or unsupported.
class OnnxException implements Exception {
  const OnnxException(this.message);

  final String message;

  @override
  String toString() => 'OnnxException: $message';
}

/// Description of a seq2seq ONNX export, discovered from the session metadata.
///
/// Exports differ wildly: some merge the KV cache into one tensor
/// (`past_key_values`), most keep one tensor per layer
/// (`past_key_values.0.decoder.key`). Reading the real input/output names keeps
/// the engine working with every converter.
class Seq2SeqIo {
  const Seq2SeqIo({
    required this.encoderInputIds,
    required this.encoderAttentionMask,
    required this.encoderHiddenStates,
    required this.decoderInputIds,
    required this.decoderAttentionMask,
    required this.encoderMaskInDecoder,
    required this.encoderHiddenInDecoder,
    required this.logitsName,
    required this.layers,
    required this.usesMergedCache,
    this.mergedPastName,
    this.mergedPresentName,
    this.pastShapes = const {},
  });

  final String encoderInputIds;
  final String encoderAttentionMask;
  final String encoderHiddenStates;

  final String decoderInputIds;

  /// Empty when the export does not take a decoder attention mask.
  final String decoderAttentionMask;
  final String? encoderMaskInDecoder;
  final String? encoderHiddenInDecoder;

  final String logitsName;
  final int layers;
  final bool usesMergedCache;
  final String? mergedPastName;
  final String? mergedPresentName;

  /// Declared shape of every `past_key_values.*` input, with the sequence
  /// dimension zeroed. Some exports insist on being handed an *empty* cache on
  /// the very first step; this is what we hand them.
  final Map<String, List<int>> pastShapes;

  static final RegExp _perLayer =
      RegExp(r'past_key_values\.(\d+)\.(encoder|decoder)\.(key|value)');

  static final RegExp _perLayerOut =
      RegExp(r'present\.(\d+)\.(encoder|decoder)\.(key|value)');

  int get tensorsPerStep => usesMergedCache ? 1 : layers * 4;

  /// Matches `present.<layer>.<side>.<kind>` output names.
  static RegExp get presentPattern => _perLayerOut;

  String pastName(int layer, String side, String kind) =>
      'past_key_values.$layer.$side.$kind';

  String presentName(int layer, String side, String kind) =>
      'present.$layer.$side.$kind';

  /// Builds the descriptor from the real names reported by both sessions.
  static Seq2SeqIo discover({
    required List<String> encoderInputs,
    required List<String> encoderOutputs,
    required List<String> decoderInputs,
    required List<String> decoderOutputs,
    Map<String, List<dynamic>> decoderInputShapes = const {},
  }) {
    final encIds = _pick(encoderInputs, const ['input_ids'], 'input_ids');
    final encMask = _pick(
        encoderInputs, const ['attention_mask'], 'attention_mask');
    final hidden = _pick(
      encoderOutputs,
      const ['last_hidden_state', 'hidden_states', 'encoder_hidden_state'],
      'last_hidden_state',
    );

    final decIds = _pick(decoderInputs, const ['input_ids', 'decoder_input_ids'],
        'decoder input ids');
    final decMask = _firstWhereOrNull(
          decoderInputs,
          const ['decoder_attention_mask', 'attention_mask'],
        ) ??
        '';
    final encMaskInDec = _firstWhereOrNull(
      decoderInputs,
      const ['encoder_attention_mask', 'encoder_hidden_states_mask'],
    );
    final encHiddenInDec = _firstWhereOrNull(
      decoderInputs,
      const ['encoder_hidden_states', 'encoder_outputs'],
    );
    final logits = _pick(decoderOutputs, const ['logits'], 'logits');

    final mergedPast = _firstWhereOrNull(
        decoderInputs, const ['past_key_values', 'past_key_values.0']);
    final mergedPresent = _firstWhereOrNull(
        decoderOutputs, const ['present', 'present.0']);

    var layers = 0;
    for (final name in decoderInputs) {
      final match = _perLayer.firstMatch(name);
      if (match != null) {
        final index = int.parse(match.group(1)!);
        if (index + 1 > layers) layers = index + 1;
      }
    }
    if (layers == 0) {
      for (final name in decoderOutputs) {
        final match = _perLayerOut.firstMatch(name);
        if (match != null) {
          final index = int.parse(match.group(1)!);
          if (index + 1 > layers) layers = index + 1;
        }
      }
    }

    final usesMerged = layers == 0 && mergedPast != null && mergedPresent != null;

    final pastShapes = <String, List<int>>{};
    for (final name in decoderInputs) {
      final declared = decoderInputShapes[name];
      if (declared == null) continue;
      final isPast = _perLayer.firstMatch(name) != null || name == mergedPast;
      if (!isPast) continue;
      pastShapes[name] = _emptyShape(declared);
    }

    return Seq2SeqIo(
      encoderInputIds: encIds,
      encoderAttentionMask: encMask,
      encoderHiddenStates: hidden,
      decoderInputIds: decIds,
      decoderAttentionMask: decMask,
      encoderMaskInDecoder: encMaskInDec,
      encoderHiddenInDecoder: encHiddenInDec,
      logitsName: logits,
      layers: layers,
      usesMergedCache: usesMerged,
      mergedPastName: mergedPast,
      mergedPresentName: mergedPresent,
      pastShapes: pastShapes,
    );
  }

  /// Turns a declared (possibly symbolic) shape into the shape of an **empty**
  /// cache tensor: batch stays 1, the sequence dimension becomes 0, everything
  /// else keeps its concrete value or falls back to 1.
  static List<int> _emptyShape(List<dynamic> declared) {
    if (declared.isEmpty) return [1, 1, 0, 1];
    final out = <int>[];
    for (var i = 0; i < declared.length; i++) {
      final value = declared[i];
      final number = value is num
          ? value.toInt()
          : int.tryParse('$value') ?? -1;
      if (i == 2) {
        out.add(0); // past sequence length
      } else if (number > 0) {
        out.add(number);
      } else {
        out.add(1); // batch, heads, head dimension when symbolic
      }
    }
    return out;
  }

  static String _pick(List<String> names, List<String> candidates, String what) {
    final found = _firstWhereOrNull(names, candidates);
    if (found != null) return found;
    if (names.isNotEmpty) return names.first;
    throw OnnxException('could not find $what in the model');
  }

  static String? _firstWhereOrNull(List<String> names, List<String> candidates) {
    for (final candidate in candidates) {
      if (names.contains(candidate)) return candidate;
    }
    for (final name in names) {
      for (final candidate in candidates) {
        if (name.contains(candidate)) return name;
      }
    }
    return null;
  }
}

/// Greedy / beam helper that keeps only the scores it needs.
class TokenHypothesis {
  TokenHypothesis(this.tokens, this.score, {this.lengthPenalty = 1.0});

  final List<int> tokens;
  double score;
  final double lengthPenalty;

  /// Length normalised score so a 3 word answer is not beaten by a 30 word one.
  double get normalised => score / math.pow(tokens.length + 5, lengthPenalty);

  TokenHypothesis extend(int token, double logProb) =>
      TokenHypothesis([...tokens, token], score + logProb,
          lengthPenalty: lengthPenalty);
}
