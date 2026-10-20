import 'dart:math' as math;

import 'analysis.dart';
import 'models.dart';

/// 运动天体：行星、彗星、小行星。它们在照片上的位置随拍摄时刻变化，所以判据
/// 和恒星完全不同——恒星靠「星表里有这么一颗星」，运动天体靠「星表里**没有**
/// 这么一颗星，而星历说它正好在这儿」。
///
/// 本文件只做后半句：拿到一组预测位置，去图上找有没有对得上的、星表又解释不了
/// 的亮点。星历本身（那些轨道根数）在 `ephemeris.dart` 里，两边分开是为了让这条
/// 判据能脱离星历单独测——抄错一个根数和写错一个匹配半径是两种故障，混在一起
/// 会表现成同一种。

/// 星历预测的一个天体位置。
class PredictedBody {
  const PredictedBody({
    required this.name,
    required this.ra,
    required this.dec,
    this.distanceAu,
    this.discDiameterArcsec,
    this.kind = BodyKind.planet,
    this.magnitude,
    this.magnitudeIsRough = false,
    this.toleranceArcmin = ephemerisToleranceArcmin,
    this.catalogBuilt,
  });

  /// 中文名，直接给用户看（「木星」）。
  final String name;

  /// 哪一类天体。决定图上用哪个记号，也决定结论怎么写。
  final BodyKind kind;

  final double ra;
  final double dec;

  /// 地心距离，天文单位。报告里写「离地球 4.3 个天文单位」用。
  final double? distanceAu;

  /// 视直径，角秒。
  ///
  /// 目前恒为 null：算它需要各行星的赤道半径，那是另一份数据，同样不能凭记忆
  /// 写。判据也不该用它——星历误差和视直径是同一个量级，把它掺进判据只会让
  /// 结论同时依赖两个都在抖的量。留在字段里是给以后补上来源时用的。
  final double? discDiameterArcsec;

  /// 这一时刻算出来的视星等。
  ///
  /// 行星那一路没有（那张近似根数表里根本没有星等），只有走内置小天体目录的
  /// 时候才有。
  final double? magnitude;

  /// [magnitude] 是不是只能当个大概。见 `models.dart` 里
  /// [MovingBodySuspicion.magnitudeIsRough]。
  final bool magnitudeIsRough;

  /// 这个天体允许的角分偏差。
  ///
  /// 按天体分而不是全局一个数：行星那张近似根数表需要 8 角分，内置小天体目录
  /// 实测三五年内漂移 1.6 角分，用不着借那么宽——容差每放宽一倍，随机吻合的
  /// 机会就多三倍。见 `smallbodies.dart` 里那三个容差常量的说明。
  final double toleranceArcmin;

  /// 位置来自哪一天构建的内置表。行星那条路为 null。
  final String? catalogBuilt;
}

/// 星历位置和图上那个亮点之间允许多大的偏差。
///
/// 这个数不是「星历有多准」，是「星历有多不准」。出处那张近似根数表在
/// 1800–2050 区间内只给到角分量级，而且**外行星更差**：木星和土星的 5:2
/// 近共振（「大不等式」）在土星黄经上有约 0.06° 的周期项，两体近似里根本
/// 没有这一项。实测一张 2026-09-01 的土星照片：预报位置和图上那个亮斑
/// 相差 4.3 角分，而当时这个数只有 2 角分——位置明明对得上，却被判成对不上。
///
/// 放宽它**不等于**放宽判据：真正拦误报的是另一半——「这个亮点星表解释不了
/// 吗」，那一问用的半径是 [catalogGateArcmin]，小得多，而且问的是候选自己的
/// 位置，星历的偏差传不过去。
const double ephemerisToleranceArcmin = 8.0;

/// 判定「这颗亮点能不能被星表解释掉」时，向星表查的半径。
///
/// 要小。它问的是「我已经找到的那个亮点，星表里有没有对应的恒星」，问的是
/// **候选自己**的位置。半径一大，一颗离得很远的恒星也能把行星顶掉。
const double catalogGateArcmin = 2.0;

/// 多大的「非星空」亮斑还够格当行星候选。
///
/// 行星的视面加上曝光过度的那圈光晕，在画面里只占很小一块；占掉一大片的
/// 是被解析开了的延展目标——月亮、窗玻璃、路灯——那是另一回事。没有这个
/// 上限的话，只要行星恰好预报在月亮附近（冲日、掩星前后很容易），月球那
/// 一大团就会被当成那颗行星报出去。
const double _blobAreaFractionLimit = 0.04;

/// 检出至少要有多少置信度才够格被当成行星。
///
/// 和分析层里「值得展示」的门槛是同一个数：低于它的多半是噪声峰，拿噪声去
/// 宣称拍到了行星，比漏报难看得多。
const double _minimumConfidence = 0.25;

/// 容差换算成像素之后的下限。
///
/// 广角拼图上每像素十几个角分，两角分连一个像素都不到；那时容差就成了零，
/// 而检出位置的质心误差本身就有大半个像素。给个下限，让「对得上」这件事
/// 在粗尺度上仍然可能成立。
const double _minimumTolerancePixels = 3.0;

/// 图上够格当行星候选的一个位置。
///
/// 两类：普通星点，以及被判成「非星空」的大亮斑。
class _Candidate {
  const _Candidate({
    required this.x,
    required this.y,
    required this.isBlob,
    this.star,
  });

  final double x;
  final double y;

  /// 是不是「大亮斑」那一类。
  final bool isBlob;

  /// 对应的星点；大亮斑没有星点，为 null。
  final DetectedStar? star;
}

/// 收集候选。
///
/// 大亮斑是刻意收进来的：行星的视面加上曝光过度的那圈光晕够大够亮，会被遮罩
/// 成一块「非星空」区域，于是在星点列表里根本不存在。只看星点，等于「行星越
/// 大越亮越认不出来」——正好把最该认出来的那一种漏掉。
List<_Candidate> _candidatesOf(SkyAnalysis analysis) {
  final frameArea = analysis.width * analysis.height;
  return [
    for (final star in analysis.compactSources)
      if (!star.isRejected && star.confidence >= _minimumConfidence)
        _Candidate(x: star.x, y: star.y, isBlob: false, star: star),
    for (final region in analysis.maskRegions)
      if (region.kind == MaskKind.blob &&
          region.width * region.height <= frameArea * _blobAreaFractionLimit)
        _Candidate(
          x: region.x + region.width / 2,
          y: region.y + region.height / 2,
          isBlob: true,
        ),
  ];
}

/// 在图上找出「星历说在这儿、星表又解释不了」的亮点。
///
/// [hasCatalogStarNear] 由调用方给：星表只在解算那一侧，这里不该知道它的形状。
/// 它的语义是「以 (ra, dec) 为中心、半径 [catalogGateArcmin] 角分内，星表里
/// 有没有一颗星」——有，就说明那颗亮点是恒星，不是行星。
///
/// 两个条件缺一不可，这是刻意的：只看「星表没星」会把噪声、坏点、被拉长的
/// 杂讯都算成行星；只看「位置对得上」会在满场恒星的密集天区里胡说八道。
///
/// 两件事的顺序也是刻意的：**先找候选，再拿候选的位置去问星表**。反过来
/// （先按预测位置问星表）在星历偏出几角分的时候问的就是另一个地方的事，
/// 结果是最该认出来的那颗行星被顶掉，而星历的偏差本来是这套近似根数的
/// 固有性质，不是异常。
List<MovingBodySuspicion> matchMovingBodies({
  required SkyAnalysis analysis,
  required Wcs wcs,
  required List<PredictedBody> predictions,
  required bool Function(double ra, double dec, double radiusArcmin)
      hasCatalogStarNear,
  double? magnitudeZeroPoint,
}) {
  if (predictions.isEmpty) return const [];
  final scale = wcs.arcsecPerPixel;
  if (!scale.isFinite || scale <= 0) return const [];

  // 只取一次：`compactSources` 每读一次都要按轴比过滤一遍全部检出。
  final candidates = _candidatesOf(analysis);
  if (candidates.isEmpty) return const [];

  final findings = <MovingBodySuspicion>[];
  for (final body in predictions) {
    // 容差按天体给（见 [PredictedBody.toleranceArcmin]），所以要在循环里换算，
    // 不能再提到外面算一次。
    final tolerancePixels = math.max(
      _minimumTolerancePixels,
      body.toleranceArcmin * 60 / scale,
    );
    final toleranceSquared = tolerancePixels * tolerancePixels;
    final (x, y) = wcs.worldToPixel(body.ra, body.dec);
    if (!x.isFinite || !y.isFinite) continue;
    // 画面外一个容差以外的天体看不见，无从判断。
    if (x < -tolerancePixels ||
        y < -tolerancePixels ||
        x > analysis.width + tolerancePixels ||
        y > analysis.height + tolerancePixels) {
      continue;
    }

    _Candidate? best;
    var bestRank = 2;
    var bestSquared = double.infinity;
    for (final candidate in candidates) {
      final dx = candidate.x - x;
      final dy = candidate.y - y;
      final squared = dx * dx + dy * dy;
      if (squared > toleranceSquared) continue;
      // 后一半判据：这个候选星表解释不了吗？问的是**它自己**的位置。
      final (ra, dec) = wcs.pixelToWorld(candidate.x, candidate.y);
      if (hasCatalogStarNear(ra, dec, catalogGateArcmin)) continue;
      // 大亮斑压过普通点源，距离只在自己那一档里比。
      //
      // 不这样排的话，实测那张土星照片会圈错地方：土星本体是一块 31×29 的
      // 饱和光斑，而光晕边缘被检出一串 flux≈0 的假点，其中一个离星历预测
      // 位置（16px）比土星本体（24.8px）还近。光晕里全是噪声峰，按距离比，
      // 行星永远输给紧贴着它的噪声；而亮斑本身在画面里很稀有——它一出现，
      // 就是在说「这里有个大家伙」。
      final rank = candidate.isBlob ? 0 : 1;
      final better =
          rank < bestRank || (rank == bestRank && squared < bestSquared);
      if (better) {
        best = candidate;
        bestRank = rank;
        bestSquared = squared;
      }
    }
    if (best == null) continue;

    findings.add(
      MovingBodySuspicion(
        name: body.name,
        ra: body.ra,
        dec: body.dec,
        x: best.x,
        y: best.y,
        separationArcsec: math.sqrt(bestSquared) * scale,
        // 没有星等零点就报 null，而不是报仪器星等：仪器星等是个没有绝对
        // 含义的数，用户拿它和「这颗比天狼星亮」之类的常识对不上。大亮斑
        // 也是一样——它已经曝到饱和，测出来的通量没有意义。
        magnitude: magnitudeZeroPoint == null || best.star == null
            ? null
            : best.star!.instrumentalMagnitude + magnitudeZeroPoint,
        distanceAu: body.distanceAu,
        discDiameterArcsec: body.discDiameterArcsec,
        kind: body.kind,
        magnitudeIsRough: body.magnitudeIsRough,
        catalogBuilt: body.catalogBuilt,
      ),
    );
  }
  return _keepOnlyBestSmallBody(findings);
}

/// 小行星和彗星一次只报一颗，报偏移最小的那颗。
///
/// 行星不用这个：同一张照片上同时拍到木星和土星是可能的，而且两边的位置判据
/// 各自独立（都靠那张近似根数表）。小天体不一样——它们来自一份有 939 颗彗星的
/// 表，8 角分容差下每一颗都独立地有一点随机吻合的机会，报出两颗时「至少有一颗
/// 是错的」的概率已经不是小数。真要出现第二颗，比起多报一个更可能是判据抖了。
///
/// 行星那一档不受影响：它们先按偏移排好，这里只在小天体里挑一颗。
List<MovingBodySuspicion> _keepOnlyBestSmallBody(
  List<MovingBodySuspicion> findings,
) {
  if (findings.length < 2) return findings;
  final small = findings.where((body) => !body.kind.isMajorPlanet).toList();
  if (small.length < 2) return findings;
  small.sort((a, b) => a.separationArcsec.compareTo(b.separationArcsec));
  final keep = small.first;
  return [
    for (final body in findings)
      if (body.kind.isMajorPlanet || identical(body, keep)) body,
  ];
}
