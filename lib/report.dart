import 'dart:math' as math;

import 'analysis.dart';
import 'models.dart';

/// 报告层：把测量结果翻译成两类东西——给人看的，和给模型看的。
///
/// 两者的口径必须一致，所以放在同一个文件里从同一份数据出发。人看的那份
/// 会丢掉精度、换成能读懂的话；模型那份要保留散布、内点数这类原始数字，
/// 让模型自己判断哪些不值得当真。

// ---------------------------------------------------------------------------
// 给模型看的测量摘要
// ---------------------------------------------------------------------------

/// 交给模型的测量摘要。
///
/// 这是模型唯一能看到的东西——原始照片不上传，模型只拿这份结构化的测量
/// 结果说话。所以字段要写成「测量值 + 它有多可信」，而不是一句结论：模型
/// 拿得到散布、内点数这类信息，才能自己判断哪些数字不值得当真。
Map<String, Object?> buildAgentReport(SkyAnalysis analysis, SolveResult? solve) {
  final record = buildObservationRecord(analysis, solve);
  return {
    'quality': analysis.quality,
    'detected_stars': analysis.compactSources.length,
    'detected_sources': analysis.stars.length,
    'compact_sources': analysis.compactSources.length,
    'elongated_candidates': analysis.streakCandidates.length,
    'rejected_by_user': analysis.stars.where((star) => star.isRejected).length,
    'noise_fraction': analysis.noise,
    'background_visual_index': analysis.backgroundIndex,
    'background_description': record.skyBrightness,
    'psf_fwhm_pixels': analysis.fwhm,
    'non_star_fraction': analysis.nonStarFraction,
    'is_likely_starfield': analysis.isLikelyStarfield,
    'starfield_confidence': analysis.starfieldConfidence,
    'diagnostics': analysis.diagnostics,
    'solved': solve != null,
    // 解算是本机算的还是在线算的，直接关系到结果能不能离线和速率上限。
    'solve_source': switch (solve?.source) {
      SolveSource.local => 'local_offline',
      SolveSource.online => 'astrometry_net',
      null => null,
    },
    'center_ra_deg': solve?.centerRa,
    'center_dec_deg': solve?.centerDec,
    'arcsec_per_pixel': solve?.arcsecPerPixel,
    'field_of_view_deg': solve?.fieldOfViewDegrees,
    'rotation_deg': solve?.rotationDegrees,
    'matched_star_count': solve?.matchedCount,
    // 本地解算能直接给出星座归属；在线解算要等 SIMBAD 回来才知道。
    'constellations': solve?.constellations,
    'catalog_stars': solve?.namedStars
        .map(
          (object) => {
            'name': object.name,
            'catalog_type': object.category,
            'ra_deg': object.ra,
            'dec_deg': object.dec,
            'gaia_g_magnitude': object.magnitude,
            'catalog': object.isLocal ? 'hipparcos_local' : 'gaia_dr3',
          },
        )
        .toList(),
    'deep_sky_objects': solve?.deepSkyObjects
        .map(
          (object) => {
            'name': object.name,
            'catalog_type': object.category,
            'ra_deg': object.ra,
            'dec_deg': object.dec,
          },
        )
        .toList(),
    'catalog_warning': solve?.catalogWarning,
    'magnitude_zero_point': solve?.magnitudeZeroPoint,
    'photometry_scatter_mag': solve?.magnitudeScatter,
    // 星等分布：模型要判断「这张图拍到了什么档次的天体」，光看上最亮那颗
    // 不够，还要知道暗端有没有堆一大片、分布是不是被截断。
    'magnitude_histogram': [
      for (final bin in magnitudeHistogram(analysis, solve))
        {'from': bin.lower, 'to': bin.upper, 'count': bin.count},
    ],
    'brightest_object': record.brightest,
    'advice': record.advice,
    'summary': record.summary,
  };
}

// ---------------------------------------------------------------------------
// 给爱好者看的观星记录
// ---------------------------------------------------------------------------

/// 一张照片的「观星记录」：一屏能读完的关键数字，加一句人话总结。
class ObservationRecord {
  const ObservationRecord({
    required this.summary,
    required this.constellation,
    required this.centerRa,
    required this.centerDec,
    required this.fieldOfView,
    required this.scale,
    required this.matchedStars,
    required this.brightest,
    required this.quality,
    required this.skyBrightness,
    required this.advice,
    required this.magnitudes,
  });

  /// 一段话讲清楚这张照片拍了什么、拍得怎么样。
  final String summary;

  /// 视场中心所在的星座；没解算时为空。
  final String? constellation;

  final String centerRa;
  final String centerDec;
  final String fieldOfView;

  /// 像素比例，人话形式（「28.8″/像素」）。
  final String scale;

  final int matchedStars;

  /// 画面里最亮的天体名（解算出来时带星等）。
  final String? brightest;

  final String quality;

  /// 天空背景的人话描述，而不是一个 0–100 的分数。
  final String skyBrightness;

  final List<String> advice;

  /// 已标定的星等列表，画直方图用。
  final List<double> magnitudes;
}

ObservationRecord buildObservationRecord(
  SkyAnalysis analysis,
  SolveResult? solve,
) {
  final magnitudes = calibratedMagnitudes(analysis, solve);
  return ObservationRecord(
    summary: _summary(analysis, solve, magnitudes),
    constellation:
        solve != null && solve.constellations.isNotEmpty
            ? solve.constellations.first
            : null,
    centerRa: solve == null ? '未解算' : formatRa(solve.centerRa),
    centerDec: solve == null ? '未解算' : formatDec(solve.centerDec),
    fieldOfView:
        solve == null ? '未解算' : formatFieldOfView(solve.fieldOfViewDegrees),
    scale: solve == null
        ? '未解算'
        : '${solve.arcsecPerPixel.toStringAsFixed(1)}″ / 像素',
    matchedStars: solve?.matchedCount ?? 0,
    brightest: _brightest(analysis, solve),
    quality: analysis.quality,
    skyBrightness: describeSkyBrightness(analysis.backgroundIndex),
    advice: buildAdvice(analysis, solve),
    magnitudes: magnitudes,
  );
}

/// 全帧统一标定的星等列表。
///
/// 有星等零点就用标定值——那才是能跟星表对的「真星等」；没有零点时退回
/// 仪器星等，此时**只能比较相对亮度**，绝对数值没有天文含义。低置信度的
/// 点源不参与统计，否则噪声会把暗端的分布撑起来，看着像拍到了一片暗星。
List<double> calibratedMagnitudes(SkyAnalysis analysis, SolveResult? solve) {
  final zeroPoint = solve?.magnitudeZeroPoint;
  return [
    for (final star in analysis.compactSources)
      if (star.confidence >= 0.25)
        star.instrumentalMagnitude + (zeroPoint ?? 0),
  ];
}

/// 一个星等区间。
class MagnitudeBin {
  const MagnitudeBin(this.lower, this.upper, this.count);

  final double lower;
  final double upper;
  final int count;

  String get label => '${lower.toStringAsFixed(1)}–${upper.toStringAsFixed(1)}';
}

/// 星等分布直方图。
///
/// 分箱宽度固定 0.5 等，而不是「把范围等分」：星等每差 5 等，亮度差 100 倍，
/// 同一个视场里的动态范围基本是固定的。按范围等分的话，一张只有 3 颗星的
/// 图也会被切成 10 个箱子、每个箱子里稀稀拉拉一根柱子，看不出任何分布形状。
List<MagnitudeBin> magnitudeHistogram(
  SkyAnalysis analysis,
  SolveResult? solve, {
  double binWidth = 0.5,
}) {
  final magnitudes = calibratedMagnitudes(analysis, solve);
  if (magnitudes.isEmpty) return const [];

  var lowest = magnitudes.first;
  var highest = magnitudes.first;
  for (final magnitude in magnitudes) {
    if (magnitude < lowest) lowest = magnitude;
    if (magnitude > highest) highest = magnitude;
  }

  final start = (lowest / binWidth).floor() * binWidth;
  final count = ((highest - start) / binWidth).floor() + 1;
  final bins = List.filled(count, 0);
  for (final magnitude in magnitudes) {
    final index = ((magnitude - start) / binWidth).floor();
    if (index >= 0 && index < count) bins[index]++;
  }
  return [
    for (var index = 0; index < count; index++)
      MagnitudeBin(
        start + index * binWidth,
        start + (index + 1) * binWidth,
        bins[index],
      ),
  ];
}

/// 星表匹配结果，直接喂给结果页的表格。
class StarRow {
  const StarRow({
    required this.name,
    required this.category,
    required this.magnitude,
    required this.ra,
    required this.dec,
    required this.confidence,
    required this.fromLocalCatalog,
  });

  final String name;
  final String category;

  /// 已经是给人看的字符串，星等未知时是「—」。
  final String magnitude;

  final double ra;
  final double dec;

  /// 与之对应的检出星点置信度；星表里有、图上没对应上的为 null。
  final double? confidence;

  /// 名字来自 APP 内置目录（离线可得）还是在线星表。
  final bool fromLocalCatalog;

  String get confidenceLabel {
    final value = confidence;
    if (value == null) return '未检出';
    if (value >= 0.7) return '较可信';
    if (value >= 0.35) return '供参考';
    return '低可信';
  }
}

/// 把星表匹配结果摊平成表格行。
///
/// 置信度不是从星表来的，而是把目录坐标投影回像素之后，找图上最近的那个
/// 检出点源。找不到（说明这颗星太暗、没被检出）就留空——空着比填一个
/// 假的「较可信」诚实。
List<StarRow> buildStarTable(SkyAnalysis analysis, SolveResult? solve) {
  if (solve == null) return const [];
  final detections = analysis.compactSources;
  return [
    for (final object in solve.namedStars)
      StarRow(
        name: object.name,
        category: object.category,
        magnitude: object.magnitude == null
            ? '—'
            : '${object.magnitudeBand} ${object.magnitude!.toStringAsFixed(2)}',
        ra: object.ra,
        dec: object.dec,
        confidence: _confidenceNear(object, detections),
        fromLocalCatalog: object.isLocal,
      ),
  ];
}

/// 距离该天体 4 像素以内最亮的检出点源置信度。
double? _confidenceNear(SkyObject object, List<DetectedStar> detections) {
  // (0, 0) 是「这颗星不在图上」的约定值，不是真的落在左上角。
  if (object.x == 0 && object.y == 0) return null;
  DetectedStar? best;
  var bestDistance = 4.0;
  for (final star in detections) {
    final distance = math.sqrt(
      math.pow(star.x - object.x, 2) + math.pow(star.y - object.y, 2),
    );
    if (distance < bestDistance) {
      bestDistance = distance;
      best = star;
    }
  }
  return best?.confidence;
}

/// 天空背景的人话翻译。
///
/// 刻意不叫「光污染等级」：这个指数是从照片本身量出来的，受曝光、ISO 和
/// 后期处理影响，跟 SQM 读数或 Bortle 等级不是一回事。说成等级会让人拿去
/// 跟别人比，比出来的差异其实主要是机器设得不一样。
String describeSkyBrightness(double index) {
  if (index < 12) return '很暗';
  if (index < 25) return '偏暗';
  if (index < 42) return '一般';
  if (index < 60) return '偏亮';
  return '很亮';
}

/// 画面里最亮的那颗天体。
String? _brightest(SkyAnalysis analysis, SolveResult? solve) {
  final stars = analysis.compactSources;
  if (stars.isEmpty) return null;
  var brightest = stars.first;
  for (final star in stars) {
    if (star.instrumentalMagnitude < brightest.instrumentalMagnitude) {
      brightest = star;
    }
  }
  final named = solve?.namedStars ?? const <SkyObject>[];
  for (final object in named) {
    final dx = object.x - brightest.x;
    final dy = object.y - brightest.y;
    if (math.sqrt(dx * dx + dy * dy) <= 4) {
      final magnitude = object.magnitude;
      return magnitude == null
          ? object.name
          : '${object.name}（${object.magnitudeBand} ${magnitude.toStringAsFixed(2)}）';
    }
  }
  // 最亮的那颗没能对上星名时要说清楚是哪种情况：没解算，和
  // 「解算了但这颗星不在目录里」（太暗、或被掩膜吃掉）是两回事。
  return solve == null
      ? '图内最亮点（未解算，无法确认星名）'
      : '图内最亮点（星表里没有对应的名称）';
}

/// 拍摄建议。每条都从测量结果里推出来，不写没有依据的话。
List<String> buildAdvice(SkyAnalysis analysis, SolveResult? solve) {
  final advice = <String>[];
  if (!analysis.isLikelyStarfield) {
    advice.add('这张图看起来不完全是星空——里面有超过 '
        '${(analysis.nonStarFraction * 100).toStringAsFixed(0)}% 的区域'
        '（文字、表格、建筑或大幅面亮块）。星空相关的测量只在星场区域内有效。');
  }
  if (analysis.fwhm > 5.5) {
    advice.add('点源半高全宽 ${analysis.fwhm.toStringAsFixed(1)} 像素，偏大：'
        '对焦可以再准一些，或者曝光期间有轻微抖动。');
  } else if (analysis.fwhm > 0 && analysis.fwhm < 1.6) {
    advice.add('点源半高全宽只有 ${analysis.fwhm.toStringAsFixed(1)} 像素，'
        '星星几乎被压在一个像素里——用了很强的降噪或锐化？'
        '这会压扁亮星的测光结果。');
  }
  if (analysis.saturatedFraction > 0.008) {
    advice.add('有 ${(analysis.saturatedFraction * 100).toStringAsFixed(1)}% 的像素过曝。'
        '亮星的核心一旦压平，星等就量不准了，可以缩短曝光或降 ISO。');
  }
  if (analysis.noise > 0.055) {
    advice.add('背景噪声 ${(analysis.noise * 100).toStringAsFixed(1)}%，偏高。'
        '同一机位多拍几张叠加（每张 10–20 张起步）比拉高 ISO 更划算。');
  }
  if (analysis.backgroundIndex > 55) {
    advice.add('天空背景偏亮（视觉指数 '
        '${analysis.backgroundIndex.toStringAsFixed(0)}/100），'
        '暗弱的天体会淹在背景里。换到远离城市灯光的位置，或者加一片光害滤镜。');
  }
  if (analysis.streakCandidates.isNotEmpty) {
    advice.add('检出 ${analysis.streakCandidates.length} 条拉长的亮点，'
        '很可能是卫星或飞机。单张照片没法确认是哪一种，'
        '但可以在下方列表里逐条剔除，别让它们带偏结果。');
  }
  if (solve == null) {
    advice.add('这次没能解开天区，所以还不知道拍的是哪一片星空。'
        '视场太窄或星点太少时会这样，可以试试更广的镜头，'
        '或填好 Astrometry.net API Key 交给在线解算。');
  }
  // 解算方式（本机 / 在线）不写进建议：它是事实陈述，不是可执行的改进，
  // 而且天区识别那张卡里已经写明。留在这里会把下面这条兜底挤掉。
  if (advice.isEmpty) {
    advice.add('这张照片的测量结果没有明显问题，可以直接作为观测记录留存。');
  }
  return advice;
}

/// 一段话的总结。给人看的，所以只讲结论，不讲算法。
String _summary(
  SkyAnalysis analysis,
  SolveResult? solve,
  List<double> magnitudes,
) {
  final buffer = StringBuffer();
  final constellation =
      solve != null && solve.constellations.isNotEmpty
          ? solve.constellations.first
          : null;
  if (solve == null) {
    buffer.write('这张照片还没能认出是哪一片星空。');
  } else if (constellation != null) {
    buffer.write('这张照片拍的是 $constellation 一带的天区，');
  } else {
    buffer.write('这张照片的天区已经解开，');
  }
  if (solve != null) {
    buffer.write(
      '中心在 ${formatRa(solve.centerRa)} / ${formatDec(solve.centerDec)}，'
      '视场对角 ${formatFieldOfView(solve.fieldOfViewDegrees)}，'
      '每像素 ${solve.arcsecPerPixel.toStringAsFixed(1)} 角秒。',
    );
    buffer.write('与星表比对上 ${solve.matchedCount} 颗恒星。');
  }
  buffer.write(
    '图上检出 ${analysis.compactSources.length} 个紧凑点源，'
    '点源半高全宽约 ${analysis.fwhm.toStringAsFixed(1)} 像素，'
    '背景${describeSkyBrightness(analysis.backgroundIndex)}，'
    '整体质量${analysis.quality}。',
  );
  if (magnitudes.isNotEmpty) {
    buffer.write(
      '能测到的最亮星等约 ${magnitudes.reduce((a, b) => a < b ? a : b).toStringAsFixed(1)}，'
      '最暗约 ${magnitudes.reduce((a, b) => a > b ? a : b).toStringAsFixed(1)}。',
    );
  }
  return buffer.toString();
}
