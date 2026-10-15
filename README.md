![AstroSophy：把手机拍的星空照片交给它，本机算出你拍到了哪片天](assets/brand/astrosophy_social_preview.png)

# AstroSophy

面向天文爱好者的 Flutter Android 应用。选一张手机里拍下的星空照片，它在本机找出星点、算出你拍的是哪片天，再把结果整理成看得懂的表格、图和一段中文说明。**不联网也能用**，没有账号与登录，没有自建服务器。

## 它做了什么

- **本机分析**：在手机上做孔径测光、点扩散函数（FWHM）估计、背景噪声与天空背景指数、饱和比例，并识别文字/表格/大亮斑这类非星空内容，避免把它们当成星点。
- **本机天区解算**：应用内置一份星表（Hipparcos 到 V=8.0 的 41,394 颗亮星，另加一层 Gaia DR3 到 G=9.0 的 13.7 万颗背景星兜底，共约 2.8 MB），用三角形指纹匹配直接算出中心坐标和像素比例，不需要上传照片。视场直径约 4.5° 以上在亮星层就能稳定解算，更窄的视场交给背景星层。
- **在线解算兜底**：本机解算不出来、并且用户明确授权时，才把预览图上传到 Astrometry.net；授权开关默认关闭。
- **爱好者报告**：星表、星等分布直方图、观星记录卡（天区、视场、匹配星数、最亮天体、画质、建议）。
- **交互式结果页**：上半屏是标注图，下半屏是图内亮点的编号列表，两边同号，点哪一颗就定位哪一颗；图可以双指放大，圆圈跟着一起放大。列表分成**亮星 / 亮点 / 可疑飞线**三组，各自可折叠，也能把整组圆圈从图上隐去或显示回来（默认只显示亮星）。隐去就是图上什么都不画——测量结果、报告和星表匹配一个字都不变。
- **可疑飞线交给用户判断**：拉长的亮点可能是卫星、飞机、抖动，也可能是被拖了尾的恒星。这一组的每一条都配一对 ✓ / ✗，判为 ✗ 的从测光和报告里排除，但仍在图上和列表里，随时能改回来。
- **星座连线与全天星图**：解出天区后，把视场内的星座轮廓和名称叠到图上（在线解算的结果同样会补上），并用一张全天图上的十字告诉你这张照片落在天上哪一块。
- **AI 解读（可选）**：填自己的 OpenAI 兼容 Key，模型只收到测量摘要，不接收照片。返回的 Markdown 会排版后显示。
- **保存与回看**：把一次观测连同测量结果存到手机上，之后可以浏览、重看、改名和删除。每条记录按结果描边。

## 启动

安装 Flutter stable SDK、Android Studio 和 Android SDK（JDK 17/21），运行 `flutter doctor` 配好工具链。连接 Android 手机并开启 USB 调试，Windows 双击 [`START.bat`](./START.bat)，或运行：

```shell
flutter pub get
flutter run
```

双击 [`BUILD_APK.bat`](./BUILD_APK.bat) 可生成 release APK。本机没装 Android SDK 的话，每次推送后 GitHub Actions 会构建一份 debug APK 并作为产物上传，可以直接下载安装。正式发行版在 [Releases](https://github.com/Eddie-Duan/Astrosophy/releases) 页面下载，推送 `v*` 标签后由 [`release.yml`](./.github/workflows/release.yml) 自动构建并发布，各版变更见 [`CHANGELOG.md`](./CHANGELOG.md)。

没有真机或还没拍过星空，可以在选图界面点「使用演示图片」，用内置的三张演示星图走一遍完整流程。

## 使用

从手机相册选择 JPG/PNG/TIFF 或相机 RAW 文件，星点与画质分析在手机本机进行。RAW 尝试读取文件中嵌入的 JPEG 预览；不保证所有相机格式都能解码，也不等同于线性 RAW 测光。可选填写 Astrometry.net Key 和 OpenAI 兼容模型 Key；天区解算上传预览图前必须明确授权，模型仅接收测量摘要。未授权时不会把图像上传到天区解算服务。

想启用 Agent，在应用“本机 API 设置”中选择 DeepSeek、OpenAI、OpenRouter 或硅基流动模板，核对/修改模型名并填写自己的 API Key。模板不含密钥；密钥只保存在设备安全存储中。

首次打开会显示整屏新手引导；各卡片的“？”可随时查看该指标的解释，顶部问号可以重播引导。

星等、天空背景指数、RAW 支持边界和隐私说明见 [`docs/TECHNICAL.md`](./docs/TECHNICAL.md)。

## 致谢

这个项目站在别人的肩膀上，用到的数据和服务都在这里说明白：

- **[Recraft](https://www.recraft.ai/)** —— 应用启动图标与引导页吉祥物 Nox 的插画均由 Recraft 在开发期生成（矢量稿）。Recraft 凭据不进入应用，也不进入仓库；生成的图纸本体随仓库分发，来源见 `assets/brand/`，生成脚本见 [`tools/make_mascot.py`](./tools/make_mascot.py)。仓库设置里的社交预览图由 [`tools/make_social_preview.py`](./tools/make_social_preview.py) 用同一张吉祥物合成，只上传到 GitHub，不进 APP 安装包。
- **[Hipparcos 主表](https://cdsarc.cds.unistra.fr/viz-bin/cat/I/239)（ESA 1997，I/239）** —— 内置亮星目录的位置与 V 星等来源。
- **[Bright Star Catalogue, 5th ed.](https://cdsarc.cds.unistra.fr/viz-bin/cat/V/50)（Hoffleit & Warren 1991，V/50）** —— 提供 Bayer/Flamsteed 星名、B-V 色指数和光谱型。
- **[星座边界表](https://cdsarc.cds.unistra.fr/viz-bin/cat/VI/42)（Roman 1987，VI/42）** —— 判断一颗星属于哪个星座。
- **[CDS VizieR](https://vizier.cds.unistra.fr/)** —— 以上三份星表都通过 VizieR 取数。星座连线不是抄任何星图的现成画法，而是对每个星座最亮的成员跑最小生成树自动生成的，没有引入第三方星图的授权问题。
- **[Astrometry.net](https://astrometry.net/)** —— 可选的在线解算服务（`nova.astrometry.net`），仅在用户授权后使用。
- **[ESA Gaia 归档](https://gea.esac.esa.int/archive/)** —— Gaia DR3 TAP 查询，提供解算视场内的恒星位置与 G 星等。
- **[SIMBAD](https://simbad.cds.unistra.fr/)** —— 星名与深空天体目录查询。
- **[Flutter](https://flutter.dev/)** 及其生态的开源包（`image`、`http`、`file_picker`、`image_picker`、`flutter_secure_storage`、`path_provider` 等）。

## 许可

使用限制见 [`LICENSE`](./LICENSE)。如有违反，作者将保留追究其责任的权利。
