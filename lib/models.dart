import 'dart:math' as math;

/// 数据模型层：只放可序列化的结果对象，不依赖 Flutter UI，便于历史记录存取和单测。
///
/// 这些类型同时被本地检测、天区解算和报告构建使用，所以按“只描述结果”来划分，
/// 一个模型内部不包含算法。

/// 图上检出的一个点源或疑似拉线。
class DetectedStar {
  const DetectedStar(
    this.x,
    this.y,
    this.flux,
    this.instrumentalMagnitude,
    this.confidence,
    this.axisRatio, {
    this.fwhm = 0,
    this.fluxError = 0,
    this.orientation = 0,
    this.isRejected = false,
  });

  final double x;
  final double y;
  final double flux;
  final double instrumentalMagnitude;
  final double confidence;
  final double axisRatio;

  /// 局部点扩散函数半高全宽（像素），来自对同一帧内多个源的统计。
  final double fwhm;

  /// 通量的一倍标准差估计（电子数/相对单位），用于给出星等误差棒。
  final double fluxError;

  /// 长轴方向（弧度，图像坐标系），拉线候选用来画椭圆和判断方向一致性。
  final double orientation;

  /// 用户把拉线候选判为“非天体”（飞机灯、卫星、镜头污点）后置位，报告里会排除。
  final bool isRejected;

  bool get isElongated => axisRatio >= 2.2;

  String get confidenceLabel => confidence >= 0.7
      ? '较可信'
      : confidence >= 0.35
          ? '供参考'
          : '低可信';

  /// 由通量误差换算的星等误差；通量为 0 或误差缺失时返回 null。
  double? get magnitudeError {
    if (flux <= 0 || fluxError <= 0) return null;
    return 1.0857 * fluxError / flux;
  }

  DetectedStar copyWith({bool? isRejected}) => DetectedStar(
        x,
        y,
        flux,
        instrumentalMagnitude,
        confidence,
        axisRatio,
        fwhm: fwhm,
        fluxError: fluxError,
        orientation: orientation,
        isRejected: isRejected ?? this.isRejected,
      );

  Map<String, Object?> toJson() => {
        'x': x,
        'y': y,
        'flux': flux,
        'instrumental_magnitude': instrumentalMagnitude,
        'confidence': confidence,
        'axis_ratio': axisRatio,
        'fwhm': fwhm,
        'flux_error': fluxError,
        'orientation': orientation,
        'is_rejected': isRejected,
      };

  static DetectedStar fromJson(Map<String, Object?> json) => DetectedStar(
        _number(json['x']),
        _number(json['y']),
        _number(json['flux']),
        _number(json['instrumental_magnitude']),
        _number(json['confidence']),
        _number(json['axis_ratio']),
        fwhm: _number(json['fwhm']),
        fluxError: _number(json['flux_error']),
        orientation: _number(json['orientation']),
        isRejected: json['is_rejected'] == true,
      );
}

/// 一个已命名的天体：恒星、星团、星系或星云。
class SkyObject {
  const SkyObject(
    this.name,
    this.ra,
    this.dec,
    this.category, {
    this.magnitude,
    this.magnitudeBand = 'G',
    this.x = 0,
    this.y = 0,
    this.isLocal = false,
    this.angularSizeArcmin,
  });

  final String name;
  final double ra;
  final double dec;
  final String category;
  final double? magnitude;
  final String magnitudeBand;
  final double x;
  final double y;

  /// 该名称来自 APP 内置亮星目录（离线得到），而不是在线星表。
  final bool isLocal;

  /// 天体本身的角尺寸（长轴，角分）。恒星没有这个字段；深空天体有，
  /// 报告里要拿它和像场尺寸比，说明「这个目标占画面多大」。
  final double? angularSizeArcmin;

  SkyObject at(double x, double y) => SkyObject(
        name,
        ra,
        dec,
        category,
        magnitude: magnitude,
        magnitudeBand: magnitudeBand,
        x: x,
        y: y,
        isLocal: isLocal,
        angularSizeArcmin: angularSizeArcmin,
      );

  Map<String, Object?> toJson() => {
        'name': name,
        'ra': ra,
        'dec': dec,
        'category': category,
        'magnitude': magnitude,
        'magnitude_band': magnitudeBand,
        'x': x,
        'y': y,
        'is_local': isLocal,
        'angular_size_arcmin': angularSizeArcmin,
      };

  static SkyObject fromJson(Map<String, Object?> json) => SkyObject(
        json['name'] as String? ?? '未命名',
        _number(json['ra']),
        _number(json['dec']),
        json['category'] as String? ?? '',
        magnitude: _nullableNumber(json['magnitude']),
        magnitudeBand: json['magnitude_band'] as String? ?? 'G',
        x: _number(json['x']),
        y: _number(json['y']),
        isLocal: json['is_local'] == true,
        angularSizeArcmin: _nullableNumber(json['angular_size_arcmin']),
      );
}

/// 一颗与星表匹配上的恒星及其在图像上的投影位置。
class GaiaMatch {
  const GaiaMatch({
    required this.sourceId,
    required this.ra,
    required this.dec,
    required this.x,
    required this.y,
    required this.gMagnitude,
  });

  final String sourceId;
  final double ra;
  final double dec;
  final double x;
  final double y;
  final double gMagnitude;

  Map<String, Object?> toJson() => {
        'source_id': sourceId,
        'ra': ra,
        'dec': dec,
        'x': x,
        'y': y,
        'g_magnitude': gMagnitude,
      };

  static GaiaMatch fromJson(Map<String, Object?> json) => GaiaMatch(
        sourceId: json['source_id'] as String? ?? '',
        ra: _number(json['ra']),
        dec: _number(json['dec']),
        x: _number(json['x']),
        y: _number(json['y']),
        gMagnitude: _number(json['g_magnitude']),
      );
}

/// 一个星座在图像上的连线。
///
/// 连线本身是 HIP 星对，存在后台 isolate 的星表里；而画线要的是像素坐标。
/// 所以投影放在解算侧做完，把已经能直接画的线段随 [SolveResult] 带回界面，
/// 界面不必再持有星表，也不必知道天球坐标怎么换算。
class ConstellationFigure {
  const ConstellationFigure({
    required this.name,
    required this.segments,
    required this.labelX,
    required this.labelY,
  });

  /// 星座名，用中文名，和「星座」指标条上的写法一致。
  final String name;

  /// 线段的图像像素坐标，每条是 `[x1, y1, x2, y2]`。已经裁到图像范围内，
  /// 所以画的时候不用再管越界。
  final List<List<double>> segments;

  /// 星座名标在哪里。取各段中点的平均而不是包围盒中心：连线分布往往是
  /// 一条弯曲的折线，包围盒中心容易落在没有任何线的空白处。
  final double labelX;
  final double labelY;

  Map<String, Object?> toJson() => {
        'name': name,
        'segments': segments,
        'label_x': labelX,
        'label_y': labelY,
      };

  static ConstellationFigure fromJson(Map<String, Object?> json) =>
      ConstellationFigure(
        name: json['name'] as String? ?? '',
        segments: (json['segments'] as List<Object?>? ?? const [])
            .whereType<List<Object?>>()
            .map((row) => row.whereType<num>().map((v) => v.toDouble()).toList())
            .where((row) => row.length == 4)
            .toList(growable: false),
        labelX: _number(json['label_x']),
        labelY: _number(json['label_y']),
      );
}

/// 天球投影（World Coordinate System），同时被在线解算和本地解算产出。
class Wcs {
  const Wcs({
    required this.width,
    required this.height,
    required this.crval1,
    required this.crval2,
    required this.crpix1,
    required this.crpix2,
    required this.cd11,
    required this.cd12,
    required this.cd21,
    required this.cd22,
  });

  final int width;
  final int height;
  final double crval1;
  final double crval2;
  final double crpix1;
  final double crpix2;
  final double cd11;
  final double cd12;
  final double cd21;
  final double cd22;

  /// 由像素坐标构造：给定中心天球坐标和每个像素的角尺度（度/像素），
  /// 生成无旋转、无扭曲的 CD 矩阵。本地解算器求出旋转角后走这里。
  factory Wcs.fromPixels({
    required int width,
    required int height,
    required double centerRa,
    required double centerDec,
    required double degreesPerPixel,
    double rotationRadians = 0,
  }) {
    final scale = degreesPerPixel;
    final cosRotation = math.cos(rotationRadians);
    final sinRotation = math.sin(rotationRadians);
    // 图像坐标 y 轴向下，而天球 eta 轴向北、xi 轴向东，所以零旋转时
    // CD 矩阵是 -s·I：向右是西（赤经减小），向下是南（赤纬减小）。
    return Wcs(
      width: width,
      height: height,
      crval1: centerRa,
      crval2: centerDec,
      crpix1: (width + 1) / 2,
      crpix2: (height + 1) / 2,
      cd11: -scale * cosRotation,
      cd12: -scale * sinRotation,
      cd21: scale * sinRotation,
      cd22: -scale * cosRotation,
    );
  }

  double get determinant => cd11 * cd22 - cd12 * cd21;

  double get arcsecPerPixel =>
      3600 * math.sqrt((cd11 * cd22 - cd12 * cd21).abs());

  /// 视场对角线尺度（度），用于展示“这张照片拍了多大的天区”。
  double get fieldOfViewDegrees {
    final (raLeft, decTop) = pixelToWorld(0, 0);
    final (raRight, decBottom) = pixelToWorld(width.toDouble(), height.toDouble());
    return angularSeparationDegrees(raLeft, decTop, raRight, decBottom);
  }

  /// 把这份坐标换算到另一个像素尺寸的像面上。
  ///
  /// 在线解算要过这一步：astrometry.net 可能先把上传的图缩小再认星（上传时
  /// 的 `downsample_factor`），回来的 NAXIS 和 CRPIX/CD 就都是缩小那一帧的。
  /// 尺寸不一样**不是错误**——按比例换算过来即可。丢掉不换算的话，一次已经
  /// 成功的在线解算会被整条丢弃，用户看到的就是「交给在线服务也算不出来」。
  ///
  /// 换算是按像素中心对齐的（FITS 的 CRPIX 是 1 基、以像素中心为原点），
  /// 所以 CRPIX 走的是 `(c-0.5)·k+0.5`，不是直接乘 k。
  Wcs rescaledTo(int targetWidth, int targetHeight) {
    if (targetWidth == width && targetHeight == height) return this;
    final scaleX = targetWidth / width;
    final scaleY = targetHeight / height;
    return Wcs(
      width: targetWidth,
      height: targetHeight,
      crval1: crval1,
      crval2: crval2,
      crpix1: (crpix1 - 0.5) * scaleX + 0.5,
      crpix2: (crpix2 - 0.5) * scaleY + 0.5,
      // 像面变大，每个像素对应的天球角度就变小，所以是除不是乘。
      cd11: cd11 / scaleX,
      cd12: cd12 / scaleX,
      cd21: cd21 / scaleY,
      cd22: cd22 / scaleY,
    );
  }

  /// 在给定像素位置，天球北方向对应的图像方向（单位向量，y 轴向下）。
  /// 旋转过的照片用它来画 N 指示，不能假定北就是图像正上方。
  (double, double) northDirectionAt(double x, double y) {
    final (ra, dec) = pixelToWorld(x, y);
    // 沿赤纬增加一个极小量，换算回像素，就是北向的像素方向。
    final stepDegrees = math.max(arcsecPerPixel / 3600 * 4, 0.0005);
    final (northX, northY) = worldToPixel(ra, dec + stepDegrees);
    return _normalize(northX - x, northY - y);
  }

  /// 在给定像素位置，天球东方向对应的图像方向（单位向量，y 轴向下）。
  (double, double) eastDirectionAt(double x, double y) {
    final (ra, dec) = pixelToWorld(x, y);
    final stepDegrees = math.max(arcsecPerPixel / 3600 * 4, 0.0005) /
        math.max(math.cos(dec * math.pi / 180).abs(), 1e-3);
    final (eastX, eastY) = worldToPixel(ra + stepDegrees, dec);
    return _normalize(eastX - x, eastY - y);
  }

  static (double, double) _normalize(double dx, double dy) {
    final length = math.sqrt(dx * dx + dy * dy);
    if (length <= 0 || !length.isFinite) return (0, -1);
    return (dx / length, dy / length);
  }

  (double, double) get imageCenter =>
      pixelToWorld((width - 1) / 2, (height - 1) / 2);

  (double, double) pixelToWorld(double x, double y) {
    const radians = math.pi / 180;
    final deltaX = x + 1 - crpix1;
    final deltaY = y + 1 - crpix2;
    final xi = (cd11 * deltaX + cd12 * deltaY) * radians;
    final eta = (cd21 * deltaX + cd22 * deltaY) * radians;
    final rho = math.sqrt(xi * xi + eta * eta);
    if (rho == 0) return (crval1 % 360, crval2);
    final c = math.atan(rho);
    final ra0 = crval1 * radians;
    final dec0 = crval2 * radians;
    final dec = math.asin(
      math.cos(c) * math.sin(dec0) +
          eta * math.sin(c) * math.cos(dec0) / rho,
    );
    final ra = ra0 +
        math.atan2(
          xi * math.sin(c),
          rho * math.cos(dec0) * math.cos(c) -
              eta * math.sin(dec0) * math.sin(c),
        );
    return ((ra / radians) % 360, dec / radians);
  }

  (double, double) worldToPixel(double ra, double dec) {
    const radians = math.pi / 180;
    final ra0 = crval1 * radians;
    final dec0 = crval2 * radians;
    final targetRa = ra * radians;
    final targetDec = dec * radians;
    final deltaRa = wrapRadians(targetRa - ra0);
    final denominator = math.sin(dec0) * math.sin(targetDec) +
        math.cos(dec0) * math.cos(targetDec) * math.cos(deltaRa);
    if (denominator <= 0) return (-1e9, -1e9);
    final xi = math.cos(targetDec) * math.sin(deltaRa) / denominator / radians;
    final eta = (math.cos(dec0) * math.sin(targetDec) -
            math.sin(dec0) * math.cos(targetDec) * math.cos(deltaRa)) /
        denominator /
        radians;
    final dx = (cd22 * xi - cd12 * eta) / determinant;
    final dy = (-cd21 * xi + cd11 * eta) / determinant;
    return (crpix1 + dx - 1, crpix2 + dy - 1);
  }

  Map<String, Object?> toJson() => {
        'width': width,
        'height': height,
        'crval1': crval1,
        'crval2': crval2,
        'crpix1': crpix1,
        'crpix2': crpix2,
        'cd11': cd11,
        'cd12': cd12,
        'cd21': cd21,
        'cd22': cd22,
      };

  static Wcs fromJson(Map<String, Object?> json) => Wcs(
        width: (_nullableNumber(json['width']) ?? 0).round(),
        height: (_nullableNumber(json['height']) ?? 0).round(),
        crval1: _number(json['crval1']),
        crval2: _number(json['crval2']),
        crpix1: _number(json['crpix1']),
        crpix2: _number(json['crpix2']),
        cd11: _number(json['cd11']),
        cd12: _number(json['cd12']),
        cd21: _number(json['cd21']),
        cd22: _number(json['cd22']),
      );

  /// 解析 FITS 头（astrometry.net 的 wcs_file 接口返回）。
  static Wcs parseFitsHeader(List<int> bytes) {
    final values = <String, String>{};
    var offset = 0;
    var ended = false;
    final asciiText = String.fromCharCodes(
      bytes.map((byte) => byte < 128 ? byte : 32),
    );
    while (offset + 80 <= asciiText.length && !ended) {
      final card = asciiText.substring(offset, offset + 80);
      offset += 80;
      final key = card.substring(0, 8).trim();
      if (key == 'END') {
        ended = true;
      } else if (card.substring(8, 10) == '= ') {
        values[key] = card.substring(10, 80).split('/').first.trim();
      }
    }
    if (!ended) throw const FormatException('星图解算没有返回有效 FITS 天球坐标。');
    double number(String key) {
      final raw = values[key]?.replaceAll('D', 'E');
      final value = raw == null ? null : double.tryParse(raw);
      if (value == null || !value.isFinite) {
        throw FormatException('解算结果缺少有效的 $key。');
      }
      return value;
    }

    final width = int.tryParse(values['NAXIS1'] ?? '');
    final height = int.tryParse(values['NAXIS2'] ?? '');
    if (width == null || height == null) throw const FormatException('解算结果缺少有效图像尺寸。');
    return Wcs(
      width: width,
      height: height,
      crval1: number('CRVAL1'),
      crval2: number('CRVAL2'),
      crpix1: number('CRPIX1'),
      crpix2: number('CRPIX2'),
      cd11: number('CD1_1'),
      cd12: number('CD1_2'),
      cd21: number('CD2_1'),
      cd22: number('CD2_2'),
    );
  }
}

/// 天区解算的最终产出，附带匹配星表和测光标定。
class SolveResult {
  const SolveResult({
    required this.centerRa,
    required this.centerDec,
    required this.arcsecPerPixel,
    required this.namedStars,
    required this.deepSkyObjects,
    required this.matchedStars,
    required this.magnitudeZeroPoint,
    required this.magnitudeScatter,
    required this.catalogWarning,
    this.source = SolveSource.online,
    this.fieldOfViewDegrees = 0,
    this.constellations = const [],
    this.constellationFigures = const [],
    this.wcs,
    this.rotationDegrees = 0,
    this.matchedCount = 0,
  });

  final double centerRa;
  final double centerDec;
  final double arcsecPerPixel;
  final List<SkyObject> namedStars;
  final List<SkyObject> deepSkyObjects;
  final List<GaiaMatch> matchedStars;
  final double? magnitudeZeroPoint;
  final double? magnitudeScatter;
  final String? catalogWarning;

  /// 结果来自 APP 本地解算还是 astrometry.net，UI 上要如实区分。
  final SolveSource source;

  /// 视场对角线尺度（度）。
  final double fieldOfViewDegrees;

  /// 视场内出现的星座名称（按视场内亮星数量排序）。
  final List<String> constellations;

  /// 视场内星座连线的像素坐标，已经过 WCS 投影和裁剪，可以直接画。
  final List<ConstellationFigure> constellationFigures;

  /// 保留原始 WCS，供叠加星座连线、画方向指示和比例尺使用。
  final Wcs? wcs;

  /// 图像的旋转角（度），0 表示北向上。
  final double rotationDegrees;

  /// 与星表成功匹配的星数，用于展示解算质量。
  final int matchedCount;

  static const empty = SolveResult(
    centerRa: 0,
    centerDec: 0,
    arcsecPerPixel: 0,
    namedStars: [],
    deepSkyObjects: [],
    matchedStars: [],
    magnitudeZeroPoint: null,
    magnitudeScatter: null,
    catalogWarning: null,
  );

  /// 把用户手动剔除的拉线候选过滤掉，报告和星表匹配都以过滤后的结果为准。
  SolveResult withoutRejected(List<DetectedStar> stars) {
    final rejected = stars.where((star) => star.isRejected).toList();
    if (rejected.isEmpty) return this;
    bool isRejected(SkyObject object) => rejected.any(
          (star) =>
              (star.x - object.x).abs() < 0.01 && (star.y - object.y).abs() < 0.01,
        );
    return SolveResult(
      centerRa: centerRa,
      centerDec: centerDec,
      arcsecPerPixel: arcsecPerPixel,
      namedStars: namedStars.where((object) => !isRejected(object)).toList(),
      deepSkyObjects: deepSkyObjects,
      matchedStars: matchedStars,
      magnitudeZeroPoint: magnitudeZeroPoint,
      magnitudeScatter: magnitudeScatter,
      catalogWarning: catalogWarning,
      source: source,
      fieldOfViewDegrees: fieldOfViewDegrees,
      constellations: constellations,
      constellationFigures: constellationFigures,
      wcs: wcs,
      rotationDegrees: rotationDegrees,
      matchedCount: matchedCount,
    );
  }

  /// 补上星座信息（以及顺带补好的深空天体角尺寸）。
  ///
  /// 在线解算只带回 WCS，星座名和连线是本机用目录算的，所以拿到结果之后
  /// 还要再装饰一道。不带 WCS 的结果原样返回——没有坐标就无从投影。
  SolveResult withConstellationDecoration(
    List<String> names,
    List<ConstellationFigure> figures, {
    List<SkyObject>? deepSkyObjects,
  }) =>
      SolveResult(
        centerRa: centerRa,
        centerDec: centerDec,
        arcsecPerPixel: arcsecPerPixel,
        namedStars: namedStars,
        deepSkyObjects: deepSkyObjects ?? this.deepSkyObjects,
        matchedStars: matchedStars,
        magnitudeZeroPoint: magnitudeZeroPoint,
        magnitudeScatter: magnitudeScatter,
        catalogWarning: catalogWarning,
        source: source,
        fieldOfViewDegrees: fieldOfViewDegrees,
        constellations: names,
        constellationFigures: figures,
        wcs: wcs,
        rotationDegrees: rotationDegrees,
        matchedCount: matchedCount,
      );

  Map<String, Object?> toJson() => {
        'center_ra_deg': centerRa,
        'center_dec_deg': centerDec,
        'arcsec_per_pixel': arcsecPerPixel,
        'named_stars': namedStars.map((object) => object.toJson()).toList(),
        'deep_sky_objects': deepSkyObjects.map((object) => object.toJson()).toList(),
        'matched_stars': matchedStars.map((match) => match.toJson()).toList(),
        'magnitude_zero_point': magnitudeZeroPoint,
        'magnitude_scatter': magnitudeScatter,
        'catalog_warning': catalogWarning,
        'source': source.name,
        'field_of_view_degrees': fieldOfViewDegrees,
        'constellations': constellations,
        'constellation_figures':
            constellationFigures.map((figure) => figure.toJson()).toList(),
        'wcs': wcs?.toJson(),
        'rotation_degrees': rotationDegrees,
        'matched_count': matchedCount,
      };

  static SolveResult fromJson(Map<String, Object?> json) => SolveResult(
        centerRa: _number(json['center_ra_deg']),
        centerDec: _number(json['center_dec_deg']),
        arcsecPerPixel: _number(json['arcsec_per_pixel']),
        namedStars: _objectList(json['named_stars'], SkyObject.fromJson),
        deepSkyObjects:
            _objectList(json['deep_sky_objects'], SkyObject.fromJson),
        matchedStars: _objectList(json['matched_stars'], GaiaMatch.fromJson),
        magnitudeZeroPoint: _nullableNumber(json['magnitude_zero_point']),
        magnitudeScatter: _nullableNumber(json['magnitude_scatter']),
        catalogWarning: json['catalog_warning'] as String?,
        source: SolveSource.values.firstWhere(
          (value) => value.name == json['source'],
          orElse: () => SolveSource.online,
        ),
        fieldOfViewDegrees: _number(json['field_of_view_degrees']),
        constellations: (json['constellations'] as List<Object?>? ?? const [])
            .whereType<String>()
            .toList(),
        constellationFigures: _objectList(
          json['constellation_figures'],
          ConstellationFigure.fromJson,
        ),
        wcs: json['wcs'] is Map
            ? Wcs.fromJson(Map<String, Object?>.from(json['wcs']! as Map))
            : null,
        rotationDegrees: _number(json['rotation_degrees']),
        matchedCount: (_nullableNumber(json['matched_count']) ?? 0).round(),
      );
}

/// 解算来源。UI 需要明确告诉用户“这是本机算出来的”还是“在线服务算出来的”。
enum SolveSource {
  local('本机离线解算'),
  online('Astrometry.net 在线解算');

  const SolveSource(this.label);

  final String label;
}

/// 用户配置的模型参数。
class ModelSettings {
  const ModelSettings({
    required this.baseUrl,
    required this.lightKey,
    required this.lightModel,
    required this.strongKey,
    required this.strongModel,
  });

  final String baseUrl;
  final String lightKey;
  final String lightModel;
  final String strongKey;
  final String strongModel;

  bool get hasAnyModel => lightKey.trim().isNotEmpty || strongKey.trim().isNotEmpty;
}

/// 拍摄元信息，尽量从图片里读出来；读不到时字段为空，不猜。
///
/// 目前真正用到、也真正会填的只有**时间**三件套（[timestamp]、
/// [timestampOffsetMinutes]、[timestampSource]）——算行星位置需要它。其余字段
/// 是预留的：读出来之前不填，也不为了让卡片好看而猜一个。
class CaptureMetadata {
  const CaptureMetadata({
    this.timestamp,
    this.timestampOffsetMinutes,
    this.timestampSource,
    this.iso,
    this.exposure,
    this.fNumber,
    this.focalLength,
    this.device,
  });

  /// 拍摄时间，ISO-8601，**不带时区**（`2026-10-15T21:34:07`）。
  /// 时区单独放在 [timestampOffsetMinutes] 里，因为 EXIF 的时间本来就没有。
  final String? timestamp;

  /// 上面那个时间相对 UTC 的偏移（分钟）。为空表示时区未知。
  final int? timestampOffsetMinutes;

  /// 时间是从哪儿来的，取值见 `CaptureTimeSource` 的名字。
  final String? timestampSource;

  final String? iso;
  final String? exposure;
  final String? fNumber;
  final String? focalLength;
  final String? device;

  bool get isEmpty => timestamp == null && device == null && exposure == null;

  Map<String, Object?> toJson() => {
        'timestamp': timestamp,
        'timestamp_offset_minutes': timestampOffsetMinutes,
        'timestamp_source': timestampSource,
        'iso': iso,
        'exposure': exposure,
        'f_number': fNumber,
        'focal_length': focalLength,
        'device': device,
      };

  static CaptureMetadata fromJson(Map<String, Object?> json) => CaptureMetadata(
        timestamp: json['timestamp'] as String?,
        timestampOffsetMinutes: (json['timestamp_offset_minutes'] as num?)
            ?.toInt(),
        timestampSource: json['timestamp_source'] as String?,
        iso: json['iso'] as String?,
        exposure: json['exposure'] as String?,
        fNumber: json['f_number'] as String?,
        focalLength: json['focal_length'] as String?,
        device: json['device'] as String?,
      );
}

/// 把角度归一到 (-π, π]。
double wrapRadians(double value) {
  while (value > math.pi) {
    value -= 2 * math.pi;
  }
  while (value < -math.pi) {
    value += 2 * math.pi;
  }
  return value;
}

/// 两点间的球面角距（度）。
double angularSeparationDegrees(
  double ra1,
  double dec1,
  double ra2,
  double dec2,
) {
  const radians = math.pi / 180;
  final deltaRa = wrapRadians((ra1 - ra2) * radians);
  final deltaDec = (dec1 - dec2) * radians;
  final a = math.pow(math.sin(deltaDec / 2), 2) +
      math.cos(dec1 * radians) *
          math.cos(dec2 * radians) *
          math.pow(math.sin(deltaRa / 2), 2);
  return 2 * math.asin(math.sqrt(a.clamp(0.0, 1.0))) / radians;
}

/// 赤经按小时/分/秒输出，天文爱好者更习惯这种写法。
String formatRa(double degrees) {
  final hours = ((degrees % 360) / 15);
  final h = hours.floor();
  final minutes = (hours - h) * 60;
  final m = minutes.floor();
  final seconds = (minutes - m) * 60;
  return '${h.toString().padLeft(2, '0')}h ${m.toString().padLeft(2, '0')}m ${seconds.toStringAsFixed(1)}s';
}

/// 赤纬按度/分/秒输出，带正负号。
String formatDec(double degrees) {
  final sign = degrees < 0 ? '-' : '+';
  final absolute = degrees.abs();
  final d = absolute.floor();
  final minutes = (absolute - d) * 60;
  final m = minutes.floor();
  final seconds = (minutes - m) * 60;
  return '$sign${d.toString().padLeft(2, '0')}° '
      '${m.toString().padLeft(2, '0')}′ '
      '${seconds.toStringAsFixed(1)}″';
}

/// 视场大小用“度”或“角分”展示，小于 1 度时换成角分更好读。
String formatFieldOfView(double degrees) {
  if (degrees <= 0) return '未知';
  if (degrees < 1) return '${(degrees * 60).toStringAsFixed(1)} 角分';
  return '${degrees.toStringAsFixed(2)}°';
}

double _number(Object? value) => _nullableNumber(value) ?? 0;

double? _nullableNumber(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

List<T> _objectList<T>(Object? value, T Function(Map<String, Object?>) fromJson) {
  if (value is! List) return <T>[];
  return value
      .whereType<Map<Object?, Object?>>()
      .map((item) => fromJson(Map<String, Object?>.from(item)))
      .toList(growable: false);
}
