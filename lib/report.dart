import 'dart:math' as math;

import 'analysis.dart';
import 'deepsky_names.dart';
import 'models.dart';
import 'moon.dart';
import 'smallbodies.dart';
import 'solver.dart';

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
Map<String, Object?> buildAgentReport(
  SkyAnalysis analysis,
  SolveResult? solve, {
  MoonFacts? moon,
}) {
  final record = buildObservationRecord(analysis, solve, moon: moon);
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
    // 月球走的是另一条链路：星点相关的字段在这类照片上没有意义，月面自己有
    // 一套。两条路径都给出去，让模型自己看它们是否互相印证。
    'is_moon_shot': analysis.isMoonShot,
    'moon': moon == null
        ? null
        : {
            'lit_fraction_measured': moon.measuredFraction,
            'lit_fraction_from_ephemeris': moon.ephemerisFraction,
            'phase_name': moon.phaseName,
            'waxing': moon.waxing,
            'disc_radius_pixels': analysis.moonDisc!.radiusPixels,
            'fraction_of_frame': analysis.moonDisc!.discAreaFraction,
            'caution': moon.caution,
          },
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
          'kind': entry.kind.name,
          'kind_label': entry.kind.label,
          'separation_arcsec': entry.detected ? entry.separationArcsec : null,
          'magnitude': entry.magnitudeIsRough ? null : entry.magnitude,
          'magnitude_is_rough': entry.magnitudeIsRough,
          'distance_au': entry.distanceAu,
          // 有没有在图上认出来。为 false 时上面那个 separation 是空的——那个
          // 差数不存在，不能给模型一个「差 0 角秒」去发挥。
          'detected': entry.detected,
          'catalog_built': entry.catalogBuilt,
        },
    ],
    'moving_body_caution': solve == null || solve.movingBodies.isEmpty
        ? null
        : movingBodyCaution,
    'unidentified_body_caution': solve == null ||
            !solve.movingBodies.any((body) => !body.detected)
        ? null
        : unidentifiedBodyCaution,
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

/// 月面的两条结论：图上量出来的，和从拍摄时刻算出来的。
///
/// 两条路径完全独立——一边数像素，一边算天体力学。它们能互相对上，才说明两边
/// 都没错；差得远就说明其中有一个站不住。这正是为什么要把两个数都摆出来，而
/// 不是挑一个报。
class MoonFacts {
  const MoonFacts({
    required this.measuredFraction,
    required this.centerX,
    required this.centerY,
    required this.radiusPixels,
    this.ephemerisFraction,
    this.phaseName,
    this.waxing,
  });

  /// 图上数出来的亮面占比（0–1）。
  final double measuredFraction;

  /// 月盘，画圈用。
  final double centerX;
  final double centerY;
  final double radiusPixels;

  /// 从拍摄时刻算出来的亮面占比；没有可用时刻时为 null。
  final double? ephemerisFraction;

  /// 相名（盈凸月、上弦…）。**依赖拍摄时刻**，没有时刻就是 null。
  final String? phaseName;

  /// 是否在盈。单张图看不出来（镜像/翻转未知），只有时刻能定。
  final bool? waxing;

  String get measuredPercent =>
      '${(measuredFraction * 100).toStringAsFixed(1)}%';

  String? get ephemerisPercent => ephemerisFraction == null
      ? null
      : '${(ephemerisFraction! * 100).toStringAsFixed(1)}%';

  /// 两条路径的差距，超过这个数就值得说一句。
  static const double _agreementTolerance = 0.05;

  /// 两条路径对不上时的说明；对得上、或者缺一条时为 null。
  String? get caution {
    final other = ephemerisFraction;
    if (other == null) return null;
    if ((measuredFraction - other).abs() <= _agreementTolerance) return null;
    return '图上量出 $measuredPercent，按拍摄时刻算是 $ephemerisPercent，'
        '差得比预期大。可能是拍摄时刻不对（这个数对时间很敏感），'
        '也可能是明暗界线附近的亮度被曝光或后期处理改了。';
  }
}

/// 从分析结果和拍摄时刻拼出月面的两条结论。
///
/// 没有 [utc] 也能给出图上量出来的那一条；只是没有相名、没有盈亏、没有第二个
/// 数可以互相印证。
MoonFacts? moonFactsOf(SkyAnalysis analysis, DateTime? utc) {
  final disc = analysis.moonDisc;
  if (disc == null) return null;
  final phase = utc == null ? null : moonPhaseAt(utc);
  return MoonFacts(
    measuredFraction: disc.illuminatedFraction,
    centerX: disc.centerX,
    centerY: disc.centerY,
    radiusPixels: disc.radiusPixels,
    ephemerisFraction: phase?.illuminatedFraction,
    phaseName: phase?.name,
    waxing: phase?.waxing,
  );
}

/// 报告最上面那一段：用户真正想知道的事，句废话都不放。
///
/// 三条原则：
///   1. **先说是什么**。星座、画面里认得出的天体，排在所有数字前面。
///   2. **不写废话**。「解析结果见下方」这类不提供信息的句子一律不要。
///   3. **名字要看得见**。天体名用 `==…==` 标出来（记号的定义见
///      `lib/markdown.dart`），一屏文字里一眼就能挑出「我拍到了什么」。
///
/// 这段文字是**本地拼的**，不走模型：它全是星表查出来的事实——名字、编号、
/// 星等、视场——编错一个字符就是错的事实。模型的活是解释这些事实，不是生产
/// 它们，所以这里也不给它编的机会。模型拿到的是同一份事实（`buildAgentReport`），
/// 它写的那段解读接在这后面。
String buildHeadlineMarkdown(
  SkyAnalysis analysis,
  SolveResult? solve, {
  MoonFacts? moon,
}) {
  final lines = <String>[];

  // 月面那一段的判据是**照片本身有没有月盘**，不是调用方有没有把 facts 传进来。
  // 只认参数的话，任何一处忘了传（比如从观星仓库里重新打开一条记录时的某条
  // 渲染路径）都会掉到下面去，标题写成「天区未识别」——而那张照片根本不是
  // 「没识别出来」，它走的是月面链路，压根没去解。少一个参数就多一句假话，
  // 这种默认值不值得留。
  final moonFacts = moon ?? moonFactsOf(analysis, null);
  if (moonFacts != null) {
    // 月面照片没有星场可报，「在哪个星座」对月亮没有意义——月亮几分钟就挪
    // 出星座边界。它有自己的三件事：相、亮面占比、占多大。
    lines.add('## ${moonFacts.phaseName ?? '月亮'}');
    lines.add('');
    lines.add('- 亮面占比 ==${moonFacts.measuredPercent}==（图上量的）');
    if (moonFacts.ephemerisPercent != null) {
      lines.add('- 按拍摄时刻算 ==${moonFacts.ephemerisPercent}==');
    }
    final disc = analysis.moonDisc!;
    lines.add('- 月盘占画面 ==${(disc.discAreaFraction * 100).toStringAsFixed(2)}%==');
    if (moonFacts.caution != null) {
      lines.add('');
      lines.add('> ${moonFacts.caution}');
    }
    return lines.join('\n');
  }

  final constellation =
      solve != null && solve.constellations.isNotEmpty
          ? solve.constellations.first
          : null;
  lines.add('## ${constellation ?? (solve == null ? '天区未识别' : '天区已解算')}');
  lines.add('');

  final bodies = buildMovingBodyEntries(solve);
  for (final body in bodies) {
    // 行星是这张图上最稀有、也最该被先看到的结论，排在第一条。
    if (!body.detected) {
      lines.add('- ${body.name}（${body.kind.label}）${body.magnitudeLabel}'
          '${body.reachLabel}——图上没有对上');
      continue;
    }
    lines.add('- ==${body.name}==（${body.kind.label}）'
        '${body.magnitudePhrase == null ? '' : '，${body.magnitudePhrase}'}'
        '，${body.separationLabel}');
  }

  final named = _chineseNamedStars(solve);
  if (named.isNotEmpty) {
    lines.add('- 亮星 ${named.map((name) => '==$name==').join('、')}');
  }

  final deepSky = buildDeepSkyEntries(solve);
  if (deepSky.isNotEmpty) {
    lines.add(
      '- 深空天体 ${deepSky.take(3).map((entry) {
        final label = entry.label;
        final coverage = entry.fieldFraction;
        if (coverage == null || coverage < 0.05) return '==$label==';
        return '==$label==（占像场 ${(coverage * 100).round()}%）';
      }).join('、')}',
    );
  }

  if (solve != null) {
    lines.add(
      '- 视场 ==${formatFieldOfView(solve.fieldOfViewDegrees)}== · '
      '==${solve.arcsecPerPixel.toStringAsFixed(1)}″==/像素 · '
      '星表匹配 ==${solve.matchedCount}== 颗',
    );
  } else if (analysis.compactSources.isNotEmpty) {
    lines.add('- 检出 ==${analysis.compactSources.length}== 个紧凑点源，但没和星表对上');
  }

  return lines.join('\n');
}

/// 画面里最亮、且**有中文名**的几颗星。
///
/// 只要中文名。这条是有意的：报告顶部是给用户「一眼认出我拍到了什么」用的，
/// 而「HIP 32349」认不出任何东西。在线解算回来的名字是 SIMBAD 的写法
/// （`* alf CMa`），对不上内置表时就不列——列一个英文编号不如不列，它只
/// 会让这一行变长。
///
/// 最多五颗：这一行是「哦，是猎户座」的量级信息，不是目录清单，清单在下面
/// 的恒星表里。
List<String> _chineseNamedStars(SolveResult? solve, {int limit = 5}) {
  final stars = solve?.namedStars;
  if (stars == null) return const [];
  final chinese = <SkyObject>[
    for (final star in stars)
      if (_containsHan(star.name)) star,
  ]..sort(
      (a, b) => (a.magnitude ?? 99).compareTo(b.magnitude ?? 99),
    );
  return [for (final star in chinese.take(limit)) star.name];
}

final _hanPattern = RegExp(r'[\u4e00-\u9fff]');

bool _containsHan(String text) => _hanPattern.hasMatch(text);

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
    this.moon,
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

  /// 月面那条链路的结论。非 null 表示这张照片走的是月面分支。
  final MoonFacts? moon;
}

ObservationRecord buildObservationRecord(
  SkyAnalysis analysis,
  SolveResult? solve, {
  MoonFacts? moon,
}) {
  final magnitudes = calibratedMagnitudes(analysis, solve);
  return ObservationRecord(
    summary: _summary(analysis, solve, magnitudes, moon),
    moon: moon,
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
    advice: buildAdvice(analysis, solve, moon: moon),
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
List<String> buildAdvice(
  SkyAnalysis analysis,
  SolveResult? solve, {
  MoonFacts? moon,
}) {
  final advice = <String>[];
  if (moon != null) {
    // 月面照片走另一条链路，星场那套建议（对焦、星点数量、解算）一条都不适用。
    advice.add('这是一张月面照片，亮面占月盘的 ${moon.measuredPercent}。'
        '拍月面讲究的是不过曝：月亮比恒星亮上万倍，'
        '要单独用很短的曝光，别和星空用同一套参数。');
    if (moon.phaseName != null) {
      advice.add('拍摄时刻算出来是${moon.phaseName}，'
          '亮面占比应有 ${moon.ephemerisPercent}，和图上量出来的'
          '${moon.measuredPercent} 是两个独立的数——'
          '它们对得上，说明测量可信。');
    } else {
      advice.add('没有拍摄时刻就没有相名，也说不清是在盈还是在亏：'
          '单张照片里相机有没有镜像或上下翻转是看不出来的。'
          '在下方填上拍摄时间，就能算出来。');
    }
    if (analysis.saturatedFraction > 0.01) {
      advice.add('有 ${(analysis.saturatedFraction * 100).toStringAsFixed(1)}% '
          '的像素已经饱和。月面比以前更亮的部分会连成一片死白，'
          '明暗界线也会被抹平——把曝光再降一档。');
    }
    final caution = moon.caution;
    if (caution != null) advice.add(caution);
    return advice;
  }
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
/// [attempt] 是这次本机解算的过程记录，见 [describeSolveAttempt]。
List<String> buildSolveFailureAdvice(
  SkyAnalysis analysis, {
  required bool uploadAllowed,
  required bool hasApiKey,
  String? onlineError,
  SolveTrace? attempt,
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
      '所以不是星点太少，而是图中点源与已知恒星位置对不上：'
      '内置目录收录到 V=8.0 的亮星，另有一层 9 等以内的背景星兜底；'
      '视场窄到 4° 以下、或者画面里大半「星点」其实是星系星云一类'
      '并非点源的东西，就还是对不上。'
      '换更广的焦段（或加 0.5× 减焦镜）更容易成功。',
    );
  }

  // 先把「该做什么」说完，再摆这次到底试了什么。顺序不能反：用户第一眼看
  // 到的应该是动作，不是数字；而数字紧跟其后，是因为下一句「在线也失败了」
  // 到底可不可信，就看得出这几层是不是真跑过。
  final detail = describeSolveAttempt(attempt);
  if (detail != null) advice.add(detail);

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

/// 本机解算「试了什么、差多少」的一行取证。
///
/// 这一行是为一次查不出原因的失败加的：同一张图、同一份代码，用户在自己手机
/// 上失败、桌面上却解得出。两种可能的原因——星表资产没读全、天区本身对不上
/// ——对用户是同一句「没找到」。把实际试过的星数和内点数写出来，两者立刻分得
/// 开：某层星数不对就是资产，星数对得上、内点差一点就是判据太紧。
///
/// 没有记录（连一层都没跑到，比如检出星点本身就太少）时返回 null：那时候
/// 前面那些「点源太少」的话已经把原因说清了，再添一行数字只是噪声。
String? describeSolveAttempt(SolveTrace? trace) {
  if (trace == null || trace.layers.isEmpty) return null;
  final layers = [
    for (final layer in trace.layers)
      '${layer.label} ${layer.starCount} 颗（试 ${layer.rungsTried} 档）',
  ];
  final buffer = StringBuffer('本机解算未成功：${layers.join('、')}；');
  if (trace.bestRequired == 0) {
    // 一次内点都没数到：三角形候选连验证那一步都没走到。
    buffer.write('候选三角形一个都没能对上内点。');
  } else {
    buffer.write(
      '最多数到 ${trace.bestInliers} 颗内点，'
      '需要 ${trace.bestRequired} 颗。',
    );
  }
  return buffer.toString();
}

/// 这个深空天体值不值得在**图上**画一个圈。

/// 两条同时成立才不画：**又大又没星等**。
///
///   * 「大」＝ 直径超过像场对角线的 [_markSizeLimit]。到这个尺寸，那个圆已经
///     不是「目标在这儿」的意思，而是绕着整幅画面的一个环——它不再指出什么，
///     只是把所有别的标注都圈进去。
///   * 「没星等」＝ 目录里压根没记它的亮度。NGC 2000.0 里这类大面积弥漫天体的
///     星等列普遍是空的，而空星等基本等于「在手机单张照片上看不见」，画个圈
///     等于圈住了空气。
///
/// 两条是「且」不是「或」：M31 也很大（178′），但它有星等 3.5，那个圈是有意义
/// 的；面纱星云的弧（70′）没有星等，可它没大到那个程度，圈也画得出来。真正
/// 被挡掉的是 IC 353 这种——180′、没星等、大部分人没听说过，画在图上只是一
/// 个大环。**它照样留在列表里**，用户还是能知道画面里有它，只是没有加减号
/// 可点：图上本来就没画，隐不隐去无从谈起。
///
/// 只在这里定义一次。图上画不画、列表里给不给加减号是同一个问题，两边各自判
/// 一次迟早会不一致——那种不一致的表现是「按了减号什么也没发生」。
bool worthMarkingOnImage({
  required double? sizeArcmin,
  required double? magnitude,
  required double fieldOfViewDegrees,
}) {
  if (sizeArcmin == null || fieldOfViewDegrees <= 0) return true;
  final fraction = (sizeArcmin / 60) / fieldOfViewDegrees;
  return fraction <= _markSizeLimit || magnitude != null;
}

/// 圆圈的直径超过像场对角线的这个比例之后，它就不再是「一个标记」了。
const double _markSizeLimit = 0.6;

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

  /// 常见中文昵称（「昴星团」）；这张表只收最常被提到的那批目标，没有就是
  /// null，此时只报编号，不硬译一个出来。
  String? get nickname => chineseNicknameOf(name);

  /// 报告里写这个名字：`M 45 昴星团`。
  String get label => deepSkyLabel(name);

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
/// 排序不按目录顺序，也不单纯按大小——分三步：
///
///   1. **模型挑过的那个排最前**（`SolveResult.primaryDeepSky`）。挑主体是
///      个判断，交给模型做：它知道 M45 是昴星团、而 IC 353 大部分人没听说过。
///   2. 没挑过（没配模型、断网、回答不像话）就退回本机那套：**有中文常用名的
///      排前面**。那张手写的表（`deepsky_names.dart`）收的正是「爱好者嘴里会
///      说的目标」，所以「这里有没有名字」近似于「这个东西有没有人认识」。
///   3. 同档之内按占画面多大排。
///
/// 少了这两步会出一个很怪的结论：拍昴星团，报告说主体是 IC 353。IC 353 在
/// NGC 2000.0 里记着 180′，比 M45 的 110′ 大，可它没有星等、没有常用名、
/// 大部分人没听说过——而 180′ 这个数本身就可疑（目录里 IC 360、IC 2118 也是
/// 恰好 180.0′，几个不同的大面积弥漫天体全都一样，更像是当年的占位值）。
/// 拿一个不可靠的尺寸去压一个响当当的名字，得到的是「这张照片拍的是 IC 353」。
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
  entries.sort((a, b) {
    // 模型挑过的，就是它。
    final primary = solve.primaryDeepSky;
    if (primary != null && a.name != b.name) {
      if (a.name == primary) return -1;
      if (b.name == primary) return 1;
    }
    final aNamed = a.nickname != null;
    final bNamed = b.nickname != null;
    if (aNamed != bNamed) return aNamed ? -1 : 1;
    return (b.fieldFraction ?? -1).compareTo(a.fieldFraction ?? -1);
  });
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
    this.kind = BodyKind.planet,
    this.magnitude,
    this.distanceAu,
    this.detected = true,
    this.magnitudeIsRough = false,
    this.catalogBuilt,
  });

  final String name;

  /// 哪一类天体。报告里要写出来——「灶神星」和「木星」的可信程度不一样，
  /// 前者来自构建时抓的内置表，后者来自写在代码里的近似根数表。
  final BodyKind kind;

  final double separationArcsec;
  final double? magnitude;
  final double? distanceAu;

  /// 图上到底认出来了没有。见 [MovingBodySuspicion.detected]。
  final bool detected;

  /// 亮度是不是只能当个大概（彗星的 k1 八成是缺省值）。这种数字不写进报告。
  final bool magnitudeIsRough;

  /// 内置小天体表的构建日期。
  final String? catalogBuilt;

  /// 「和星历位置差 42″」。
  String get separationLabel {
    final seconds = separationArcsec;
    if (seconds < movingBodyCoincidenceArcsec) return '和星历位置几乎重合';
    return '和星历位置差 ${seconds.round()}″';
  }

  /// 「亮度约 8.0 等」；不可靠或没有时为 null。
  ///
  /// 不可靠的亮度宁可不写：写出来用户就会拿它和星表里的星等比，而那个数可能差
  /// 好几等。
  String? get magnitudePhrase => magnitude == null || magnitudeIsRough
      ? null
      : '亮度约 ${magnitude!.toStringAsFixed(1)} 等';

  /// 「，亮度约 8.0 等」。
  String get magnitudeLabel {
    final phrase = magnitudePhrase;
    return phrase == null ? '' : '，$phrase';
  }

  String get distanceLabel => distanceAu == null
      ? ''
      : '，距地球约 ${distanceAu!.toStringAsFixed(2)} 个天文单位';

  /// 「，这个器材拍不到」——只有算出来比手机能记到的极限还暗时才这么说。
  ///
  /// 不说的话，用户看到「冥王星 14.6 等」只会以为是我们没找到。
  String get reachLabel {
    final value = magnitude;
    if (value == null) return '';
    return value > smallBodyPhotoLimitMagnitude
        ? '，比手机能拍到的极限还暗，这个器材拍不到'
        : '，亮度上够得着，但这张图上没有对上';
  }

  /// 一句话讲完这一条。
  ///
  /// 认出来的讲位置、亮度、距离，以及它和星历差了多少；没认出来的不能讲「差
  /// 多少」——那个差数根本不存在。
  String get describe => detected
      ? '$name$distanceLabel$magnitudeLabel，$separationLabel'
      : '$name$distanceLabel$magnitudeLabel$reachLabel';

  /// [describe] 去掉开头的名字。想在名字后面插一句类别（「灶神星（小行星）」）
  /// 时用，省得把三段拼装再写一遍。
  String get describeWithoutName => describe.substring(name.length);
}

/// 落到报告里的那条不确定度说明。
///
/// 行星识别这东西一旦给错就是错的，所以结论旁边必须说清楚它凭什么成立、
/// 以及凭什么可能不成立。最后那句「隔几天再拍一张」不是客套——那是唯一能
/// 真正把「疑似」变成「确认」的、用户自己就做得到的办法：行星几天里会挪出
/// 肉眼可见的位置，恒星不会。
const String movingBodyCaution =
    '这些是「疑似」，不是「确认」。判断依据有两条，缺一不可：星表里这个位置'
    '查不到星，而且星历算出的位置上有颗亮点。行星用的是一张近似根数表，'
    '位置本身有角分量级的误差，所以看到「差几十角秒」是正常的。'
    '小行星和彗星的位置来自应用内置的星历表（表上写着构建日期），'
    '表建好之后就不再更新——离构建日期越远，位置越不准，谷神星三年能偏二十角分。'
    '想看得更实，可以过几天在同一机位再拍一张：这些天体几天里会挪位置，恒星不会。';

/// 「它在画面里，但没认出来」那一条的说明。
///
/// 单独一条，因为这两件事的成因完全不同：认出来是「位置对上了 ＋ 星表里没有星」，
/// 没认出来是「位置算出来了，但图上找不到够亮的点」——八成是亮度不够。混在一段话
/// 里说，用户会以为前者也不可信。
const String unidentifiedBodyCaution =
    '「画面里还有」那几条是另一回事：它们的位置是算出来的，但图上没有找到能对上'
    '的亮点。多数情况是亮度不够——手机和小口径望远镜拍不到十几等的天体，'
    '这跟这个天体在不在那儿没有关系。';

/// 把解算结果里的疑似运动天体整理成报告条目。
///
/// 排序分两段：真的认出来的按「和星历差多少」排（差得越少，「就是它」越站得住），
/// 没认出来的接在后面按亮度排（最亮的排前面，用户最可能问的就是它）。
List<MovingBodyEntry> buildMovingBodyEntries(SolveResult? solve) {
  final bodies = solve?.movingBodies;
  if (bodies == null || bodies.isEmpty) return const [];
  final detected = <MovingBodySuspicion>[
    for (final body in bodies)
      if (body.detected) body,
  ]..sort((a, b) => a.separationArcsec.compareTo(b.separationArcsec));
  final unidentified = <MovingBodySuspicion>[
    for (final body in bodies)
      if (!body.detected) body,
  ]..sort((a, b) => (a.magnitude ?? 99).compareTo(b.magnitude ?? 99));
  return [
    for (final body in [...detected, ...unidentified])
      MovingBodyEntry(
        name: body.name,
        separationArcsec: body.separationArcsec,
        kind: body.kind,
        magnitude: body.magnitude,
        distanceAu: body.distanceAu,
        detected: body.detected,
        magnitudeIsRough: body.magnitudeIsRough,
        catalogBuilt: body.catalogBuilt,
      ),
  ];
}

/// 一段话的总结。给人看的，所以只讲结论，不讲算法。
String _summary(
  SkyAnalysis analysis,
  SolveResult? solve,
  List<double> magnitudes, [
  MoonFacts? moon,
]) {
  if (moon != null) {
    final buffer = StringBuffer('这张照片拍的是月亮。');
    buffer.write('月盘占画面约 ${(analysis.moonDisc!.discAreaFraction * 100).toStringAsFixed(2)}%，'
        '亮面占月盘 ${moon.measuredPercent}。');
    if (moon.phaseName != null) {
      buffer.write('按拍摄时刻算，这时月亮是${moon.phaseName}');
      buffer.write('（亮面 $moon.ephemerisPercent）。');
    } else {
      buffer.write('没有拍摄时刻，所以算不出相名，也说不清是在盈还是在亏。');
    }
    buffer.write('画面里没有可用的星场——拍月亮的时候基本拍不到别的。');
    return buffer.toString();
  }
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
    final detected = [
      for (final entry in entries)
        if (entry.detected) entry,
    ];
    final unidentified = [
      for (final entry in entries)
        if (!entry.detected) entry,
    ];
    if (detected.isNotEmpty) {
      buffer.write('另外，图上 '
          '${detected.map((entry) => '${entry.name}（${entry.kind.label}）${entry.describeWithoutName}').join('、')}，'
          '疑似是行星这一类会动的天体——'
          '这个判断依赖拍摄时刻，也依赖星历的精度，所以只说疑似。');
    }
    if (unidentified.isNotEmpty) {
      buffer.write('${detected.isEmpty ? '另外，' : ''}这张照片上还应该有 '
          '${unidentified.map((entry) => entry.describe).join('、')}。');
    }
  }
  return buffer.toString();
}
