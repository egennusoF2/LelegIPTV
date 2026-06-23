plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

import java.util.Base64

android {
    namespace = "com.lelegiptv.leleg_iptv"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    flavorDimensions += "device"
    productFlavors {
        create("mobile") {
            dimension = "device"
            isDefault = true
            buildConfigField("boolean", "LELEG_TV_FLAVOR", "false")
            manifestPlaceholders["lelegTvFlavor"] = "false"
        }
        create("tv") {
            dimension = "device"
            buildConfigField("boolean", "LELEG_TV_FLAVOR", "true")
            manifestPlaceholders["lelegTvFlavor"] = "true"
        }
    }

    buildFeatures {
        buildConfig = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.lelegiptv.leleg_iptv"
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

// Garantisce LELEG_ANDROID_TV=true su ogni build flavor tv (anche senza --dart-define CLI).
val lelegTvDartDefine =
    Base64.getEncoder()
        .encodeToString("LELEG_ANDROID_TV=true".toByteArray(Charsets.UTF_8))

val requestedTvBuild =
    gradle.startParameter.taskNames.any { task ->
        task.contains("Tv", ignoreCase = true) || task.contains("tv", ignoreCase = false)
    }

if (requestedTvBuild) {
    val existing = project.findProperty("dart-defines")?.toString().orEmpty()
    if (existing.contains(lelegTvDartDefine).not()) {
        val merged =
            if (existing.isEmpty()) lelegTvDartDefine else "$existing,$lelegTvDartDefine"
        project.extensions.extraProperties.set("dart-defines", merged)
    }
}
