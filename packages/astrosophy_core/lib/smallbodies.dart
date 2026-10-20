import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'strings.dart';
import 'ephemeris.dart';
import 'models.dart';
import 'moving.dart';
import 'orbit.dart';

/// 内置的小天体目录：亮小行星、矮行星、彗星。
///
/// 数据由 `tools/build_smallbodies.py` 离线生成，来源是 JPL 的小行星数据库接口
/// （根数、绝对星等 H、斜率 G、直径）和国际小行星中心的彗星根数表（q、e、i、ω、
/// Ω、过近日点时刻 Tp、M1、k1）。
///
/// ## 为什么只有这一小撮
///
/// MPC 的整份小行星星表有 140 万颗，压缩后 89 MB。手机照片上够得着的是视星等
/// ≲ 13 等的那一小撮：内置的 16 颗亮小行星最亮时全部在 6.5–12.5 等之间，其余
/// 一百多万颗永远不可能出现在候选里，进来只是每张图白算一遍。
///
/// **彗星反过来，必须全收**：新的亮彗星是这套判据最值得报的东西，而它恰恰是每年
/// 才冒出来一两个、事前不知道是哪颗的。全部 939 颗只占 191 KB，比一颗小行星的
/// 误差都便宜。
///
/// ## 精度：真正的短板是「表有多旧」，不是算法
///
/// 两体传播对 JPL Horizons 实测（在根数历元附近 ±60 天）：
///
/// * 小行星：灶神星当天 0.17′、+1 年 0.08′、+3 年 1.60′；谷神星 +1 年 0.69′、
///   +3 年 19.8′、+10 年 34.7′。
/// * 彗星近抛物线那一支（Barker 方程）：C/2013 A1 0.34′、C/2013 US10 1.24′、
///   C/2004 B1 5.85′（这颗离地球 40 AU，误差大是因为它太远）。
///
/// 也就是说模型本身好于 1 角分，**漂移全靠表变旧**。所以：
///
///   * 小行星的位置容差收到 4 角分（够宽到容下三五年内 1.6′ 的漂移，又比行星
///     那张近似根数表需要的 8 角分紧）；
///   * 彗星仍用 8 角分——彗星的根数质量参差得多，实测里有 5.85′ 这种。
///     一个例子：C/1942 EA 的 MPC 根数和 Horizons 的编目根数在同一个历元上
///     日心距就差 0.6 AU，位置差 90′。差的是**数据**，不是传播。
///   * 表里的历元必须跟着数据一起发出去（[SmallBodyCatalog.built]），报告里要写。
class SmallBody {
  const SmallBody({
    required this.kind,
    required this.name,
    required this.designation,
    this.epoch,
    this.semiMajorAxis,
    this.eccentricity,
    this.inclination,
    this.nodeLongitude,
    this.perihelionArgument,
    this.meanAnomaly,
    this.perihelionDistance,
    this.perihelionTime,
    this.absoluteMagnitude,
    this.slopeParameter,
    this.nuclearMagnitude,
    this.magnitudeSlope,
    this.magnitudeIsDefault = false,
    this.diameterKm,
  });

  final BodyKind kind;

  /// 中文名，直接给用户看。
  final String name;

  /// 正式编号（「4 Vesta」「C/2023 A3 (Tsuchinshan-ATLAS)」）。
  final String designation;

  /// 小行星／矮行星：根数历元（TT 儒略日）。
  final double? epoch;

  final double? semiMajorAxis;
  final double? eccentricity;
  final double? inclination;
  final double? nodeLongitude;
  final double? perihelionArgument;
  final double? meanAnomaly;

  /// 彗星：近日点距离（天文单位）。
  final double? perihelionDistance;

  /// 彗星：过近日点时刻（TT 儒略日）。
  ///
  /// 存成儒略日而不是日期字符串：传播要按天算，字符串每读一次都要解析一次，
  /// 而这条链路上每张图要遍历几百颗彗星。
  final double? perihelionTime;

  /// 小行星／矮行星的绝对星等 H。
  final double? absoluteMagnitude;

  /// 小行星／矮行星的 H/G 相位律斜率 G。
  final double? slopeParameter;

  /// 彗星的核星等 M1。
  final double? nuclearMagnitude;

  /// 彗星的光度指数 k1。
  final double? magnitudeSlope;

  /// 彗星的 k1 是不是 MPC 填的缺省值。
  final bool magnitudeIsDefault;

  /// 直径，公里。彗星的核没有可靠的直径，为 null。
  final double? diameterKm;

  /// 视星等能不能当个数报出去。
  ///
  /// 彗星的 k1 有八成是 MPC 填的缺省值 4.0，用缺省值算出来的亮度可能差好几等。
  /// 这种值照样拿来筛「够不够亮」，但不写进报告。
  bool get magnitudeIsReliable => !(kind == BodyKind.comet && magnitudeIsDefault);

  static SmallBody fromJson(Map<String, Object?> json) {
    final comet = json['kind'] == 'comet';
    return SmallBody(
      kind: comet
          ? BodyKind.comet
          : (json['kind'] == 'dwarf_planet'
              ? BodyKind.dwarfPlanet
              : BodyKind.asteroid),
      name: json['name'] as String? ?? t('未命名'),
      designation: json['designation'] as String? ?? '',
      epoch: _number(json['epoch']),
      semiMajorAxis: _number(json['a']),
      eccentricity: _number(json['e']),
      inclination: _number(json['i']),
      nodeLongitude: _number(json['om']),
      perihelionArgument: _number(json['w']),
      meanAnomaly: _number(json['ma']),
      perihelionDistance: _number(json['q']),
      perihelionTime: _number(json['tp']),
      absoluteMagnitude: _number(json['H']),
      slopeParameter: _number(json['G']),
      nuclearMagnitude: _number(json['M1']),
      magnitudeSlope: comet ? _number(json['k1']) : null,
      magnitudeIsDefault: json['magnitude_is_default'] == true,
      diameterKm: _number(json['diameter_km']),
    );
  }
}

/// 内置小天体目录。
class SmallBodyCatalog {
  SmallBodyCatalog._(this.components, this.comets, this.built);

  /// 亮小行星与矮行星。数量少、根数稳，所以每一颗都值得单独说一句话。
  final List<SmallBody> components;

  /// 全部彗星。只在亮度够的时候才参与比对。
  final List<SmallBody> comets;

  /// 这份表的构建日期（ISO，``YYYY-MM-DD``）。报告里要写出来：内置表会过时，
  /// 而「今天是哪一天」正是判断这份位置还能不能用的唯一依据。
  final String built;

  static SmallBodyCatalog parse(String json) {
    final root = jsonDecode(json);
    if (root is! Map) return SmallBodyCatalog._(const [], const [], '');
    return SmallBodyCatalog._(
      [
        for (final row in (root['bodies'] as List<Object?>? ?? const []))
          SmallBody.fromJson((row as Map).cast<String, Object?>()),
      ],
      [
        for (final row in (root['comets'] as List<Object?>? ?? const []))
          SmallBody.fromJson((row as Map).cast<String, Object?>()),
      ],
      root['built'] as String? ?? '',
    );
  }

  static Future<SmallBodyCatalog> loadFile(String path) async =>
      parse(await File(path).readAsString());

  bool get isEmpty => components.isEmpty && comets.isEmpty;

  /// 全部天体，先小行星矮行星、后彗星。给「按名字查」用。
  List<SmallBody> get all => [...components, ...comets];

  /// 按名字或编号查一颗天体。查不到返回 null。
  ///
  /// 同时认中文名（「灶神星」）、编号（「4」「Vesta」「C/2023 A3」）和正式全名，
  /// 大小写不敏感，前后空格无所谓。Nox 的 `find_small_body` 靠它把用户说的
  /// 「灶神星」认出来。
  ///
  /// 分四轮，从最严到最松：先逐字相等（走一遍就够，绝大多数查询在这里命中），
  /// 再按编号前缀，再按编号里出现过的子串，最后才在中文名里找子串。顺序不能
  /// 反——「4」这种输入要是先走子串匹配，会先命中 433 或 511 这类编号里带 4
  /// 的天体，而用户想查的就是第 4 号。
  SmallBody? find(String query) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return null;
    for (final body in all) {
      if (body.name.toLowerCase() == needle) return body;
      if (body.designation.toLowerCase() == needle) return body;
    }
    for (final body in all) {
      if (body.designation.toLowerCase().startsWith(needle)) return body;
    }
    for (final body in all) {
      if (body.designation.toLowerCase().contains(needle)) return body;
    }
    for (final body in all) {
      if (body.name.toLowerCase().contains(needle)) return body;
    }
    return null;
  }

  /// [moment] 时刻够亮、且离太阳够远的小天体的预测位置。
  ///
  /// 两步的顺序是有讲究的：**先按亮度筛，再算位置**。反过来的话，每张图都要
  /// 把 939 颗彗星全拿去和检出比对——8 角分容差下，随机吻合的期望个数会到 4.6
  /// 个左右。按当时的亮度先筛，工作集掉到 80 上下，期望降到 0.4。
  ///
  /// 不能筛掉的还有一种：离太阳很近的天体（大距小的彗星，尤其是掠日彗星）。
  /// 它可能亮得离谱，但它只在白天的天空中——夜里拍的照片上根本不可能有它，
  /// 留着它只是白送一次误报的机会。
  List<PredictedBody> visibleBodies(
    DateTime moment, {
    required double sunRa,
    required double sunDec,
    double limitMagnitude = smallBodyMagnitudeLimit,
    double minimumElongationDegrees = smallBodyMinimumElongationDegrees,
  }) {
    final found = <PredictedBody>[];
    for (final body in all) {
      final magnitude = magnitudeOf(body, moment);
      if (magnitude == null || magnitude > limitMagnitude) continue;
      final position = positionOf(body, moment);
      if (position == null) continue;
      if (sunRa.isFinite && sunDec.isFinite) {
        final elongation = angularSeparationDegrees(
          sunRa,
          sunDec,
          position.ra,
          position.dec,
        );
        if (elongation < minimumElongationDegrees) continue;
      }
      found.add(
        PredictedBody(
          name: body.name,
          ra: position.ra,
          dec: position.dec,
          distanceAu: position.distanceAu,
          kind: body.kind,
          magnitude: magnitude,
          magnitudeIsRough: !body.magnitudeIsReliable,
          toleranceArcmin: body.kind == BodyKind.comet
              ? cometToleranceArcmin
              : smallBodyToleranceArcmin,
        ),
      );
    }
    return found;
  }

  /// 够亮的天体里最亮的 [limit] 颗，按亮度从亮到暗。
  ///
  /// 报告用来回答「今天这片天区里有哪颗小行星值得一看」，而不是把所有够亮的天体
  /// 都倒出来。够亮的有一百多颗，全列出来等于没列。
  List<({SmallBody body, double magnitude})> brightest(
    DateTime moment, {
    int limit = 5,
    double limitMagnitude = smallBodyMagnitudeLimit,
  }) {
    final found = <({SmallBody body, double magnitude})>[];
    for (final body in all) {
      final magnitude = magnitudeOf(body, moment);
      if (magnitude == null || magnitude > limitMagnitude) continue;
      found.add((body: body, magnitude: magnitude));
    }
    found.sort((a, b) => a.magnitude.compareTo(b.magnitude));
    return found.take(limit).toList();
  }
}

/// 视星等筛选门槛。
///
/// 实测（对全部 939 颗彗星逐颗算峰值亮度）：亮到 13 等以内的有 84 颗，按 8 角分
/// 容差算，随机吻合的期望是 0.41 个；放到 16 等就有 198 颗、期望 0.97 个，一次
/// 误报就够难看。14 等是这个门槛在「不漏彗星」和「不瞎报」之间的位置——它对应
/// 约 111 颗。
const double smallBodyMagnitudeLimit = 14.0;

/// 小天体和太阳至少隔开多少度才值得比对。
///
/// 大距以内的天体只在暮光或白天的天空中，夜里拍的照片上不会有，留着它只是白送
/// 一次误报的机会。20° 是「天已经黑透了」的大致界线。
const double smallBodyMinimumElongationDegrees = 20.0;

/// 小行星和矮行星允许的位置偏差，角分。
///
/// 4 而不是行星那套的 8：这批根数是 JPL 逐颗维护的，实测三五年内的漂移在 1.6′
/// 以内，用不着借 8′ 那么宽——容差每放宽一倍，随机吻合的机会就多三倍。
const double smallBodyToleranceArcmin = 4.0;

/// 彗星允许的位置偏差，角分。和行星同一档：彗星根数质量参差得多，实测里有
/// 5.85′ 的（C/2004 B1）。收紧了会把真彗星挡在门外。
const double cometToleranceArcmin = 8.0;

/// 手机照片大致能记到多暗。
///
/// 比它暗的天体即使位置算得再准也没意义，报告就只写「它今天在这儿，但拍不到」，
/// 而不是假装看不出它。
const double smallBodyPhotoLimitMagnitude = 13.0;

/// [moment] 时刻 [body] 的地心赤道位置。算不出来返回 null。
EquatorialPosition? positionOf(SmallBody body, DateTime moment) {
  final time = julianDay(moment);
  final earth = heliocentricPosition(
    earthMoonBarycentre,
    julianCenturies(time),
  );
  final heliocentric = heliocentricPositionOf(body, time);
  if (heliocentric == null) return null;
  return equatorialFromEcliptic(
    PositionVector(
      heliocentric.x - earth.x,
      heliocentric.y - earth.y,
      heliocentric.z - earth.z,
    ),
  );
}

/// [body] 在儒略日 [time] 的日光心黄道位置。
///
/// 两条分支，按「根数里给的是平近点角还是过近日点时刻」分：
///
///   * 小行星、矮行星、偏心率 < 1 的彗星：解椭圆开普勒方程；
///   * 偏心率 ≥ 1 的彗星：解 Barker 方程（抛物线）。全部 939 颗里 114 颗走这条，
///     构建时已经滤掉了 e > 1.05 的那一颗（1I/'Oumuamua，需要真双曲解法）。
PositionVector? heliocentricPositionOf(SmallBody body, double time) {
  final eccentricity = body.eccentricity;
  final inclination = body.inclination;
  final node = body.nodeLongitude;
  final argument = body.perihelionArgument;
  if (eccentricity == null || inclination == null || node == null || argument == null) {
    return null;
  }

  final perihelionTime = body.perihelionTime;
  if (perihelionTime != null) {
    final perihelionDistance = body.perihelionDistance;
    if (perihelionDistance == null || perihelionDistance <= 0) return null;
    final days = time - perihelionTime;
    final double trueAnomaly;
    final double distance;
    if (eccentricity < 1.0) {
      final state = ellipticState(
        perihelionDistanceAu: perihelionDistance,
        eccentricity: eccentricity,
        daysFromPerihelion: days,
      );
      trueAnomaly = state.trueAnomalyDegrees;
      distance = state.distanceAu;
    } else {
      final state = parabolicState(
        perihelionDistanceAu: perihelionDistance,
        daysFromPerihelion: days,
      );
      trueAnomaly = state.trueAnomalyDegrees;
      distance = state.distanceAu;
    }
    return _orbitPlaneToEcliptic(
      inclinationDegrees: inclination,
      nodeLongitudeDegrees: node,
      perihelionArgumentDegrees: argument,
      trueAnomalyDegrees: trueAnomaly,
      radius: distance,
    );
  }

  final semiMajorAxis = body.semiMajorAxis;
  final meanAnomaly = body.meanAnomaly;
  final epoch = body.epoch;
  if (semiMajorAxis == null || meanAnomaly == null || epoch == null) return null;
  if (semiMajorAxis <= 0 || eccentricity < 0 || eccentricity >= 1) return null;
  final motion = 0.9856076686 / math.pow(semiMajorAxis, 1.5);
  return heliocentricFromElements(
    semiMajorAxis: semiMajorAxis,
    eccentricity: eccentricity,
    inclinationDegrees: inclination,
    nodeLongitudeDegrees: node,
    perihelionArgumentDegrees: argument,
    meanAnomalyDegrees: meanAnomaly + motion * (time - epoch),
  );
}

/// [moment] 时刻 [body] 的视星等。算不出来返回 null。
///
/// 两条不同的亮度律，不能混：
///
///   * 小行星和矮行星用 **H/G 相位律**，把「冲日附近比平时亮」这件事按相位角算
///     进去。少了这一项，同一颗小行星在冲日和方照会差一两等。
///   * 彗星用 **M1/k1 律**。它和 H/G 不一样，而且是**活动**亮度的经验式——彗核
///     本身暗得多，看到的亮是彗发散射出来的。所以彗星的亮度天然比小行星难报。
double? magnitudeOf(SmallBody body, DateTime moment) {
  final time = julianDay(moment);
  final heliocentric = heliocentricPositionOf(body, time);
  if (heliocentric == null) return null;
  final earth = heliocentricPosition(
    earthMoonBarycentre,
    julianCenturies(time),
  );
  final geocentric = PositionVector(
    heliocentric.x - earth.x,
    heliocentric.y - earth.y,
    heliocentric.z - earth.z,
  );
  final sunDistance = heliocentric.distance;
  final earthDistance = geocentric.distance;
  if (sunDistance <= 0 || earthDistance <= 0) return null;

  final cometMagnitude = body.nuclearMagnitude;
  final cometSlope = body.magnitudeSlope;
  if (cometMagnitude != null && cometSlope != null) {
    return cometMagnitude +
        5 * _log10(earthDistance) +
        2.5 * cometSlope * _log10(math.max(sunDistance, 0.02));
  }

  final absolute = body.absoluteMagnitude;
  if (absolute == null) return null;
  final slope = body.slopeParameter ?? 0.15;
  // 相位角：日—天体—地 的夹角，余弦定理。
  final cosPhase =
      (sunDistance * sunDistance + earthDistance * earthDistance - 1) /
          (2 * sunDistance * earthDistance);
  final phase = math.acos(cosPhase.clamp(-1.0, 1.0));
  final halfTangent = math.tan(phase / 2);
  final first = math.exp(-3.33 * math.pow(halfTangent, 0.63).toDouble());
  final second = math.exp(-1.87 * math.pow(halfTangent, 1.22).toDouble());
  final phaseFunction = (1 - slope) * first + slope * second;
  return absolute +
      5 * _log10(sunDistance * earthDistance) -
      2.5 * _log10(math.max(phaseFunction, 1e-12));
}

/// 轨道平面里的 (r, ν) 转黄道直角坐标。
///
/// 和 `orbit.dart` 里 [heliocentricFromElements] 的最后一步是同一件事，但那边
/// 是从平近点角出发的；彗星那条路手里直接就是真近点角，没必要绕回去再解一次
/// 开普勒方程——绕回去还会在 e ≈ 1 时把精度丢掉。
PositionVector _orbitPlaneToEcliptic({
  required double inclinationDegrees,
  required double nodeLongitudeDegrees,
  required double perihelionArgumentDegrees,
  required double trueAnomalyDegrees,
  required double radius,
}) {
  const perDegree = math.pi / 180;
  final radians = trueAnomalyDegrees * perDegree;
  final xOrbital = radius * math.cos(radians);
  final yOrbital = radius * math.sin(radians);

  final inclination = inclinationDegrees * perDegree;
  final argument = perihelionArgumentDegrees * perDegree;
  final node = nodeLongitudeDegrees * perDegree;
  final cosArgument = math.cos(argument);
  final sinArgument = math.sin(argument);
  final cosNode = math.cos(node);
  final sinNode = math.sin(node);
  final cosInclination = math.cos(inclination);
  final sinInclination = math.sin(inclination);

  return PositionVector(
    (cosArgument * cosNode - sinArgument * sinNode * cosInclination) * xOrbital +
        (-sinArgument * cosNode - cosArgument * sinNode * cosInclination) *
            yOrbital,
    (cosArgument * sinNode + sinArgument * cosNode * cosInclination) * xOrbital +
        (-sinArgument * sinNode + cosArgument * cosNode * cosInclination) *
            yOrbital,
    (sinArgument * sinInclination) * xOrbital +
        (cosArgument * sinInclination) * yOrbital,
  );
}

double _log10(double value) => math.log(value) / math.ln10;

double? _number(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}
