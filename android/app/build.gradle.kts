import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing, in priority order:
//  1. android/key.properties (private store keystore; gitignored, or written by
//     CI from repository secrets) — required for store releases.
//  2. android/sideload.jks — a PUBLIC keystore committed to the repo so every
//     CI build carries the SAME signature: sideloaded updates then install in
//     place instead of conflicting (each CI runner's debug key is random, which
//     made every fresh APK an "app not installed" conflict).
//  3. The debug key, as a last resort so the build always assembles.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}
val sideloadKeystore = rootProject.file("sideload.jks")
val hasSideloadKeystore = sideloadKeystore.exists()

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
            } else if (hasSideloadKeystore) {
                // Public by design (see android/.gitignore) — sideload only.
                keyAlias = "sideload"
                keyPassword = "sideload"
                storeFile = sideloadKeystore
                storePassword = "sideload"
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
            // Private keystore > public sideload keystore > debug (last resort).
            signingConfig = if (hasReleaseKeystore || hasSideloadKeystore) {
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
