import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import '../../../core/utils/job_cancellation.dart';
import 'flores.dart';
import 'onnx_backend.dart';
import 'sentencepiece.dart';

/// What a translation cost, for the statistics line.
class NllbStats {
  int encoderRuns = 0;
  int decoderSteps = 0;
  int tokensGenerated = 0;
  int tokensProcessed = 0;
  Duration total = Duration.zero;

  double get tokensPerSecond => total.inMicroseconds == 0
      ? 0
      : tokensGenerated / (total.inMicroseconds / 1e6);

  void add(NllbStats other) {
    encoderRuns += other.encoderRuns;
    decoderSteps += other.decoderSteps;
    tokensGenerated += other.tokensGenerated;
    tokensProcessed += other.tokensProcessed;
    total += other.total;
  }
}

/// On-device NLLB-200 (seq2seq) inference.
///
/// The model is a classic encoder–decoder transformer exported to ONNX as two
/// files. Translation runs entirely on the CPU of the phone:
///
/// ```
/// text ─▶ sentencepiece ─▶ encoder (once) ─▶ hidden states
///                                │
///   [eos] + <target language> ─▶ decoder ─▶ next token ─┐
///                ▲                                      │
///                └────── KV cache (past_key_values) ────┘
/// ```
///
/// The KV cache is what makes this usable on a phone: every step feeds **one**
/// token, not the whole sentence. Every intermediate tensor is disposed as soon
/// as it is consumed — that is the difference between a steady memory profile
/// and an out-of-memory crash on page 30.
class NllbEngine {
  NllbEngine({
    required this.backend,
    required this.tokenizer,
    required this.io,
    required this.encoder,
    required this.decoder,
    this.maxInputTokens = 384,
    this.maxNewTokens = 400,
    this.beamSize = 1,
    this.threads = 2,
  });

  final OnnxBackend backend;
  final SentencePieceTokenizer tokenizer;
  final Seq2SeqIo io;
  final OrtSession encoder;
  final OrtSession decoder;

  /// Hard cap on the encoder input: NLLB was trained with 512 positions and the
  /// attention matrix grows with the square of the length.
  final int maxInputTokens;
  final int maxNewTokens;
  final int beamSize;
  final int threads;

  final NllbStats stats = NllbStats();

  int get eosId => tokenizer.eosId;

  int languageTokenId(FloresLanguage language) {
    final id = tokenizer.pieceToId(language.code);
    if (id < 0) {
      throw NllbException(
          'the model vocabulary has no token for ${language.code}');
    }
    return id;
  }

  // ------------------------------------------------------------------ encode

  Future<_EncodedSource> _encode(List<int> ids) async {
    final stopwatch = Stopwatch()..start();
    final length = ids.length;
    final inputIds = await OrtValue.fromList(
      Int64List.fromList(ids),
      [1, length],
    );
    final attentionMask = await OrtValue.fromList(
      Int64List.fromList(List<int>.filled(length, 1)),
      [1, length],
    );
    try {
      final outputs = await encoder.run({
        io.encoderInputIds: inputIds,
        io.encoderAttentionMask: attentionMask,
      });
      final hidden = outputs[io.encoderHiddenStates];
      if (hidden == null) {
        throw const NllbException('encoder produced no hidden states');
      }
      // The decoder needs the encoder mask on every step: build it once and
      // keep it alive with the hidden states.
      OrtValue? encoderMask;
      if (io.encoderMaskInDecoder != null) {
        encoderMask = await OrtValue.fromList(
          Int64List.fromList(List<int>.filled(length, 1)),
          [1, length],
        );
      }
      stats.encoderRuns++;
      stats.tokensProcessed += length;
      return _EncodedSource(hidden, encoderMask, length);
    } finally {
      await inputIds.dispose();
      await attentionMask.dispose();
      stopwatch.stop();
      stats.total += stopwatch.elapsed;
    }
  }

  // --------------------------------------------------------------- translate

  /// Translates one piece of text.
  ///
  /// When [source] is `null` the source language token is omitted: NLLB is
  /// multilingual enough to infer it from the text once the target token is
  /// forced.
  Future<String> translate(
    String text, {
    required FloresLanguage target,
    FloresLanguage? source,
    JobCancellation? cancellation,
  }) async {
    final ids = _buildInputIds(text, source: source);
    final encoded = await _encode(ids);
    try {
      final targetToken = languageTokenId(target);
      final beams = beamSize < 1 ? 1 : beamSize;
      final tokens = beams == 1
          ? await _greedyDecode(encoded, targetToken, cancellation)
          : await _beamDecode(encoded, targetToken, beams, cancellation);
      return tokenizer.decode(tokens);
    } finally {
      await encoded.dispose();
    }
  }

  List<int> _buildInputIds(String text, {FloresLanguage? source}) {
    final encoded = tokenizer.encode(text);
    int? sourceToken;
    if (source != null) {
      final id = tokenizer.pieceToId(source.code);
      if (id >= 0) sourceToken = id;
    }
    final budget = maxInputTokens - (sourceToken != null ? 2 : 1);
    return <int>[
      if (sourceToken != null) sourceToken,
      ...encoded.take(budget < 1 ? 1 : budget),
      eosId,
    ];
  }

  // ------------------------------------------------------------------ greedy

  /// Greedy decoding: one token per step, stopping at EOS or after
  /// [maxNewTokens]. This is the default because it costs the least memory.
  Future<List<int>> _greedyDecode(
    _EncodedSource encoded,
    int targetToken,
    JobCancellation? cancellation,
  ) async {
    final stopwatch = Stopwatch()..start();
    final generated = <int>[];
    final cache = <String, _TensorRef>{};
    final decoderMask = <int>[];
    var inputToken = eosId;
    var forced = true;

    try {
      for (var step = 0; step < maxNewTokens; step++) {
        cancellation?.throwIfCancelled();
        decoderMask.add(1);

        final result = await _decoderStep(
          encoded: encoded,
          cache: cache,
          inputToken: inputToken,
          decoderMask: decoderMask,
        );
        stats.decoderSteps++;

        final next = forced ? targetToken : _argmax(result.logits);
        await _release(result.logitsValue);
        if (forced) {
          // The forced step only places the target language token; it is never
          // part of the visible translation.
          forced = false;
          inputToken = next;
          continue;
        }
        if (next == eosId) break;

        generated.add(next);
        stats.tokensGenerated++;
        inputToken = next;
        if (_degenerate(generated)) break;
      }
    } finally {
      await _clearCache(cache);
      stopwatch.stop();
      stats.total += stopwatch.elapsed;
    }
    return generated;
  }

  // -------------------------------------------------------------------- beam

  /// Beam search.
  ///
  /// Each hypothesis owns its own KV cache; when a hypothesis is split into
  /// several candidates the cache tensors are **reference counted** and
  /// released as soon as the last holder is pruned. That keeps the extra memory
  /// down to the surviving hypotheses instead of `beam × layers × 4` copies.
  Future<List<int>> _beamDecode(
    _EncodedSource encoded,
    int targetToken,
    int beams,
    JobCancellation? cancellation,
  ) async {
    final stopwatch = Stopwatch()..start();
    var live = <_BeamState>[_BeamState.start(inputToken: eosId)];
    final finished = <_BeamState>[];

    try {
      for (var step = 0; step < maxNewTokens && live.isNotEmpty; step++) {
        cancellation?.throwIfCancelled();
        final candidates = <_BeamState>[];

        for (final state in live) {
          state.decoderMask.add(1);
          final result = await _decoderStep(
            encoded: encoded,
            cache: state.cache,
            inputToken: state.inputToken,
            decoderMask: state.decoderMask,
          );
          stats.decoderSteps++;

          if (state.forced) {
            candidates.add(state.extend(targetToken, 0));
          } else {
            for (final entry in _topK(result.logits, beams)) {
              if (entry.$1 == eosId) {
                finished.add(state.finish(entry.$2));
              } else {
                candidates.add(state.extend(entry.$1, entry.$2));
              }
            }
          }
          await _release(result.logitsValue);
        }

        if (candidates.isEmpty) break;
        candidates.sort((a, b) => b.normalised.compareTo(a.normalised));
        final keep = candidates.take(beams).toList();

        // Every parent is done: children have already retained what they need.
        for (final state in live) {
          await state.dispose();
        }
        for (final dropped in candidates.skip(beams)) {
          await dropped.dispose();
        }
        live = keep;
        if (finished.length >= beams) break;
      }

      for (final state in live) {
        await state.dispose();
      }
    } finally {
      stopwatch.stop();
      stats.total += stopwatch.elapsed;
    }

    if (finished.isEmpty) return const [];
    final best =
        finished.reduce((a, b) => a.normalised > b.normalised ? a : b);
    return best.tokens;
  }

  // ------------------------------------------------------------------- step

  /// One decoder step.
  ///
  /// [cache] is updated in place: the tensors it held are released (reference
  /// counted) and replaced by this step's `present.*` outputs. The returned
  /// logits tensor belongs to the caller and must be released.
  Future<_StepResult> _decoderStep({
    required _EncodedSource encoded,
    required Map<String, _TensorRef> cache,
    required int inputToken,
    required List<int> decoderMask,
  }) async {
    final ids = await OrtValue.fromList(
      Int64List.fromList([inputToken]),
      [1, 1],
    );
    final mask = await OrtValue.fromList(
      Int64List.fromList(decoderMask),
      [1, decoderMask.length],
    );

    final inputs = <String, OrtValue>{
      io.decoderInputIds: ids,
      if (io.decoderAttentionMask.isNotEmpty) io.decoderAttentionMask: mask,
      if (io.encoderMaskInDecoder != null && encoded.mask != null)
        io.encoderMaskInDecoder!: encoded.mask!,
      if (io.encoderHiddenInDecoder != null)
        io.encoderHiddenInDecoder!: encoded.hidden,
      for (final entry in cache.entries) entry.key: entry.value.value,
    };

    final firstStep = cache.isEmpty;
    final empties = <OrtValue>[];

    try {
      final outputs = await _runDecoder(inputs, firstStep, empties);
      final nextCache = <String, _TensorRef>{};
      OrtValue? logitsValue;

      for (final entry in outputs.entries) {
        if (entry.key == io.logitsName) {
          logitsValue = entry.value;
          continue;
        }
        if (io.usesMergedCache) {
          nextCache[io.mergedPastName ?? 'past_key_values'] =
              _TensorRef(entry.value);
          continue;
        }
        final match = Seq2SeqIo.presentPattern.firstMatch(entry.key);
        if (match == null) {
          await _release(entry.value);
          continue;
        }
        final layer = int.parse(match.group(1)!);
        nextCache[io.pastName(layer, match.group(2)!, match.group(3)!)] =
            _TensorRef(entry.value);
      }

      await _clearCache(cache);
      cache.addAll(nextCache);

      final logits = logitsValue == null
          ? Float32List(0)
          : Float32List.fromList(
              (await logitsValue.asFlattenedList())
                  .map((value) => (value as num).toDouble())
                  .toList(growable: false),
            );
      return _StepResult(logits, logitsValue);
    } finally {
      await ids.dispose();
      await mask.dispose();
      for (final value in empties) {
        try {
          await value.dispose();
        } catch (_) {}
      }
      empties.clear();
    }
  }

  /// Runs the decoder.
  ///
  /// Exports disagree about the first step: some are happy with no cache input
  /// at all, others demand an explicit *empty* `past_key_values`. We try the
  /// cheap version first and retry once with zero-length tensors built from the
  /// shapes the model itself declared.
  Future<Map<String, OrtValue>> _runDecoder(
    Map<String, OrtValue> inputs,
    bool firstStep,
    List<OrtValue> empties,
  ) async {
    try {
      return await decoder.run(inputs);
    } catch (error) {
      if (!firstStep) rethrow;
      final withEmpty = await _fillEmptyCache(inputs, empties);
      if (withEmpty == null) rethrow;
      try {
        return await decoder.run(withEmpty);
      } catch (_) {
        throw NllbException(
          'the decoder rejected the first step. Its ONNX export expects a KV '
          'cache shape this build cannot construct ($error)',
        );
      }
    }
  }

  /// Adds zero-length cache tensors to [inputs]; `null` when we have no shape.
  Future<Map<String, OrtValue>?> _fillEmptyCache(
    Map<String, OrtValue> inputs,
    List<OrtValue> empties,
  ) async {
    if (io.pastShapes.isEmpty) return null;
    final out = <String, OrtValue>{...inputs};
    for (final entry in io.pastShapes.entries) {
      final value = await OrtValue.fromList(Float32List(0), entry.value);
      empties.add(value);
      out[entry.key] = value;
    }
    return out;
  }

  int _argmax(Float32List logits) {
    if (logits.isEmpty) return eosId;
    var best = 0;
    var bestValue = -double.infinity;
    for (var i = 0; i < logits.length; i++) {
      final value = logits[i];
      if (value > bestValue) {
        bestValue = value;
        best = i;
      }
    }
    return best;
  }

  /// log-softmax + top-k over the whole vocabulary.
  List<(int, double)> _topK(Float32List logits, int k) {
    if (logits.isEmpty) return [(eosId, 0)];
    var max = -double.infinity;
    for (final value in logits) {
      if (value > max) max = value;
    }
    var sum = 0.0;
    for (final value in logits) {
      sum += math.exp(value - max);
    }
    final logSum = max + math.log(sum);
    final best = <(int, double)>[];
    for (var i = 0; i < logits.length; i++) {
      final logProb = logits[i] - logSum;
      if (best.length < k) {
        best.add((i, logProb));
        best.sort((a, b) => b.$2.compareTo(a.$2));
      } else if (logProb > best.last.$2) {
        best.last = (i, logProb);
        best.sort((a, b) => b.$2.compareTo(a.$2));
      }
    }
    return best;
  }

  /// Catches the classic "and and and and…" failure of greedy decoders.
  bool _degenerate(List<int> tokens) {
    if (tokens.length < 10) return false;
    final tail = tokens.sublist(tokens.length - 10);
    final first = tail.first;
    return tail.every((token) => token == first);
  }

  Future<void> _release(OrtValue? value) async {
    if (value == null) return;
    try {
      await value.dispose();
    } catch (_) {}
  }

  Future<void> _clearCache(Map<String, _TensorRef> cache) async {
    for (final reference in cache.values) {
      await reference.release();
    }
    cache.clear();
  }
}

/// Encoder output for one sentence (tensors stay alive for the whole decode).
class _EncodedSource {
  _EncodedSource(this.hidden, this.mask, this.length);

  final OrtValue hidden;
  final OrtValue? mask;
  final int length;

  Future<void> dispose() async {
    try {
      await hidden.dispose();
    } catch (_) {}
    final value = mask;
    if (value != null) {
      try {
        await value.dispose();
      } catch (_) {}
    }
  }
}

/// Output of a single decoder step.
class _StepResult {
  _StepResult(this.logits, this.logitsValue);

  final Float32List logits;
  final OrtValue? logitsValue;
}

/// A reference counted OrtValue.
///
/// Beam search shares one KV cache between a parent hypothesis and its
/// children; the tensors are only released once the last holder is pruned.
class _TensorRef {
  _TensorRef(this.value);

  final OrtValue value;
  int _refs = 1;

  void retain() => _refs++;

  Future<void> release() async {
    _refs--;
    if (_refs > 0) return;
    try {
      await value.dispose();
    } catch (_) {}
  }
}

/// One hypothesis of the beam, carrying its own KV cache.
class _BeamState {
  _BeamState._(
    this.tokens,
    this.decoderMask,
    this.cache,
    this.score,
    this.inputToken,
    this.forced,
  );

  factory _BeamState.start({required int inputToken}) => _BeamState._(
        <int>[],
        <int>[],
        <String, _TensorRef>{},
        0,
        inputToken,
        true,
      );

  final List<int> tokens;
  final List<int> decoderMask;
  final Map<String, _TensorRef> cache;
  final double score;
  final int inputToken;
  final bool forced;

  /// Length normalised score: a 3 word answer must not lose to a 30 word one.
  double get normalised => score / math.pow(tokens.length + 5, 0.9);

  _BeamState extend(int token, double logProb) {
    final nextCache = <String, _TensorRef>{
      for (final entry in cache.entries) entry.key: (entry.value..retain()),
    };
    return _BeamState._(
      [...tokens, token],
      [...decoderMask],
      nextCache,
      score + logProb,
      token,
      false,
    );
  }

  _BeamState finish(double logProb) => _BeamState._(
        List<int>.of(tokens),
        const <int>[],
        <String, _TensorRef>{},
        score + logProb,
        inputToken,
        false,
      );

  Future<void> dispose() async {
    for (final reference in cache.values) {
      await reference.release();
    }
    cache.clear();
  }
}

/// Raised when the model files are unusable.
class NllbException implements Exception {
  const NllbException(this.message);

  final String message;

  @override
  String toString() => 'NllbException: $message';
}
