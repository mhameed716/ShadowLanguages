/// Human readable formatting helpers for the terminal UI.
abstract final class Formatters {
  /// `1.2 MB`, `840 KB`, `312 B`
  static String bytes(int bytes, {int decimals = 1}) {
    if (bytes < 0) return '-';
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(decimals)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(decimals)} MB';
    return '${(mb / 1024).toStringAsFixed(decimals)} GB';
  }

  /// `01:23` / `1:02:03`
  static String duration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (h > 0) return '$h:$m:$s';
    return '$m:$s';
  }

  /// `42%` (rounded, clamped)
  static String percent(double value) =>
      '${(value.clamp(0.0, 1.0) * 100).round()}%';

  /// Collapses whitespace and trims, keeps paragraph breaks readable.
  static String oneLine(String value) =>
      value.replaceAll(RegExp(r'\s+'), ' ').trim();

  /// `shadow_translated_my_book.pdf`
  static String translatedFileName(String sourceName) {
    final name = sourceName.trim();
    final base = name.toLowerCase().endsWith('.pdf')
        ? name.substring(0, name.length - 4)
        : name;
    final safe = base
        .replaceAll(RegExp(r'[^\w\u0600-\u06FF\- ]+'), '')
        .trim()
        .replaceAll(RegExp(r'\s+'), '_');
    final slug = safe.isEmpty ? 'document' : safe;
    return 'shadow_translated_$slug.pdf';
  }

  /// Strips the extension for display purposes.
  static String withoutExtension(String name) {
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? name : name.substring(0, dot);
  }

  /// Shortens long log payloads so the stream stays readable.
  static String truncate(String value, int max) {
    if (value.length <= max) return value;
    return '${value.substring(0, max - 1)}…';
  }
}
