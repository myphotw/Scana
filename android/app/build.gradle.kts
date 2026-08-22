plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.myphotw.scana"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.myphotw.scana"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")

            // ML Kit Document Scanner 16.0.0 fails during getClient() when
            // Flutter's implicit Release R8/resource shrinking is enabled.
            // The no-shrink Release has been verified on the target device.
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("org.opencv:opencv:4.13.0")
    // Production primary scanner UI and on-device document processing.
    implementation("com.google.android.gms:play-services-mlkit-document-scanner:16.0.0")
    // AI comparison PoC: bundled CPU-only LiteRT inference. The model itself
    // lives in src/main/assets, so no runtime download or network permission is required.
    implementation("com.google.ai.edge.litert:litert:1.4.1")
    // Bundled Korean model: available on first run without a network download.
    implementation("com.google.mlkit:text-recognition-korean:16.0.1")
}
