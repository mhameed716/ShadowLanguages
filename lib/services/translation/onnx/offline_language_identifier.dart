import '../gemini_client.dart' show LanguageDetection;
import 'flores.dart';

/// Offline language identification.
///
/// There is no room on a phone for a 100 MB language-ID model, and no network
/// to call one, so this is a two signal scorer:
///
/// 1. **Script** — which Unicode blocks the text lives in. Arabic script narrows
///    the field to Arabic/Persian/Urdu/Pashto/Kurdish immediately.
/// 2. **Function words** — every language has a handful of words that appear in
///    almost every paragraph (`the`, `der`, `ال`, `の`…). Counting them is
///    cheap, deterministic and needs no model.
///
/// The two scores are combined into a confidence in the 0..100 range — the
/// same shape the cloud detector returned, so the terminal line keeps reading
/// `[System]: Source language detected successfully: [English - 99.9%]`.
class OfflineLanguageIdentifier {
  const OfflineLanguageIdentifier({this.uiLanguageCode = 'ar'});

  final String uiLanguageCode;

  static const int _minSample = 24;

  /// Identifies [sample]; returns `und` when the text is too short.
  LanguageDetection identify(String sample) {
    final text = sample.trim();
    if (text.length < _minSample) {
      return LanguageDetection(
        code: 'und',
        name: uiLanguageCode == 'ar' ? 'غير محدد' : 'Unknown',
        confidence: 0,
      );
    }

    final script = _scriptOf(text);
    final words = _words(text);
    final totalWords = words.length;
    final lower = text.toLowerCase();

    FloresLanguage best = FloresCatalog.byCode('eng_Latn');
    var bestScore = -1.0;

    for (final candidate in _profiles) {
      var score = 0.0;

      // 1. script agreement
      if (candidate.script == script) {
        score += 1;
      } else if (_compatible(candidate.script, script)) {
        score += 0.4;
      } else {
        continue; // a Hebrew profile cannot explain Cyrillic text
      }

      // 2. function words
      var hits = 0;
      for (final marker in candidate.markers) {
        if (lower.contains(marker)) hits++;
      }
      if (candidate.markers.isNotEmpty) {
        score += 3 * (hits / candidate.markers.length);
      }

      // 3. word level hits (stronger signal than a substring scan)
      if (totalWords > 3) {
        var wordHits = 0;
        for (final word in words) {
          if (candidate.words.contains(word)) wordHits++;
        }
        score += 4 * (wordHits / totalWords) * 5;
      }

      // 4. letters that only this language uses. Ukrainian "і/ї/є/ґ" against
      //    Russian "ы/ъ/э" is the classic case: two profiles that share every
      //    function word and are told apart by four glyphs.
      if (candidate.distinctive.isNotEmpty) {
        var found = 0;
        for (final rune in text.runes) {
          if (candidate.distinctive.contains(rune)) found++;
        }
        if (found > 0) score += 2 * (found > 5 ? 1.0 : found / 5);
      }

      if (score > bestScore) {
        bestScore = score;
        best = candidate.language;
      }
    }

    final confidence = _toConfidence(bestScore, script);
    final flores = FloresCatalog.byCode(best.code);
    return LanguageDetection(
      code: flores.code,
      name: flores.nameFor(uiLanguageCode),
      confidence: confidence,
    );
  }

  /// How far a script alone carries the answer.
  ///
  /// Some writing systems belong to exactly one language of our table, so the
  /// script is decisive even when the text has no spaces and the function-word
  /// score stays low (Japanese, Korean, Thai…). Others are shared by a family
  /// (Latin, Arabic, Cyrillic) and only raise the floor.
  static const Map<String, double> _scriptFloor = {
    'Jpan': 99.0,
    'Hang': 98.0,
    'Khmr': 96.0,
    'Laoo': 96.0,
    'Mymr': 96.0,
    'Thai': 95.0,
    'Grek': 94.0,
    'Hebr': 94.0,
    'Armn': 93.0,
    'Geor': 93.0,
    'Sinh': 93.0,
    'Ethi': 92.0,
    'Hans': 90.0,
    'Hant': 90.0,
    'Gujr': 88.0,
    'Guru': 88.0,
    'Knda': 88.0,
    'Mlym': 88.0,
    'Orya': 88.0,
    'Taml': 88.0,
    'Telu': 88.0,
    'Beng': 85.0,
    'Olck': 80.0,
    'Deva': 72.0,
    'Arab': 70.0,
    'Cyrl': 70.0,
    'Tibt': 85.0,
    'Nkoo': 90.0,
    'Tfng': 85.0,
  };

  /// Maps the raw score onto something a human reads as a probability.
  static double _toConfidence(double score, String script) {
    // A script match alone is worth ~55%; strong function word evidence pushes
    // towards 99.9. CJK scripts get a bonus because their signal is unambiguous.
    final bonus = (script == 'Hans' || script == 'Hant' || script == 'Jpan' ||
            script == 'Hang' || script == 'Thai' || script == 'Hebr' ||
            script == 'Arab')
        ? 0.6
        : 0.0;
    final value = (score + bonus) / 5.6 * 100;
    final floor = _scriptFloor[script] ?? 0.0;
    final result = value > floor ? value : floor;
    if (result <= 35) return 35;
    return result > 99.9 ? 99.9 : double.parse(result.toStringAsFixed(1));
  }

  /// Which script dominates the sample.
  static String _scriptOf(String text) {
    final counts = <String, int>{};
    for (final rune in text.runes) {
      final script = _scriptOfRune(rune);
      if (script == null) continue;
      counts[script] = (counts[script] ?? 0) + 1;
    }
    if (counts.isEmpty) return 'Latn';
    var best = 'Latn';
    var bestCount = 0;
    for (final entry in counts.entries) {
      if (entry.value > bestCount) {
        best = entry.key;
        bestCount = entry.value;
      }
    }
    return best;
  }

  static String? _scriptOfRune(int rune) {
    if (rune >= 0x0600 && rune <= 0x06FF) return 'Arab';
    if (rune >= 0x0750 && rune <= 0x077F) return 'Arab';
    if (rune >= 0xFB50 && rune <= 0xFDFF) return 'Arab';
    if (rune >= 0xFE70 && rune <= 0xFEFF) return 'Arab';
    if (rune >= 0x0590 && rune <= 0x05FF) return 'Hebr';
    if (rune >= 0x0400 && rune <= 0x04FF) return 'Cyrl';
    if (rune >= 0x0370 && rune <= 0x03FF) return 'Grek';
    if (rune >= 0x0900 && rune <= 0x097F) return 'Deva';
    if (rune >= 0x0980 && rune <= 0x09FF) return 'Beng';
    if (rune >= 0x0A80 && rune <= 0x0AFF) return 'Gujr';
    if (rune >= 0x0A00 && rune <= 0x0A7F) return 'Guru';
    if (rune >= 0x0C80 && rune <= 0x0CFF) return 'Knda';
    if (rune >= 0x0D00 && rune <= 0x0D7F) return 'Mlym';
    if (rune >= 0x0B00 && rune <= 0x0B7F) return 'Orya';
    if (rune >= 0x0B80 && rune <= 0x0BFF) return 'Taml';
    if (rune >= 0x0C00 && rune <= 0x0C7F) return 'Telu';
    if (rune >= 0x0D80 && rune <= 0x0DFF) return 'Sinh';
    if (rune >= 0x0E00 && rune <= 0x0E7F) return 'Thai';
    if (rune >= 0x0E80 && rune <= 0x0EFF) return 'Laoo';
    if (rune >= 0x1000 && rune <= 0x109F) return 'Mymr';
    if (rune >= 0x1780 && rune <= 0x17FF) return 'Khmr';
    if (rune >= 0x1200 && rune <= 0x137F) return 'Ethi';
    if (rune >= 0x0530 && rune <= 0x058F) return 'Armn';
    if (rune >= 0x10A0 && rune <= 0x10FF) return 'Geor';
    if (rune >= 0x3040 && rune <= 0x30FF) return 'Jpan';
    if (rune >= 0x4E00 && rune <= 0x9FFF) return 'Hans';
    if (rune >= 0xAC00 && rune <= 0xD7AF) return 'Hang';
    if (rune >= 0x0041 && rune <= 0x024F) return 'Latn';
    return null;
  }

  /// Latin text can be many languages; Arabic script covers several too.
  static bool _compatible(String candidate, String actual) {
    const groups = {
      'Arab': ['Arab'],
      'Latn': ['Latn'],
      'Cyrl': ['Cyrl'],
    };
    return groups[candidate]?.contains(actual) ?? false;
  }

  static List<String> _words(String text) => text
      .toLowerCase()
      .split(RegExp(r'[^\p{L}\p{N}’\']+', unicode: true))
      .where((word) => word.length > 1)
      .take(400)
      .toList(growable: false);

  // ------------------------------------------------------------- the profiles

  static const List<_Profile> _profiles = [
    _Profile('eng_Latn', 'Latn', [' the ', ' and ', ' of ', ' to ', ' is '],
        {'the', 'and', 'of', 'to', 'is', 'in', 'that', 'for', 'with', 'was'}),
    _Profile('fra_Latn', 'Latn', [' le ', ' la ', ' les ', ' des ', ' est '],
        {'le', 'la', 'les', 'des', 'est', 'une', 'dans', 'pour', 'avec', 'que'}),
    _Profile('deu_Latn', 'Latn', [' der ', ' die ', ' und ', ' das ', ' ist '],
        {'der', 'die', 'und', 'das', 'ist', 'nicht', 'mit', 'sich', 'auf', 'für'}),
    _Profile('spa_Latn', 'Latn', [' el ', ' la ', ' de ', ' que ', ' los '],
        {'el', 'la', 'de', 'que', 'los', 'del', 'una', 'por', 'para', 'con'}),
    _Profile('por_Latn', 'Latn', [' de ', ' que ', ' não ', ' com ', ' uma '],
        {'de', 'que', 'não', 'com', 'uma', 'para', 'por', 'mais', 'como', 'dos'}),
    _Profile('ita_Latn', 'Latn', [' il ', ' che ', ' non ', ' per ', ' con '],
        {'il', 'che', 'non', 'per', 'con', 'una', 'del', 'della', 'sono', 'nel'}),
    _Profile('nld_Latn', 'Latn', [' de ', ' het ', ' een ', ' van ', ' niet '],
        {'de', 'het', 'een', 'van', 'niet', 'met', 'voor', 'op', 'zijn', 'die'}),
    _Profile('tur_Latn', 'Latn', [' bir ', ' ve ', ' bu ', ' için ', ' ile '],
        {'bir', 've', 'bu', 'için', 'ile', 'olarak', 'daha', 'çok', 'var', 'olan'}),
    _Profile('pol_Latn', 'Latn', [' nie ', ' jest ', ' się ', ' na ', ' do '],
        {'nie', 'jest', 'się', 'na', 'do', 'że', 'jak', 'przez', 'oraz', 'tylko'}),
    _Profile('ron_Latn', 'Latn', [' și ', ' de ', ' este ', ' cu ', ' pentru '],
        {'și', 'de', 'este', 'cu', 'pentru', 'care', 'din', 'sau', 'mai', 'al'}),
    _Profile('ces_Latn', 'Latn', [' a ', ' je ', ' na ', ' se ', ' pro '],
        {'a', 'je', 'na', 'se', 'pro', 'který', 'jak', 'ale', 'nebo', 'byl'}),
    _Profile('hun_Latn', 'Latn', [' a ', ' az ', ' és ', ' nem ', ' hogy '],
        {'a', 'az', 'és', 'nem', 'hogy', 'egy', 'van', 'de', 'meg', 'csak'}),
    _Profile('fin_Latn', 'Latn', [' ja ', ' on ', ' ei ', ' että ', ' se '],
        {'ja', 'on', 'ei', 'että', 'se', 'oli', 'kuin', 'mutta', 'hän', 'tämä'}),
    _Profile('ind_Latn', 'Latn', [' dan ', ' yang ', ' untuk ', ' tidak ', ' ini '],
        {'dan', 'yang', 'untuk', 'tidak', 'ini', 'dengan', 'dari', 'akan', 'pada'}),
    _Profile('zsm_Latn', 'Latn', [' dan ', ' yang ', ' untuk ', ' tidak ', ' ini '],
        {'dan', 'yang', 'untuk', 'tidak', 'ini', 'dengan', 'dari', 'akan', 'pada'}),
    _Profile('vie_Latn', 'Latn', [' và ', ' của ', ' không ', ' các ', ' này '],
        {'và', 'của', 'không', 'các', 'này', 'trong', 'được', 'một', 'cho', 'với'}),
    _Profile('rus_Cyrl', 'Cyrl', [' и ', ' в ', ' не ', ' что ', ' на '],
        {'и', 'в', 'не', 'что', 'на', 'с', 'по', 'для', 'как', 'это'},
        {0x044B, 0x044A, 0x044D}),
    _Profile('ukr_Cyrl', 'Cyrl', [' і ', ' в ', ' не ', ' на ', ' що '],
        {'і', 'в', 'не', 'на', 'що', 'з', 'та', 'для', 'як', 'це'},
        {0x0456, 0x0457, 0x0454, 0x0491}),
    _Profile('ell_Grek', 'Grek', [' και ', ' το ', ' της ', ' είναι ', ' για '],
        {'και', 'το', 'της', 'είναι', 'για', 'με', 'στο', 'τα', 'του', 'από'}),
    _Profile('arb_Arab', 'Arab', [' ال', ' في ', ' من ', ' على ', ' أن '],
        {'في', 'من', 'على', 'أن', 'إلى', 'عن', 'مع', 'هذا', 'كان', 'التي'}),
    _Profile('pes_Arab', 'Arab', [' ال', ' در ', ' به ', ' از ', ' که '],
        {'در', 'به', 'از', 'که', 'را', 'با', 'این', 'برای', 'است', 'های'},
        {0x06CC, 0x06A9, 0x06AF, 0x0698, 0x0686, 0x067E}),
    _Profile('urd_Arab', 'Arab', [' کے ', ' کی ', ' میں ', ' اور ', ' ہے '],
        {'کے', 'کی', 'میں', 'اور', 'ہے', 'سے', 'کا', 'نے', 'پر', 'تھا'},
        {0x06D2, 0x0679, 0x0688, 0x067A, 0x06BE, 0x0649}),
    _Profile('heb_Hebr', 'Hebr', [' את ', ' של ', ' לא ', ' על ', ' כי '],
        {'את', 'של', 'לא', 'על', 'כי', 'עם', 'זה', 'הוא', 'כל', 'אשר'}),
    _Profile('hin_Deva', 'Deva', [' के ', ' की ', ' में ', ' और ', ' है '],
        {'के', 'की', 'में', 'और', 'है', 'से', 'का', 'पर', 'यह', 'थे'}),
    _Profile('mar_Deva', 'Deva', const [' च्या ', ' ची ', ' मध्ये ', ' आणि ', ' आहे '],
        {'च्या', 'ची', 'मध्ये', 'आणि', 'आहे', 'ते', 'होते', 'करून', 'मात्र'}),
    _Profile('ben_Beng', 'Beng', const [' এর ', ' এবং ', ' এই ', ' জন্য ', ' হয় '],
        {'এর', 'এবং', 'এই', 'জন্য', 'হয়', 'করে', 'থেকে', 'আছে', 'একটি'}),
    _Profile('tha_Thai', 'Thai', const ['และ', 'ของ', 'ที่', 'ใน', 'เป็น'],
        {'และ', 'ของ', 'ที่', 'ใน', 'เป็น', 'ไม่', 'มี', 'การ', 'ได้', 'ไป'}),
    _Profile('zho_Hans', 'Hans', const ['的', '是', '在', '和', '不'],
        {'的', '是', '在', '和', '不', '了', '有', '我', '他', '这'}),
    _Profile('zho_Hant', 'Hant', const ['的', '是', '在', '和', '不'],
        {'的', '是', '在', '和', '不', '了', '有', '我', '他', '這'}),
    _Profile('jpn_Jpan', 'Jpan', const ['の', 'に', 'は', 'を', 'が'],
        {'の', 'に', 'は', 'を', 'が', 'で', 'と', 'も', 'た', 'する'}),
    _Profile('kor_Hang', 'Hang', const ['이', '의', '에', '를', '은'],
        {'이', '의', '에', '를', '은', '는', '과', '하다', '있다', '그'}),
    _Profile('amh_Ethi', 'Ethi', const ['እና', 'የ', 'ነው', 'በ', 'ላይ'],
        {'እና', 'የ', 'ነው', 'በ', 'ላይ', 'ወደ', 'ከ', 'ስለ'}),
  ];
}

/// One candidate language.
class _Profile {
  const _Profile(this.code, this.script, this.markers, this.words,
      [this.distinctive = const {}]);

  final String code;
  final String script;

  /// Substring markers (already padded with spaces when meaningful).
  final List<String> markers;

  /// Exact word hits.
  final Set<String> words;

  /// Code points that practically only occur in this language.
  final Set<int> distinctive;

  FloresLanguage get language => FloresCatalog.byCode(code);
}
