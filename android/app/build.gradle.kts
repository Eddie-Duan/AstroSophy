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

// 用 `compilerOptions` 而不是 `android { kotlinOptions { } }`：后者在 Kotlin 2.2
// 上已经升级成**错误级**的废弃（不再是警告），CI 里它就是 `Script compilation
// errors` 下面那条，和别的错误并排躺着。
//
// 位置必须是这个层级：`kotlin { }` 是 Kotlin 插件挂的项目级扩展，`android { }`
// 里面没有它，塞进去会得到一句 `Unresolved reference: kotlin`。
//
// 也不能干脆删掉：JVM 目标不对齐时 Gradle 报
// "Inconsistent JVM-target compatibility"，那是构建直接失败。
kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

flutter {
    source = "../.."
}
