plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.shadowlang.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.shadowlang.app"
        // PDFium (via pdfrx) and the network stack set the real floor.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Many books are big: keep the 64 bit ABIs and drop the rest.
        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64")
        }
    }

    buildTypes {
        release {
            // TODO(operator): add your own signing config before publishing.
            // keytool -genkey -v -keystore ~/shadow.jks -keyalg RSA -keysize 2048 -validity 10000 -alias shadow
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = true
            isShrinkResources = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
        debug {
            // PDFium is a large native library: keep debuggable builds fast.
            isMinifyEnabled = false
        }
    }

    packaging {
        jniLibs {
            // PDFium ships one native library per ABI only.
            useLegacyPackaging = false
        }
    }
}

flutter {
    source = "../.."
}
