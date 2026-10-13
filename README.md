# ShadowLanguages

**تطبيق أندرويد بـ Flutter يترجم كتب PDF مع الحفاظ على التصميم الأصلي بنسبة 100%.**
الصور، الخلفيات، الألوان، الجداول والأعمدة تبقى كما هي — النص فقط هو ما يُستبدل،
في نفس الإحداثيات ونفس المقاسات.

> A cyberpunk PDF translation terminal: it reads the text layer of any PDF with
> precise coordinates, translates **only the text** with Google Gemini, then
> injects the translation back over the artwork of the *original* file.

---

## ١. الفكرة / How it works

```
  PDF  ──► ① استخراج             ② ترجمة              ③ حقن
            Extract layout       Gemini (JSON)        Inject & save
        ┌──────────────────┐  ┌─────────────────┐  ┌──────────────────┐
        │ pdfrx يقرأ كل     │  │ النص فقط يُرسل   │  │ تغطية النص القديم │
        │ حرف مع إحداثياته  │  │ مع رقم مرجعي     │  │ بنفس الإحداثيات  │
        │ X/Y + قياس اللون  │  │ لكل مقطع         │  │ ثم رسم النص       │
        └──────────────────┘  └─────────────────┘  └──────────────────┘
                                    │                        │
                              ذاكرة مصطلحات           تحديث تدريجي
                              (Glossary memory)      (Incremental update)
```

1. **Parsing & Bounding boxes** — `PdfLayoutExtractor` (pdfrx / PDFium) collects
   every character with its rect, builds blocks/lines, and `BackgroundSampler`
   samples the page background and ink colours from a rendered pixmap.
2. **Content-targeted translation** — only extracted strings go to Gemini
   (`TranslationPipeline`), batched, each item carrying its stable reference id,
   plus a growing glossary so terminology stays consistent across the book.
3. **Text replacement & injection** — the custom engine in
   `lib/services/pdf/inject/` appends a new content stream to the **original**
   PDF (incremental update): a cover rectangle in the sampled background colour,
   then the translated text with a bundled TrueType font, shaped for Arabic
   (contextual forms + lam-alef ligatures) and re-ordered with a full UAX#9 bidi
   implementation. Original bytes are never modified.

## ٢. الشاشات / Screens

| الشاشة | المحتوى |
|---|---|
| **The Cyber Terminal Hub** | منطقة رفع بحدود نيون، اسم الملف وحجمه الحقيقي، قائمة لغات العالم، سطر الكشف التلقائي `[System]: Source language detected successfully: [English - 99.9%]`, تدفق سجل أحادي المسافة، وشريط تقدم نيون متحرك. |
| **The Shadow Reader** | قارئ PDF داكن مريح للعين، **Dual View** للمقارنة مع الأصل، بحث فوري داخل الكتاب، وتصدير باسم `shadow_translated_[book_name].pdf`. |
| **System Config** | مفتاح Gemini (محفوظ في Keystore ولا يُخزن في النسخ الاحتياطية)، اختبار اتصال، الموديل، الحرارة، التوازي، خيارات محرك PDF، لون النيون، لغة الواجهة، إدارة المكتبة والذاكرة المؤقتة. |

## ٣. التشغيل / Getting started

```bash
# pdfrx 2.6.x يحتاج Flutter >= 3.47 / Dart >= 3.13
flutter upgrade
flutter pub get
```

Then bootstrap the Android Gradle wrapper once (the wrapper jar is not committed):

```bash
flutter create --platforms=android --org com.shadowlang --project-name shadow_languages .
```

> `flutter create` only fills in missing platform scaffolding — it does **not**
> overwrite existing files, so `lib/`, `assets/`, `pubspec.yaml`, the manifest and
> the icons are preserved.

```bash
flutter analyze
flutter run            # جهاز أو محاكي أندرويد
flutter build apk --release
```

First launch asks for a **Gemini API key** (get one from
[ai.google.dev](https://ai.google.dev)); it is stored with
`flutter_secure_storage` (AES, Android Keystore) and never written to
SharedPreferences.

## ٤. البنية / Layout

```
lib/
  main.dart                 Flutter bootstrap + provider overrides
  app.dart                  MaterialApp: theme, locale, onboarding gate
  core/
    theme/                  palette (#0A0A0A/#0D0D0D/#000000, #00FF66, #00E5FF), fonts, ThemeData
    localization/           Strings EN/AR (152 keys each)
    logging/                LogBus — live ring-buffered log stream
    di/providers.dart       Riverpod graph
    utils/                  Result, cancellation token, formatters
  data/                     models + repositories (settings, library)
  services/
    pdf/
      inject/               PDF parser, lexer, writer, TTF reader, font embedding,
                            incremental-update injection session
      shaping/              UAX#9 bidi, Arabic contextual shaping + ligatures,
                            Unicode tables (generated)
      layout/               font resolver, shrink-to-fit block layout
      extraction/           text-layer mapping, background/ink sampling
      pdf_engine.dart       facade: extractLayout() / injectTranslations()
    translation/            Gemini client, language catalog, batched pipeline
  features/
    terminal/               Screen 1 — Cyber Terminal Hub
    reader/                 Screen 2 — Shadow Reader (Dual View, search, export)
    settings/               Screen 3 — System Config
    onboarding/             First run
    shell/                  tab shell
assets/
  fonts/pdf/                NotoSans (Latin/Greek/Cyrillic) + NotoNaskhArabic — embedded in the PDF
  fonts/ui/                 Orbitron, ShareTechMono, JetBrainsMono — the terminal look
  branding/                 app icon (512) + store art
tool/
  gen_icons.py              regenerates every icon density
  gen_unicode_tables.py     regenerates lib/services/pdf/shaping/data/*.dart
```

## ٥. ملاحظات / Notes

* Fonts are bundled (no network needed at runtime) and **subset on the fly** when
  embedded: only the glyphs actually used are written into the PDF.
* RTL targets are fully shaped in-app: `arabic_shaper` + `bidi` mirror
  `arabic_reshaper` / `python-bidi` behaviour, because Identity-H/CID=GID fonts
  get no GSUB processing from a PDF reader.
* The injection is an **incremental update**: the original file bytes are kept
  intact and the new content is appended, so annotations, outlines and the
  document catalogue survive.
* `minSdk 24`, `arm64-v8a / armeabi-v7a / x86_64` (PDFium is a large native lib).
