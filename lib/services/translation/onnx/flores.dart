/// The 200 languages NLLB-200 was trained on (Flores-200 codes).
///
/// NLLB does not take a BCP-47 tag: it takes a language **token** such as
/// `arb_Arab` or `eng_Latn`, written in the model vocabulary. This table is the
/// bridge between the language the user picks and that token, with English and
/// Arabic names for the UI.
class FloresLanguage {
  const FloresLanguage({
    required this.code,
    required this.english,
    required this.arabic,
    required this.script,
    this.rtl = false,
    this.popular = false,
  });

  /// NLLB token, e.g. `arb_Arab`.
  final String code;

  final String english;
  final String arabic;

  /// Writing system: `Arab`, `Latn`, `Cyrl`, `Deva`, … (for OCR + shaping).
  final String script;

  final bool rtl;
  final bool popular;

  String get scriptCode => code.split('_').length > 1 ? code.split('_').last : '';

  String nameFor(String languageCode) =>
      languageCode == 'ar' ? arabic : english;

  @override
  String toString() => code;
}

/// The catalogue, ordered with the widely used languages first.
abstract final class FloresCatalog {
  /// Every language NLLB-200 knows, including the script variants.
  static const List<FloresLanguage> languages = [
    // ------------------------------------------------------- the popular ones
    FloresLanguage(
        code: 'arb_Arab',
        english: 'Arabic',
        arabic: 'العربية',
        script: 'Arab',
        rtl: true,
        popular: true),
    FloresLanguage(
        code: 'eng_Latn',
        english: 'English',
        arabic: 'الإنجليزية',
        script: 'Latn',
        popular: true),
    FloresLanguage(
        code: 'fra_Latn',
        english: 'French',
        arabic: 'الفرنسية',
        script: 'Latn',
        popular: true),
    FloresLanguage(
        code: 'spa_Latn',
        english: 'Spanish',
        arabic: 'الإسبانية',
        script: 'Latn',
        popular: true),
    FloresLanguage(
        code: 'deu_Latn',
        english: 'German',
        arabic: 'الألمانية',
        script: 'Latn',
        popular: true),
    FloresLanguage(
        code: 'tur_Latn',
        english: 'Turkish',
        arabic: 'التركية',
        script: 'Latn',
        popular: true),
    FloresLanguage(
        code: 'rus_Cyrl',
        english: 'Russian',
        arabic: 'الروسية',
        script: 'Cyrl',
        popular: true),
    FloresLanguage(
        code: 'zho_Hans',
        english: 'Chinese (Simplified)',
        arabic: 'الصينية المبسطة',
        script: 'Hans',
        popular: true),
    FloresLanguage(
        code: 'zho_Hant',
        english: 'Chinese (Traditional)',
        arabic: 'الصينية التقليدية',
        script: 'Hant',
        popular: true),
    FloresLanguage(
        code: 'jpn_Jpan',
        english: 'Japanese',
        arabic: 'اليابانية',
        script: 'Jpan',
        popular: true),
    FloresLanguage(
        code: 'kor_Hang',
        english: 'Korean',
        arabic: 'الكورية',
        script: 'Hang',
        popular: true),
    FloresLanguage(
        code: 'hin_Deva',
        english: 'Hindi',
        arabic: 'الهندية',
        script: 'Deva',
        popular: true),
    FloresLanguage(
        code: 'urd_Arab',
        english: 'Urdu',
        arabic: 'الأردية',
        script: 'Arab',
        rtl: true,
        popular: true),
    FloresLanguage(
        code: 'pes_Arab',
        english: 'Persian',
        arabic: 'الفارسية',
        script: 'Arab',
        rtl: true,
        popular: true),
    FloresLanguage(
        code: 'ita_Latn',
        english: 'Italian',
        arabic: 'الإيطالية',
        script: 'Latn',
        popular: true),
    FloresLanguage(
        code: 'por_Latn',
        english: 'Portuguese',
        arabic: 'البرتغالية',
        script: 'Latn',
        popular: true),
    FloresLanguage(
        code: 'nld_Latn',
        english: 'Dutch',
        arabic: 'الهولندية',
        script: 'Latn',
        popular: true),
    FloresLanguage(
        code: 'ind_Latn',
        english: 'Indonesian',
        arabic: 'الإندونيسية',
        script: 'Latn',
        popular: true),
    FloresLanguage(
        code: 'zsm_Latn',
        english: 'Malay',
        arabic: 'الملايوية',
        script: 'Latn',
        popular: true),
    FloresLanguage(
        code: 'heb_Hebr',
        english: 'Hebrew',
        arabic: 'العبرية',
        script: 'Hebr',
        rtl: true,
        popular: true),
    FloresLanguage(
        code: 'swh_Latn',
        english: 'Swahili',
        arabic: 'السواحلية',
        script: 'Latn',
        popular: true),

    // -------------------------------------------------------------- Arabic
    FloresLanguage(
        code: 'arz_Arab',
        english: 'Egyptian Arabic',
        arabic: 'العربية المصرية',
        script: 'Arab',
        rtl: true),
    FloresLanguage(
        code: 'ary_Arab',
        english: 'Moroccan Arabic',
        arabic: 'العربية المغربية',
        script: 'Arab',
        rtl: true),
    FloresLanguage(
        code: 'apc_Arab',
        english: 'North Levantine Arabic',
        arabic: 'العربية الشامية الشمالية',
        script: 'Arab',
        rtl: true),
    FloresLanguage(
        code: 'ajp_Arab',
        english: 'South Levantine Arabic',
        arabic: 'العربية الشامية الجنوبية',
        script: 'Arab',
        rtl: true),
    FloresLanguage(
        code: 'ars_Arab',
        english: 'Najdi Arabic',
        arabic: 'العربية النجدية',
        script: 'Arab',
        rtl: true),
    FloresLanguage(
        code: 'arb_Latn',
        english: 'Arabic (Romanised)',
        arabic: 'العربية بالحروف اللاتينية',
        script: 'Latn'),
    FloresLanguage(
        code: 'prs_Arab',
        english: 'Dari',
        arabic: 'الدرية',
        script: 'Arab',
        rtl: true),
    FloresLanguage(
        code: 'snd_Arab',
        english: 'Sindhi',
        arabic: 'السندية',
        script: 'Arab',
        rtl: true),
    FloresLanguage(
        code: 'ckb_Arab',
        english: 'Central Kurdish',
        arabic: 'الكردية السورانية',
        script: 'Arab',
        rtl: true),
    FloresLanguage(
        code: 'kmr_Latn',
        english: 'Northern Kurdish',
        arabic: 'الكردية الكرمانجية',
        script: 'Latn'),
    FloresLanguage(
        code: 'pbt_Psqt',
        english: 'Southern Pashto',
        arabic: 'البشتو الجنوبية',
        script: 'Arab',
        rtl: true),
    FloresLanguage(
        code: 'uig_Arab',
        english: 'Uyghur',
        arabic: 'الأويغورية',
        script: 'Arab',
        rtl: true),
    FloresLanguage(
        code: 'azb_Arab',
        english: 'South Azerbaijani',
        arabic: 'الأذربيجانية الجنوبية',
        script: 'Arab',
        rtl: true),
    FloresLanguage(
        code: 'uzs_Arab',
        english: 'Southern Uzbek',
        arabic: 'الأوزبكية الجنوبية',
        script: 'Arab',
        rtl: true),
    FloresLanguage(
        code: 'knc_Arab',
        english: 'Central Kanuri (Arabic)',
        arabic: 'الكانورية (عربي)',
        script: 'Arab',
        rtl: true),
    FloresLanguage(
        code: 'kas_Arab',
        english: 'Kashmiri (Arabic)',
        arabic: 'الكشميرية (عربي)',
        script: 'Arab',
        rtl: true),
    FloresLanguage(
        code: 'bjn_Arab',
        english: 'Banjar (Arabic)',
        arabic: 'البنجارية (عربي)',
        script: 'Arab',
        rtl: true),
    FloresLanguage(
        code: 'ace_Arab',
        english: 'Acehnese (Arabic)',
        arabic: 'الأتشينيه (عربي)',
        script: 'Arab',
        rtl: true),

    // -------------------------------------------------------------- Latin
    FloresLanguage(code: 'afr_Latn', english: 'Afrikaans', arabic: 'الأفريكانية', script: 'Latn'),
    FloresLanguage(code: 'als_Latn', english: 'Tosk Albanian', arabic: 'الألبانية (توسك)', script: 'Latn'),
    FloresLanguage(code: 'ast_Latn', english: 'Asturian', arabic: 'الأستورية', script: 'Latn'),
    FloresLanguage(code: 'ayr_Latn', english: 'Southern Aymara', arabic: 'الأيمارا الجنوبية', script: 'Latn'),
    FloresLanguage(code: 'azj_Latn', english: 'North Azerbaijani', arabic: 'الأذربيجانية الشمالية', script: 'Latn'),
    FloresLanguage(code: 'bam_Latn', english: 'Bambara', arabic: 'البامبارا', script: 'Latn'),
    FloresLanguage(code: 'ban_Latn', english: 'Balinese', arabic: 'البالية', script: 'Latn'),
    FloresLanguage(code: 'bem_Latn', english: 'Bemba', arabic: 'البيمبا', script: 'Latn'),
    FloresLanguage(code: 'bjn_Latn', english: 'Banjar (Latin)', arabic: 'البنجارية (لاتيني)', script: 'Latn'),
    FloresLanguage(code: 'bos_Latn', english: 'Bosnian', arabic: 'البوسنية', script: 'Latn'),
    FloresLanguage(code: 'bug_Latn', english: 'Buginese', arabic: 'البوغينية', script: 'Latn'),
    FloresLanguage(code: 'cat_Latn', english: 'Catalan', arabic: 'الكتالانية', script: 'Latn'),
    FloresLanguage(code: 'ceb_Latn', english: 'Cebuano', arabic: 'السيبوانية', script: 'Latn'),
    FloresLanguage(code: 'ces_Latn', english: 'Czech', arabic: 'التشيكية', script: 'Latn'),
    FloresLanguage(code: 'cjk_Latn', english: 'Chokwe', arabic: 'التشوكوية', script: 'Latn'),
    FloresLanguage(code: 'crh_Latn', english: 'Crimean Tatar', arabic: 'التترية القرمية', script: 'Latn'),
    FloresLanguage(code: 'cym_Latn', english: 'Welsh', arabic: 'الويلزية', script: 'Latn'),
    FloresLanguage(code: 'dan_Latn', english: 'Danish', arabic: 'الدنماركية', script: 'Latn'),
    FloresLanguage(code: 'dik_Latn', english: 'Southwestern Dinka', arabic: 'الدينكا الجنوبية', script: 'Latn'),
    FloresLanguage(code: 'dyu_Latn', english: 'Dyula', arabic: 'الديولية', script: 'Latn'),
    FloresLanguage(code: 'epo_Latn', english: 'Esperanto', arabic: 'الإسبرانتو', script: 'Latn'),
    FloresLanguage(code: 'est_Latn', english: 'Estonian', arabic: 'الإستونية', script: 'Latn'),
    FloresLanguage(code: 'eus_Latn', english: 'Basque', arabic: 'الباسكية', script: 'Latn'),
    FloresLanguage(code: 'ewe_Latn', english: 'Ewe', arabic: 'الإيوية', script: 'Latn'),
    FloresLanguage(code: 'fao_Latn', english: 'Faroese', arabic: 'الفاروية', script: 'Latn'),
    FloresLanguage(code: 'fij_Latn', english: 'Fijian', arabic: 'الفيجية', script: 'Latn'),
    FloresLanguage(code: 'fin_Latn', english: 'Finnish', arabic: 'الفنلندية', script: 'Latn'),
    FloresLanguage(code: 'fon_Latn', english: 'Fon', arabic: 'الفونية', script: 'Latn'),
    FloresLanguage(code: 'fur_Latn', english: 'Friulian', arabic: 'الفريولية', script: 'Latn'),
    FloresLanguage(code: 'fuv_Latn', english: 'Nigerian Fulfulde', arabic: 'الفولانية النيجيرية', script: 'Latn'),
    FloresLanguage(code: 'gla_Latn', english: 'Scottish Gaelic', arabic: 'الغيلية الاسكتلندية', script: 'Latn'),
    FloresLanguage(code: 'gle_Latn', english: 'Irish', arabic: 'الأيرلندية', script: 'Latn'),
    FloresLanguage(code: 'glg_Latn', english: 'Galician', arabic: 'الجاليكية', script: 'Latn'),
    FloresLanguage(code: 'grn_Latn', english: 'Guarani', arabic: 'الغوارانية', script: 'Latn'),
    FloresLanguage(code: 'hat_Latn', english: 'Haitian Creole', arabic: 'الكريولية الهايتية', script: 'Latn'),
    FloresLanguage(code: 'hau_Latn', english: 'Hausa', arabic: 'الهوسا', script: 'Latn'),
    FloresLanguage(code: 'hrv_Latn', english: 'Croatian', arabic: 'الكرواتية', script: 'Latn'),
    FloresLanguage(code: 'hun_Latn', english: 'Hungarian', arabic: 'المجرية', script: 'Latn'),
    FloresLanguage(code: 'ibo_Latn', english: 'Igbo', arabic: 'الإيغبو', script: 'Latn'),
    FloresLanguage(code: 'ilo_Latn', english: 'Ilocano', arabic: 'الإيلوكانية', script: 'Latn'),
    FloresLanguage(code: 'isl_Latn', english: 'Icelandic', arabic: 'الآيسلندية', script: 'Latn'),
    FloresLanguage(code: 'jav_Latn', english: 'Javanese', arabic: 'الجاوية', script: 'Latn'),
    FloresLanguage(code: 'kab_Latn', english: 'Kabyle', arabic: 'القبائلية', script: 'Latn'),
    FloresLanguage(code: 'kac_Latn', english: 'Jingpho', arabic: 'الجينغفو', script: 'Latn'),
    FloresLanguage(code: 'kam_Latn', english: 'Kamba', arabic: 'الكامبا', script: 'Latn'),
    FloresLanguage(code: 'kbp_Latn', english: 'Kabiye', arabic: 'الكابيية', script: 'Latn'),
    FloresLanguage(code: 'kea_Latn', english: 'Kabuverdianu', arabic: 'الكريولية الرأس أخضرية', script: 'Latn'),
    FloresLanguage(code: 'kik_Latn', english: 'Kikuyu', arabic: 'الكيكويو', script: 'Latn'),
    FloresLanguage(code: 'kin_Latn', english: 'Kinyarwanda', arabic: 'الكينيارواندا', script: 'Latn'),
    FloresLanguage(code: 'kmb_Latn', english: 'Kimbundu', arabic: 'الكيمبوندو', script: 'Latn'),
    FloresLanguage(code: 'knc_Latn', english: 'Central Kanuri (Latin)', arabic: 'الكانورية (لاتيني)', script: 'Latn'),
    FloresLanguage(code: 'kon_Latn', english: 'Kongo', arabic: 'الكونغوية', script: 'Latn'),
    FloresLanguage(code: 'lij_Latn', english: 'Ligurian', arabic: 'الليغورية', script: 'Latn'),
    FloresLanguage(code: 'lim_Latn', english: 'Limburgish', arabic: 'الليمبورغية', script: 'Latn'),
    FloresLanguage(code: 'lin_Latn', english: 'Lingala', arabic: 'اللينغالا', script: 'Latn'),
    FloresLanguage(code: 'lit_Latn', english: 'Lithuanian', arabic: 'الليتوانية', script: 'Latn'),
    FloresLanguage(code: 'lmo_Latn', english: 'Lombard', arabic: 'اللومباردية', script: 'Latn'),
    FloresLanguage(code: 'ltg_Latn', english: 'Latgalian', arabic: 'اللاتغالية', script: 'Latn'),
    FloresLanguage(code: 'ltz_Latn', english: 'Luxembourgish', arabic: 'اللوكسمبورغية', script: 'Latn'),
    FloresLanguage(code: 'lua_Latn', english: 'Luba-Kasai', arabic: 'اللوبا كاساي', script: 'Latn'),
    FloresLanguage(code: 'lug_Latn', english: 'Ganda', arabic: 'اللوغاندية', script: 'Latn'),
    FloresLanguage(code: 'luo_Latn', english: 'Luo', arabic: 'اللووية', script: 'Latn'),
    FloresLanguage(code: 'lus_Latn', english: 'Mizo', arabic: 'الميزو', script: 'Latn'),
    FloresLanguage(code: 'lvs_Latn', english: 'Standard Latvian', arabic: 'اللاتفية', script: 'Latn'),
    FloresLanguage(code: 'min_Latn', english: 'Minangkabau', arabic: 'المينانغكاباو', script: 'Latn'),
    FloresLanguage(code: 'mlt_Latn', english: 'Maltese', arabic: 'المالطية', script: 'Latn'),
    FloresLanguage(code: 'mos_Latn', english: 'Mossi', arabic: 'الموسية', script: 'Latn'),
    FloresLanguage(code: 'mri_Latn', english: 'Maori', arabic: 'الماورية', script: 'Latn'),
    FloresLanguage(code: 'nno_Latn', english: 'Norwegian Nynorsk', arabic: 'النرويجية (نينورسك)', script: 'Latn'),
    FloresLanguage(code: 'nob_Latn', english: 'Norwegian Bokmal', arabic: 'النرويجية (بوكمول)', script: 'Latn'),
    FloresLanguage(code: 'nso_Latn', english: 'Northern Sotho', arabic: 'السوتو الشمالية', script: 'Latn'),
    FloresLanguage(code: 'nus_Latn', english: 'Nuer', arabic: 'النويرية', script: 'Latn'),
    FloresLanguage(code: 'nya_Latn', english: 'Nyanja', arabic: 'النيانجا', script: 'Latn'),
    FloresLanguage(code: 'oci_Latn', english: 'Occitan', arabic: 'الأوكسيتانية', script: 'Latn'),
    FloresLanguage(code: 'pag_Latn', english: 'Pangasinan', arabic: 'البانغاسينانية', script: 'Latn'),
    FloresLanguage(code: 'pap_Latn', english: 'Papiamento', arabic: 'البابيامنتو', script: 'Latn'),
    FloresLanguage(code: 'plt_Latn', english: 'Plateau Malagasy', arabic: 'الملغاشية', script: 'Latn'),
    FloresLanguage(code: 'pol_Latn', english: 'Polish', arabic: 'البولندية', script: 'Latn'),
    FloresLanguage(code: 'quy_Latn', english: 'Ayacucho Quechua', arabic: 'الكيتشوا', script: 'Latn'),
    FloresLanguage(code: 'ron_Latn', english: 'Romanian', arabic: 'الرومانية', script: 'Latn'),
    FloresLanguage(code: 'run_Latn', english: 'Rundi', arabic: 'الروندية', script: 'Latn'),
    FloresLanguage(code: 'sag_Latn', english: 'Sango', arabic: 'السانغو', script: 'Latn'),
    FloresLanguage(code: 'scn_Latn', english: 'Sicilian', arabic: 'الصقلية', script: 'Latn'),
    FloresLanguage(code: 'slk_Latn', english: 'Slovak', arabic: 'السلوفاكية', script: 'Latn'),
    FloresLanguage(code: 'slv_Latn', english: 'Slovenian', arabic: 'السلوفينية', script: 'Latn'),
    FloresLanguage(code: 'smo_Latn', english: 'Samoan', arabic: 'الساموية', script: 'Latn'),
    FloresLanguage(code: 'sna_Latn', english: 'Shona', arabic: 'الشونا', script: 'Latn'),
    FloresLanguage(code: 'som_Latn', english: 'Somali', arabic: 'الصومالية', script: 'Latn'),
    FloresLanguage(code: 'sot_Latn', english: 'Southern Sotho', arabic: 'السوتو الجنوبية', script: 'Latn'),
    FloresLanguage(code: 'srd_Latn', english: 'Sardinian', arabic: 'السردينية', script: 'Latn'),
    FloresLanguage(code: 'ssw_Latn', english: 'Swati', arabic: 'السواتي', script: 'Latn'),
    FloresLanguage(code: 'sun_Latn', english: 'Sundanese', arabic: 'السوندانية', script: 'Latn'),
    FloresLanguage(code: 'szl_Latn', english: 'Silesian', arabic: 'السيليزية', script: 'Latn'),
    FloresLanguage(code: 'taq_Latn', english: 'Tamasheq (Latin)', arabic: 'التماشق (لاتيني)', script: 'Latn'),
    FloresLanguage(code: 'tgl_Latn', english: 'Tagalog', arabic: 'التاغالوغية', script: 'Latn'),
    FloresLanguage(code: 'tpi_Latn', english: 'Tok Pisin', arabic: 'التوك بيسين', script: 'Latn'),
    FloresLanguage(code: 'tsn_Latn', english: 'Tswana', arabic: 'التسوانية', script: 'Latn'),
    FloresLanguage(code: 'tso_Latn', english: 'Tsonga', arabic: 'التسونغا', script: 'Latn'),
    FloresLanguage(code: 'tuk_Latn', english: 'Turkmen', arabic: 'التركمانية', script: 'Latn'),
    FloresLanguage(code: 'tum_Latn', english: 'Tumbuka', arabic: 'التومبوكا', script: 'Latn'),
    FloresLanguage(code: 'twi_Latn', english: 'Twi', arabic: 'التوية', script: 'Latn'),
    FloresLanguage(code: 'uzn_Latn', english: 'Northern Uzbek', arabic: 'الأوزبكية الشمالية', script: 'Latn'),
    FloresLanguage(code: 'vec_Latn', english: 'Venetian', arabic: 'الفينيسية', script: 'Latn'),
    FloresLanguage(code: 'vie_Latn', english: 'Vietnamese', arabic: 'الفيتنامية', script: 'Latn'),
    FloresLanguage(code: 'war_Latn', english: 'Waray', arabic: 'الواراي', script: 'Latn'),
    FloresLanguage(code: 'wol_Latn', english: 'Wolof', arabic: 'الولوفية', script: 'Latn'),
    FloresLanguage(code: 'xho_Latn', english: 'Xhosa', arabic: 'الكوسية', script: 'Latn'),
    FloresLanguage(code: 'yor_Latn', english: 'Yoruba', arabic: 'اليوروبية', script: 'Latn'),
    FloresLanguage(code: 'zul_Latn', english: 'Zulu', arabic: 'الزولوية', script: 'Latn'),

    // ----------------------------------------------------------- Cyrillic
    FloresLanguage(code: 'bak_Cyrl', english: 'Bashkir', arabic: 'الباشكيرية', script: 'Cyrl'),
    FloresLanguage(code: 'bel_Cyrl', english: 'Belarusian', arabic: 'البيلاروسية', script: 'Cyrl'),
    FloresLanguage(code: 'bul_Cyrl', english: 'Bulgarian', arabic: 'البلغارية', script: 'Cyrl'),
    FloresLanguage(code: 'kaz_Cyrl', english: 'Kazakh', arabic: 'القازاقية', script: 'Cyrl'),
    FloresLanguage(code: 'khk_Cyrl', english: 'Halh Mongolian', arabic: 'المنغولية (خالخ)', script: 'Cyrl'),
    FloresLanguage(code: 'kir_Cyrl', english: 'Kyrgyz', arabic: 'القيرغيزية', script: 'Cyrl'),
    FloresLanguage(code: 'mkd_Cyrl', english: 'Macedonian', arabic: 'المقدونية', script: 'Cyrl'),
    FloresLanguage(code: 'srp_Cyrl', english: 'Serbian', arabic: 'الصربية', script: 'Cyrl'),
    FloresLanguage(code: 'tat_Cyrl', english: 'Tatar', arabic: 'التترية', script: 'Cyrl'),
    FloresLanguage(code: 'tgk_Cyrl', english: 'Tajik', arabic: 'الطاجيكية', script: 'Cyrl'),
    FloresLanguage(code: 'ukr_Cyrl', english: 'Ukrainian', arabic: 'الأوكرانية', script: 'Cyrl'),
    FloresLanguage(code: 'alt_Cyrl', english: 'Northern Altai', arabic: 'الألتاي الشمالية', script: 'Cyrl'),

    // -------------------------------------------------------------- Indic
    FloresLanguage(code: 'asm_Beng', english: 'Assamese', arabic: 'الآسامية', script: 'Beng'),
    FloresLanguage(code: 'awa_Deva', english: 'Awadhi', arabic: 'الأوادية', script: 'Deva'),
    FloresLanguage(code: 'ben_Beng', english: 'Bengali', arabic: 'البنغالية', script: 'Beng'),
    FloresLanguage(code: 'bho_Deva', english: 'Bhojpuri', arabic: 'البوجبورية', script: 'Deva'),
    FloresLanguage(code: 'guj_Gujr', english: 'Gujarati', arabic: 'الغوجاراتية', script: 'Gujr'),
    FloresLanguage(code: 'hne_Deva', english: 'Chhattisgarhi', arabic: 'التشاتيسغارية', script: 'Deva'),
    FloresLanguage(code: 'kan_Knda', english: 'Kannada', arabic: 'الكانادية', script: 'Knda'),
    FloresLanguage(code: 'kas_Deva', english: 'Kashmiri (Devanagari)', arabic: 'الكشميرية (ديفاناغاري)', script: 'Deva'),
    FloresLanguage(code: 'mag_Deva', english: 'Magahi', arabic: 'الماغاهية', script: 'Deva'),
    FloresLanguage(code: 'mai_Deva', english: 'Maithili', arabic: 'المايثيلية', script: 'Deva'),
    FloresLanguage(code: 'mal_Mlym', english: 'Malayalam', arabic: 'المالايالامية', script: 'Mlym'),
    FloresLanguage(code: 'mar_Deva', english: 'Marathi', arabic: 'الماراثية', script: 'Deva'),
    FloresLanguage(code: 'mni_Beng', english: 'Meitei', arabic: 'المانيبورية', script: 'Beng'),
    FloresLanguage(code: 'npi_Deva', english: 'Nepali', arabic: 'النيبالية', script: 'Deva'),
    FloresLanguage(code: 'ory_Orya', english: 'Odia', arabic: 'الأوديا', script: 'Orya'),
    FloresLanguage(code: 'pan_Guru', english: 'Punjabi', arabic: 'البنجابية', script: 'Guru'),
    FloresLanguage(code: 'san_Deva', english: 'Sanskrit', arabic: 'السنسكريتية', script: 'Deva'),
    FloresLanguage(code: 'sat_Olck', english: 'Santali', arabic: 'السانتالية', script: 'Olck'),
    FloresLanguage(code: 'sin_Sinh', english: 'Sinhala', arabic: 'السنهالية', script: 'Sinh'),
    FloresLanguage(code: 'tam_Taml', english: 'Tamil', arabic: 'التاميلية', script: 'Taml'),
    FloresLanguage(code: 'tel_Telu', english: 'Telugu', arabic: 'التيلوغوية', script: 'Telu'),

    // ------------------------------------------------------ other scripts
    FloresLanguage(code: 'amh_Ethi', english: 'Amharic', arabic: 'الأمهرية', script: 'Ethi'),
    FloresLanguage(code: 'bod_Tibt', english: 'Tibetan', arabic: 'التبتية', script: 'Tibt'),
    FloresLanguage(code: 'dzo_Tibt', english: 'Dzongkha', arabic: 'الدزونخا', script: 'Tibt'),
    FloresLanguage(code: 'ell_Grek', english: 'Greek', arabic: 'اليونانية', script: 'Grek'),
    FloresLanguage(code: 'hye_Armn', english: 'Armenian', arabic: 'الأرمنية', script: 'Armn'),
    FloresLanguage(code: 'kat_Geor', english: 'Georgian', arabic: 'الجورجية', script: 'Geor'),
    FloresLanguage(code: 'khm_Khmr', english: 'Khmer', arabic: 'الخميرية', script: 'Khmr'),
    FloresLanguage(code: 'lao_Laoo', english: 'Lao', arabic: 'اللاوية', script: 'Laoo'),
    FloresLanguage(code: 'mya_Mymr', english: 'Burmese', arabic: 'البورمية', script: 'Mymr'),
    FloresLanguage(code: 'nqo_Nkoo', english: 'N-Ko', arabic: 'النكو', script: 'Nkoo', rtl: true),
    FloresLanguage(code: 'shn_Mymr', english: 'Shan', arabic: 'الشانية', script: 'Mymr'),
    FloresLanguage(code: 'taq_Tfng', english: 'Tamasheq (Tifinagh)', arabic: 'التماشق (تيفيناغ)', script: 'Tfng'),
    FloresLanguage(code: 'tha_Thai', english: 'Thai', arabic: 'التايلاندية', script: 'Thai'),
    FloresLanguage(code: 'tir_Ethi', english: 'Tigrinya', arabic: 'التيغرينية', script: 'Ethi'),
    FloresLanguage(code: 'tzm_Tfng', english: 'Central Atlas Tamazight', arabic: 'الأمازيغية', script: 'Tfng'),
    FloresLanguage(code: 'ydd_Hebr', english: 'Eastern Yiddish', arabic: 'اليديشية الشرقية', script: 'Hebr', rtl: true),
  ];

  /// Short list shown at the top of the picker.
  static List<FloresLanguage> get popular =>
      languages.where((l) => l.popular).toList(growable: false);

  static FloresLanguage byCode(String code) => languages.firstWhere(
        (language) => language.code == code,
        orElse: () => const FloresLanguage(
          code: 'eng_Latn',
          english: 'English',
          arabic: 'الإنجليزية',
          script: 'Latn',
        ),
      );

  static bool knows(String code) =>
      languages.any((language) => language.code == code);

  /// Case/diacritic insensitive search over both names.
  static List<FloresLanguage> search(String query) {
    final needle = _fold(query);
    if (needle.isEmpty) return popular;
    final starts = <FloresLanguage>[];
    final contains = <FloresLanguage>[];
    for (final language in languages) {
      final english = _fold(language.english);
      final arabic = _fold(language.arabic);
      final code = _fold(language.code);
      if (english.startsWith(needle) || arabic.startsWith(needle)) {
        starts.add(language);
      } else if (english.contains(needle) ||
          arabic.contains(needle) ||
          code.contains(needle)) {
        contains.add(language);
      }
    }
    return [...starts, ...contains];
  }

  /// Best guess for "the user picked BCP-47 `ar`": map onto an NLLB code.
  static FloresLanguage fromBcp47(String tag) {
    final lower = tag.toLowerCase();
    const map = {
      'ar': 'arb_Arab',
      'arz': 'arz_Arab',
      'en': 'eng_Latn',
      'fr': 'fra_Latn',
      'de': 'deu_Latn',
      'es': 'spa_Latn',
      'it': 'ita_Latn',
      'pt': 'por_Latn',
      'nl': 'nld_Latn',
      'ru': 'rus_Cyrl',
      'tr': 'tur_Latn',
      'fa': 'pes_Arab',
      'ur': 'urd_Arab',
      'he': 'heb_Hebr',
      'hi': 'hin_Deva',
      'id': 'ind_Latn',
      'ms': 'zsm_Latn',
      'zh': 'zho_Hans',
      'ja': 'jpn_Jpan',
      'ko': 'kor_Hang',
      'ku': 'ckb_Arab',
      'sw': 'swh_Latn',
      'th': 'tha_Thai',
      'vi': 'vie_Latn',
      'el': 'ell_Grek',
      'bn': 'ben_Beng',
      'ta': 'tam_Taml',
      'te': 'tel_Telu',
      'ml': 'mal_Mlym',
      'mr': 'mar_Deva',
      'ne': 'npi_Deva',
      'uk': 'ukr_Cyrl',
      'pl': 'pol_Latn',
      'cs': 'ces_Latn',
      'sv': 'nob_Latn',
      'da': 'dan_Latn',
      'fi': 'fin_Latn',
      'no': 'nob_Latn',
      'ro': 'ron_Latn',
      'hu': 'hun_Latn',
      'am': 'amh_Ethi',
      'ps': 'pbt_Psqt',
    };
    return byCode(map[lower] ?? 'eng_Latn');
  }

  /// Which ML Kit / OCR script handles this language (null = not covered).
  static String? ocrScriptFor(FloresLanguage language) => switch (language.script) {
        'Latn' || 'Arab' || 'Hebr' || 'Cyrl' || 'Grek' || 'Ethi' => 'latin',
        'Hans' || 'Hant' => 'chinese',
        'Deva' || 'Beng' || 'Gujr' || 'Guru' || 'Knda' || 'Mlym' || 'Orya' ||
        'Taml' || 'Telu' || 'Sinh' =>
          'devanagari',
        'Jpan' => 'japanese',
        'Hang' => 'korean',
        _ => null,
      };

  static String _fold(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[ً-ْٰـ]'), '')
      .replaceAll(RegExp(r'\s+'), '')
      .trim();
}
