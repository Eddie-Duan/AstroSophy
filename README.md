# AstroSophy

面向天文爱好者的 Flutter 手机应用：本地检测星点和图像质量，可选解算天区、匹配 Gaia 星表及调用个人模型 Key 生成中文解读。

## 启动

安装 Flutter stable SDK、Android Studio 和 Android SDK（JDK 17/21），运行 `flutter doctor` 配好工具链。连接 Android 手机并开启 USB 调试，Windows 双击 [`START.bat`](./START.bat)，或运行：

```shell
flutter pub get
flutter run
```

双击 [`BUILD_APK.bat`](./BUILD_APK.bat) 可生成 release APK。

## 使用

从手机相册选择 JPG/PNG/TIFF 或相机 RAW 文件，星点与画质分析在手机本机进行。RAW 尝试读取文件中嵌入的 JPEG 预览；不保证所有相机格式都能解码，也不等同于线性 RAW 测光。可选填写 Astrometry.net Key 和 OpenAI 兼容模型 Key；天区解算上传预览图前必须明确授权，模型仅接收测量摘要。

星等、天空背景指数、RAW 支持边界和隐私说明见 [`docs/TECHNICAL.md`](./docs/TECHNICAL.md)。

使用限制见 [`LICENSE`](./LICENSE)。如有违反，作者将保留追究其责任的权利。