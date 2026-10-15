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
    // 深空天体连同角尺寸一起给模型：只给名字的话，模型没法判断「这张照片
    // 是拍全景还是特写」，也就没法评价构图和器材匹配度。
    'deep_sky_objects': [
      for (final entry in buildDeepSkyEntries(solve))
        {
          'name': entry.name,
          'type': entry.category,
          'ra_deg': entry.raDeg,
          'dec_deg': entry.decDeg,
          'angular_size_arcmin': entry.angularSizeArcmin,
          'fraction_of_field_of_view': entry.fieldFraction,
        },
    ],
    // 疑似运动天体。给模型的时候必须连判据和不确定度一起给：只给一个名字，
    // 模型会把它当既成事实写进解读里，而这里其实只说得出「疑似」。
    'moving_bodies': [
      for (final entry in buildMovingBodyEntries(solve))
        {
          'name': entry.name,
          'separation_arcsec': entry.separationArcsec,
          'magnitude': entry.magnitude,
          'distance_au': entry.distanceAu,
        },
    ],
    'moving_body_caution': solve == null || solve.movingBodies.isEmpty
        ? null
        : movingBodyCaution,
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
    required this.deepSky,
    required this.movingBodies,
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

  /// 画面中的深空天体，按占画面大小排序。
  final List<DeepSkyEntry> deepSky;

  /// 疑似的运动天体（行星、太阳），按和星历位置的差距从小到大排。
  ///
  /// 空表示没判出来——可能是没有拍摄时刻，也可能是星表在那里能查到星。
  final List<MovingBodyEntry> movingBodies;
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
    deepSky: buildDeepSkyEntries(solve),
    movingBodies: buildMovingBodyEntries(solve),
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
  // 拍深空目标的人最容易被「星点怎么这么少」劝退，以为是自己拍砸了。
  // 画面里有深空天体时先把这句话说在前头：这是目标本身的性质，不是失败。
  final deepSky = buildDeepSkyEntries(solve);
  if (deepSky.isNotEmpty && analysis.compactSources.length < 40) {
    final main = deepSky.first;
    final what = main.category.isEmpty
        ? main.name
        : '${main.name}（${main.category}）';
    final sizePart =
        main.angularSizeArcmin == null ? '' : '（${main.sizeLabel}）';
    final coveragePart =
        main.coverageLabel.isEmpty ? '' : '，${main.coverageLabel}';
    advice.add(
      '这张照片拍的是深空目标 $what$sizePart$coveragePart。'
      '这类目标本身就是一个延展的亮斑，'
      '画面里的紧凑星点本来就比普通星场少，不是拍坏了，也不是对焦不准。',
    );
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

/// 本机没解出天区时给用户的提示。
///
/// 「星点不足」这种话没有用——用户看完还是不知道该干什么。所以这里每一条都
/// 要落到一个具体动作上：换焦段、改曝光、开在线解算、还是先确认拍的是不是
/// 星空。判断依据全部来自已有的测量结果，不猜。
///
/// [uploadAllowed] / [hasApiKey] 决定「开在线解算」这条建议是能立刻照做，
/// 还是得先去设置里配；[onlineError] 非空表示在线那一步已经试过并失败了。
List<String> buildSolveFailureAdvice(
  SkyAnalysis analysis, {
  required bool uploadAllowed,
  required bool hasApiKey,
  String? onlineError,
}) {
  final advice = <String>[];
  final compact = analysis.compactSources.length;

  if (!analysis.isLikelyStarfield) {
    advice.add(
      '本机没能认出这片天区，而且这张图看起来就不是以星场为主的照片。'
      '先在相册里裁掉文字、地面和建筑，只留星空再试一次。',
    );
  } else if (compact < 8) {
    advice.add(
      '本机没能认出这片天区：图上只检出 $compact 个紧凑点源，参考星太少。'
      '把曝光时间加倍（或 ISO 提高一档）重拍一张，'
      '或者把镜头拉到更广的焦段——视场越大，画面里的参考星越多。',
    );
  } else {
    advice.add(
      '本机没能认出这片天区。图上检出了 $compact 个紧凑点源，'
      '所以不是星点太少，而是这些星点和本机星表对不上：'
      '星表收录了 41394 颗 V=8.0 以内的亮星，另有一层 13.7 万颗 9 等以内的'
      '背景星兜底（覆盖约 2.8 MB，全部内置在手机里）；'
      '视场窄到 4° 以下、或者画面里大半「星点」其实是星系星云一类'
      '并非点源的东西，就还是对不上。'
      '换更广的焦段（或加 0.5× 减焦镜）是本机解算最容易成功的办法。',
    );
  }

  if (uploadAllowed && hasApiKey) {
    advice.add(
      onlineError == null
          ? '也可以交给在线解算：它用的是完整的星表，窄视场基本只有这条路能走通。'
          : '在线解算这次也没成功（$onlineError）。'
              '在线服务用的是完整星表，如果它也认不出来，'
              '更可能是画面本身的问题——检查是否有云、拖线、严重失焦。',
    );
  } else {
    advice.add(
      uploadAllowed
          ? '在线解算已经开着，但设置里还没有 Astrometry.net 的 API Key。'
              '填上 Key 之后，窄视场就可以交给在线服务——它用的是完整的星表。'
          : '如果这是一张长焦或望远镜拍的照片，本机解算多半解不出来。'
              '到「设置」里填上 Astrometry.net 的 API Key 并授权上传，'
              '就可以改走在线解算。',
    );
  }

  if (analysis.fwhm > 8) {
    advice.add(
      '另外，点源半高全宽有 ${analysis.fwhm.toStringAsFixed(1)} 像素，'
      '明显偏大：先重新手动对焦（实时取景放到最大找最锐的位置）再拍。',
    );
  } else if (analysis.streakCandidates.length > 30) {
    advice.add(
      '另外，画面里有 ${analysis.streakCandidates.length} 条拉长的亮点。'
      '如果是星点拖线，说明曝光期间设备动了——缩短单张曝光时间会有帮助。',
    );
  }
  return advice;
}

/// 画面里的一个深空天体，已经整理成能直接写进报告的形式。
///
/// 「画面中有 M31」只是一半的信息。用户真正想知道的还有两件事：它是什么，
/// 以及**它占了画面多大**——同一个目标在 200mm 和 1000mm 下是两张完全不同
/// 的照片，前者是全景，后者是特写。所以角尺寸和像场占比都要算出来。
class DeepSkyEntry {
  const DeepSkyEntry({
    required this.name,
    required this.category,
    this.angularSizeArcmin,
    this.fieldFraction,
    this.raDeg = 0,
    this.decDeg = 0,
  });

  final String name;

  /// 天球坐标。报告正文用不到，交给模型的摘要要用——模型可能想据此判断
  /// 这个目标当时的地平高度、或者属于哪个星座。
  final double raDeg;
  final double decDeg;

  /// 天体类型，已经翻成中文（「旋涡星系」「疏散星团」）。
  final String category;

  /// 天体长轴角尺寸（角分）；目录里查不到时为 null。
  final double? angularSizeArcmin;

  /// 长轴占像场对角线的比例；没有角尺寸时同样为 null。
  final double? fieldFraction;

  bool get isLarge => (fieldFraction ?? 0) >= 0.35;

  /// 「约 190′ 长」或「尺寸未知」。
  String get sizeLabel {
    final size = angularSizeArcmin;
    if (size == null || size <= 0) return '尺寸未知';
    if (size < 1) return '约 ${(size * 60).round()}″';
    if (size < 60) return '约 ${size.toStringAsFixed(1)}′';
    return '约 ${(size / 60).toStringAsFixed(2)}°';
  }

  /// 「占像场对角线的 13%」或「比像场还大」。
  String get coverageLabel {
    final fraction = fieldFraction;
    if (fraction == null) return '';
    if (fraction >= 1) return '比像场对角线还大，画面里只是它的一部分';
    if (fraction >= 0.35) return '约占像场对角线的 ${(fraction * 100).round()}%，是这张照片的主体';
    if (fraction >= 0.1) return '约占像场对角线的 ${(fraction * 100).round()}%';
    return '只占像场对角线的 ${(fraction * 100).toStringAsFixed(1)}%，在这套器材上偏小';
  }
}

/// 把解算结果里的深空天体整理成报告条目。
///
/// 排序按「占画面多大」而不是目录顺序：用户扫一眼报告，先看到大的那个才对，
/// 那才是这张照片真正拍的东西。
List<DeepSkyEntry> buildDeepSkyEntries(SolveResult? solve) {
  if (solve == null) return const [];
  final field = solve.fieldOfViewDegrees;
  final entries = <DeepSkyEntry>[
    for (final object in solve.deepSkyObjects)
      DeepSkyEntry(
        name: object.name,
        category: object.category,
        raDeg: object.ra,
        decDeg: object.dec,
        angularSizeArcmin: object.angularSizeArcmin,
        fieldFraction: object.angularSizeArcmin == null ||
                field <= 0
            ? null
            : (object.angularSizeArcmin! / 60) / field,
      ),
  ];
  entries.sort((a, b) => (b.fieldFraction ?? -1).compareTo(a.fieldFraction ?? -1));
  return entries;
}

/// 星历位置和检出点差到这个角秒数以内，就报不出「差多少」了。
///
/// 这个门槛不是在说「算得准」，恰恰相反：星历近似根数本身的误差就有角分量级，
/// 解算带来的尺度误差也是零点几角秒一档，所以一角秒以内的那个差数主要是噪声，
/// 报成「差 0.4″」是假精确。图上标注和报告正文共用这一个数，否则同一颗行星
/// 会在图上说「重合」、在报告里说「差 0.4″」。
const double movingBodyCoincidenceArcsec = 1.0;

/// 一个疑似运动天体，报告里的一行。
///
/// 和深空天体一样，这里呈现的是「结论 ＋ 这个结论有多硬」。[separationArcsec]
/// 必须跟着名字一起给出去：它就是这个结论的不确定度，藏起来的话「疑似」两个
/// 字就成了一句空话。
class MovingBodyEntry {
  const MovingBodyEntry({
    required this.name,
    required this.separationArcsec,
    this.magnitude,
    this.distanceAu,
  });

  final String name;
  final double separationArcsec;
  final double? magnitude;
  final double? distanceAu;

  /// 「和星历位置差 42″」。
  String get separationLabel {
    final seconds = separationArcsec;
    if (seconds < movingBodyCoincidenceArcsec) return '和星历位置几乎重合';
    return '和星历位置差 ${seconds.round()}″';
  }

  String get magnitudeLabel =>
      magnitude == null ? '' : '，星等约 ${magnitude!.toStringAsFixed(1)}';

  String get distanceLabel => distanceAu == null
      ? ''
      : '，距地球约 ${distanceAu!.toStringAsFixed(2)} 个天文单位';

  /// 一句话讲完这一条：位置、亮度、距离，以及它和星历差了多少。
  String get describe => '$name$distanceLabel$magnitudeLabel，$separationLabel';
}

/// 落到报告里的那条不确定度说明。
///
/// 行星识别这东西一旦给错就是错的，所以结论旁边必须说清楚它凭什么成立、
/// 以及凭什么可能不成立。最后那句「隔几天再拍一张」不是客套——那是唯一能
/// 真正把「疑似」变成「确认」的、用户自己就做得到的办法：行星几天里会挪出
/// 肉眼可见的位置，恒星不会。
const String movingBodyCaution =
    '这些是「疑似」，不是「确认」。判断依据有两条，缺一不可：星表里这个位置'
    '查不到星，而且星历算出的位置上有颗亮点。用的星历是近似根数，位置本身有'
    '角分量级的误差，所以看到「差几十角秒」是正常的。想看得更实，可以过几天'
    '在同一机位再拍一张：行星会挪位置，恒星不会。';

/// 把解算结果里的疑似运动天体整理成报告条目。
List<MovingBodyEntry> buildMovingBodyEntries(SolveResult? solve) {
  final bodies = solve?.movingBodies;
  if (bodies == null || bodies.isEmpty) return const [];
  // 和星历差得少的排前面：差得越少，「就是它」越站得住。
  final sorted = [...bodies]
    ..sort((a, b) => a.separationArcsec.compareTo(b.separationArcsec));
  return [
    for (final body in sorted)
      MovingBodyEntry(
        name: body.name,
        separationArcsec: body.separationArcsec,
        magnitude: body.magnitude,
        distanceAu: body.distanceAu,
      ),
  ];
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
  // 画面里的深空天体比「拍到了哪颗星」更接近用户真正想拍的东西，所以放在
  // 最后单说一句，而不是埋进星表里。
  if (solve != null && solve.deepSkyObjects.isNotEmpty) {
    final entries = buildDeepSkyEntries(solve);
    final names = entries
        .take(3)
        .map((entry) => entry.category.isEmpty
            ? entry.name
            : '${entry.name}（${entry.category}）')
        .join('、');
    final main = entries.first;
    final coverage =
        main.coverageLabel.isEmpty ? '' : '，${main.coverageLabel}';
    buffer.write(
      '画面里有 ${solve.deepSkyObjects.length} 个深空天体，'
      '其中最主要的是 $names——${main.sizeLabel}$coverage。',
    );
  }
  // 行星是这张照片里唯一「只在这一刻成立」的东西，所以它有话说的时候要单独
  // 讲一句、并当场把「疑似」两个字说出口——总结里出现的东西用户会当成结论。
  if (solve != null && solve.movingBodies.isNotEmpty) {
    final entries = buildMovingBodyEntries(solve);
    buffer.write('另外，图上 ${entries.map((entry) => entry.describe).join('、')}，'
        '疑似是行星这一类会动的天体——'
        '这个判断依赖拍摄时刻，也依赖星历的精度，所以只说疑似。');
  }
  return buffer.toString();
}
