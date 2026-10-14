# ShadowLanguages

**تطبيق أندرويد بـ Flutter يترجم كتب PDF مع الحفاظ على التصميم الأصلي بنسبة 100%.**
الصور، الخلفيات، الألوان، الجداول والأعمدة تبقى كما هي — النص فقط هو ما يُستبدل،
في نفس الإحداثيات ونفس المقاسات.

> A cyberpunk PDF translation terminal: it reads the text layer of any PDF with
> precise coordinates, reads the words hidden inside page **images** with an
> on-device OCR engine, translates **only the text** with **Meta NLLB-200
> running locally through ONNX Runtime**, then injects the translation back
> over the artwork of the *original* file.
>
> **No internet. No API key. No cloud.** The default engine never opens a
> socket: the model, the tokenizer and the OCR all live on the phone.

---

## ٠. العمل بدون إنترنت / 100% offline

الترجمة تتم **داخل الجهاز** عبر نموذج **Meta NLLB-200 (Distilled 600M)** محوّل
إلى ONNX، ويُشغَّل عبر `flutter_onnxruntime`. لا مفتاح، لا اتصال، ولا أي بيانات
تخرج من الهاتف.

```
                      ┌──────────────────────── على الجهاز فقط ───────────────────────┐
  نص الصفحة  ─►  SentencePiece  ─►  Encoder (مرة واحدة)  ─►  Hidden states
                                                                  │
                          [eos] + <رمز اللغة الهدف>  ─►  Decoder  ─►  الكلمة التالية ─┐
                                        ▲                                             │
                                        └──────── KV cache (past_key_values) ─────────┘

  صورة الصفحة  ─►  تدرّج رمادي + Otsu  ─►  ملامح الأسطر  ─►  CRNN/CTC  ─►  نص داخل الصورة
                                                                              │
                                                              يُترجم ثم يُرسم فوق الصورة
                                                              بهالة (halo) دون تغييرها
```

| الجزء | الملف | ملاحظة |
|---|---|---|
| جلسات ONNX، خيوط المعالجة، تنظيف الذاكرة | `onnx/onnx_backend.dart` | كل موتر وسيط يُحرَّر فوراً (`useArena: false`) |
| اكتشاف أسماء الموترات وطبقات الـ KV | `onnx/onnx_backend.dart` → `Seq2SeqIo.discover` | يعمل مع merged cache أو cache لكل طبقة |
| ترميز SentencePiece (BPE) | `onnx/sentencepiece.dart` | يقرأ `tokenizer.model` مباشرة بدون مكتبة إضافية |
| لغات NLLB-200 (≈200) | `onnx/flores.dart` | الأسماء بالعربية والإنجليزية، اتجاه النص، ونظام الكتابة |
| حلقة فك الترميز (greedy / beam) | `onnx/nllb_engine.dart` | KV cache + عدّاد مراجع للفرضيات + كشف التكرار |
| كشف اللغة دون إنترنت | `onnx/offline_language_identifier.dart` | نظام الكتابة + كلمات الوظيفة |
| عميل الترجمة (ذكاء التقسيم) | `onnx/nllb_translation_client.dart` | تقسيم جُملي، تسلسل، مهلة تبريد اختيارية |
| OCR محلي | `onnx/ocr/onnx_ocr.dart` | Otsu + إسقاط الحبر + CTC، بلا أي خدمة خارجية |
| ربط الـ OCR بالصفحات | `onnx/ocr/pdf_image_ocr.dart` | يrender المنطقة فقط (~200 dpi) ويحوّلها لإحداثيات PDF |
| دمج النص المستخرج في خريطة الكتاب | `onnx/ocr/ocr_augmentation.dart` | المناطق تصبح بلوكات عادية بمعرفات `ocr-p{page}-i{n}` |
| إدارة ملفات النماذج | `onnx/model_manager.dart` | فحص، استيراد، تحقّق، تحميل |

### تثبيت النماذج

النماذج بمئات الميجابايت، لذلك **ليست** ضمن المستودع ولا ضمن APK. مرة واحدة فقط:

1. حمّل نسخة ONNX من `facebook/nllb-200-distilled-600M` (ال encoder وال decoder)
   وملف `tokenizer.model`، و(اختيارياً) نموذج تعرّف نصوص ONNX وملف الأبجدية.
2. انسخها إلى `ShadowLanguages/models` على الذاكرة الخارجية، أو استخدم
   زر **استيراد ملف نموذج** داخل `System Config ▸ النماذج المحلية`.
3. الأسماء المقبولة:

| الملف | الأسماء المقبولة |
|---|---|
| المُرمِّز | `nllb-encoder.onnx` · `encoder_model.onnx` |
| فاكّ الترميز | `nllb-decoder.onnx` · `decoder_model.onnx` |
| المُقطِّع | `tokenizer.model` · `sentencepiece.model` |
| OCR | `ocr-rec.onnx` · `rec.onnx` |
| الأبجدية | `ocr_charset.txt` · `charset.txt` |

**أو بضغطة واحدة:** زر **تنزيل النماذج (مرة واحدة)** في نفس الشاشة يجلب الملفات
الناقصة من Hugging Face مع شريط تقدّم وإمكانية **الاستكمال** عند انقطاع الاتصال
(`.part` + `Range`) وتحقّق SHA-256، ثم يتحقق من سلامتها قبل اعتمادها. بعد هذه
المرة الوحيدة يعمل التطبيق في **وضع الطيران** إلى الأبد.

بدون نموذج الـ OCR يعمل التطبيق بشكل طبيعي وتُترك نصوص الصور كما هي. وبدون نموذج
الترجمة يعرض التطبيق رسالة واضحة `err_model_missing` بدل الانهيار.

### الذاكرة والحرارة

* التقسيم جُملي: فقرة طويلة تُقسَّم قبل الترميز، فلا تُبنى مصفوفة انتباه ضخمة.
* الاستدلال **تسلسلي**: تشغيل Decoderَين معاً يضاعف الذاكرة بلا فائدة تُذكر.
* كل موتر وسيط يُحرَّر بعد قراءته مباشرة (`OrtValue.dispose`).
* من الإعدادات: عدد الأنوية (1–4)، دقة فك الترميز (1 = الأسرع، 4 = الأفضل)،
  ومهلة تبريد بين الفقرات للكتب الطويلة.

### المحرك السحابي (اختياري)

`GeminiClient` ما زال موجوداً خلف نفس الواجهة `TranslationClient`، لكنه **معطّل
افتراضياً**. من يفعّله في الإعدادات يحتاج مفتاح API واتصالاً — أما الوضع
الافتراضي فلا يحتاج شيئاً.

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
2. **Content-targeted translation** — only extracted strings go to the engine
   (`TranslationPipeline`), batched, each item carrying its stable reference id,
   plus a growing glossary so terminology stays consistent across the book. The
   default engine is **NLLB-200 on the device**; the optional cloud engine is
   one setting away.
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
| **System Config** | اختيار المحرك (داخل الجهاز ← افتراضي، أو سحابي اختياري)، حالة ملفات النماذج واستيرادها، تفعيل الـ OCR، عدد الأنوية ودقة فك الترميز ومهلة التبريد، مفتاح Gemini (محفوظ في Keystore، اختياري)، الموديل، الحرارة، التوازي، خيارات محرك PDF، لون النيون، لغة الواجهة، إدارة المكتبة والذاكرة المؤقتة. |

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

---

## ٦. تحصين الأخطاء / Error handling

كل ما يمكن أن ينكسر مغلف بطبقة واحدة: الخدمات ترمي، والمتحكّم (`TerminalController`)
يحوّل أي استثناء إلى `Failure` (في `lib/core/error/failure.dart`) فيه مفتاح ترجمة،
وسبب تقني للسجل، وإجراءات الاسترداد الممكنة (`canRetry` / `canResume`). لا يصل أي
استثناء خام إلى الواجهة أبداً.

| السيناريو | ما يحدث | الإجراء المتاح للمستخدم |
|---|---|---|
| ملف تالف / ناقص التحميل | `PdfValidator` يفحص الترويسة `%PDF-` وعلامة `%%EOF` وشجرة الصفحات قبل أي شيء | رسالة `err_pdf_truncated` ولا تبدأ المهمة |
| ملف محمي بكلمة مرور | يُكتشف عبر PDFium قبل الفتح | شاشة إدخال كلمة مرور، ولا تُهدر أي صفحة |
| كلمة مرور خاطئة | `createSimplePasswordProvider` يمنع حلقة إعادة المحاولة اللانهائية | `err_pdf_password` والمحاولة مرة أخرى |
| لا توجد طبقة نصية (كتاب ممسوح) | يُكتشف بعد الاستخراج | `err_pdf_no_text` |
| انقطاع الإنترنت | فحص اتصال قبل البدء، ثم إعادة محاولة بتأخير تصاعدي داخل `GeminiClient` | `err_network` + استئناف |
| تجاوز حد الطلبات (429) | قراءة `Retry-After` والالتزام به + تبريد تكيفي عبر `RateLimiter` | `err_rate_limit` + استئناف |
| استجابة غير قابلة للتحليل | `TranslationException(parse)` | `err_parse` + إعادة المحاولة |
| تعذّر الكتابة في الذاكرة | `Failure(storage)` — والترجمة محفوظة في نقطة الحفظ | إعادة المحاولة دون فقدان |
| إلغاء المهمة | `JobCancelledException` | التقدم محفوظ + زر الاستئناف |

## ٧. هل استبدال النص في نفس الإحداثيات يفسد الصور أو الجداول؟

**السؤال وجيه، والإجابة: ممكن — لو غطّينا النص القديم بمستطيل فوق رسمة. لذلك لا نفعل ذلك أبداً.**

قبل كتابة أي بايت يشغّل التطبيق تحليل تداخل من إشارتين مستقلتين
(`lib/services/pdf/extraction/`):

1. **هندسة دقيقة** — `ContentScanner` يعيد تشغيل تدفق المحتوى (content stream)
   للصفحة مع تتبّع مصفوفة الإحداثيات (CTM)، فيعرف أماكن رسم الصور (`Do` على
   `XObject/Image`) والمتجهات (`re`, `m`, `l`) والأنماط بوحدة النقاط.
2. **بكسلات حقيقية** — `OverlapDetector` يعرض الصفحة ويحسب داخل صندوق كل كتلة:
   نسبة الحبر، ونسبة الصفوف/الأعمدة المظلمة بالكامل (حدود الجداول)، ونسبة
   الألوان المتوسطة (تدرّج/صورة خلفية).

ثم يُتخذ قرار لكل كتلة:

| الاستراتيجية | متى | ماذا يحدث |
|---|---|---|
| `cover` | خلفية مسطّحة (ورق عادي) | مستطيل بلون الصفحة المقاس + النص المترجم في نفس الإحداثيات — لا فرق ولو بكسل |
| `halo` | توجد صورة أو تدرّج أو لوح ملوّن خلف النص | **لا رسم لأي مستطيل**؛ النص يُرسم بنمط `2 Tr` (تعبئة + حدّ) بهالة بلون مضاد. الصورة الأصلية تظهر خلف الحروف كما هي |
| `tight` | الكتلة داخل جدول أو إطار | تغطية بدون أي هامش حتى لا يتسرّب اللون فوق الخطوط، وتصغير النص ليحتويه الخلية |
| `keepOriginal` | خطر مرتفع جداً | تُترك الكتلة كما كتبها المؤلف وتُبلَّغ في السجل |

وبعد الحقن يعمل `LayoutVerifier` كدليل قاطع: يعرض الملف الأصلي والملف المترجم
بنفس الدقة ويقارن البكسلات **خارج** صناديق النص المسموح بتغييرها. أي اختلاف هناك
يعني أننا أتلفنا شيئاً، فيُبلَّغ بنسبة الاختلاف ورقم الصفحة. القاعدة الذهبية في
الكود: **لا تَمْحُ بكسلاً لا تستطيع إعادته**.

## ٨. الاستئناف / Checkpoints

بعد كل صفحة مترجمة تُكتب نقطة حفظ في `getApplicationSupportDirectory()/checkpoints`
(`JobCheckpoint` + `CheckpointRepository`) تحوي النصوص المترجمة وذاكرة المصطلحات
وعدد الصفحات المنجزة. انقطاع الكهرباء في الصفحة ٤٠ من ٥٠ يكلّف صفحة واحدة،
وزر **RESUME** يكمل من حيث توقّف دون إعادة ترجمة ما أُنجز (وبلا استهلاك رموز).

## ٩. حدود الـ API والتقسيم الذكي / Rate limits & smart chunking

**(هذه الحدود تخص المحرك السحابي الاختياري فقط. المحرك المحلي لا يملك حدوداً
سوى ذاكرة الجهاز وحرارته — انظر القسم ٠.)**

* **تنظيم الطلبات** — `RateLimiter` يفرض فاصلاً زمنياً أدنى بين الطلبات، ويضاعفه
  تصاعدياً عند الفشل حتى ٢٠ ثانية، ويُريحه عند النجاح.
* **احترام `Retry-After`** — عند 429 يقرأ التطبيق الترويسة وينتظرها، ويُبرد كل
  العمال المتوازيين بنفس المدة.
* **تقسيم ذكي** — `SmartChunker` يقسّم أي نص أطول من الحد المسموح
  (هرمياً: فقرة ← جملة ← شبه جملة ← قَطع اضطراري)، ثم تُوصل الأجزاء بترتيبها.
  مختبر آلياً: لا حرف يُفقَد ولا مقطع يتجاوز الحد.
* **حجم الدفعة قابل للضبط** من شاشة الإعدادات (٦٠٠–٤٠٠٠ حرف/طلب).

## ١٠. توافق الخطوط / Fonts

الخطوط مدمجة داخل التطبيق (`NotoSans` للاتينية/اليونانية/السيريلية،
`NotoNaskhArabic` للعربية) وتُضمَّن في الملف الناتج مع **تجزئة تلقائية**
(subset) فلا تُكتب إلا المحارف المستعملة. وقبل بدء المهمة يشغّل التطبيق فحص
تغطية (`FontCoverageReport`) لأبجدية اللغة الهدف ويحذّر إذا كانت التغطية ناقصة،
وأي محرف غير موجود يُسجَّل ولا يُرسم فارغاً بصمت.

## ١١. اللغة

الواجهة عربية بالكامل افتراضياً (مع تبديل إلى الإنجليزية من الإعدادات)،
والتخطيط يتحول تلقائياً إلى RTL، واللغة الهدف الافتراضية هي العربية.
