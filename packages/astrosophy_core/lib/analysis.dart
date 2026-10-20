import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as imglib;

import 'strings.dart';
import 'models.dart';
import 'moon_disc.dart';
import 'sun_disc.dart';

/// 图像分析层：解码、星点检测、非星空掩膜、孔径测光和处理图生成。
///
/// 这一层不依赖 Flutter UI，整个 [SkyAnalysis.analyze] 可以在独立 isolate 里跑。
/// 算法刻意做成“先分类、再测量”，因为面向的是随手拍的手机照片：画面里经常有
/// 文字、表格、地面景物和路灯，直接按阈值取亮点会大面积误检。

/// 判定为非星空的区域类型，UI 上用来区分提示措辞。
enum MaskKind {
  /// 面积远超星点的大亮斑：月亮、路灯、被照亮的建筑。
  blob,

  /// 密集且亮度高度一致的小结构：屏幕或照片上的文字。
  text,

  /// 细长的非直线感结构：表格边框、电缆、栏杆。
  line,
}

/// 一块被判为非星空的矩形区域（图像像素坐标）。
class MaskRegion {
  const MaskRegion({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.kind,
  });

  final double x;
  final double y;
  final double width;
  final double height;
  final MaskKind kind;

  double get area => width * height;

  Map<String, Object?> toJson() => {
        'x': x,
        'y': y,
        'width': width,
        'height': height,
        'kind': kind.name,
      };

  static MaskRegion fromJson(Map<String, Object?> json) => MaskRegion(
        x: _asDouble(json['x']),
        y: _asDouble(json['y']),
        width: _asDouble(json['width']),
        height: _asDouble(json['height']),
        kind: MaskKind.values.firstWhere(
          (value) => value.name == json['kind'],
          orElse: () => MaskKind.blob,
        ),
      );
}

/// 用户确认后从图像分析中排除的归一化矩形。该矩形只作用于测量数据，
/// 原图预览不会被裁剪或覆盖。
class ImageExclusion {
  const ImageExclusion({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final double x;
  final double y;
  final double width;
  final double height;
}

/// 一次本地分析的完整结果。
/// 星点检测的松紧程度。广域用它把银河纹理里更暗的星也捞出来，
/// 普通场景仍保持原来的 5σ/3.2σ，避免假星。
enum StarDetectionProfile { normal, wide }

class SkyAnalysis {
  const SkyAnalysis({
    required this.width,
    required this.height,
    required this.stars,
    required this.quality,
    required this.background,
    required this.noise,
    required this.backgroundIndex,
    required this.saturatedFraction,
    required this.diagnostics,
    required this.preview,
    required this.processedPreview,
    required this.fwhm,
    required this.nonStarFraction,
    required this.maskRegions,
    required this.isLikelyStarfield,
    required this.starfieldConfidence,
    required this.brightFlatFraction,
    this.solverExtras = const [],
    this.moonDisc,
    this.sunDisc,
  });

  final int width;
  final int height;

  /// 全部检出对象，包含紧凑点源、拉长候选和用户已剔除的项。
  final List<DetectedStar> stars;

  final String quality;
  final double background;
  final double noise;
  final double backgroundIndex;
  final double saturatedFraction;
  final List<String> diagnostics;

  /// 供上传和显示用的预览图（缩放后的原图）。
  final Uint8List preview;

  /// 处理图：扣除天空背景、按反双曲正弦拉伸、并抹掉非星空区域，只留下星场。
  final Uint8List processedPreview;

  /// 全帧统计出的点扩散函数半高全宽（像素），用来判断对焦、给测光定孔径。
  final double fwhm;

  /// 被判为非星空的像素占比。
  final double nonStarFraction;

  /// 非星空区域清单，UI 用来画掩膜和解释原因。
  final List<MaskRegion> maskRegions;

  /// 这张图整体看起来是不是星空照片。
  final bool isLikelyStarfield;

  /// 星空判定的置信度（0–1），低的时候 UI 要明确提示“可能不是星空照片”。
  final double starfieldConfidence;

  /// 近乎平坦（没有噪声起伏）的像素占比。截图、纯色背景会非常高。
  final double brightFlatFraction;

  /// 形态上是拉线候选、但允许进入解算的亮源（见 `analysis.dart` 的 `_classify`）。
  ///
  /// 它们**不在** [stars] 里：界面上的编号、列表、星等统计都只认 [stars]，
  /// 否则用户会看到一堆分不清是星还是拖线的圆圈。这里只服务于解算。
  final List<DetectedStar> solverExtras;

  /// 量出来的月面。**非 null 表示这张照片走的是月面分支**，此时 [stars] 一定
  /// 是空的：月面亮得离谱，星点检测在它身上没有意义。
  ///
  /// 分流在 [analyze] 的**最一开始**做，不是等星点流程跑完再判断——实测一张
  /// 月球照会被现有判据老老实实当成正常星场，在月面上「检出」13 颗星，甚至
  /// 局部对比度还挺高。等它跑完再改判，报告里那些数字早就编好了。
  final MoonDisc? moonDisc;

  /// 太阳圆盘；只在「太阳」场景里尝试，和月亮是互斥的两条盘面链路。
  final SunDisc? sunDisc;

  /// 这张照片是不是以月面为主。
  bool get isMoonShot => moonDisc != null;

  bool get isSunShot => sunDisc != null;

  /// 参与星表匹配和测光的紧凑点源（排除拉长候选和用户剔除项）。
  List<DetectedStar> get compactSources => stars
      .where((star) => !star.isElongated && !star.isRejected)
      .toList(growable: false);

  /// 全部紧凑点源，含被用户剔除的，供列表完整展示。
  List<DetectedStar> get allCompactSources =>
      stars.where((star) => !star.isElongated).toList(growable: false);

  /// 拉长候选：可能是拖线、卫星/飞机轨迹、失焦或伪影。
  List<DetectedStar> get streakCandidates =>
      stars.where((star) => star.isElongated).toList(growable: false);

  /// 按亮度排序的紧凑点源，序号从 1 开始，与 UI 列表和图上编号一一对应。
  List<DetectedStar> get rankedCompactSources => _rank(allCompactSources);

  List<DetectedStar> get rankedStreakCandidates => _rank(streakCandidates);

  /// 图上所有会显示编号的对象，编号顺序与 [numberedTargets] 完全一致。
  List<DetectedStar> get numberedTargets => [
        ...rankedCompactSources,
        ...rankedStreakCandidates,
      ];

  List<DetectedStar> _rank(List<DetectedStar> source) =>
      source.toList(growable: false)
        ..sort((a, b) => a.instrumentalMagnitude.compareTo(b.instrumentalMagnitude));

  /// 本机解算的输入候选。
  ///
  /// 和展示用的 [compactSources] 是**两套判据**：解算这边多收一类「形似略
  /// 拉长的亮源」（[solverExtras]）。多一个假点源只是多一个对不上的候选，
  /// 内点验证自己会把它筛掉；而窄视场里少一颗真参考星，整张图就直接解不
  /// 出来。展示那边则相反，宁缺毋滥——图上多一个圈，用户就得多费一次神。
  ///
  /// 用户手动剔除的拉线不进候选：他已经明确说过「这不是天体」。剔除是按
  /// 坐标记在 [stars] 上的，而 [solverExtras] 是另一批对象，所以要按坐标比对。
  List<DetectedStar> get solveCandidates {
    final rejected = stars.where((star) => star.isRejected).toList();
    if (rejected.isEmpty) {
      return [...compactSources, ...solverExtras];
    }
    bool wasRejected(DetectedStar star) =>
        rejected.any((item) => _sameSource(item, star));
    return [
      ...compactSources,
      ...solverExtras.where((star) => !wasRejected(star)),
    ];
  }

  /// 取一块子图，坐标平移到子图局部原点。
  ///
  /// 只用于分块解算：星点表、FWHM、背景这些测量值原样带过去，`width/height`
  /// 换成子图尺寸。预览图不重编码，解算那边本来也不看它。
  SkyAnalysis subRegion(int left, int top, int regionWidth, int regionHeight) {
    final right = left + regionWidth;
    final bottom = top + regionHeight;
    bool inside(DetectedStar star) =>
        star.x >= left && star.x < right && star.y >= top && star.y < bottom;
    return SkyAnalysis(
      width: regionWidth,
      height: regionHeight,
      stars: [
        for (final star in stars)
          if (inside(star)) star.translated(left.toDouble(), top.toDouble()),
      ],
      quality: quality,
      background: background,
      noise: noise,
      backgroundIndex: backgroundIndex,
      saturatedFraction: saturatedFraction,
      diagnostics: diagnostics,
      preview: preview,
      processedPreview: processedPreview,
      fwhm: fwhm,
      nonStarFraction: nonStarFraction,
      maskRegions: const [],
      isLikelyStarfield: isLikelyStarfield,
      starfieldConfidence: starfieldConfidence,
      brightFlatFraction: brightFlatFraction,
      solverExtras: [
        for (final star in solverExtras)
          if (inside(star)) star.translated(left.toDouble(), top.toDouble()),
      ],
    );
  }

  /// 标记/取消标记某个拉长候选，返回新结果（列表本身不可变）。
  SkyAnalysis withRejection(DetectedStar target, bool rejected) => copyWith(
        stars: stars
            .map(
              (star) => _sameSource(star, target)
                  ? star.copyWith(isRejected: rejected)
                  : star,
            )
            .toList(growable: false),
      );

  SkyAnalysis copyWith({List<DetectedStar>? stars}) => SkyAnalysis(
        width: width,
        height: height,
        stars: stars ?? this.stars,
        quality: quality,
        background: background,
        noise: noise,
        backgroundIndex: backgroundIndex,
        saturatedFraction: saturatedFraction,
        diagnostics: diagnostics,
        preview: preview,
        processedPreview: processedPreview,
        fwhm: fwhm,
        nonStarFraction: nonStarFraction,
        maskRegions: maskRegions,
        isLikelyStarfield: isLikelyStarfield,
        starfieldConfidence: starfieldConfidence,
        brightFlatFraction: brightFlatFraction,
        solverExtras: solverExtras,
        moonDisc: moonDisc,
        sunDisc: sunDisc,
      );

  static bool _sameSource(DetectedStar a, DetectedStar b) =>
      (a.x - b.x).abs() < 0.01 && (a.y - b.y).abs() < 0.01;

  Map<String, Object?> toJson() => {
        'width': width,
        'height': height,
        'stars': stars.map((star) => star.toJson()).toList(),
        'quality': quality,
        'background': background,
        'noise': noise,
        'background_index': backgroundIndex,
        'saturated_fraction': saturatedFraction,
        'diagnostics': diagnostics,
        'fwhm': fwhm,
        'non_star_fraction': nonStarFraction,
        'mask_regions': maskRegions.map((region) => region.toJson()).toList(),
        'is_likely_starfield': isLikelyStarfield,
        'starfield_confidence': starfieldConfidence,
        'bright_flat_fraction': brightFlatFraction,
        'solver_extras': solverExtras.map((star) => star.toJson()).toList(),
        'moon_disc': moonDisc?.toJson(),
        'sun_disc': sunDisc?.toJson(),
      };

  /// 历史记录里只存索引信息，图片从磁盘重新读，不在 JSON 里塞 base64。
  static SkyAnalysis fromJson(
    Map<String, Object?> json, {
    required Uint8List preview,
    required Uint8List processedPreview,
  }) =>
      SkyAnalysis(
        width: _asDouble(json['width']).round(),
        height: _asDouble(json['height']).round(),
        stars: ((json['stars'] as List<Object?>?) ?? const [])
            .whereType<Map<Object?, Object?>>()
            .map((item) => DetectedStar.fromJson(Map<String, Object?>.from(item)))
            .toList(growable: false),
        quality: json['quality'] as String? ?? t('未知'),
        background: _asDouble(json['background']),
        noise: _asDouble(json['noise']),
        backgroundIndex: _asDouble(json['background_index']),
        saturatedFraction: _asDouble(json['saturated_fraction']),
        diagnostics: ((json['diagnostics'] as List<Object?>?) ?? const [])
            .whereType<String>()
            .toList(growable: false),
        preview: preview,
        processedPreview: processedPreview,
        fwhm: _asDouble(json['fwhm']),
        nonStarFraction: _asDouble(json['non_star_fraction']),
        maskRegions: ((json['mask_regions'] as List<Object?>?) ?? const [])
            .whereType<Map<Object?, Object?>>()
            .map((item) => MaskRegion.fromJson(Map<String, Object?>.from(item)))
            .toList(growable: false),
        isLikelyStarfield: json['is_likely_starfield'] != false,
        starfieldConfidence: _asDouble(json['starfield_confidence']),
        brightFlatFraction: _asDouble(json['bright_flat_fraction']),
        solverExtras: ((json['solver_extras'] as List<Object?>?) ?? const [])
            .whereType<Map<Object?, Object?>>()
            .map((item) => DetectedStar.fromJson(Map<String, Object?>.from(item)))
            .toList(growable: false),
        moonDisc: json['moon_disc'] is Map<Object?, Object?>
            ? MoonDisc.fromJson(
                Map<String, Object?>.from(json['moon_disc'] as Map<Object?, Object?>),
              )
            : null,
        sunDisc: json['sun_disc'] is Map<Object?, Object?>
            ? SunDisc.fromJson(
                Map<String, Object?>.from(json['sun_disc'] as Map<Object?, Object?>),
              )
            : null,
      );

  /// 对外唯一入口：给一份图片字节，返回分析结果。
  /// 星点检测的松紧程度。广域用它把银河纹理里更暗的星也捞出来，
  /// 普通场景仍保持原来的 5σ/3.2σ，避免假星。
  static SkyAnalysis analyze(
    Uint8List bytes, {
    List<ImageExclusion> exclusions = const [],
    bool detectMoon = true,
    bool detectSun = false,
    StarDetectionProfile profile = StarDetectionProfile.normal,
  }) {
    final decoded = decodeImageOrRawPreview(bytes);
    if (decoded == null) {
      throw FormatException(
        t('无法解码此图片或 RAW 内嵌预览。请在相机应用中导出 JPG/PNG 后重试。'),
      );
    }
    final image = _downscale(decoded);
    final width = image.width;
    final height = image.height;

    final gray = _toGrayscale(image);
    final grayBytes = _byteGrayscale(gray);

    if (detectSun) {
      final sunDisc = measureSunDisc(
        gray: grayBytes,
        width: width,
        height: height,
      );
      if (sunDisc != null) {
        return _analyzeSun(image, gray, width, height, sunDisc);
      }
    }

    // 定性分流放在最一开始：月面为主的照片走月面那条链路，根本不进星点流程。
    //
    // 不这么做的话后果是实打实的——实测一张月球照会被现有星点判据老老实实
    // 判成「正常星场」，在月面上找出 13 颗「星」。月面本身就亮得离谱，等星点
    // 流程跑完再回头看，报告里的星等、噪声、解算建议早就编好了。
    final moonDisc = detectMoon
        ? measureMoonDisc(
            gray: grayBytes,
            width: width,
            height: height,
          )
        : null;
    if (moonDisc != null) {
      return _analyzeMoon(image, gray, width, height, moonDisc);
    }

    final excludedRegions = _applyImageExclusions(
      gray,
      width,
      height,
      exclusions,
    );
    var saturated = 0;
    for (var i = 0; i < gray.length; i++) {
      if (gray[i] >= 250 / 255) saturated++;
    }
    final saturatedFraction = saturated / gray.length;

    final grid = _BackgroundGrid(gray, width, height);
    final threshold = _ThresholdMap(gray, width, height, grid, profile);

    var classified = _classify(
      _findComponents(gray, width, height, threshold.primary, grid),
      gray,
      width,
      height,
      grid,
    );
    // 标准阈值下点源太少时，降低阈值再试一次：手机夜景常见的欠曝照片能多救回一些星。
    var usedRelaxedThreshold = false;
    if (classified.stars.length < 8) {
      final relaxed = _classify(
        _findComponents(gray, width, height, threshold.relaxed, grid),
        gray,
        width,
        height,
        grid,
      );
      if (relaxed.stars.length > classified.stars.length) {
        classified = relaxed;
        usedRelaxedThreshold = true;
      }
    }

    // 测光要等分类全部定下来、整帧的 PSF 有得估了再做，所以放在这里而不是
    // 分类过程里。孔径半径整帧统一，理由写在 [_measureAperture]。
    final apertureRadius = _apertureRadiusOf(classified.stars);
    final compact = <DetectedStar>[
      for (final component in classified.stars)
        _toStar(
          component,
          grid,
          aperture: apertureRadius > 0
              ? _measureAperture(component, grid, gray, width, height,
                  apertureRadius)
              : null,
        ),
    ];
    final streaks = <DetectedStar>[
      for (final component in classified.trails) _toStar(component, grid),
    ];
    // 解算候选里的「拉线」不走近圆孔径：它们本来就不是圆的，套一个圆孔
    // 只会把邻星的通量也算进来。通量在这里只用来排序，阈值连通域的和够用。
    final solverOnly = <DetectedStar>[
      for (final component in classified.solverExtras) _toStar(component, grid),
    ];

    final suppressed = _suppressTextRows([...compact, ...streaks]);
    final stars = [...compact, ...streaks]
        .where((star) => !suppressed.contains(star))
        .toList(growable: false)
      ..sort((a, b) => a.instrumentalMagnitude.compareTo(b.instrumentalMagnitude));
    // 被文字抑制律筛掉的对象不能进解算候选——一排排得整整齐齐的亮点是印刷
    // 品，不是星空。抑制是按对象比对的，而上面那批和 [solverOnly] 是两次
    // 构造出来的不同对象，所以这里按坐标再比一次。
    final suppressedPositions = [
      for (final star in suppressed) (star.x, star.y),
    ];
    final solverExtras = solverOnly
        .where(
          (star) => !suppressedPositions.any(
            (position) =>
                (position.$1 - star.x).abs() < 0.01 &&
                (position.$2 - star.y).abs() < 0.01,
          ),
        )
        .toList(growable: false);

    final maskRegions = [...classified.regions, ...excludedRegions];
    final brightFlatFraction = _brightFlatFraction(gray, width, height);
    final starfield = _judgeStarfield(
      stars: stars,
      maskRegions: maskRegions,
      brightFlatFraction: brightFlatFraction,
      width: width,
      height: height,
    );
    final fwhm = _estimateFwhm(stars);

    // 被文字抑制掉的点也要从画面里抹掉，否则处理图上会留下文字残影。
    final mask = Uint8List(width * height);
    for (final region in maskRegions) {
      _fillMask(mask, width, height, region.x, region.y, region.width, region.height);
    }
    // 掩膜按笔画的实际大小铺：一像素宽、几十像素高的笔画用 8×8 的小方块
    // 盖不住，处理图上会留下一条线。
    for (final star in suppressed) {
      final reach = math.max(star.fwhm * star.axisRatio, 5.0) / 2 + 2;
      _fillMask(mask, width, height, star.x - reach, star.y - reach,
          reach * 2, reach * 2);
    }
    var maskedPixels = 0;
    for (var i = 0; i < mask.length; i++) {
      if (mask[i] != 0) maskedPixels++;
    }

    final diagnostics = _buildDiagnostics(
      stars: stars,
      regions: maskRegions,
      starfield: starfield,
      background: grid.globalBackground,
      noise: grid.globalNoise,
      saturatedFraction: saturatedFraction,
      fwhm: fwhm,
      usedRelaxedThreshold: usedRelaxedThreshold,
      suppressedText: suppressed.length,
    );
    if (excludedRegions.isNotEmpty) {
      diagnostics.add(
        t('已按用户确认的视觉建议排除 {0} 个非星空区域；只影响测量，原图保持不变。', [excludedRegions.length]),
      );
    }

    return SkyAnalysis(
      width: width,
      height: height,
      stars: stars,
      quality: _qualityLabel(
        stars: stars,
        noise: grid.globalNoise,
        saturatedFraction: saturatedFraction,
        starfieldConfidence: starfield.confidence,
      ),
      background: grid.globalBackground,
      noise: grid.globalNoise,
      backgroundIndex: grid.globalBackground * 100,
      saturatedFraction: saturatedFraction,
      diagnostics: diagnostics,
      preview: Uint8List.fromList(imglib.encodeJpg(image, quality: 92)),
      processedPreview: _renderProcessedPreview(gray, width, height, grid, mask),
      fwhm: fwhm,
      nonStarFraction: maskedPixels / mask.length,
      maskRegions: maskRegions,
      isLikelyStarfield: starfield.isStarfield,
      starfieldConfidence: starfield.confidence,
      brightFlatFraction: brightFlatFraction,
      solverExtras: solverExtras,
    );
  }
}

// ---------------------------------------------------------------------------
// 月面分支
// ---------------------------------------------------------------------------

/// 0–255 的整帧灰度，月面测量吃这个口径。
Uint8List _byteGrayscale(Float32List gray) {
  final bytes = Uint8List(gray.length);
  for (var i = 0; i < gray.length; i++) {
    bytes[i] = (gray[i] * 255).round().clamp(0, 255);
  }
  return bytes;
}

/// 月面分支：不做星点检测，只报月面本身。
///
/// 星点那条链路的产物——星等、FWHM、非星空掩膜、解算候选——在月球照上全是
/// 噪声（月面上的「星点」就是环形山和噪点）。与其报一堆听起来很专业的假数字，
/// 不如一条都不报。
SkyAnalysis _analyzeMoon(
  imglib.Image image,
  Float32List gray,
  int width,
  int height,
  MoonDisc disc,
) {
  final bytes = _byteGrayscale(gray);

  // 天空统计量只取月盘外那一圈。盘内是月亮，算进去背景就虚高了——而这张图
  // 的背景本来就是月面分析自己要用的一把尺子。
  final outer = disc.radiusPixels * 1.15 + 4;
  final outerSq = outer * outer;
  var sum = 0.0;
  var sumSq = 0.0;
  var count = 0;
  var saturated = 0;
  for (var y = 0; y < height; y++) {
    final dy = y - disc.centerY;
    for (var x = 0; x < width; x++) {
      final value = bytes[y * width + x];
      if (value >= 250) saturated++;
      final dx = x - disc.centerX;
      if (dx * dx + dy * dy <= outerSq) continue;
      final level = value.toDouble();
      sum += level;
      sumSq += level * level;
      count++;
    }
  }
  final skyMean = count == 0 ? 0.0 : sum / count;
  final variance = count == 0 ? 0.0 : sumSq / count - skyMean * skyMean;
  final background = skyMean / 255.0;
  final noise = variance > 0 ? math.sqrt(variance) / 255.0 : 0.0;
  final saturatedFraction = bytes.isEmpty ? 0.0 : saturated / bytes.length;

  final preview = Uint8List.fromList(imglib.encodeJpg(image, quality: 92));
  final litPercent = (disc.illuminatedFraction * 100).toStringAsFixed(1);
  final discPercent = (disc.discAreaFraction * 100).toStringAsFixed(2);

  return SkyAnalysis(
    width: width,
    height: height,
    stars: const [],
    quality: t('月面'),
    background: background,
    noise: noise,
    backgroundIndex: background * 100,
    saturatedFraction: saturatedFraction,
    diagnostics: [
      t('这张照片以月面为主，走的是月面分析，不做星点检测。月亮比任何恒星都亮得多，在它身上找「星」找到的只是环形山和噪点；这类照片里通常也没有可用的星场。'),
      t('月盘：圆心 ({0}, {1}) 像素，半径 {2} 像素，占画面 {3}%。', [disc.centerX.round(), disc.centerY.round(), disc.radiusPixels.toStringAsFixed(1), discPercent]),
      t('亮面占比 {0}%：这是数出来的——被照亮的像素数除以整个月盘的面积。月面是球，投影到画面上是正圆，明暗界线投影成半个椭圆，亮面那块占整个圆的比恰好就是亮面占比，所以直接数像素就是准的。', [litPercent]),
      t('注意这个数只说明「多大一块亮着」，说明不了「在盈还是在亏」：单张照片里相机有没有镜像、有没有上下翻转是看不出来的（加了天顶镜的折射镜是镜像的，牛顿式是旋转的）。月的盈亏和相名要靠拍摄时刻算，见报告里的月相一条。'),
    ],
    preview: preview,
    // 处理图那条链路是「扣背景、拉伸、抹掉非星空区域、只留星场」，
    // 在月球照上没有意义，也不该把月亮本身「抹掉」。原图即是成品。
    processedPreview: preview,
    fwhm: 0,
    nonStarFraction: 0,
    maskRegions: const [],
    isLikelyStarfield: false,
    starfieldConfidence: 0,
    brightFlatFraction: 0,
    moonDisc: disc,
  );
}

SkyAnalysis _analyzeSun(
  imglib.Image image,
  Float32List gray,
  int width,
  int height,
  SunDisc disc,
) {
  final bytes = _byteGrayscale(gray);
  final outer = disc.radiusPixels * 1.15 + 4;
  final outerSq = outer * outer;
  var sum = 0.0;
  var sumSq = 0.0;
  var count = 0;
  var saturated = 0;
  for (var y = 0; y < height; y++) {
    final dy = y - disc.centerY;
    for (var x = 0; x < width; x++) {
      final value = bytes[y * width + x];
      if (value >= 250) saturated++;
      final dx = x - disc.centerX;
      if (dx * dx + dy * dy <= outerSq) continue;
      final level = value.toDouble();
      sum += level;
      sumSq += level * level;
      count++;
    }
  }
  final skyMean = count == 0 ? 0.0 : sum / count;
  final variance = count == 0 ? 0.0 : sumSq / count - skyMean * skyMean;
  final background = skyMean / 255.0;
  final noise = variance > 0 ? math.sqrt(variance) / 255.0 : 0.0;
  final saturatedFraction = bytes.isEmpty ? 0.0 : saturated / bytes.length;
  final preview = Uint8List.fromList(imglib.encodeJpg(image, quality: 92));
  final discPercent = (disc.discAreaFraction * 100).toStringAsFixed(2);

  return SkyAnalysis(
    width: width,
    height: height,
    stars: const [],
    quality: t('日面'),
    background: background,
    noise: noise,
    backgroundIndex: background * 100,
    saturatedFraction: saturatedFraction,
    diagnostics: [
      t('这张照片以日面为主，走的是太阳盘面分析，不做星点检测。'),
      t('日面：圆心 ({0}, {1}) 像素，半径 {2} 像素，占画面 {3}%。', [
        disc.centerX.round(),
        disc.centerY.round(),
        disc.radiusPixels.toStringAsFixed(1),
        discPercent,
      ]),
      t('检出 {0} 处暗斑，合计约占日面 {1}%；暗斑可能是黑子，也可能来自灰尘或处理痕迹。', [
        disc.darkSpotCount,
        (disc.darkSpotAreaFraction * 100).toStringAsFixed(2),
      ]),
      t('拍摄太阳必须使用合格的太阳滤镜；没有滤镜时不要用手机或望远镜直视太阳。'),
    ],
    preview: preview,
    processedPreview: preview,
    fwhm: 0,
    nonStarFraction: 0,
    maskRegions: const [],
    isLikelyStarfield: false,
    starfieldConfidence: 0,
    brightFlatFraction: 0,
    sunDisc: disc,
  );
}

List<MaskRegion> _applyImageExclusions(
  Float32List gray,
  int width,
  int height,
  List<ImageExclusion> exclusions,
) {
  if (exclusions.length > 8) {
    throw FormatException(t('一次最多只能排除 8 个图像区域。'));
  }
  final regions = <MaskRegion>[];
  var totalArea = 0.0;
  for (final exclusion in exclusions) {
    final values = [
      exclusion.x,
      exclusion.y,
      exclusion.width,
      exclusion.height,
    ];
    if (values.any((value) => !value.isFinite) ||
        exclusion.x < 0 ||
        exclusion.y < 0 ||
        exclusion.width <= 0 ||
        exclusion.height <= 0 ||
        exclusion.x + exclusion.width > 1 ||
        exclusion.y + exclusion.height > 1) {
      throw FormatException(t('图像排除区域的坐标无效。'));
    }
    final region = MaskRegion(
      x: exclusion.x * width,
      y: exclusion.y * height,
      width: exclusion.width * width,
      height: exclusion.height * height,
      kind: MaskKind.text,
    );
    if (region.width < 2 ||
        region.height < 2 ||
        region.area > width * height * 0.25) {
      throw FormatException(t('图像排除区域尺寸超出允许范围。'));
    }
    if (regions.any(
      (other) =>
          region.x < other.x + other.width &&
          region.x + region.width > other.x &&
          region.y < other.y + other.height &&
          region.y + region.height > other.y,
    )) {
      throw FormatException(t('图像排除区域不能互相重叠。'));
    }
    totalArea += region.area;
    if (totalArea > width * height * 0.3) {
      throw FormatException(t('建议排除区域总面积过大，已拒绝应用。'));
    }
    _replaceRegionWithBoundaryMedian(gray, width, height, region);
    regions.add(region);
  }
  return regions;
}

void _replaceRegionWithBoundaryMedian(
  Float32List gray,
  int width,
  int height,
  MaskRegion region,
) {
  final x0 = region.x.floor().clamp(0, width);
  final y0 = region.y.floor().clamp(0, height);
  final x1 = (region.x + region.width).ceil().clamp(0, width);
  final y1 = (region.y + region.height).ceil().clamp(0, height);
  final samples = <double>[];
  for (var y = math.max(0, y0 - 3); y < math.min(height, y1 + 3); y++) {
    for (var x = math.max(0, x0 - 3); x < math.min(width, x1 + 3); x++) {
      if (x >= x0 && x < x1 && y >= y0 && y < y1) continue;
      samples.add(gray[y * width + x]);
    }
  }
  if (samples.isEmpty) {
    throw FormatException(t('无法为图像排除区域估计背景。'));
  }
  samples.sort();
  final middle = samples.length ~/ 2;
  final background = samples.length.isOdd
      ? samples[middle]
      : (samples[middle - 1] + samples[middle]) / 2;
  for (var y = y0; y < y1; y++) {
    for (var x = x0; x < x1; x++) {
      gray[y * width + x] = background;
    }
  }
}

void _fillMask(
  Uint8List mask,
  int width,
  int height,
  double x,
  double y,
  double regionWidth,
  double regionHeight,
) {
  final x0 = x.floor().clamp(0, width);
  final y0 = y.floor().clamp(0, height);
  final x1 = (x + regionWidth).ceil().clamp(0, width);
  final y1 = (y + regionHeight).ceil().clamp(0, height);
  for (var py = y0; py < y1; py++) {
    for (var px = x0; px < x1; px++) {
      mask[py * width + px] = 1;
    }
  }
}

/// 在 isolate 里跑分析用的入口，参数和返回值都必须是可跨 isolate 传递的类型。
Future<SkyAnalysis> analyzeImageBytes(
  Uint8List bytes, {
  List<ImageExclusion> exclusions = const [],
  bool detectMoon = true,
  bool detectSun = false,
  StarDetectionProfile profile = StarDetectionProfile.normal,
}) async =>
    SkyAnalysis.analyze(
      bytes,
      exclusions: exclusions,
      detectMoon: detectMoon,
      detectSun: detectSun,
      profile: profile,
    );

// ---------------------------------------------------------------------------
// 解码
// ---------------------------------------------------------------------------

/// 解码普通图片；失败时退回在相机 RAW 容器里找最大的内嵌 JPEG 预览。
imglib.Image? decodeImageOrRawPreview(Uint8List bytes) {
  try {
    final decoded = imglib.decodeImage(bytes);
    if (decoded != null) return decoded;
  } on Exception {
    // 相机 RAW 容器里可能内嵌了可用的 JPEG 预览，下面继续找。
  }

  imglib.Image? largestPreview;
  var start = 0;
  var inspected = 0;
  while (start + 3 < bytes.length && inspected < 32) {
    while (start + 1 < bytes.length &&
        !(bytes[start] == 0xFF && bytes[start + 1] == 0xD8)) {
      start++;
    }
    if (start + 1 >= bytes.length) break;
    final jpegStart = start;
    var end = jpegStart + 2;
    while (end + 1 < bytes.length &&
        !(bytes[end] == 0xFF && bytes[end + 1] == 0xD9)) {
      end++;
    }
    if (end + 1 >= bytes.length) break;
    try {
      final preview = imglib.decodeImage(bytes.sublist(jpegStart, end + 2));
      if (preview != null &&
          (largestPreview == null ||
              preview.width * preview.height >
                  largestPreview.width * largestPreview.height)) {
        largestPreview = preview;
      }
    } on Exception {
      // 继续找下一段完整的 JPEG 缩略图。
    }
    inspected++;
    start = end + 2;
  }
  return largestPreview;
}

imglib.Image _downscale(imglib.Image decoded) {
  const limit = 1200;
  if (decoded.width <= limit && decoded.height <= limit) return decoded;
  return decoded.width >= decoded.height
      ? imglib.copyResize(decoded,
          width: limit, interpolation: imglib.Interpolation.linear)
      : imglib.copyResize(decoded,
          height: limit, interpolation: imglib.Interpolation.linear);
}

/// 亮度用 Rec.709 权重；存成 Float32 省内存，后续计算都在这个缓冲上做。
Float32List _toGrayscale(imglib.Image image) {
  final gray = Float32List(image.width * image.height);
  var index = 0;
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final pixel = image.getPixel(x, y);
      gray[index++] =
          (0.2126 * pixel.r + 0.7152 * pixel.g + 0.0722 * pixel.b) / 255.0;
    }
  }
  return gray;
}

// ---------------------------------------------------------------------------
// 背景与噪声
// ---------------------------------------------------------------------------

/// 分块背景模型。整幅图用一个全局中位数，在城市光污染的渐变天空上会翻车；
/// 按 32×32 分块各估一个中位数，再双线性插值，得到平滑的背景面。
/// 噪声用 MAD 换算标准差，对星点和热噪点都不敏感。
class _BackgroundGrid {
  _BackgroundGrid(Float32List gray, int width, int height) {
    cols = (width / tileSize).ceil();
    rows = (height / tileSize).ceil();
    background = Float32List(cols * rows);
    noise = Float32List(cols * rows);

    final buffer = Float32List(tileSize * tileSize);
    final differences = Float64List(tileSize * tileSize);
    for (var ty = 0; ty < rows; ty++) {
      for (var tx = 0; tx < cols; tx++) {
        final x0 = tx * tileSize;
        final y0 = ty * tileSize;
        final x1 = math.min(width, x0 + tileSize);
        final y1 = math.min(height, y0 + tileSize);
        var count = 0;
        for (var y = y0; y < y1; y++) {
          for (var x = x0; x < x1; x++) {
            buffer[count++] = gray[y * width + x];
          }
        }
        final view = Float32List.sublistView(buffer, 0, count)..sort();
        background[ty * cols + tx] = _medianSorted(view);

        // 噪声用**相邻像素差值的中位数**估，而不是块内像素的 MAD。
        //
        // 差别全在星云上：MAD 量的是块内像素的离散度，于是**平滑的亮度梯度也
        // 被算成噪声**。一块 32×32 压在星云边缘时，块内亮度落差可能有 0.1，折算
        // 出的 σ ≈ 0.02；而平坦夜空里 σ ≈ 0.002。阈值是「背景 + 5σ」，两个数一
        // 乘就是十倍之差——嵌在星云上的星够不到门槛，整片天区里的星连同解算一起
        // 丢。实测：三裂星云那张照片里的星就是这么消失的。
        //
        // 相邻像素之差对平滑梯度几乎免疫：星云在相邻两像素之间的变化远小于噪声
        // 本身，而噪声和星点都贡献差值。除以 √2 是因为两个独立量之差的方差是单
        // 个的两倍。
        var pairs = 0;
        for (var y = y0; y < y1; y++) {
          final row = y * width;
          for (var x = x0; x + 1 < x1; x++) {
            differences[pairs++] = (gray[row + x + 1] - gray[row + x]).abs();
          }
        }
        if (pairs == 0) {
          noise[ty * cols + tx] = 1 / 255;
          continue;
        }
        final differenceView =
            Float64List.sublistView(differences, 0, pairs)..sort();
        noise[ty * cols + tx] = math.max(
          1.4826 * _medianSorted(differenceView) / math.sqrt2,
          1 / 255,
        );
      }
    }

    globalBackground = background[(rows ~/ 2) * cols + cols ~/ 2];
    var sum = 0.0;
    for (final value in noise) {
      sum += value;
    }
    globalNoise = sum / noise.length;
  }

  static const tileSize = 32;

  late final int cols;
  late final int rows;
  late final Float32List background;
  late final Float32List noise;
  late final double globalBackground;
  late final double globalNoise;

  /// 背景面在任意像素上的双线性插值取值。
  double backgroundAt(double x, double y) {
    final gridX = (x / tileSize - 0.5).clamp(0.0, (cols - 1).toDouble());
    final gridY = (y / tileSize - 0.5).clamp(0.0, (rows - 1).toDouble());
    final x0 = gridX.floor();
    final y0 = gridY.floor();
    final x1 = math.min(x0 + 1, cols - 1);
    final y1 = math.min(y0 + 1, rows - 1);
    final fx = gridX - x0;
    final fy = gridY - y0;
    final top =
        background[y0 * cols + x0] * (1 - fx) + background[y0 * cols + x1] * fx;
    final bottom =
        background[y1 * cols + x0] * (1 - fx) + background[y1 * cols + x1] * fx;
    return top * (1 - fy) + bottom * fy;
  }

  double noiseAt(double x, double y) {
    final gridX = (x / tileSize - 0.5).clamp(0.0, (cols - 1).toDouble());
    final gridY = (y / tileSize - 0.5).clamp(0.0, (rows - 1).toDouble());
    return math.max(noise[gridY.round() * cols + gridX.round()], 1 / 255);
  }
}

/// 每个像素的判断阈值 = 局部背景 + kσ 局部噪声。
/// 局部化以后，光污染梯度强的区域不会因为全局阈值过高而漏检暗星。
class _ThresholdMap {
  _ThresholdMap(
    Float32List gray,
    int width,
    int height,
    _BackgroundGrid grid,
    StarDetectionProfile profile,
  ) {
    final primarySigma =
        profile == StarDetectionProfile.wide ? 4.2 : 5.0;
    final relaxedSigma =
        profile == StarDetectionProfile.wide ? 2.8 : 3.2;
    primary = Float32List(gray.length);
    relaxed = Float32List(gray.length);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final index = y * width + x;
        final background = grid.backgroundAt(x.toDouble(), y.toDouble());
        final sigma = grid.noiseAt(x.toDouble(), y.toDouble());
        primary[index] =
            math.max(background + primarySigma * sigma, background + 4 / 255);
        relaxed[index] =
            math.max(background + relaxedSigma * sigma, background + 3 / 255);
      }
    }
  }

  late final Float32List primary;
  late final Float32List relaxed;
}

// ---------------------------------------------------------------------------
// 连通域检测与分类
// ---------------------------------------------------------------------------

/// 一个阈值以上连通域的形态与测光统计。
class _Component {
  _Component(this.minX, this.minY);

  int minX;
  int minY;
  // 起始像素就是第一个成员，所以 max 从 0 出发用“取更大值”累计是对的。
  int maxX = 0;
  int maxY = 0;
  double flux = 0;
  double weightedX = 0;
  double weightedY = 0;
  double peakSignal = 0;
  double centroidX = 0;
  double centroidY = 0;
  double varianceX = 0;
  double varianceY = 0;
  double covariance = 0;
  double concentration = 0;
  double minorSigma = 0;
  final List<int> pixels = <int>[];

  int get area => pixels.length;
  int get boxWidth => maxX - minX + 1;
  int get boxHeight => maxY - minY + 1;
  int get boxArea => boxWidth * boxHeight;
  double get fillRatio => boxArea == 0 ? 0 : area / boxArea;
  double get spread => math.max(boxWidth, boxHeight).toDouble();
  double get thinness => math.min(boxWidth, boxHeight).toDouble();

  /// 峰值相对平均信号的比例。真星点有明显核心（>1.4），
  /// 文字笔画和实心色块几乎是常数（≈1）。
  double get peakRatio {
    if (flux <= 0 || area == 0) return 1;
    final mean = flux / area;
    return mean <= 0 ? 1 : peakSignal / mean;
  }

  /// 长短轴比，由亮度加权的二阶矩算出。
  double get axisRatio {
    if (flux <= 0) return 1;
    final vx = varianceX / flux;
    final vy = varianceY / flux;
    final vxy = covariance / flux;
    final halfTrace = (vx + vy) / 2;
    final offset = math.sqrt((vx - vy) * (vx - vy) / 4 + vxy * vxy);
    return math.sqrt(
      math.max(0.0, halfTrace + offset) / math.max(0.05, halfTrace - offset),
    );
  }

  /// 长轴方向（弧度）。
  double get orientation {
    if (flux <= 0) return 0;
    final vx = varianceX / flux;
    final vy = varianceY / flux;
    final vxy = covariance / flux;
    return 0.5 * math.atan2(2 * vxy, vx - vy);
  }
}

/// 从一批像素统计一个组件：通量、重心、峰值、包围盒、二阶矩。
///
/// 只写这一处，因为有两处要用它：[_findComponents] 把一整个连通域交给它，
/// [_splitAtPeaks] 把拆分后的每一份也交给它。两边各写一份迟早会算出不同的数
/// ——而这两边的数会直接比较。
_Component _measurePixels(
  List<int> pixels,
  Float32List gray,
  int width,
  _BackgroundGrid grid,
) {
  final first = pixels.first;
  final component = _Component(first % width, first ~/ width)
    ..maxX = first % width
    ..maxY = first ~/ width;
  for (final index in pixels) {
    final px = index % width;
    final py = index ~/ width;
    final signal = gray[index] - grid.backgroundAt(px.toDouble(), py.toDouble());
    component.pixels.add(index);
    component.flux += signal;
    component.weightedX += signal * px;
    component.weightedY += signal * py;
    if (signal > component.peakSignal) component.peakSignal = signal;
    if (px < component.minX) component.minX = px;
    if (py < component.minY) component.minY = py;
    if (px > component.maxX) component.maxX = px;
    if (py > component.maxY) component.maxY = py;
  }
  if (component.flux > 0) {
    component.centroidX = component.weightedX / component.flux;
    component.centroidY = component.weightedY / component.flux;
  } else {
    component.centroidX = (component.minX + component.maxX) / 2;
    component.centroidY = (component.minY + component.maxY) / 2;
  }
  _computeMoments(component, gray, width, grid);
  return component;
}

/// 在阈值掩膜上做 8 连通标记，同时累计形态统计。
/// 每个像素只归属一个连通域，统计结果不会有跨域污染。
List<_Component> _findComponents(
  Float32List gray,
  int width,
  int height,
  Float32List threshold,
  _BackgroundGrid grid,
) {
  final visited = Uint8List(width * height);
  final components = <_Component>[];
  final stack = <int>[];
  final pixels = <int>[];

  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final start = y * width + x;
      if (visited[start] != 0 || gray[start] < threshold[start]) continue;

      pixels.clear();
      stack.add(start);
      visited[start] = 1;
      while (stack.isNotEmpty) {
        final index = stack.removeLast();
        final px = index % width;
        final py = index ~/ width;
        pixels.add(index);

        for (var dy = -1; dy <= 1; dy++) {
          final ny = py + dy;
          if (ny < 0 || ny >= height) continue;
          for (var dx = -1; dx <= 1; dx++) {
            final nx = px + dx;
            if (nx < 0 || nx >= width) continue;
            final neighbour = ny * width + nx;
            if (visited[neighbour] != 0) continue;
            if (gray[neighbour] < threshold[neighbour]) continue;
            visited[neighbour] = 1;
            stack.add(neighbour);
          }
        }
      }

      final component = _measurePixels(pixels.toList(), gray, width, grid);
      if (component.flux > 0) components.add(component);
    }
  }
  return components;
}

/// 用通量加权的二阶矩算长短轴、方向和 3×3 集中度。
void _computeMoments(
  _Component component,
  Float32List gray,
  int width,
  _BackgroundGrid grid,
) {
  var vx = 0.0;
  var vy = 0.0;
  var vxy = 0.0;
  var central = 0.0;
  for (final index in component.pixels) {
    final x = index % width;
    final y = index ~/ width;
    final signal = gray[index] - grid.backgroundAt(x.toDouble(), y.toDouble());
    if (signal <= 0) continue;
    final dx = x - component.centroidX;
    final dy = y - component.centroidY;
    vx += signal * dx * dx;
    vy += signal * dy * dy;
    vxy += signal * dx * dy;
    if (dx.abs() <= 1 && dy.abs() <= 1) central += signal;
  }
  component.varianceX = vx;
  component.varianceY = vy;
  component.covariance = vxy;
  component.concentration = component.flux <= 0 ? 0 : central / component.flux;

  // 短轴 σ：星点的短轴方向宽度，用来估 FWHM。
  if (component.flux > 0) {
    final mx = vx / component.flux;
    final my = vy / component.flux;
    final mxy = vxy / component.flux;
    final halfTrace = (mx + my) / 2;
    final offset = math.sqrt((mx - my) * (mx - my) / 4 + mxy * mxy);
    component.minorSigma = math.sqrt(math.max(halfTrace - offset, 0.05));
  }
}

/// 两个峰至少隔多远才算两颗星。
///
/// 按这颗组件的短轴 σ 缩放，而不是写死像素数：换一台机器、换一个焦段，PSF 就
/// 变了，写死的数会在这台机器上拆得太碎、在另一台上又拆不开。取 2.2σ ≈ 0.94
/// 倍 FWHM——比一个 PSF 还近的两个峰，物理上分不出是两颗星还是一个核。
///
/// 下限 3 px 是给噪声留的：σ 估得很小时不该退化成「每个像素一个峰」。
const _splitPeakSigmaFactor = 2.2;
const _splitPeakMinimumSeparation = 3.0;

/// 拆出来的一份至少要占整块通量的这一比例，才算一颗独立的星。
///
/// 亮星旁边的碎片（光晕里 JPEG 振铃造成的假峰）通量只有主星的百分之几，单独
/// 列出来只是往列表里塞噪声。实测真实照片上，这个门槛把亮星周围 5 个这类碎片
/// 挡掉，而两颗真星之间通量差 2 等时较小的那颗仍然留得住。
const _splitPartMinimumFluxShare = 0.08;

/// 「不够圆但有核心」的组件，细过这个宽度就还当它是笔画，不拆。
///
/// 实测：这一档里粘在一起的星点短边 9–19 px，而文字笔画和电缆都 ≤ 6 px。
const _mergeMinimumThickness = 8.0;

/// 把一个「不够圆、但有明确核心」的组件按亮度峰拆成几颗星。
///
/// **为什么非拆不可**：两颗星挨得近时，5σ 阈值以上的光晕会连成一块，这块的轴比
/// 必然超过 2.2，而它的重心落在两颗星**中间**。旧行为是把它当「线状非星空」掩膜
/// 掉，于是两颗星一起消失——实测一张真实照片里 6 颗被削顶的亮星和 31 颗密集处的
/// 星就是这么丢的。只改成「当一颗星收下」也不行：圆心会画在两者之间，位置仍然是
/// 错的。所以要真的把它们分开。
///
/// 拆法是最朴素的就近归属：先找局部极大，去掉同一片平顶里的重复峰，再把每个
/// 像素归给最近的那个峰。只有一处峰时就整块归还——调用方照旧当一颗星处理。
List<_Component> _splitAtPeaks(
  _Component component,
  Float32List gray,
  int width,
  int height,
  _BackgroundGrid grid,
) {
  final peaks = <int>[];
  for (final index in component.pixels) {
    final px = index % width;
    final py = index ~/ width;
    var isPeak = true;
    for (var dy = -1; dy <= 1 && isPeak; dy++) {
      final ny = py + dy;
      if (ny < 0 || ny >= height) continue;
      for (var dx = -1; dx <= 1; dx++) {
        final nx = px + dx;
        if (nx < 0 || nx >= width) continue;
        if (gray[ny * width + nx] > gray[index]) {
          isPeak = false;
          break;
        }
      }
    }
    if (isPeak) peaks.add(index);
  }
  if (peaks.isEmpty) return const [];

  // 按亮度从高到低留峰，彼此太近的丢掉：饱和的核心是一片平顶，不去重会把
  // 一颗星拆成几十份。间距按这颗组件的 PSF 缩放，见 [_splitPeakSigmaFactor]。
  peaks.sort((a, b) => gray[b].compareTo(gray[a]));
  final separation = math.max(
    _splitPeakMinimumSeparation,
    _splitPeakSigmaFactor * component.minorSigma,
  );
  final kept = <int>[];
  for (final peak in peaks) {
    final px = peak % width;
    final py = peak ~/ width;
    var tooClose = false;
    for (final other in kept) {
      final dx = (px - other % width).toDouble();
      final dy = (py - other ~/ width).toDouble();
      if (math.sqrt(dx * dx + dy * dy) < separation) {
        tooClose = true;
        break;
      }
    }
    if (!tooClose) kept.add(peak);
  }
  if (kept.length <= 1) return [component];

  final buckets = <List<int>>[for (final _ in kept) <int>[]];
  for (final index in component.pixels) {
    final px = index % width;
    final py = index ~/ width;
    var best = 0;
    var bestDistance = double.infinity;
    for (var i = 0; i < kept.length; i++) {
      final dx = (px - kept[i] % width).toDouble();
      final dy = (py - kept[i] ~/ width).toDouble();
      final distance = dx * dx + dy * dy;
      if (distance < bestDistance) {
        bestDistance = distance;
        best = i;
      }
    }
    buckets[best].add(index);
  }

  final parts = <_Component>[];
  for (final bucket in buckets) {
    if (bucket.length < 3) continue;
    parts.add(_measurePixels(bucket, gray, width, grid));
  }
  // 拆不出两块以上就别拆：碎片不够成星，整块交回去让调用方按老规矩处理。
  if (parts.length < 2) return [component];
  // 只留占整块通量足够大的一份：亮星光晕里的振铃峰通量极小，列出来只是噪声。
  var total = 0.0;
  for (final part in parts) {
    total += part.flux;
  }
  final significant = [
    for (final part in parts)
      if (total <= 0 || part.flux >= total * _splitPartMinimumFluxShare) part,
  ];
  return significant.length >= 2 ? significant : [component];
}

/// 在一大块「像星云」的连通域里，把嵌在它上面的星找回来。
///
/// **为什么需要这一步**：星云的辉光只要在小尺度上有点结构，就会整片越过阈值、
/// 连成一块面积几千的连通域。压在它上面的星于是被这块吞掉——阈值、连通域、分类
/// 三步都过了，唯一没过的是「面积太大 ⇒ 当非星空」这一刀。用户那张三裂星云就是
/// 这么丢星的：红框罩住星云核心，核心上明明有亮星，图上一个圈都没有。
///
/// 判据和主检测是同一条，只是换成局部的说法：峰要高出**周围一圈环带的中位数**
/// 至少 5σ（σ 用对梯度免疫的那份估计）。星点是点，立刻高出一截；星云自己的纹理
/// 是平滑的，高不出来。环带取环形的中位数而不是「减去背景面」，是因为背景面在
/// 星云内部本来就被星云自己抬高了，减不出局部反差。
List<_Component> _starsInsideNebula(
  _Component component,
  Float32List gray,
  int width,
  int height,
  _BackgroundGrid grid,
) {
  final peaks = <int>[];
  for (final index in component.pixels) {
    final px = index % width;
    final py = index ~/ width;
    var isPeak = true;
    for (var dy = -1; dy <= 1 && isPeak; dy++) {
      final ny = py + dy;
      if (ny < 0 || ny >= height) continue;
      for (var dx = -1; dx <= 1; dx++) {
        final nx = px + dx;
        if (nx < 0 || nx >= width) continue;
        if (gray[ny * width + nx] > gray[index]) {
          isPeak = false;
          break;
        }
      }
    }
    if (isPeak) peaks.add(index);
  }
  if (peaks.isEmpty) return const [];

  peaks.sort((a, b) => gray[b].compareTo(gray[a]));
  final kept = <int>[];
  for (final peak in peaks) {
    final px = peak % width;
    final py = peak ~/ width;
    var tooClose = false;
    for (final other in kept) {
      final dx = (px - other % width).toDouble();
      final dy = (py - other ~/ width).toDouble();
      if (math.sqrt(dx * dx + dy * dy) < _nebulaPeakSeparation) {
        tooClose = true;
        break;
      }
    }
    if (tooClose) continue;

    // 环带中位数当局部天空：星云被算进去是应该的，要的正是「这颗高出它周围多少」。
    final samples = <double>[];
    for (var y = py - _nebulaPeakOuterRadius; y <= py + _nebulaPeakOuterRadius; y++) {
      if (y < 0 || y >= height) continue;
      for (var x = px - _nebulaPeakOuterRadius; x <= px + _nebulaPeakOuterRadius; x++) {
        if (x < 0 || x >= width) continue;
        final dx = x - px;
        final dy = y - py;
        final squared = dx * dx + dy * dy;
        if (squared < _nebulaPeakInnerRadius * _nebulaPeakInnerRadius) continue;
        if (squared > _nebulaPeakOuterRadius * _nebulaPeakOuterRadius) continue;
        samples.add(gray[y * width + x]);
      }
    }
    if (samples.isEmpty) continue;
    samples.sort();
    final sky = _medianSorted(samples);
    final sigma = math.max(
      grid.noiseAt(px.toDouble(), py.toDouble()),
      1 / 255,
    );
    if (gray[peak] - sky < _nebulaPeakSigma * sigma) continue;
    // 光「比周围高」还不够，还得**像一颗点源**：从峰往八个方向走出去，信号都要
    // 落下来。这条是拿真实照片和合成图量出来的——平顶上的每个像素都「比周围
    // 高」，只判高低的话，一个半径 12 像素的亮斑里会凭空生出十颗星，表格的横线
    // 也会变成一串星。
    //
    // 落幅取「4σ 和自身反差 25% 里较大的那个」。只看 σ 是不够的：合成图里噪声
    // 接近零时 4σ 只有两三个灰度级，一条印刷线沿线抖两下就算「落下来了」，于是
    // 表格又被认成一串星。星点是真的掉，掉的不止几个灰度级。
    final fall = math.max(
      _nebulaFalloffSigma * sigma,
      _nebulaFalloffFraction * (gray[peak] - sky),
    );
    if (!_fallsOffInEveryDirection(
      gray,
      width,
      height,
      px,
      py,
      gray[peak] - fall,
    )) {
      continue;
    }
    kept.add(peak);
  }
  if (kept.isEmpty) return const [];

  // 就近归属：每颗星只收自己周围那一小片像素，星云剩下的部分仍按非星空处理。
  final parts = <_Component>[];
  for (final peak in kept) {
    final px = peak % width;
    final py = peak ~/ width;
    final cluster = <int>[
      for (final index in component.pixels)
        if (_withinCluster(index % width - px, index ~/ width - py)) index,
    ];
    if (cluster.length < 3) continue;
    parts.add(_measurePixels(cluster, gray, width, grid));
  }
  return parts;
}

bool _withinCluster(int dx, int dy) =>
    dx * dx + dy * dy <=
    (_nebulaPeakClusterRadius * _nebulaPeakClusterRadius).round();

/// 从某个像素往八个方向走出去，信号是不是都落下来了。
///
/// 这是「点源」和「一片东西」的分界：星的亮度朝四面八方都在掉；星云的平坦区域、
/// 表格的横线竖线、大亮斑的内部，总有方向走上去**不降反平**——那些方向正是它
/// 「不是点」的证据。
///
/// 八个方向里允许一个不掉（[_nebulaFalloffDirections] 取 7）：一颗星旁边紧挨着
/// 另一颗星时，朝它那个方向本来就不会掉下来。
bool _fallsOffInEveryDirection(
  Float32List gray,
  int width,
  int height,
  int px,
  int py,
  double level,
) {
  const directions = <(int, int)>[
    (-1, -1), (0, -1), (1, -1),
    (-1, 0), (1, 0),
    (-1, 1), (0, 1), (1, 1),
  ];
  var dropped = 0;
  for (final (dx, dy) in directions) {
    var fell = true;
    for (var step = 1; step <= _nebulaFalloffRadius; step++) {
      final x = px + dx * step;
      final y = py + dy * step;
      // 走出画面当作「掉了」：贴着边角的星不该因为这个理由被丢掉。
      if (x < 0 || y < 0 || x >= width || y >= height) break;
      if (gray[y * width + x] <= level) break;
      if (step == _nebulaFalloffRadius) fell = false;
    }
    if (fell) dropped++;
  }
  return dropped >= _nebulaFalloffDirections;
}

/// 星云里找星用的几个尺度。
///
/// 这里拿不到「这颗星多大」（FWHM 要等分类完才估得出来），所以用固定的像素尺度。
/// 星点的核心就是几个像素宽，比这更近的两个峰无论如何分辨不开；环带取 3–6 px，
/// 正好把星点排除在外、只量它周围的星云。
const _nebulaPeakSeparation = 4.0;
const _nebulaPeakInnerRadius = 3;
const _nebulaPeakOuterRadius = 6;
const _nebulaPeakClusterRadius = 3.0;
const _nebulaPeakSigma = 5.0;

/// 「像点源」那一条的尺度：往外走几步、要掉多少、几个方向算数。
///
/// 走得够远（5 px 超过一个 PSF），才穿得过饱和星那一片削平的核心。掉幅取
/// 「4σ 和自身反差的 [_nebulaFalloffFraction] 里较大的那个」：σ 那条管噪声，
/// 反差那条管「这一下到底算不算真的掉下来」——合成图噪声接近零时前者会失效。
const _nebulaFalloffRadius = 5;
const _nebulaFalloffSigma = 4.0;
const _nebulaFalloffFraction = 0.25;
const _nebulaFalloffDirections = 7;

class _ClassifiedField {
  _ClassifiedField(this.stars, this.trails, this.regions, this.solverExtras);

  final List<_Component> stars;
  final List<_Component> trails;
  final List<MaskRegion> regions;

  /// 展示上算拉线候选、但允许进入解算的点源，见 [_classify] 里的说明。
  final List<_Component> solverExtras;
}

/// 允许进入解算候选的最大轴比。
///
/// 比 [DetectedStar.isElongated] 的 2.2 宽：2.2 到 3.5 这一段里既有真的卫星
/// 轨迹，也有被拖尾、被薄云压扁、或者赤道仪轻微抖动的恒星。前者对解算无害
/// （质心落在没有目录星的地方，内点验证自然把它排除），后者却是实打实的
/// 参考星——窄视场里少一颗就可能直接解不出来。再长的就不是「略拉长」了，
/// 质心离开星的位置太远，放进来只会污染匹配。
const _solverMaxAxisRatio = 3.5;

/// 进入解算候选的最小短边像素数。
///
/// 卫星轨迹和衍射星芒都是一像素宽的细线，质心沿线的位置由阈值噪声决定，
/// 精度只有几个像素，拿来当三角形顶点只会污染匹配。真星的短边至少两三
/// 个像素，这一条把它们分开。
const _solverMinThinness = 2.0;

/// 形态分类：紧凑点源 → 星点；细长均匀 → 拉线候选；其余 → 非星空区域。
///
/// 只做形态判断，不做测光——测光要等整帧的点扩散函数估出来之后统一做，
/// 见 [_measureAperture]。
///
/// 分类结果里有**两套**判据，不能合成一套：
///
/// * 展示用（stars / trails / regions）——宁缺毋滥，画在图上、列进表里的
///   东西用户要逐条看，误报会直接毁掉体验；
/// * 解算用（stars + solverExtras）——宁滥勿缺，多一个假点源只是多一个对不
///   上的候选，少一颗真星却可能让整张图解不出来。
///
/// 略拉长但有明确核心的亮源正好落在这两套判据的缝里：它形态上是拖线，本质
/// 上多半是一颗恒星。所以它**同时**进 trails（展示上照旧当拉线候选，用户
/// 能看、能剔）和 solverExtras（解算时当点源用）。
/// 还有第三种情况，比上面那种更常见：**几颗星在阈值处连成了一块**。这块既不是
/// 圆点（轴比过线）也不是细线（粗得多），旧代码把它当非星空掩膜掉，于是两颗
/// 星一起消失。它必须被**拆开**，见 [_splitAtPeaks]。
_ClassifiedField _classify(
  List<_Component> components,
  Float32List gray,
  int width,
  int height,
  _BackgroundGrid grid,
) {
  final stars = <_Component>[];
  final trails = <_Component>[];
  final regions = <MaskRegion>[];
  final solverExtras = <_Component>[];

  for (final component in components) {
    if (component.area < 3 || component.flux <= 0) continue;

    // 尺度远超星点：月亮、路灯、被照亮的建筑，以及表格、栏杆这类
    // 横跨大半个画面的长结构。
    //
    // 但**星云也落在这里**（辉光在小尺度上有结构，就会整片越过阈值连成一大块），
    // 而压在星云上的星会被这块一起吞掉。所以先试着把里面嵌着的星捞出来，再按非
    // 星空处理剩下的部分——捞不捞得着都不影响这一块自己的归类。
    if (component.area > 400 || component.spread > 64) {
      stars.addAll(_starsInsideNebula(component, gray, width, height, grid));
      regions.add(_regionOf(component, _kindOf(component)));
      continue;
    }

    // 星点要有明确的核心，或者足够紧凑。
    //
    // 判「有没有核心」比判「面积够不够小」可靠得多：同一颗星亮一倍，过阈
    // 面积就大一圈，卡面积的写法会让一颗星随着曝光不同、时有时无地被划成
    // 非星空；而峰值和均值的比例几乎不随曝光变。反过来，印刷文字的笔画和
    // 实心色块通体一个亮度，峰值和均值几乎相等，正好落在另一头。
    //
    // 硬边的小亮块（手机样张里不少星点就是这样，没有高斯尾巴）峰值和均值
    // 一样，但中心集中度很高，靠 [concentration] 兜住；真正均匀铺开的色块
    // 两个条件都不满足。
    final hasCore = component.peakRatio >= 1.35;
    final compact = component.concentration >= 0.30;

    if (component.axisRatio < 2.2 && (hasCore || compact)) {
      stars.add(component);
      continue;
    }

    // 细长又均匀的是拖线（卫星、飞机、赤道仪抖动）。填充率低或者太粗的
    // 细长结构不是拖线，是表格边框、电缆、栏杆这一类。
    if (component.axisRatio >= 2.2 &&
        component.fillRatio >= 0.5 &&
        component.thinness <= 6) {
      trails.add(component);
      // 有核心、或者中心够集中的「拉线」多半是被拖尾的恒星：真轨迹亮度沿线
      // 均匀，两个条件都够不着（见 [_Component.peakRatio] 与
      // [_Component.concentration]）。判据故意比展示那边松——这里不需要
      // 确认它是恒星，只要「不像卫星轨迹」就够了，剩下的交给内点验证。
      if ((hasCore || compact) &&
          component.axisRatio <= _solverMaxAxisRatio &&
          component.thinness >= _solverMinThinness) {
        solverExtras.add(component);
      }
      continue;
    }

    // 不够圆、但有明确核心、而且不是细笔画：这是几颗星在阈值处粘成的一块。
    //
    // 既不拆也不收（旧行为）是把它们一起当非星空掩膜掉，两颗星一起消失；只收不拆
    // 则是把圆圈画在它们中间，位置仍然是错的。所以先拆，拆不动再按老规矩处理。
    // 细笔画（文字、电缆）不拆：它们的短边只有几个像素，拆出来的碎片不成星。
    if (hasCore && component.thinness >= _mergeMinimumThickness) {
      final parts = _splitAtPeaks(component, gray, width, height, grid);
      final usable = [
        for (final part in parts)
          if (part.area >= 3 &&
              part.axisRatio < 2.2 &&
              (part.peakRatio >= 1.35 || part.concentration >= 0.30))
            part,
      ];
      if (usable.length >= 2) {
        stars.addAll(usable);
        continue;
      }
    }

    regions.add(_regionOf(component, _kindOf(component)));
  }
  return _ClassifiedField(stars, trails, regions, solverExtras);
}

/// 给一块非星空区域定个说得通的类型，UI 上据此换提示措辞。
MaskKind _kindOf(_Component component) {
  // 细长的，或者填得很稀的（表格网格、大号文字笔画）：是线状结构。
  if (component.axisRatio >= 2.2 && component.thinness <= 6) return MaskKind.line;
  if (component.fillRatio < 0.25) return MaskKind.line;
  // 成片的实心亮块：月亮、路灯、纯色高亮框。
  if (component.area > 60) return MaskKind.blob;
  return MaskKind.text;
}

MaskRegion _regionOf(_Component component, MaskKind kind) => MaskRegion(
      x: component.minX.toDouble(),
      y: component.minY.toDouble(),
      width: component.boxWidth.toDouble(),
      height: component.boxHeight.toDouble(),
      kind: kind,
    );

/// 圆孔径测光的产物。
/// 假定的传感器增益（每光子对应多少灰度）。
///
/// 灰度是 0–1 的浮点，但来源是 8 位量化，所以 1/255 就是它的量化步长。
/// 用这个数把「灰度」换算成「相对光子数」，天体本身的光子噪声才有量纲
/// 可算。绝对测光需要用相机的实际增益重新标定，文档里也是这么写的。
const _assumedGain = 255.0;

class _Aperture {
  const _Aperture(this.flux, this.variance, this.radius);

  /// 扣掉天空之后的孔内总通量（相对单位）。
  final double flux;

  /// 通量的一倍方差，翻成星等误差就是 1.0857·√variance / flux。
  final double variance;

  final double radius;
}

/// 对一颗星做圆孔径测光。
///
/// **为什么不直接用阈值连通域的通量**：阈值是绝对的（局部背景 + kσ），
/// 由整帧的短轴 σ 给出一个统一的孔径半径。
///
/// 取中位数而不是平均值：视场里总混着几块没被掩膜吃掉的碎块，平均值会被
/// 它们拽偏，中位数不会。σ 太小或太大的一律不采信——那是噪声碎块和糊成
/// 一片的星团，不是这个视场的 PSF。
double _apertureRadiusOf(List<_Component> components) {
  final sigmas = <double>[];
  for (final component in components) {
    final sigma = component.minorSigma;
    if (sigma > 0.5 && sigma < 8.0) sigmas.add(sigma);
  }
  if (sigmas.isEmpty) return 0;
  sigmas.sort();
  final middle = sigmas.length ~/ 2;
  final sigma = sigmas.length.isOdd
      ? sigmas[middle]
      : (sigmas[middle - 1] + sigmas[middle]) / 2;
  return (1.5 * 2.355 * sigma).clamp(2.5, 18.0);
}

/// 星越亮，过阈的连通域就越大。十倍的亮度差会被量成十几倍的通量差，而且
/// 放大倍数还跟着背景亮度和局部噪声漂移。星等都是相对量，这种系统性偏差
/// 会原样变成错误的星等差——比随机误差糟糕得多，因为它不会因为多拍几张
/// 就抵消掉。
///
/// 所以另开一圈固定角半径的圆孔径：孔外再套一圈环带，只取环带像素的
/// 中位数当天空值，孔内的像素才计入通量。孔径半径由整帧的 FWHM 决定
/// （见 [_apertureRadiusOf]），取 1.5 倍 FWHM——对高斯来说这一圈已经收到
/// 99% 以上，再往外开只是白白多收噪声。
///
/// 半径是**整帧统一**的，不是每颗星各算各的。这一点很关键：逐颗星从自己
/// 的过阈连通域反推 σ，亮星的连通域被阈值多切出一圈，推出来的 σ 就偏大，
/// 孔径跟着变大，通量又被系统性地抬高——正好抵消掉改用孔径测光想消除的
/// 那个偏差。同一个视场里所有星的 PSF 是同一个，孔径也就该是同一个。
///
/// 误差预算用标准的三项：天体光子噪声、天空光子噪声按孔径面积缩放、
/// 以及「天空值本身估得不准」带来的那一项。像素值是相对单位不是电子数，
/// 所以这里给出的是相对不确定度，文档里也是这么写的。
_Aperture _measureAperture(
  _Component component,
  _BackgroundGrid grid,
  Float32List gray,
  int width,
  int height,
  double radius,
) {
  final annulusInner = radius + 1.5;
  final annulusOuter = radius + 6.0;
  final cx = component.centroidX;
  final cy = component.centroidY;

  final x0 = math.max(0, (cx - annulusOuter).floor());
  final x1 = math.min(width - 1, (cx + annulusOuter).ceil());
  final y0 = math.max(0, (cy - annulusOuter).floor());
  final y1 = math.min(height - 1, (cy + annulusOuter).ceil());

  final samples = <double>[];
  for (var y = y0; y <= y1; y++) {
    for (var x = x0; x <= x1; x++) {
      final dx = x - cx;
      final dy = y - cy;
      final squared = dx * dx + dy * dy;
      if (squared > annulusOuter * annulusOuter) continue;
      if (squared < annulusInner * annulusInner) continue;
      samples.add(gray[y * width + x]);
    }
  }

  double sky;
  double skyVariance;
  if (samples.isEmpty) {
    // 环带被画面边缘切光了（贴着角的星），退回背景面的局部值。
    sky = grid.backgroundAt(cx, cy);
    skyVariance = grid.noiseAt(cx, cy) * grid.noiseAt(cx, cy);
  } else {
    samples.sort();
    sky = _medianSorted(samples);
    var sum = 0.0;
    for (final value in samples) {
      sum += (value - sky) * (value - sky);
    }
    skyVariance = samples.length > 1 ? sum / (samples.length - 1) : 0;
  }

  var flux = 0.0;
  var objectPhotons = 0.0;
  var area = 0;
  final squaredRadius = radius * radius;
  for (var y = y0; y <= y1; y++) {
    for (var x = x0; x <= x1; x++) {
      final dx = x - cx;
      final dy = y - cy;
      if (dx * dx + dy * dy > squaredRadius) continue;
      final value = gray[y * width + x];
      flux += value - sky;
      objectPhotons += math.max(value - sky, 0);
      area++;
    }
  }
  if (area == 0) return _Aperture(0, 0, radius);

  // 误差预算三项，单位统一在灰度平方上：
  //   1. 天体自身的光子噪声——灰度来源是 8 位量化，除以「每光子多少灰度」
  //      就得到光子数；JPEG/PNG 的 8 位量化让这个换算在量级上是站得住的。
  //   2. 天空光子噪声，按孔径面积缩放。
  //   3. 天空值本身估得不准带来的那一项，随孔径面积和环带样本数变化。
  // 这里给出的是相对不确定度；要做绝对测光得用传感器的实际增益重新标定。
  final skySamples = math.max(samples.length, 1);
  final variance = objectPhotons / _assumedGain +
      area * skyVariance * (1 + area / skySamples);
  return _Aperture(flux, variance, radius);
}

DetectedStar _toStar(_Component component, _BackgroundGrid grid, {_Aperture? aperture}) {
  final flux = aperture?.flux ?? component.flux;
  final magnitude = flux <= 0 ? 30.0 : -2.5 * math.log(flux) / math.ln10;
  final sigma = grid.noiseAt(component.centroidX, component.centroidY);

  // 信噪比按「通量 / 通量的一倍标准差」估。走圆孔径时用孔径自己的误差预算，
  // 没有孔径（拉线）时退回「局部噪声 × 根号面积」。
  final fluxError = aperture != null
      ? math.sqrt(math.max(aperture.variance, 0.0))
      : math.sqrt(math.max(component.flux, 0.0) + component.area * sigma * sigma);
  final snr = fluxError <= 0 ? 0.0 : flux / fluxError;

  final axisRatio = component.axisRatio;
  final shapePenalty = math.sqrt(math.min(1.0, 2 / math.max(axisRatio, 1.0)));
  final concentrated = component.concentration.clamp(0.0, 1.0);
  final confidence =
      ((snr / (snr + 6)) * (0.4 + 0.6 * concentrated) * shapePenalty)
          .clamp(0.0, 1.0)
          .toDouble();

  return DetectedStar(
    component.centroidX,
    component.centroidY,
    flux,
    magnitude,
    confidence,
    axisRatio,
    fwhm: 2.355 * component.minorSigma,
    fluxError: fluxError,
    orientation: component.orientation,
  );
}

/// 一行文字最少要有几个笔画才值得动手。
const _textRowMinimum = 5;

/// 同一行文字的竖直中心最多能差多少像素。真实的一行字基线对齐，
/// 字形的重心也就差几个像素；差得更多的对象不该算作同一行。
const _textRowTolerance = 6.0;

/// 同一行相邻笔画之间允许的最大水平间隔。整行字里最宽的通常是词间距，
/// 再大就该断开成两串了。
const _textStrokeGap = 24.0;

/// 文字与图标的抑制。
///
/// 单个笔画和一颗星几乎没法区分：都小、都亮、都圆头圆脑，形态分类器在
/// 这里使不上劲。文字的特征不在单笔画上，而在**排列**上——同一行字的
/// 笔画高度接近、通量接近、沿基线排开。真实星空是随机分布的，不会出现
/// 这种秩序。
///
/// 所以按「行」判：先把对象按竖直中心归行，再在行内按 x 找出间距连续的
/// 一段，一段够长、而且通量足够均匀，就整段判为文字。
///
/// 之所以连拉线候选项一起过滤：一根一像素宽、十几像素高的笔画，形态上
/// 和卫星拖线是同一类，只看单体会被报成拖线。但卫星一次只来一条，不会
/// 在一条水平线上排成整齐的一串。
Set<DetectedStar> _suppressTextRows(List<DetectedStar> detections) {
  final suppressed = <DetectedStar>{};
  if (detections.length < _textRowMinimum) return suppressed;

  final ordered = [...detections]..sort((a, b) => a.y.compareTo(b.y));
  final rows = <List<DetectedStar>>[];
  for (final star in ordered) {
    if (rows.isNotEmpty &&
        (star.y - rows.last.first.y).abs() <= _textRowTolerance) {
      rows.last.add(star);
    } else {
      rows.add(<DetectedStar>[star]);
    }
  }

  for (final row in rows) {
    if (row.length < _textRowMinimum) continue;
    row.sort((a, b) => a.x.compareTo(b.x));
    var start = 0;
    for (var i = 1; i <= row.length; i++) {
      if (i < row.length && row[i].x - row[i - 1].x <= _textStrokeGap) continue;
      final run = row.sublist(start, i);
      start = i;
      if (run.length < _textRowMinimum) continue;
      // 跨度太短说明只是碰巧在竖直方向挤到一起，不是一行字。
      if (run.last.x - run.first.x < _textRowMinimum * 4) continue;
      if (!_looksLikeUniformInk(run)) continue;
      suppressed.addAll(run);
    }
  }
  return suppressed;
}

/// 同一行字用的是一支笔，笔画通量几乎一样。
///
/// 恒星亮度按幂律分布，即使碰巧排成一行，通量的相对离散度也远大于这个
/// 阈值——这一条是「整行字」和「一行亮星」之间最可靠的分界。
bool _looksLikeUniformInk(List<DetectedStar> run) {
  var mean = 0.0;
  for (final star in run) {
    mean += star.flux;
  }
  mean /= run.length;
  if (mean <= 0) return false;
  var variance = 0.0;
  for (final star in run) {
    variance += (star.flux - mean) * (star.flux - mean);
  }
  return math.sqrt(variance / run.length) / mean < 0.22;
}

/// 近乎平坦的像素占比：截图、纯色块会非常高，真实夜空因为噪声不会。
/// 明亮的平坦区域占多大比例。
///
/// 大片的平坦区域是截图和文档的典型特征，但这条判据对天文照片要格外小心：
/// **堆栈、降噪之后的星空照片同样平坦**——天空背景被压成近乎纯色，八像素
/// 见方的窗口里灰度起伏还不到一个量化步长。只看平坦比例的话，越是认真
/// 处理过的照片越容易被判成「不是星空」，正好把最用心拍的那批用户挡在
/// 门外。
///
/// 所以只把**明亮的**平坦区域算进来：文档的白纸、界面的浅色面板是亮的，
/// 夜空是暗的。暗色界面截图也拦得住——它们几乎没有紧凑点源，还有成片的
/// 文字被掩膜，那两项就足够把它压下去了。
double _brightFlatFraction(Float32List gray, int width, int height) {
  const tile = 8;
  // 比这亮的平坦块才算「白纸」；夜空即使在明亮的城市里也远低于此。
  const brightLevel = 0.35;
  var flat = 0;
  var total = 0;
  for (var ty = 0; ty < height; ty += tile) {
    for (var tx = 0; tx < width; tx += tile) {
      final x1 = math.min(width, tx + tile);
      final y1 = math.min(height, ty + tile);
      var min = double.infinity;
      var max = -double.infinity;
      var sum = 0.0;
      var count = 0;
      for (var y = ty; y < y1; y++) {
        for (var x = tx; x < x1; x++) {
          final value = gray[y * width + x];
          if (value < min) min = value;
          if (value > max) max = value;
          sum += value;
          count++;
        }
      }
      total++;
      if (max - min < 1.5 / 255 && count > 0 && sum / count > brightLevel) {
        flat++;
      }
    }
  }
  return total == 0 ? 0 : flat / total;
}

class _StarfieldVerdict {
  const _StarfieldVerdict(this.isStarfield, this.confidence);

  final bool isStarfield;
  final double confidence;
}

/// 综合判断“这到底是不是一张星空照片”。
_StarfieldVerdict _judgeStarfield({
  required List<DetectedStar> stars,
  required List<MaskRegion> maskRegions,
  required double brightFlatFraction,
  required int width,
  required int height,
}) {
  final pixels = width * height;
  final mask = Uint8List(pixels);
  for (final region in maskRegions) {
    _fillMask(mask, width, height, region.x, region.y, region.width, region.height);
  }
  var maskedArea = 0;
  for (final value in mask) {
    if (value != 0) maskedArea++;
  }
  final maskedFraction = pixels == 0 ? 0.0 : maskedArea / pixels;
  final compact = stars.where((star) => !star.isElongated).length;

  var score = 0.0;
  // 星空照片最硬的指标：紧凑点源数量。
  if (compact >= 25) {
    score += 0.45;
  } else if (compact >= 8) {
    score += 0.3;
  } else if (compact >= 3) {
    score += 0.12;
  }
  // 密集文字/表格占比高 → 强烈倾向“不是星空”。
  if (maskedFraction < 0.05) {
    score += 0.25;
  } else if (maskedFraction < 0.2) {
    score += 0.1;
  } else {
    score -= 0.25;
  }
  // 大片**明亮**的平坦区域是截图/文档的典型特征（夜空也会平坦，但它是暗的）。
  if (brightFlatFraction < 0.15) {
    score += 0.25;
  } else if (brightFlatFraction > 0.5) {
    score -= 0.35;
  }
  final clamped = score.clamp(0.0, 1.0).toDouble();
  return _StarfieldVerdict(clamped >= 0.45, clamped);
}

/// 用较亮紧凑星点的短轴散布估计点扩散函数半高全宽。
double _estimateFwhm(List<DetectedStar> stars) {
  final compact = stars.where((star) => !star.isElongated).toList()
    ..sort((a, b) => a.instrumentalMagnitude.compareTo(b.instrumentalMagnitude));
  if (compact.isEmpty) return 0;
  final values = compact
      .take(20)
      .map((star) => star.fwhm)
      .where((value) => value > 0.2 && value < 40)
      .toList()
    ..sort();
  if (values.isEmpty) return 0;
  final middle = values.length ~/ 2;
  return values.length.isOdd
      ? values[middle]
      : (values[middle - 1] + values[middle]) / 2;
}

List<String> _buildDiagnostics({
  required List<DetectedStar> stars,
  required List<MaskRegion> regions,
  required _StarfieldVerdict starfield,
  required double background,
  required double noise,
  required double saturatedFraction,
  required double fwhm,
  required bool usedRelaxedThreshold,
  required int suppressedText,
}) {
  final diagnostics = <String>[];
  final compact = stars.where((star) => !star.isElongated).toList();
  final trails = stars.where((star) => star.isElongated).toList();

  if (!starfield.isStarfield) {
    diagnostics.add(
      t('这张图看起来不是纯粹的星空照片：检出的密集亮点更像文字、表格或界面元素。请换一张以星场为主的照片，或先在相册里裁掉文字区域。'),
    );
  }
  if (usedRelaxedThreshold) {
    diagnostics.add(t('标准阈值检出的点源偏少，已自动降低阈值重试；弱点源中可能混入噪声。'));
  }
  final textRegions =
      regions.where((region) => region.kind == MaskKind.text).length;
  final blobRegions =
      regions.where((region) => region.kind == MaskKind.blob).length;
  final lineRegions =
      regions.where((region) => region.kind == MaskKind.line).length;
  if (textRegions > 0) {
    diagnostics.add(tn('已屏蔽 {0} 处疑似文字/表格笔画，这些位置不参与星点统计。', textRegions, [textRegions]));
  }
  if (blobRegions > 0) {
    diagnostics.add(tn('已屏蔽 {0} 处大面积亮斑（可能是月亮、路灯或建筑），不做星点处理。', blobRegions, [blobRegions]));
  }
  if (lineRegions > 0) {
    diagnostics.add(tn('已屏蔽 {0} 处直线结构（可能是表格边框、电缆或栏杆）。', lineRegions, [lineRegions]));
  }
  if (suppressedText > 0) {
    diagnostics.add(
      t('已忽略 {0} 个疑似文字或图标的亮点：它们大小相近、亮度一致、还排成整齐的一行，是印刷品的特征，不是星空。', [suppressedText]),
    );
  }
  if (trails.isNotEmpty) {
    diagnostics.add(
      t('检出 {0} 个拉长的亮点候选，可能是拖线、失焦或飞机/卫星轨迹；单张照片不能据此确认，请在下方逐个判断是否保留。', [trails.length]),
    );
  }
  if (compact.length < 8) {
    diagnostics.add(t('检出的紧凑亮点较少；可能曝光不足、虚焦或云雾遮挡。'));
  }
  if (noise > 0.06) diagnostics.add(t('背景噪声偏高，弱星检测和相对亮度测量可靠性下降。'));
  if (saturatedFraction > 0.01) diagnostics.add(t('部分像素接近饱和，亮星核心的亮度信息可能丢失。'));
  if (background > 0.38) {
    diagnostics.add(t('图像背景偏亮；受曝光影响，不能直接换算成 SQM 或 Bortle 等级。'));
  }
  if (fwhm > 8 && compact.isNotEmpty) {
    diagnostics.add(t('星点弥散较大（约 {0} px），可能是轻微失焦或手抖。', [fwhm.toStringAsFixed(1)]));
  }
  if (compact.isNotEmpty &&
      compact.take(30).map((star) => star.confidence).reduce((a, b) => a + b) /
              math.min(30, compact.length) <
          0.38) {
    diagnostics.add(t('点源形态不够集中，可能存在抖动、虚焦或强降噪；测光置信度偏低。'));
  }
  if (compact.length < 8) {
    diagnostics.add(t('拍摄建议：固定设备并重新手动对焦；避开云雾和灯光直射后再试。'));
  }
  if (noise > 0.06) {
    diagnostics.add(t('拍摄建议：优先拍摄多张较短曝光用于后续叠加，避免只提高 ISO。'));
  }
  if (saturatedFraction > 0.01) {
    diagnostics.add(t('拍摄建议：降低曝光或增益，避免亮星核心过曝。'));
  }
  if (background > 0.38) {
    diagnostics.add(t('拍摄建议：若现场天空也明显发亮，可换到更暗地点并缩短单张曝光。'));
  }
  if (diagnostics.isEmpty) {
    diagnostics.add(t('检出紧凑亮点；准确星名仍需可靠的天球坐标解算。'));
  }
  return diagnostics;
}

String _qualityLabel({
  required List<DetectedStar> stars,
  required double noise,
  required double saturatedFraction,
  required double starfieldConfidence,
}) {
  final compact = stars.where((star) => !star.isElongated).length;
  if (starfieldConfidence < 0.45) return t('较弱');
  if (compact >= 25 && noise < 0.04 && saturatedFraction < 0.01) return t('较好');
  if (compact >= 8) return t('一般');
  return t('较弱');
}

/// 处理图：扣背景 → 反双曲正弦拉伸 → 抹掉非星空区域，只留下星场。
Uint8List _renderProcessedPreview(
  Float32List gray,
  int width,
  int height,
  _BackgroundGrid grid,
  Uint8List mask,
) {
  final output = imglib.Image(width: width, height: height);
  // 拉伸参数：asinh 压缩动态范围，让暗星和亮星的细节能同时看见。
  const gain = 3.0;
  const reference = 40.0;
  final normaliser = math.log(
    gain * reference + math.sqrt(gain * reference * gain * reference + 1),
  );
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final index = y * width + x;
      if (mask[index] != 0) {
        output.setPixelRgb(x, y, 0, 0, 0);
        continue;
      }
      final background = grid.backgroundAt(x.toDouble(), y.toDouble());
      final sigma = grid.noiseAt(x.toDouble(), y.toDouble());
      final signal = (gray[index] - background) / sigma * gain;
      final stretched =
          math.log(signal + math.sqrt(signal * signal + 1)) / normaliser;
      final level = (stretched.clamp(0.0, 1.0) * 255).round();
      output.setPixelRgb(x, y, level, level, level);
    }
  }
  return Uint8List.fromList(imglib.encodeJpg(output, quality: 88));
}

double _medianSorted(List<double> sorted) {
  if (sorted.isEmpty) return 0;
  final middle = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[middle]
      : (sorted[middle - 1] + sorted[middle]) / 2;
}

double _asDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0;
  return 0;
}
