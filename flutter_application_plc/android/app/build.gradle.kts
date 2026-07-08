import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

// ── Signing config ──────────────────────────────────────────────────────────
// Priority: key.properties file (local dev) → ANDROID_* env vars (CI)
val keystorePropsFile = rootProject.file("key.properties")
val keystoreProps = Properties()
if (keystorePropsFile.exists()) {
    keystoreProps.load(FileInputStream(keystorePropsFile))
}

fun prop(key: String): String =
    (keystoreProps[key] as String?)?.takeIf { it.isNotBlank() }
        ?: System.getenv("ANDROID_${key.uppercase().replace('.', '_')}") ?: ""

android {
    namespace   = "com.hzortech.lugh"
    compileSdk  = flutter.compileSdkVersion
    ndkVersion  = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = JavaVersion.VERSION_17.toString() }

    signingConfigs {
        create("release") {
            val storeFilePath = prop("storeFile")
            storeFile    = if (storeFilePath.isNotBlank()) file(storeFilePath) else null
            storePassword = prop("storePassword")
            keyAlias      = prop("keyAlias")
            keyPassword   = prop("keyPassword")
        }
    }

    defaultConfig {
        applicationId = "com.hzortech.lugh"
        minSdk        = flutter.minSdkVersion
        targetSdk     = flutter.targetSdkVersion
        versionCode   = flutter.versionCode
        versionName   = flutter.versionName
    }

    buildTypes {
        release {
            val cfg = signingConfigs.getByName("release")
            signingConfig = if (cfg.storeFile != null) cfg
                            else signingConfigs.getByName("debug")
            isMinifyEnabled   = false   // Enable with Proguard when ready
            isShrinkResources = false
        }
    }
}

flutter {
    source = "../.."
}
