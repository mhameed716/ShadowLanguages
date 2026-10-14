import 'dart:convert';
import 'dart:io' show HttpDate;
import 'dart:math' as math;

import 'package:dio/dio.dart';

import '../../core/utils/job_cancellation.dart';
import '../../data/models/text_block.dart';
import 'translation_client.dart';
import 'translation_options.dart';

/// What went wrong, in a shape the UI can translate into a message.
enum TranslationErrorKind {
  missingKey,
  invalidKey,
  quota,
  rateLimit,
  server,
  network,
  timeout,
  parse,
  cancelled,
  unknown,
}

class TranslationException implements Exception {
  const TranslationException(
    this.kind,
    this.message, {
    this.statusCode,
    this.retryAfter,
  });

  final TranslationErrorKind kind;
  final String message;
  final int? statusCode;

  /// `Retry-After` sent by the API on 429/503: how long to wait, if it said.
  final Duration? retryAfter;

  @override
  String toString() => 'TranslationException(${kind.name}): $message';
}

/// A detected source language.
class LanguageDetection {
  const LanguageDetection({
    required this.code,
    required this.name,
    required this.confidence,
  });

  final String code;
  final String name;

  /// 0..100
  final double confidence;

  bool get isReliable => confidence >= 60;
}

/// One translated block coming back from the model.
class BlockTranslation {
  const BlockTranslation({required this.id, required this.text});

  final String id;
  final String text;
}

/// Token usage reported by the API (for the stats row).
class TokenUsage {
  const TokenUsage({this.promptTokens = 0, this.responseTokens = 0});

  final int promptTokens;
  final int responseTokens;

  int get total => promptTokens + responseTokens;

  TokenUsage operator +(TokenUsage other) => TokenUsage(
        promptTokens: promptTokens + other.promptTokens,
        responseTokens: responseTokens + other.responseTokens,
      );
}

/// Thin, dependency-light client for the Gemini `generateContent` endpoint.
///
/// Deliberately hand written instead of wrapping a SDK: we need JSON schema
/// constrained output, per-request cancellation and precise error taxonomy.
class GeminiClient implements TranslationClient {
  GeminiClient({
    required String apiKey,
    required this.model,
    this.temperature = 0.2,
    this.maxAttempts = 5,
    Dio? dio,
  })  : _apiKey = apiKey,
        _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 25),
              receiveTimeout: const Duration(seconds: 180),
              sendTimeout: const Duration(seconds: 60),
              responseType: ResponseType.json,
              headers: const {'Content-Type': 'application/json'},
            ));

  static const String baseUrl =
      'https://generativelanguage.googleapis.com/v1beta/models';

  @override
  bool get isOffline => false;

  @override
  String get displayName => 'Gemini $model (cloud)';

  String _apiKey;
  final String model;
  final double temperature;
  final int maxAttempts;
  final Dio _dio;

  TokenUsage _usage = const TokenUsage();
  TokenUsage get usage => _usage;
  void resetUsage() => _usage = const TokenUsage();

  set apiKey(String value) => _apiKey = value;

  Uri get _endpoint => Uri.parse('$baseUrl/$model:generateContent?key=$_apiKey');

  /// Verifies that the key works and the model is reachable.
  Future<String> ping() async {
    final result = await _generate(
      systemInstruction: 'You are a connectivity probe.',
      prompt: 'Reply with the single word: PONG',
      schema: _textSchema,
      cancellation: null,
    );
    final text = result.$1;
    return text.trim().isEmpty ? 'PONG' : text.trim().split('\n').first;
  }

  /// Detects the source language of a text sample.
  Future<LanguageDetection> detectLanguage(String sample) async {
    final (text, _) = await _generate(
      systemInstruction:
          'You are a language identification engine. Answer only with JSON.',
      prompt: 'Identify the language of this text sample.\n'
          'Return JSON: {"code": "<BCP-47 code>", "name": "<English name>", '
          '"confidence": <0-100>}\n\nSample:\n"""\n$sample\n"""',
      schema: const {
        'type': 'OBJECT',
        'properties': {
          'code': {'type': 'STRING'},
          'name': {'type': 'STRING'},
          'confidence': {'type': 'NUMBER'},
        },
        'required': ['code', 'name', 'confidence'],
      },
      cancellation: null,
    );
    final decoded = _decodeJsonObject(text);
    final rawConfidence = decoded['confidence'];
    final confidence = rawConfidence is num
        ? rawConfidence.toDouble()
        : double.tryParse('$rawConfidence') ?? 0;
    return LanguageDetection(
      code: '${decoded['code'] ?? 'und'}',
      name: '${decoded['name'] ?? 'Unknown'}',
      confidence: confidence.clamp(0, 100),
    );
  }

  /// Translates a batch of blocks.
  Future<List<BlockTranslation>> translateBatch({
    required List<TextBlock> blocks,
    required TranslationOptions options,
    String context = '',
    Map<String, String> glossary = const {},
    JobCancellation? cancellation,
  }) async {
    if (_apiKey.trim().isEmpty) {
      throw const TranslationException(
          TranslationErrorKind.missingKey, 'No API key configured');
    }
    if (blocks.isEmpty) return const [];

    final payload = <Map<String, dynamic>>[
      for (final block in blocks)
        {'id': block.id, 'text': block.text},
    ];
    final buffer = StringBuffer()
      ..writeln('Translate every item of the JSON array below into '
          '${options.targetLanguageName} (${options.targetLanguageCode}).')
      ..writeln('Rules:');
    if (options.preserveMeaning) {
      buffer.writeln(
          '- Preserve the author voice, register and tone. Do not summarise, '
          'expand or annotate.');
    }
    if (options.keepNumbers) {
      buffer.writeln(
          '- Keep numbers, dates, formulas, code, URLs, emails and '
          'measurements exactly as written.');
    }
    buffer.writeln(
        '- Keep the same punctuation style. Do not add quotation marks, '
        'bullet characters or line breaks.');
    buffer.writeln('- Do not translate proper nouns unless a well established '
        'translation exists.');
    if (glossary.isNotEmpty) {
      buffer.writeln('- Use exactly these term translations:');
      for (final entry in glossary.entries) {
        buffer.writeln('    • ${entry.key} → ${entry.value}');
      }
    }
    if (context.isNotEmpty) {
      buffer.writeln('- Context from the previous pages (do not translate it):');
      buffer.writeln('    """$context"""');
    }
    buffer.writeln(
        '- Return JSON: {"translations":[{"id": <same id>, "text": '
        '<translated text>}...]} with exactly one entry per input item, in the '
        'same order.');
    buffer.writeln('\nInput:\n${jsonEncode(payload)}');

    final (text, _) = await _generate(
      systemInstruction:
          'You are a literary-grade translation engine. You translate book '
          'paragraphs while preserving their meaning, tone and typographic '
          'neutrality. You always answer with valid JSON only.',
      prompt: buffer.toString(),
      schema: const {
        'type': 'OBJECT',
        'properties': {
          'translations': {
            'type': 'ARRAY',
            'items': {
              'type': 'OBJECT',
              'properties': {
                'id': {'type': 'STRING'},
                'text': {'type': 'STRING'},
              },
              'required': ['id', 'text'],
            },
          },
        },
        'required': ['translations'],
      },
      cancellation: cancellation,
      temperatureOverride: options.temperature,
    );

    final decoded = _decodeJsonObject(text);
    final list = decoded['translations'];
    if (list is! List) {
      throw const TranslationException(
          TranslationErrorKind.parse, 'Response has no "translations" array');
    }
    final out = <BlockTranslation>[];
    for (final item in list) {
      if (item is! Map) continue;
      final id = '${item['id']}';
      final value = '${item['text'] ?? ''}';
      if (id.isEmpty) continue;
      out.add(BlockTranslation(id: id, text: value));
    }
    return out;
  }

  static const Map<String, dynamic> _textSchema = {
    'type': 'OBJECT',
    'properties': {
      'text': {'type': 'STRING'},
    },
    'required': ['text'],
  };

  Future<(String, TokenUsage)> _generate({
    required String systemInstruction,
    required String prompt,
    required Map<String, dynamic> schema,
    JobCancellation? cancellation,
    double? temperatureOverride,
  }) async {
    final body = <String, dynamic>{
      'systemInstruction': {
        'parts': [
          {'text': systemInstruction},
        ],
      },
      'contents': [
        {
          'role': 'user',
          'parts': [
            {'text': prompt},
          ],
        },
      ],
      'generationConfig': {
        'temperature': temperatureOverride ?? temperature,
        'topP': 0.95,
        'responseMimeType': 'application/json',
        'responseSchema': schema,
      },
      'safetySettings': [
        for (final category in const [
          'HARM_CATEGORY_HARASSMENT',
          'HARM_CATEGORY_HATE_SPEECH',
          'HARM_CATEGORY_SEXUALLY_EXPLICIT',
          'HARM_CATEGORY_DANGEROUS_CONTENT',
        ])
          {'category': category, 'threshold': 'BLOCK_NONE'},
      ],
    };

    var attempt = 0;
    while (true) {
      attempt++;
      cancellation?.throwIfCancelled();
      try {
        final response = await _dio.postUri<dynamic>(
          _endpoint,
          data: body,
          options: Options(
            receiveTimeout: const Duration(seconds: 180),
            validateStatus: (status) => status != null && status < 500,
          ),
        );
        final data = response.data;
        final map = data is Map
            ? data.cast<String, dynamic>()
            : (jsonDecode(data as String) as Map).cast<String, dynamic>();
        _recordUsage(map);
        final candidates = map['candidates'];
        if (candidates is! List || candidates.isEmpty) {
          final feedback = map['promptFeedback'];
          throw TranslationException(
            TranslationErrorKind.parse,
            'Model returned no candidates${feedback == null ? '' : ' ($feedback)'}',
          );
        }
        final candidate = (candidates.first as Map).cast<String, dynamic>();
        final content = (candidate['content'] as Map?)?.cast<String, dynamic>();
        final parts = content?['parts'];
        if (parts is! List || parts.isEmpty) {
          throw const TranslationException(
              TranslationErrorKind.parse, 'Empty response from the model');
        }
        final text = ((parts.first as Map)['text'] ?? '').toString();
        if (text.trim().isEmpty) {
          throw const TranslationException(
              TranslationErrorKind.parse, 'Empty text in response');
        }
        return (text, _usage);
      } on TranslationException {
        rethrow;
      } on DioException catch (e) {
        final status = e.response?.statusCode;
        if (e.type == DioExceptionType.cancel) {
          throw const JobCancelledException();
        }
        if (e.type == DioExceptionType.connectionTimeout ||
            e.type == DioExceptionType.sendTimeout ||
            e.type == DioExceptionType.receiveTimeout) {
          if (attempt >= maxAttempts) {
            throw TranslationException(
                TranslationErrorKind.timeout, 'Request timed out', statusCode: status);
          }
        } else if (status != null) {
          final message = _messageFromError(e.response?.data);
          if (status == 400 || status == 401 || status == 403) {
            throw TranslationException(
              TranslationErrorKind.invalidKey,
              message,
              statusCode: status,
            );
          }
          if (status == 429) {
            final retryAfter = _retryAfterOf(e.response);
            if (retryAfter != null) {
              // Respect the server: wait exactly as long as it asked.
              await Future<void>.delayed(retryAfter);
            }
            if (attempt >= maxAttempts) {
              throw TranslationException(
                TranslationErrorKind.rateLimit,
                message,
                statusCode: status,
                retryAfter: retryAfter,
              );
            }
          } else if (status >= 500) {
            if (attempt >= maxAttempts) {
              throw TranslationException(TranslationErrorKind.server, message,
                  statusCode: status);
            }
          } else {
            throw TranslationException(TranslationErrorKind.unknown, message,
                statusCode: status);
          }
        } else if (attempt >= maxAttempts) {
          throw TranslationException(
              TranslationErrorKind.network, e.message ?? 'Network failure');
        }

        final delay = Duration(
          milliseconds: (400 * math.pow(2, attempt - 1)).round() +
              math.Random().nextInt(250),
        );
        await Future<void>.delayed(delay);
        if (cancellation?.isCancelled ?? false) {
          throw const JobCancelledException();
        }
      } catch (e) {
        throw TranslationException(TranslationErrorKind.unknown, '$e');
      }
    }
  }

  void _recordUsage(Map<String, dynamic> map) {
    final usage = map['usageMetadata'];
    if (usage is! Map) return;
    final prompt = usage['promptTokenCount'];
    final response = usage['candidatesTokenCount'];
    _usage = _usage +
        TokenUsage(
          promptTokens: prompt is num ? prompt.toInt() : 0,
          responseTokens: response is num ? response.toInt() : 0,
        );
  }

  /// Parses the `Retry-After` header (seconds, or an HTTP date).
  static Duration? _retryAfterOf(Response<dynamic>? response) {
    final value = response?.headers.value('retry-after');
    if (value == null) return null;
    final seconds = int.tryParse(value.trim());
    if (seconds != null) {
      return Duration(seconds: seconds.clamp(1, 300));
    }
    try {
      final date = HttpDate.parse(value);
      final delta = date.difference(DateTime.now());
      if (delta.inSeconds <= 0) return null;
      return Duration(seconds: delta.inSeconds.clamp(1, 300));
    } catch (_) {
      return null;
    }
  }

  static String _messageFromError(Object? data) {
    if (data is Map) {
      final error = data['error'];
      if (error is Map) {
        return '${error['message'] ?? error['status'] ?? 'API error'}';
      }
    }
    if (data is String && data.isNotEmpty) {
      return data.length > 240 ? '${data.substring(0, 240)}…' : data;
    }
    return 'API error';
  }

  Map<String, dynamic> _decodeJsonObject(String text) {
    var json = text.trim();
    if (json.startsWith('```')) {
      json = json.replaceAll(RegExp(r'^```(?:json)?'), '').replaceAll(RegExp(r'```$'), '').trim();
    }
    final decoded = jsonDecode(json);
    if (decoded is Map) return decoded.cast<String, dynamic>();
    throw const TranslationException(
        TranslationErrorKind.parse, 'Response was not a JSON object');
  }
}
