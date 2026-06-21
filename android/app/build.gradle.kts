import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing is read from android/key.properties when present (kept out of
// git — see .gitignore). When it's absent (CI without secrets, contributor
// builds, local dev) the release build falls back to the debug key so the APK
// still assembles. Drop in key.properties + the keystore to sign for the store.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.onyxbible.reader"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.onyxbible.reader"
        // minSdk/targetSdk follow Flutter's defaults, kept conservative so the
        // app installs on Boox devices' older Android builds.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (hasReleaseKeystore) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    packaging {
        resources {
            pickFirsts.add("androidsupportmultidexversion.txt")
        }
        jniLibs {
            pickFirsts.add("lib/*/libc++_shared.so")
        }
    }

    buildTypes {
        release {
            // Sign with the real keystore when configured; otherwise the debug
            // key so the release APK still installs for sideloading.
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // No code shrinking: R8 full-mode otherwise errors on optional
            // Play Core / deferred-component classes the app never uses.
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

flutter {
    source = "../.."
}
