# 星鉴技术与使用说明

## 应用能力

- Flutter/Dart Android 手机应用；相册选择、拍摄、星场检测、测量展示均在设备内运行。
- 图片分析先缩放到最大边长 1200 px，再计算稳健背景、背景噪声、饱和比例和紧凑亮点；星点检测放在独立 isolate，避免阻塞 UI。
- 图片选择支持常见图片和相机 RAW 文件。RAW 解码尝试在容器中查找最大的嵌入式 JPEG 预览；不同相机格式和厂商编码差异很大，因此不是完整 LibRaw 支持，也不是对传感器原始线性数据的分析。
- 亮星位置/星等来自 Gaia DR3 TAP，名称和天体类型在运行时从 SIMBAD TAP 按解算视场查询并作坐标交叉匹配；没有手工枚举恒星清单。在线星表不可用时会显示 Gaia 来源编号或明确的目录警告。
- 星团、星云、星系等对象由 SIMBAD 视场查询返回；对象类别来自目录的天体类型代码，目录数据可用性受第三方服务影响。
- 低质量或无法解算的图片仍提供本地降级分析；不会在无坐标时猜测天体名称。

## 测量边界

1. **相对仪器星等**：本地检测星点的像素通量相对值，只能比较当前同一图像中的亮度，不是校准视星等。
2. **Gaia G 星等**：需先匹配 Gaia DR3，并至少有 5 颗可靠参考星才报告近似零点散布。设备光谱响应、白平衡、JPEG 曲线、饱和、镜头暗角等会带来系统误差，散布值不包含完整误差预算。
3. **天空背景视觉指数**：像素背景亮度归一化后的指标，受到曝光、ISO、白平衡和后期处理强烈影响，不是现场光污染测量，不能解释为 SQM 或 Bortle 等级。
4. **质量提示**：由点源数、背景 MAD、饱和比例和局部点源形态生成；不是完整的云量、遮挡、卫星/飞机轨迹分类模型。

## 隐私与联网

- API Key 使用 Android Keystore 支持的安全存储保存在当前设备；不会写入仓库文件。
- 可选 Astrometry.net 解算只有在用户勾选确认后才开始，并将分析预览 JPEG 上传至 `nova.astrometry.net`。请求设置 `publicly_visible=n`，但不能保证第三方数据留存或绝对保密。
- Gaia TAP 查询只发送解算得到的中心坐标和视场，不上传原始照片。
- 星名与深空天体目录查询发送视场坐标至 SIMBAD TAP 服务。
- 可选语言模型仅收到本地质量指标、天体名和测量摘要，不接收照片或 Key。模型 Key 会发送到用户输入的 Base URL；只应填写可信服务地址。
- 启用 Agent 需由用户自行在“本机 API 设置”填写 Key。DeepSeek、OpenAI、OpenRouter 和硅基流动模板仅预填 OpenAI 兼容 Base URL 与模型名，不内置 Key；模型名和接口支持可能变更，请以服务商控制台为准。自定义服务须兼容 `/chat/completions` 请求格式。
- 未启用解算或 Agent 时，图像读取、星点检测和画质诊断不需要网络。

## Android 启动与测试

1. 安装 Flutter stable SDK、Android Studio 和 Android SDK。
2. 运行 `flutter doctor`，接受 Android SDK licenses，并准备 Android 模拟器或开启 USB 调试的实体设备。
3. 在仓库根目录运行 `flutter pub get` 和 `flutter run`，或双击 `START.bat`。
4. 运行 `flutter test` 和 `flutter analyze` 执行项目验证。
5. 仓库中的 release APK 使用本机 Android debug keystore 签名，仅供个人设备安装；若有合法许可并另作分发，须按 Flutter Android 文档配置正式签名凭据。不要把 keystore 或密钥提交到 Git。

## 代码结构

- `lib/main.dart`：手机 UI、图像处理、FITS/WCS 投影、Astrometry.net、Gaia DR3/SIMBAD 动态目录查询和模型路由。
- `android/`：Android Manifest、应用入口和 Gradle 配置。
- `test/`：本地合成星场与天球坐标格式检查。
- `pubspec.yaml`：Flutter 应用与 Dart package 依赖。
