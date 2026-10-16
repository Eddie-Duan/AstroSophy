<div align="center">

<img src="assets/brand/astrosophy_social_preview.png" alt="AstroSophy：把手机拍的星空照片交给它，本机算出你拍到了哪片天" width="100%">

# AstroSophy

**把手机拍的星空照片交给它，本机算出你拍到了哪片天。**

[![版本](https://img.shields.io/github/v/tag/Eddie-Duan/AstroSophy?label=version&style=flat-square&color=e8763a)](https://github.com/Eddie-Duan/AstroSophy/releases)
[![下载量](https://img.shields.io/github/downloads/Eddie-Duan/AstroSophy/total?label=downloads&style=flat-square&color=1f9e6e)](https://github.com/Eddie-Duan/AstroSophy/releases)
![平台](https://img.shields.io/badge/platform-Android-3ddc84?style=flat-square&logo=android&logoColor=white)
![Flutter](https://img.shields.io/badge/Flutter-%E2%89%A53.24-02569b?style=flat-square&logo=flutter&logoColor=white)
[![许可](https://img.shields.io/badge/license-non--commercial%20learning%20%26%20research-blue?style=flat-square)](./LICENSE)

**Welcome PR. Welcome Issue.**

</div>

面向天文爱好者的 Flutter Android 应用。选一张手机里拍下的星空照片，它在本机找出星点、算出你拍的是哪片天，再把结果整理成看得懂的表格、图和一段中文说明。**不联网也能用。**

## 功能

- **本机分析**：在手机上做孔径测光、点扩散函数（FWHM）估计、背景噪声与天空背景指数、饱和比例，并识别文字/表格/大亮斑这类非星空内容，避免把它们当成星点。
- **中英双语**：界面文字全部经一张查表（`t()`），可在设置里随时切换。中文原文就是 key，所以漏翻的地方退回中文原文，而不会露出 `report.unresolved.label` 这种占位符。翻译表是标准 ARB，放在 `lib/l10n/app_<语言>.arb`——加一门语言只要多放一个文件、重跑 `tools/build_strings.py`，不必碰任何 Dart 代码。见 [技术与使用说明](./docs/TECHNICAL.md) 的「界面文字与多语言」。
- **本机天区解算**：应用内置一份星表（Hipparcos 到 V=8.0 的 41,394 颗亮星，另加一层 Gaia DR3 到 G=11 的 120.6 万颗背景星兜底，共约 10 MB），用三角形指纹匹配直接算出中心坐标和像素比例。星表按三层用：亮星层不够就加上 G<9 的那批背景星，还不够才动用整层。视场直径约 4.5° 以上在亮星层就能稳定解算，更窄的视场交给背景星层，窄到智能望远镜那个量级（对角线 1.5°～2.5°）也照样在手机上解——门槛不是视场大小，而是画面里到底有没有目录星可以互相印证。
- **在线解算兜底**：本机解算不出来、并且用户明确授权时，才把预览图上传到 Astrometry.net；授权开关默认关闭。
- **取景裁剪**：选好照片之后先用一个裁剪框圈出要分析的范围，之后分析的、以及必要时上传的，都只有这一块。设备在画面下方压的水印和信息条留在框外就行——那种东西一起送去解算会被当成星点。
- **解析可以放到后台**：解析动辄一两分钟，用户不用守着。点「保存并退出」就把这一屏松开手——直接回到刚打开应用的样子，解析在后台接着跑，跑完自动存进观星仓库；这期间可以去挑下一张图。首页会留一条横幅，随时能回到那次解析看进度。
- **进度条会换颜色**：薄荷绿是本机在算，蓝是本机正在动用最深那层星表（左端另挂一句「本地深度思考」），琥珀是照片已经传给在线解算了，**红色是本机解算已经成功**——那条红只在照片确实没出过设备的时候出现，不必读任何字。还有一套**银白底加蓝斑点**：你选了「直接分析月球」之后，这一次只报月亮，星点检测和星表匹配全都跳过了。
- **照片出去过，报告会说**：如果这一次最后是靠 Astrometry.net 解出来的，结果页那张「观星记录」会换成琥珀色边框，并在最前面写明分析预览已上传、坐标和天体名来自该服务。颜色和进度条上表示「在线」的那一套是同一个琥珀。
- **Nox 助手（可选）**：主界面右上角进。它知道这个应用会什么、不会什么，能读本机的观测记录和当前照片的分析结果，也能替你保存、改名、删除记录、请求在线解算、打开页面。写入和联网的操作仍然逐次征求确认，模型不能读任意文件、访问网址或执行代码。
- **爱好者报告**：报告最前面就是「拍到了什么」——所在星座、有中文星官名的亮星、按「编号 ＋ 中文常用名」写出的星团星云（`M 45 昴星团`、`NGC 6960 西面纱星云`），天体名在正文里带颜色。同一个天体在图上的标注、列表和报告里用的是同一个写法。后面接星表、星等分布直方图和一排测量数字。**图上四类目标用四种互不相同的记号**：亮星是薄荷绿实线圆，深空天体是粉色实线圆（大小跟着天体自身的角尺寸），行星和矮行星是琥珀色虚线圆加十字，小行星和彗星是浅蓝色四角框加十字。虚线和方框都在说同一件事——这个位置是算出来的，不是看出来的。
- **月面分析**：以月亮为主的照片在分析最一开始就被分流，走独立的月面链路——不再进星点检测（在月面上找「星」找到的只是环形山和噪点）。给出月盘的圆心与半径、亮面占比，配合拍摄时刻再给出相名与盈亏。两个亮面占比是两条独立的路径（数像素 vs 算星历），界面并排摆出来互相印证。
- **交互式结果页**：上半屏是标注图，下半屏是图内亮点的编号列表，两边同号，点哪一颗就定位哪一颗；图可以双指放大，圆圈跟着一起放大。列表分成**亮星 / 亮点 / 可疑飞线**三组，各自可折叠，也能把整组圆圈从图上隐去或显示回来（默认只显示亮星）。隐去就是图上什么都不画——测量结果、报告和星表匹配一个字都不变。图上的文字标注会自己避让，不会互相压住。
- **全屏看图与导出**：点图上的全屏按钮进整屏，能放到 12 倍；退出全屏后半屏那块还停在原处。全屏里可以把**当前勾选的标注**（隐去哪一组、收起哪颗星都算数）按原始图像尺寸重画成一张 PNG，交给系统分享面板存到相册或文件。
- **可疑飞线交给用户判断**：拉长的亮点可能是卫星、飞机、抖动，也可能是被拖了尾的恒星。这一组的每一条都配一对 ✓ / ✗，判为 ✗ 的从测光和报告里排除，但仍在图上和列表里，随时能改回来。
- **系内天体**：行星、矮行星、小行星、彗星在「图上目标」里单列一组，紧接着深空天体，**默认就在图上画着标记**。判据是「星表里这个位置没有星 ＋ 星历说它就在这儿」，两条缺一不可，所以结论一律写成「疑似」。内置 16 颗亮小行星（灶神星最亮 6.5 等，全部 ≤ 12.5 等）、10 颗矮行星和全部 939 颗彗星；亮度要够、而且离太阳不能太近（大距 20° 以内只在暮光里）。落在画面里但不够亮的照样说一句「它今天在这儿，亮度 X 等，拍不到」，不静默省略——只是图上不会给它画记号，因为那等于宣称看见了。彗星的亮度有八成的光度参数是缺省值，所以只写「可能够亮」，不给数字。内置表带着构建日期：位置实测一年偏 0.7′、三年偏 20′，日期要跟着结论一起看。
- **星座连线与全天星图**：解出天区后，把视场内的星座轮廓和名称叠到图上（在线解算的结果同样会补上），并用一张全天图上的十字告诉你这张照片落在天上哪一块。
- **Agent（可选）**：查询当前报告、当前视场天体（含系内天体）、某颗小行星或彗星现在在哪儿、本机观测摘要与单条观测详情；也可申请保存/改名/删除观测、在线解算、视觉遮罩，或直接打开记录页与设置页，每项写入或联网操作都会先请用户确认。工具调用次数有限，模型不能任意读文件、访问网址或执行代码。
- **视觉遮罩**：用户可以让兼容视觉输入的模型寻找照片中的水印/文字区域。发送图片和应用遮罩分别需要确认；遮罩只作用于本机测量，原图不变。普通分析不上传图片。
- **保存与回看**：把一次观测连同测量结果存到手机上，之后可以浏览、重看、改名和删除。每条记录按结果描边。

## 启动

安装 Flutter stable SDK、Android Studio 和 Android SDK（JDK 17/21），运行 `flutter doctor` 配好工具链。连接 Android 手机并开启 USB 调试，Windows 双击 [`START.bat`](./START.bat)，或运行：

```shell
flutter pub get
flutter run
```

双击 [`BUILD_APK.bat`](./BUILD_APK.bat) 可生成 release APK，产物是 `build/app/outputs/flutter-apk/AstroSophy.apk`。正式发行版在 [Releases](https://github.com/Eddie-Duan/AstroSophy/releases) 页面下载，文件名同样是 `AstroSophy.apk`；推送 `v*` 标签后由 [`release.yml`](./.github/workflows/release.yml) 自动构建并发布，各版变更见 [`CHANGELOG.md`](./CHANGELOG.md)。**发版用的签名凭据必须配在仓库 secrets 里**——用 debug keystore 签出来的包每次签名都不同，用户装上就得先卸载、数据一起没；配置方法见 [`docs/TECHNICAL.md`](./docs/TECHNICAL.md)。

没有真机或还没拍过星空，可以在选图界面点「演示图」，用内置的五张演示照片走一遍完整流程——四张星空（含一张土星、一张灶神星所在的天区）和一张月球照。

## 使用

从手机相册选择 JPG/PNG/TIFF 或相机 RAW 文件，星点与画质分析在手机本机进行。RAW 尝试读取文件中嵌入的 JPEG 预览；不保证所有相机格式都能解码，也不等同于线性 RAW 测光。可选填写 Astrometry.net Key 和 OpenAI 兼容模型 Key；普通 Agent 对话只发送测量摘要，查阅观测记录时才会把相应文字摘要交给模型。在线解算或视觉遮罩会发送图片预览，并在执行前单独向用户确认。

想启用 Agent，在应用“本机 API 设置”中选择 DeepSeek、OpenAI、OpenRouter 或硅基流动模板，核对/修改模型名并填写自己的 API Key。视觉遮罩（找水印/文字）用的是同一个模型，所以那个模型需要支持图像输入。模板不含密钥；密钥只保存在设备安全存储中。

首次打开会显示整屏新手引导；各卡片的“?”可随时查看该指标的解释，顶部问号可以重播引导。

星等、天空背景指数、RAW 支持边界和隐私说明见 [`docs/TECHNICAL.md`](./docs/TECHNICAL.md)；AI 现在做什么、接下来还能做什么、哪些方向明确不做，见 [`docs/AI-ROADMAP.md`](./docs/AI-ROADMAP.md)。

## 致谢

这个项目站在巨人的肩膀上，所用的数据和服务在这里说明：

- **[Recraft](https://www.recraft.ai/)** —— 应用启动图标与引导页四页插画（含吉祥物 Nox）均由 Recraft 在开发期生成。Recraft 凭据不进入应用，也不进入仓库；生成的图纸本体随仓库分发，来源见 `assets/brand/`，生成脚本见 [`tools/make_onboarding_art.py`](./tools/make_onboarding_art.py)。仓库设置里的社交预览图由 [`tools/make_social_preview.py`](./tools/make_social_preview.py) 用同一张吉祥物合成。
- **[Hipparcos 主表](https://cdsarc.cds.unistra.fr/viz-bin/cat/I/239)（ESA 1997，I/239）** —— 内置亮星目录的位置与 V 星等来源。
- **[Bright Star Catalogue, 5th ed.](https://cdsarc.cds.unistra.fr/viz-bin/cat/V/50)（Hoffleit & Warren 1991，V/50）** —— 提供 Bayer/Flamsteed 星名、B-V 色指数和光谱型。
- **[星座边界表](https://cdsarc.cds.unistra.fr/viz-bin/cat/VI/42)（Roman 1987，VI/42）** —— 判断一颗星属于哪个星座。
- **[CDS VizieR](https://vizier.cds.unistra.fr/)** —— 以上三份星表都通过 VizieR 取数。星座连线不是抄任何星图的现成画法，而是对每个星座最亮的成员跑最小生成树自动生成的，没有引入第三方星图的授权问题。
- **[Astrometry.net](https://astrometry.net/)** —— 可选的在线解算服务（`nova.astrometry.net`），仅在用户授权后使用。
- **[ESA Gaia 归档](https://gea.esac.esa.int/archive/)** —— Gaia DR3 TAP 查询，提供解算视场内的恒星位置与 G 星等。
- **[SIMBAD](https://simbad.cds.unistra.fr/)** —— 星名与深空天体目录查询。
- **[NGC 2000.0](https://cdsarc.cds.unistra.fr/viz-bin/cat/VII/118)（Sky Catalogue 2000.0 的 NGC/IC 部分，VII/118）** —— 内置深空目录（Messier 110 加亮 NGC/IC 成员）的名称、类型、角尺寸与视星等。**深空天体的中文常用名**（蟹状星云、马头星云、东面纱星云…）是手写的一张短表（[`lib/deepsky_names.dart`](./lib/deepsky_names.dart)），只收最常被提到的那批目标，取中文天文普及读物里的通行译法；没收录的只显示编号，不硬译。**小行星、矮行星和彗星的中文名**同理，取通行的中文译名（灶神星、共工星、紫金山彗星…），彗星里没有通用译名的就用 MPC 的正式编号——每年新发现的几十颗都还没有译名，硬凑一个反而让人对不上号。
- **[Jean Meeus《Astronomical Algorithms》](https://www.willbell.com/math/mc1.htm)** —— 月相算式（第 47 章 47.2/47.3/47.4 三个基本角、第 48 章 48.4 的相位角与 48.1 的亮面占比），实现见 [`lib/moon.dart`](./lib/moon.dart)。不用它算别的：解算与行星位置走的是 JPL 的近似根数，见 [`docs/TECHNICAL.md`](./docs/TECHNICAL.md)。
- **[JPL 小行星星历服务（SBDB API）](https://ssd-api.jpl.nasa.gov/doc/sbdb.html)** —— 16 颗亮小行星与 10 颗矮行星的轨道根数、历元、绝对星等 H、斜率 G 和直径。**拍不到的那几颗也收**。
- **[JPL Horizons](https://ssd.jpl.nasa.gov/horizons/)** —— 开发期用来核对两体传播的精度（模型本身好于 1 角分，漂移全靠内置表变旧）。
- **[国际小行星中心（MPC）](https://www.minorplanetcenter.net/)** —— `iau/MPCORB/CometEls.txt` 提供全部 939 颗彗星的根数、过近日点时刻、M1 与 k1。那份表由 [`tools/build_smallbodies.py`](./tools/build_smallbodies.py) 在构建时抓一次，构建日期跟着数据一起发出去。
- **[Flutter](https://flutter.dev/)** 及其生态的开源包（`image`、`http`、`file_picker`、`image_picker`、`flutter_secure_storage`、`path_provider`、`share_plus` 等）。

## 许可

使用限制见 [`LICENSE`](./LICENSE)。如有违反，作者将保留追究其责任的权利。
