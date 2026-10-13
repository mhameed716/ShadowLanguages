import 'strings_ar.dart';
import 'strings_en.dart';

/// Map based localisation (English + Arabic) with an English fallback so a
/// missing translation never breaks the UI.
class Strings {
  const Strings(this.languageCode)
      : _values = languageCode == 'ar' ? arStrings : enStrings,
        _fallback = enStrings;

  final String languageCode;
  final Map<String, String> _values;
  final Map<String, String> _fallback;

  bool get isRtl => languageCode == 'ar';

  TextDirection get direction =>
      isRtl ? TextDirection.rtl : TextDirection.ltr;

  /// Look up [key], interpolating `{name}` placeholders with [args].
  String get(String key, [Map<String, Object>? args]) {
    var value = _values[key] ?? _fallback[key] ?? key;
    if (args != null && args.isNotEmpty) {
      for (final entry in args.entries) {
        value = value.replaceAll('{${entry.key}}', '${entry.value}');
      }
    }
    return value;
  }

  /// Shorthand: `t('start_translation')`
  String call(String key, [Map<String, Object>? args]) => get(key, args);

  static const List<AppLanguage> supported = [
    AppLanguage('en', 'English', 'EN'),
    AppLanguage('ar', 'العربية', 'ع'),
  ];
}

class AppLanguage {
  const AppLanguage(this.code, this.name, this.short);

  final String code;
  final String name;
  final String short;
}
