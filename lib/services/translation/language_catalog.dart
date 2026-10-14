import '../pdf/shaping/bidi.dart';

/// A language the user can translate into.
class AppLanguageOption {
  const AppLanguageOption({
    required this.code,
    required this.name,
    required this.nativeName,
    this.rtl = false,
  });

  /// BCP-47-ish code handed to the neural core (`ar`, `zh-CN`, ...).
  final String code;

  /// English name, used for search and display in English.
  final String name;

  /// Endonym, shown next to the English name.
  final String nativeName;

  final bool rtl;

  String get displayName => nativeName == name ? name : '$name · $nativeName';

  @override
  String toString() => '$code — $name';
}

/// Languages offered by the target selector.
///
/// The list is intentionally broad (the model can translate into far more), and
/// [AppLanguageCatalog.byCode] still builds a sensible option for a code that
/// is not listed.
abstract final class AppLanguageCatalog {
  static const List<AppLanguageOption> languages = [
    AppLanguageOption(code: 'ar', name: 'Arabic', nativeName: 'العربية', rtl: true),
    AppLanguageOption(code: 'en', name: 'English', nativeName: 'English'),
    AppLanguageOption(code: 'es', name: 'Spanish', nativeName: 'Español'),
    AppLanguageOption(code: 'fr', name: 'French', nativeName: 'Français'),
    AppLanguageOption(code: 'de', name: 'German', nativeName: 'Deutsch'),
    AppLanguageOption(code: 'it', name: 'Italian', nativeName: 'Italiano'),
    AppLanguageOption(code: 'pt', name: 'Portuguese', nativeName: 'Português'),
    AppLanguageOption(code: 'pt-BR', name: 'Portuguese (Brazil)', nativeName: 'Português (Brasil)'),
    AppLanguageOption(code: 'ru', name: 'Russian', nativeName: 'Русский'),
    AppLanguageOption(code: 'uk', name: 'Ukrainian', nativeName: 'Українська'),
    AppLanguageOption(code: 'pl', name: 'Polish', nativeName: 'Polski'),
    AppLanguageOption(code: 'nl', name: 'Dutch', nativeName: 'Nederlands'),
    AppLanguageOption(code: 'sv', name: 'Swedish', nativeName: 'Svenska'),
    AppLanguageOption(code: 'da', name: 'Danish', nativeName: 'Dansk'),
    AppLanguageOption(code: 'no', name: 'Norwegian', nativeName: 'Norsk'),
    AppLanguageOption(code: 'fi', name: 'Finnish', nativeName: 'Suomi'),
    AppLanguageOption(code: 'is', name: 'Icelandic', nativeName: 'Íslenska'),
    AppLanguageOption(code: 'cs', name: 'Czech', nativeName: 'Čeština'),
    AppLanguageOption(code: 'sk', name: 'Slovak', nativeName: 'Slovenčina'),
    AppLanguageOption(code: 'hu', name: 'Hungarian', nativeName: 'Magyar'),
    AppLanguageOption(code: 'ro', name: 'Romanian', nativeName: 'Română'),
    AppLanguageOption(code: 'bg', name: 'Bulgarian', nativeName: 'Български'),
    AppLanguageOption(code: 'el', name: 'Greek', nativeName: 'Ελληνικά'),
    AppLanguageOption(code: 'tr', name: 'Turkish', nativeName: 'Türkçe'),
    AppLanguageOption(code: 'az', name: 'Azerbaijani', nativeName: 'Azərbaycan'),
    AppLanguageOption(code: 'kk', name: 'Kazakh', nativeName: 'Қазақша'),
    AppLanguageOption(code: 'uz', name: 'Uzbek', nativeName: 'Oʻzbekcha'),
    AppLanguageOption(code: 'fa', name: 'Persian', nativeName: 'فارسی', rtl: true),
    AppLanguageOption(code: 'ps', name: 'Pashto', nativeName: 'پښتو', rtl: true),
    AppLanguageOption(code: 'ku', name: 'Kurdish', nativeName: 'Kurdî', rtl: true),
    AppLanguageOption(code: 'ur', name: 'Urdu', nativeName: 'اردو', rtl: true),
    AppLanguageOption(code: 'hi', name: 'Hindi', nativeName: 'हिन्दी'),
    AppLanguageOption(code: 'bn', name: 'Bengali', nativeName: 'বাংলা'),
    AppLanguageOption(code: 'ta', name: 'Tamil', nativeName: 'தமிழ்'),
    AppLanguageOption(code: 'te', name: 'Telugu', nativeName: 'తెలుగు'),
    AppLanguageOption(code: 'ml', name: 'Malayalam', nativeName: 'മലയാളം'),
    AppLanguageOption(code: 'kn', name: 'Kannada', nativeName: 'ಕನ್ನಡ'),
    AppLanguageOption(code: 'mr', name: 'Marathi', nativeName: 'मराठी'),
    AppLanguageOption(code: 'gu', name: 'Gujarati', nativeName: 'ગુજરાતી'),
    AppLanguageOption(code: 'pa', name: 'Punjabi', nativeName: 'ਪੰਜਾਬੀ'),
    AppLanguageOption(code: 'ne', name: 'Nepali', nativeName: 'नेपाली'),
    AppLanguageOption(code: 'si', name: 'Sinhala', nativeName: 'සිංහල'),
    AppLanguageOption(code: 'he', name: 'Hebrew', nativeName: 'עברית', rtl: true),
    AppLanguageOption(code: 'am', name: 'Amharic', nativeName: 'አማርኛ'),
    AppLanguageOption(code: 'sw', name: 'Swahili', nativeName: 'Kiswahili'),
    AppLanguageOption(code: 'so', name: 'Somali', nativeName: 'Soomaali'),
    AppLanguageOption(code: 'ha', name: 'Hausa', nativeName: 'Hausa'),
    AppLanguageOption(code: 'yo', name: 'Yoruba', nativeName: 'Yorùbá'),
    AppLanguageOption(code: 'ig', name: 'Igbo', nativeName: 'Igbo'),
    AppLanguageOption(code: 'zu', name: 'Zulu', nativeName: 'isiZulu'),
    AppLanguageOption(code: 'af', name: 'Afrikaans', nativeName: 'Afrikaans'),
    AppLanguageOption(code: 'zh', name: 'Chinese (Simplified)', nativeName: '简体中文'),
    AppLanguageOption(code: 'zh-TW', name: 'Chinese (Traditional)', nativeName: '繁體中文'),
    AppLanguageOption(code: 'ja', name: 'Japanese', nativeName: '日本語'),
    AppLanguageOption(code: 'ko', name: 'Korean', nativeName: '한국어'),
    AppLanguageOption(code: 'th', name: 'Thai', nativeName: 'ไทย'),
    AppLanguageOption(code: 'lo', name: 'Lao', nativeName: 'ລາວ'),
    AppLanguageOption(code: 'km', name: 'Khmer', nativeName: 'ខ្មែរ'),
    AppLanguageOption(code: 'my', name: 'Burmese', nativeName: 'မြန်မာ'),
    AppLanguageOption(code: 'vi', name: 'Vietnamese', nativeName: 'Tiếng Việt'),
    AppLanguageOption(code: 'id', name: 'Indonesian', nativeName: 'Bahasa Indonesia'),
    AppLanguageOption(code: 'ms', name: 'Malay', nativeName: 'Bahasa Melayu'),
    AppLanguageOption(code: 'tl', name: 'Filipino', nativeName: 'Filipino'),
    AppLanguageOption(code: 'sr', name: 'Serbian', nativeName: 'Српски'),
    AppLanguageOption(code: 'hr', name: 'Croatian', nativeName: 'Hrvatski'),
    AppLanguageOption(code: 'bs', name: 'Bosnian', nativeName: 'Bosanski'),
    AppLanguageOption(code: 'sl', name: 'Slovenian', nativeName: 'Slovenščina'),
    AppLanguageOption(code: 'mk', name: 'Macedonian', nativeName: 'Македонски'),
    AppLanguageOption(code: 'sq', name: 'Albanian', nativeName: 'Shqip'),
    AppLanguageOption(code: 'et', name: 'Estonian', nativeName: 'Eesti'),
    AppLanguageOption(code: 'lv', name: 'Latvian', nativeName: 'Latviešu'),
    AppLanguageOption(code: 'lt', name: 'Lithuanian', nativeName: 'Lietuvių'),
    AppLanguageOption(code: 'hy', name: 'Armenian', nativeName: 'Հայերեն'),
    AppLanguageOption(code: 'ka', name: 'Georgian', nativeName: 'ქართული'),
    AppLanguageOption(code: 'mn', name: 'Mongolian', nativeName: 'Монгол'),
    AppLanguageOption(code: 'cy', name: 'Welsh', nativeName: 'Cymraeg'),
    AppLanguageOption(code: 'ga', name: 'Irish', nativeName: 'Gaeilge'),
    AppLanguageOption(code: 'eu', name: 'Basque', nativeName: 'Euskara'),
    AppLanguageOption(code: 'ca', name: 'Catalan', nativeName: 'Català'),
    AppLanguageOption(code: 'gl', name: 'Galician', nativeName: 'Galego'),
    AppLanguageOption(code: 'mt', name: 'Maltese', nativeName: 'Malti'),
    AppLanguageOption(code: 'yi', name: 'Yiddish', nativeName: 'ייִדיש', rtl: true),
  ];

  static AppLanguageOption get defaultTarget => byCode('ar');

  static AppLanguageOption byCode(String code) => languages.firstWhere(
        (l) => l.code == code,
        orElse: () => AppLanguageOption(code: code, name: code, nativeName: code),
      );

  /// Case/diacritic insensitive search across codes, names and endonyms.
  static List<AppLanguageOption> search(String query) {
    final q = _normalise(query);
    if (q.isEmpty) return languages;
    return languages.where((l) {
      return _normalise(l.code).contains(q) ||
          _normalise(l.name).contains(q) ||
          _normalise(l.nativeName).contains(q);
    }).toList(growable: false);
  }

  static String _normalise(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[\s\-_()]'), '');

  /// True when [code] is a right-to-left language (used by the reader UI).
  static bool isRtl(String code) =>
      byCode(code).rtl || Bidi.isRtlDominant(_sampleOf(code));

  static const Map<String, String> _samples = {
    'ar': 'اللغة',
    'fa': 'زبان',
    'he': 'שפה',
    'ur': 'زبان',
    'ps': 'ژبه',
    'ku': 'زمان',
    'yi': 'שפּראַך',
  };

  static String _sampleOf(String code) => _samples[code] ?? code;
}
