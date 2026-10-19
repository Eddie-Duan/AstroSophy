import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

/// 正式签名凭据从两处按优先级取：
///
///   1. **环境变量**（CI）——密码不落盘，只在构建那一层的内存里；
///   2. **`android/key.properties`**（本机）。
///
/// 两处都没有就退回 debug 签名，`flutter run` 和 `BUILD_APK.bat` 照旧能跑。
///
/// 为什么 release 必须有正式签名：这个位置以前写的是
/// `signingConfig = signingConfigs.getByName("debug")`，而 CI 每次都是全新的
/// runner、`~/.android/debug.keystore` 是那台机器现生成的——于是**每一版 APK
/// 的签名都不一样**。Android 只允许同一把钥匙签名的包覆盖安装，签名一变就得
/// 先卸载，应用内存储（API Key、观星仓库）跟着一起被清空。症状就是「从
/// Releases 下载的更新每次都要重填 Key、记录全没了」。
val signingProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) FileInputStream(file).use { load(it) }
}

fun signingCredential(environment: String, property: String): String? =
    System.getenv(environment)?.takeIf { it.isNotBlank() }
        ?: signingProperties.getProperty(property)?.takeIf { it.isNotBlank() }

val releaseStoreFile = signingCredential("ASTROSOPHY_STORE_FILE", "storeFile")
val releaseStorePassword =
    signingCredential("ASTROSOPHY_STORE_PASSWORD", "storePassword")
val releaseKeyAlias = signingCredential("ASTROSOPHY_KEY_ALIAS", "keyAlias")
val releaseKeyPassword =
    signingCredential("ASTROSOPHY_KEY_PASSWORD", "keyPassword")
val hasReleaseSigning = releaseStoreFile != null &&
    releaseStorePassword != null &&
    releaseKeyAlias != null &&
    releaseKeyPassword != null

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
        // camera_android_camerax 要求 23；实时星图用了它。原来跟随 Flutter
        // 默认值（21）会在清单合并时直接失败。
        minSdk = 23
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(releaseStoreFile!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        getByName("release") {
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                // 没配正式凭据就退回 debug 签名。本机构建、`flutter run` 都照旧，
                // 但**用它发布的包换不了钥匙**——装到用户机上就得先卸载，数据
                // 跟着没。CI 那边就不允许这种退路：release 流程在缺少凭据时直接
                // 报错停下，见 `.github/workflows/release.yml`。
                signingConfigs.getByName("debug")
            }
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
