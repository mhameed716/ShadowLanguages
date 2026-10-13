# ShadowLanguages — release shrinking rules.

# Flutter engine + plugins
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class com.shadowlang.app.MainActivity { *; }

# Cloud messaging / Gson style reflection used by some plugins
-keepattributes *Annotation*
-keepattributes Signature
-keepattributes InnerClasses
-keepattributes EnclosingMethod

# PDFium (pdfrx) native bridge
-keep class com.pdfium.** { *; }
-keepclasseswithmembernames class * {
    native <methods>;
}

# dart:ffi entry points must keep their names
-keep class com.shadowlang.** { *; }
-dontwarn org.bouncycastle.**
-dontwarn com.google.crypto.tink.**
