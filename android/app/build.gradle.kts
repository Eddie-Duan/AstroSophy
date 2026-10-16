plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.astrosophy.app"
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
        applicationId = "com.astrosophy.app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        getByName("release") {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

// 产物就叫 `AstroSophy.apk`，不叫 `app-release.apk`。
//
// 用 Variant API 而不是 `archivesBaseName`：那个属性在 AGP 8 里已经废弃，而
// 「这个变体输出的文件叫什么」本来也正是 Variant API 管的事。
//
// 只在 release 上去掉后缀。debug 那两个字符留着，是因为已经有别的地方按
// `AstroSophy-debug.apk` / `AstroSophy-<abi>.apk` 找文件；把三种变体的产物
// 压成同一个名字，它们会互相覆盖。
androidComponents {
    onVariants { variant ->
        variant.outputs.forEach { output ->
            val abi = output.filters
                .find { it.filterType == com.android.build.api.variant.FilterConfiguration.FilterType.ABI }
                ?.identifier
            val base = if (variant.buildType == "release") {
                "AstroSophy"
            } else {
                "AstroSophy-${variant.buildType}"
            }
            output.outputFileName.set(
                if (abi == null) "$base.apk" else "$base-$abi.apk"
            )
        }
    }
}

flutter {
    source = "../.."
}
