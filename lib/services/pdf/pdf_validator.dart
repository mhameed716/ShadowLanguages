import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pdfrx/pdfrx.dart';

import '../../core/error/failure.dart';
import 'inject/pdf_reader.dart';

/// What the pre-flight check concluded about a file.
enum PdfValidationStatus {
  /// Safe to translate.
  ok,

  /// The document can be processed but the user should know something is odd
  /// (missing `%%EOF`, recovered xref, no copy permission…).
  repairable,

  /// Stop: show the message, do not start the job.
  fatal,
}

/// Why a password attempt failed.
enum PdfUnlockResult { opened, wrongPassword, damaged }

/// Result of the pre-flight check every picked file goes through.
class PdfValidation {
  const PdfValidation({
    required this.status,
    required this.kind,
    required this.messageKey,
    this.detail,
    this.pageCount = 0,
    this.sizeBytes = 0,
    this.isEncrypted = false,
    this.version,
  });

  final PdfValidationStatus status;

  /// Maps straight onto [FailureKind] so the UI can react (ask password, retry…)
  final FailureKind kind;

  /// Localisation key of the message shown to the user.
  final String messageKey;

  /// Raw technical detail for the log stream only.
  final String? detail;

  final int pageCount;
  final int sizeBytes;
  final bool isEncrypted;

  /// `%PDF-1.7` style header when it could be read.
  final String? version;

  bool get isOk => status != PdfValidationStatus.fatal;
  bool get isFatal => status == PdfValidationStatus.fatal;
  bool get needsPassword => isEncrypted;

  Failure toFailure() => Failure(
        kind,
        messageKey: messageKey,
        argument: detail,
        technical: detail,
      );

  @override
  String toString() =>
      'PdfValidation(${status.name}, ${kind.name}, pages=$pageCount)';
}

/// Guards the pipeline against the worst input it can be handed: an empty file,
/// a renamed .docx, a half downloaded PDF, an encrypted book…
///
/// Everything is checked **before** a single byte is sent to the neural core,
/// so the user gets an actionable message instead of a stack trace.
class PdfValidator {
  PdfValidator({this.maxFileBytes = 220 * 1024 * 1024, this.probeEngine = true});

  /// Files bigger than this are refused: PDFium renders whole pages and the
  /// injection keeps the original bytes in memory twice over.
  final int maxFileBytes;

  /// Open the file with the PDF engine as well (catches encryption and damage
  /// the structural parser would happily ignore).
  final bool probeEngine;

  static const int _headerScan = 2048;
  static const int _tailScan = 8192;

  Future<PdfValidation> validateFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      return _fatal(FailureKind.fileMissing, 'err_file_missing');
    }

    int size;
    try {
      size = await file.length();
    } catch (e) {
      return _fatal(FailureKind.fileUnreadable, 'err_file_unreadable', '$e');
    }
    if (size <= 0) {
      return _fatal(FailureKind.fileEmpty, 'err_file_empty', null, size);
    }

    Uint8List head;
    Uint8List tail;
    try {
      final raf = await file.open(mode: FileMode.read);
      try {
        head = await _readAt(raf, 0, _headerScan, size);
        tail =
            await _readAt(raf, (size - _tailScan).clamp(0, size), _tailScan, size);
      } finally {
        await raf.close();
      }
    } catch (e) {
      return _fatal(FailureKind.fileUnreadable, 'err_file_unreadable', '$e', size);
    }

    final version = _readVersion(head);
    if (version == null) {
      return _fatal(FailureKind.pdfInvalid, 'err_pdf_invalid', 'not_a_pdf', size);
    }

    final tailText = latin1.decode(tail, allowInvalid: true);
    final headText = latin1.decode(head, allowInvalid: true);
    final encryptedTrailer =
        tailText.contains('/Encrypt') || headText.contains('/Encrypt');

    if (size > maxFileBytes) {
      return PdfValidation(
        status: PdfValidationStatus.fatal,
        kind: FailureKind.fileTooLarge,
        messageKey: 'err_file_too_large',
        detail: '$size bytes',
        sizeBytes: size,
        version: version,
      );
    }

    final hasEof = tailText.contains('%%EOF');

    // ------------------------------------------------ structural parse (ours)
    int pageCount = 0;
    String? structureError;
    try {
      final reader = PdfFileReader(await file.readAsBytes());
      pageCount = reader.pageCount;
      reader.catalog; // throws when the catalog cannot be resolved
    } catch (e) {
      structureError = '$e';
    }

    if (structureError != null) {
      // A missing %%EOF with a broken xref is the classic "download cut off".
      return PdfValidation(
        status: PdfValidationStatus.fatal,
        kind: hasEof ? FailureKind.pdfInvalid : FailureKind.pdfTruncated,
        messageKey: hasEof ? 'err_pdf_invalid' : 'err_pdf_truncated',
        detail: structureError,
        sizeBytes: size,
        version: version,
      );
    }
    if (pageCount <= 0) {
      return _fatal(FailureKind.pdfNoPages, 'err_pdf_no_pages', null, size, version);
    }

    // --------------------------------------------------- engine probe (PDFium)
    if (probeEngine) {
      final probe = await tryUnlock(path, null, detectOnly: true);
      if (probe == PdfUnlockResult.wrongPassword) {
        return PdfValidation(
          status: PdfValidationStatus.fatal,
          kind: FailureKind.pdfEncrypted,
          messageKey: 'err_pdf_encrypted',
          detail: 'PDFium: password required',
          pageCount: pageCount,
          sizeBytes: size,
          isEncrypted: true,
          version: version,
        );
      }
      if (probe == PdfUnlockResult.damaged) {
        return PdfValidation(
          status: PdfValidationStatus.fatal,
          kind: hasEof ? FailureKind.pdfInvalid : FailureKind.pdfTruncated,
          messageKey: hasEof ? 'err_pdf_invalid' : 'err_pdf_truncated',
          detail: 'PDFium refused the document',
          sizeBytes: size,
          version: version,
        );
      }
    } else if (encryptedTrailer) {
      return PdfValidation(
        status: PdfValidationStatus.fatal,
        kind: FailureKind.pdfEncrypted,
        messageKey: 'err_pdf_encrypted',
        pageCount: pageCount,
        sizeBytes: size,
        isEncrypted: true,
        version: version,
      );
    }

    if (!hasEof) {
      // The parser recovered the document anyway: warn but continue.
      return PdfValidation(
        status: PdfValidationStatus.repairable,
        kind: FailureKind.pdfTruncated,
        messageKey: 'err_pdf_missing_eof',
        pageCount: pageCount,
        sizeBytes: size,
        version: version,
      );
    }

    return PdfValidation(
      status: PdfValidationStatus.ok,
      kind: FailureKind.unknown,
      messageKey: 'pdf_ok',
      pageCount: pageCount,
      sizeBytes: size,
      version: version,
    );
  }

  /// Cheap check on already loaded bytes (used after a re-pick or a resume).
  PdfValidation validateBytes(Uint8List data) {
    if (data.isEmpty) return _fatal(FailureKind.fileEmpty, 'err_file_empty');
    final head = Uint8List.sublistView(
      data,
      0,
      data.length < _headerScan ? data.length : _headerScan,
    );
    final version = _readVersion(head);
    if (version == null) {
      return _fatal(FailureKind.pdfInvalid, 'err_pdf_invalid', 'not_a_pdf',
          data.length);
    }
    return PdfValidation(
      status: PdfValidationStatus.ok,
      kind: FailureKind.unknown,
      messageKey: 'pdf_ok',
      sizeBytes: data.length,
      version: version,
    );
  }

  /// Tries to open [path].
  ///
  /// * [password] `null` + [detectOnly] → tells whether the file is protected.
  /// * [password] set → tells whether that password is the right one.
  ///
  /// Never throws: a broken engine or an unreadable file is reported as
  /// [PdfUnlockResult.damaged].
  Future<PdfUnlockResult> tryUnlock(
    String path,
    String? password, {
    bool detectOnly = false,
  }) async {
    PdfDocument? document;
    try {
      document = await PdfDocument.openFile(
        path,
        passwordProvider: detectOnly
            ? () => null
            : createSimplePasswordProvider(password ?? ''),
        firstAttemptByEmptyPassword: detectOnly,
      );
      // Touch the page list so a broken page tree is caught here, later.
      document.pages.length;
      return PdfUnlockResult.opened;
    } on PdfPasswordException {
      return detectOnly
          ? PdfUnlockResult.wrongPassword // == "a password is required"
          : PdfUnlockResult.wrongPassword;
    } on PdfException {
      return PdfUnlockResult.damaged;
    } catch (_) {
      return PdfUnlockResult.damaged;
    } finally {
      await document?.dispose();
    }
  }

  // ------------------------------------------------------------------ helpers

  static Future<Uint8List> _readAt(
      RandomAccessFile raf, int offset, int length, int fileSize) async {
    final start = offset.clamp(0, fileSize);
    final end = (start + length).clamp(0, fileSize);
    if (end <= start) return Uint8List(0);
    await raf.setPosition(start);
    return await raf.read(end - start);
  }

  /// Returns `%PDF-1.7` when the header is present (PDF tolerates junk before).
  static String? _readVersion(Uint8List head) {
    final text = latin1.decode(head, allowInvalid: true);
    final match = RegExp(r'%PDF-\d\.\d').firstMatch(text);
    return match?.group(0);
  }

  PdfValidation _fatal(
    FailureKind kind,
    String messageKey, [
    String? detail,
    int sizeBytes = 0,
    String? version,
  ]) =>
      PdfValidation(
        status: PdfValidationStatus.fatal,
        kind: kind,
        messageKey: messageKey,
        detail: detail,
        sizeBytes: sizeBytes,
        version: version,
      );
}
