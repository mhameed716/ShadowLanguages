import '../utils/job_cancellation.dart';

/// Every way a job can fail, in one place.
///
/// Nothing in the app throws a raw [Exception] at the UI: services throw or
/// return, the controller converts to a [Failure], and the UI renders a
/// localised message plus the actions that can actually recover the job
/// ([canRetry] / [canResume]).
enum FailureKind {
  missingKey,
  invalidKey,
  quota,
  rateLimit,
  server,
  network,
  timeout,
  parse,

  fileMissing,
  fileEmpty,
  fileTooLarge,
  fileUnreadable,

  pdfInvalid,
  pdfTruncated,
  pdfEncrypted,
  pdfWrongPassword,
  pdfNoPages,
  pdfNoText,

  fontCoverage,
  storage,
  outOfMemory,
  cancelled,
  unknown,
}

/// A user presentable failure.
class Failure implements Exception {
  const Failure(
    this.kind, {
    required this.messageKey,
    this.argument,
    this.technical,
    this.canRetry = false,
    this.canResume = false,
  });

  final FailureKind kind;

  /// Localisation key, e.g. `err_pdf_encrypted`.
  final String messageKey;

  /// Value for the `{message}`/`{argument}` placeholder of the localised text.
  final String? argument;

  /// Raw error text: shown in the log stream, never as the primary message.
  final String? technical;

  /// Retrying the whole job can plausibly work (network hiccup, 5xx…).
  final bool canRetry;

  /// Enough work was checkpointed that the job can continue where it stopped.
  final bool canResume;

  bool get isCancelled => kind == FailureKind.cancelled;

  bool get isAuth =>
      kind == FailureKind.missingKey || kind == FailureKind.invalidKey;

  bool get isDocument =>
      kind == FailureKind.pdfInvalid ||
      kind == FailureKind.pdfTruncated ||
      kind == FailureKind.pdfEncrypted ||
      kind == FailureKind.pdfWrongPassword ||
      kind == FailureKind.pdfNoPages ||
      kind == FailureKind.pdfNoText ||
      kind == FailureKind.fileMissing ||
      kind == FailureKind.fileEmpty ||
      kind == FailureKind.fileTooLarge ||
      kind == FailureKind.fileUnreadable;

  /// True when the same operation may succeed if the user simply tries again
  /// after fixing the network.
  bool get isTransient =>
      kind == FailureKind.network ||
      kind == FailureKind.timeout ||
      kind == FailureKind.server ||
      kind == FailureKind.rateLimit ||
      kind == FailureKind.quota;

  @override
  String toString() => 'Failure(${kind.name}: $messageKey ${argument ?? ''})';

  // ------------------------------------------------------------------ mapping

  /// Converts anything thrown by the platform, the PDF engine or the network
  /// layer into a [Failure] with the right recovery options.
  static Failure from(Object error, {StackTrace? stack}) {
    final technical = _technical(error, stack);
    return switch (error) {
      Failure() => error,
      JobCancelledException() => Failure(
          FailureKind.cancelled,
          messageKey: 'err_cancelled',
          technical: technical,
        ),
      PdfShieldedException() => Failure(
          error.encrypted
              ? FailureKind.pdfEncrypted
              : FailureKind.pdfWrongPassword,
          messageKey:
              error.encrypted ? 'err_pdf_encrypted' : 'err_pdf_password',
          argument: error.message,
          technical: technical,
        ),
      _ => Failure(
          _kindOf(error),
          messageKey: _keyOf(error),
          argument: _argumentOf(error),
          technical: technical,
          canRetry: _retryable(error),
        ),
    };
  }

  static String _technical(Object error, StackTrace? stack) {
    final text = error.toString();
    if (stack == null) return text;
    final first = stack.toString().split('\n').take(3).join(' | ');
    return '$text — $first';
  }

  static FailureKind _kindOf(Object error) {
    final name = error.runtimeType.toString();
    final text = error.toString().toLowerCase();
    if (error is TranslationException) return _fromTranslation(error);
    if (name == 'PdfParseException' ||
        text.contains('pdfparseexception') ||
        text.contains('damaged') ||
        text.contains('corrupt')) {
      return FailureKind.pdfInvalid;
    }
    if (name == 'PdfPasswordException' ||
        text.contains('password') && text.contains('pdf')) {
      return FailureKind.pdfEncrypted;
    }
    if (name == 'FileSystemException' ||
        name == 'PathAccessException' ||
        name == 'PathNotFoundException') {
      return FailureKind.storage;
    }
    if (text.contains('out of memory') || text.contains('allocation failed')) {
      return FailureKind.outOfMemory;
    }
    if (text.contains('timeout') || text.contains('timed out')) {
      return FailureKind.timeout;
    }
    if (text.contains('socketexception') ||
        text.contains('network') ||
        text.contains('connection') ||
        text.contains('host lookup') ||
        text.contains('failed host')) {
      return FailureKind.network;
    }
    if (text.contains('no api key') || text.contains('api key')) {
      return FailureKind.missingKey;
    }
    return FailureKind.unknown;
  }

  static FailureKind _fromTranslation(TranslationException error) =>
      switch (error.kind) {
        TranslationErrorKind.missingKey => FailureKind.missingKey,
        TranslationErrorKind.invalidKey => FailureKind.invalidKey,
        TranslationErrorKind.quota => FailureKind.quota,
        TranslationErrorKind.rateLimit => FailureKind.rateLimit,
        TranslationErrorKind.server => FailureKind.server,
        TranslationErrorKind.network => FailureKind.network,
        TranslationErrorKind.timeout => FailureKind.timeout,
        TranslationErrorKind.parse => FailureKind.parse,
        TranslationErrorKind.cancelled => FailureKind.cancelled,
        TranslationErrorKind.unknown => FailureKind.unknown,
      };

  static String _keyOf(Object error) => switch (_kindOf(error)) {
        FailureKind.missingKey => 'err_no_api_key',
        FailureKind.invalidKey => 'err_invalid_key',
        FailureKind.quota => 'err_quota',
        FailureKind.rateLimit => 'err_rate_limit',
        FailureKind.server => 'err_server',
        FailureKind.network => 'err_network',
        FailureKind.timeout => 'err_timeout',
        FailureKind.parse => 'err_parse',
        FailureKind.pdfInvalid => 'err_pdf_invalid',
        FailureKind.pdfTruncated => 'err_pdf_truncated',
        FailureKind.pdfEncrypted => 'err_pdf_encrypted',
        FailureKind.pdfWrongPassword => 'err_pdf_password',
        FailureKind.pdfNoPages => 'err_pdf_no_pages',
        FailureKind.pdfNoText => 'err_pdf_no_text',
        FailureKind.fileMissing => 'err_file_missing',
        FailureKind.fileEmpty => 'err_file_empty',
        FailureKind.fileTooLarge => 'err_file_too_large',
        FailureKind.fileUnreadable => 'err_file_unreadable',
        FailureKind.storage => 'err_storage',
        FailureKind.outOfMemory => 'err_memory',
        FailureKind.fontCoverage => 'err_font_coverage',
        FailureKind.cancelled => 'err_cancelled',
        FailureKind.unknown => 'err_unknown',
      };

  static String? _argumentOf(Object error) {
    if (error is TranslationException) {
      final code = error.statusCode;
      return code == null ? error.message : '${error.message} ($code)';
    }
    final text = error.toString();
    return text.length > 200 ? '${text.substring(0, 200)}…' : text;
  }

  static bool _retryable(Object error) => switch (_kindOf(error)) {
        FailureKind.network ||
        FailureKind.timeout ||
        FailureKind.server ||
        FailureKind.rateLimit ||
        FailureKind.quota ||
        FailureKind.unknown =>
          true,
        _ => false,
      };

  // ---------------------------------------------------------------- factories

  static const Failure cancelled = Failure(
    FailureKind.cancelled,
    messageKey: 'err_cancelled',
  );

  static Failure document(FailureKind kind, {String? argument}) => Failure(
        kind,
        messageKey: _keyFromKind(kind),
        argument: argument,
      );

  static String _keyFromKind(FailureKind kind) => switch (kind) {
        FailureKind.missingKey => 'err_no_api_key',
        FailureKind.invalidKey => 'err_invalid_key',
        FailureKind.quota => 'err_quota',
        FailureKind.rateLimit => 'err_rate_limit',
        FailureKind.server => 'err_server',
        FailureKind.network => 'err_network',
        FailureKind.timeout => 'err_timeout',
        FailureKind.parse => 'err_parse',
        FailureKind.pdfInvalid => 'err_pdf_invalid',
        FailureKind.pdfTruncated => 'err_pdf_truncated',
        FailureKind.pdfEncrypted => 'err_pdf_encrypted',
        FailureKind.pdfWrongPassword => 'err_pdf_password',
        FailureKind.pdfNoPages => 'err_pdf_no_pages',
        FailureKind.pdfNoText => 'err_pdf_no_text',
        FailureKind.fileMissing => 'err_file_missing',
        FailureKind.fileEmpty => 'err_file_empty',
        FailureKind.fileTooLarge => 'err_file_too_large',
        FailureKind.fileUnreadable => 'err_file_unreadable',
        FailureKind.storage => 'err_storage',
        FailureKind.outOfMemory => 'err_memory',
        FailureKind.fontCoverage => 'err_font_coverage',
        FailureKind.cancelled => 'err_cancelled',
        FailureKind.unknown => 'err_unknown',
      };
}

/// Raised by [PdfValidator] when the document cannot be opened.
///
/// [encrypted] distinguishes "the file is protected" (ask for a password) from
/// "the password we tried is wrong" (ask again).
class PdfShieldedException implements Exception {
  const PdfShieldedException(this.message, {this.encrypted = true});

  final String message;
  final bool encrypted;

  @override
  String toString() =>
      'PdfShieldedException(${encrypted ? 'encrypted' : 'wrong password'}): $message';
}
