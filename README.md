# AstroSophy

面向天文爱好者的 Flutter Android 应用：本地检测星点、画质与疑似拉线候选，可选解算天区、匹配 Gaia 星表及调用个人模型 Key 生成中文解读。无需自建服务器。

## 启动

安装 Flutter stable SDK、Android Studio 和 Android SDK（JDK 17/21），运行 `flutter doctor` 配好工具链。连接 Android 手机并开启 USB 调试，Windows 双击 [`START.bat`](./START.bat)，或运行：

```shell
flutter pub get
flutter run
```

双击 [`BUILD_APK.bat`](./BUILD_APK.bat) 可生成 release APK。

## 使用

从手机相册选择 JPG/PNG/TIFF 或相机 RAW 文件，星点与画质分析在手机本机进行。RAW 尝试读取文件中嵌入的 JPEG 预览；不保证所有相机格式都能解码，也不等同于线性 RAW 测光。可选填写 Astrometry.net Key 和 OpenAI 兼容模型 Key；天区解算上传预览图前必须明确授权，模型仅接收测量摘要。未授权时不会把图像上传到天区解算服务。

想启用 Agent，在应用“本机 API 设置”中选择 DeepSeek、OpenAI、OpenRouter 或硅基流动模板，核对/修改模型名并填写自己的 API Key。模板不含密钥；密钥只保存在设备安全存储中。

首次打开会显示简短上手引导；分析指标旁的“？”可随时查看解释，顶部问号可重新打开引导。Android 启动图标由 Recraft 生成的矢量稿导出。

星等、天空背景指数、RAW 支持边界和隐私说明见 [`docs/TECHNICAL.md`](./docs/TECHNICAL.md)。

使用限制见 [`LICENSE`](./LICENSE)。如有违反，作者将保留追究其责任的权利。