import 'dart:math' as math;
import 'dart:typed_data';

import 'analysis.dart';
import 'catalog.dart';
import 'models.dart';

/// 本机离线天区解算（lost-in-space plate solving）。
///
/// 四步，全部在手机上完成，不需要联网：
///
/// 1. **建索引**：为目录里每颗星找**角距最近**的若干颗邻居，从中两两三点
///    组成三角形。三角形用「次长边/最短边」和「最长边/最短边」两个比值
///    当指纹——它们对平移、旋转、缩放、翻转都不敏感。
/// 2. **取图内三角形**：从检出的星点里挑最亮的若干颗当种子，每颗同样取
///    它**最近的**若干邻居组三角形。
/// 3. **粗匹配**：指纹对上了就得到三点对应关系，据此解出「像素坐标 →
///    切平面坐标」的相似变换。
/// 4. **验证精修**：把目录星投影回图像数内点，够多就接受，再用全部内点
///    最小二乘，并迭代把切点挪到像面中心。
///
/// 两边都按「最近邻居」而不是「最亮邻居」组三角形，是整个算法能对任意
/// 视场尺寸都成立的关键：最近邻居给出的三角形边长自动等于当地的星间
/// 距，而全天星表大致均匀，所以图内和目录两侧的三角形尺度天然接近。
/// 若换成「最亮的 N 颗」，广角照片里最亮的星彼此隔着十几度，窄视场里
/// 最亮的星又都在视场外，两种极端都会让两侧的三角形尺度对不上。
///
/// 一个关键的近似：目录三角形的比值用**球面角距**算，图内三角形的比值用
/// **像素距离**算。两者在 TAN 投影下相差 O(θ²)（θ 是离切点的角距），对
/// 几度的视场只有万分之几，远小于指纹容差。省掉投影让索引构建快得多。
///
/// **适用视场**：目录到 V=8.0，全天 41394 颗。视场里大约要有 20 颗目录星
/// 才能稳定解算，对应视场直径约 4.5° 以上。更窄的望远镜视场请走在线解算。
class PlateSolver {
  PlateSolver(
    this.catalog, {
    this.maxIndexStars,
    this.neighbours = 6,
  });

  final StarCatalog catalog;

  /// 建索引时只用最亮的多少颗星；null 表示整张目录。
  ///
  /// 目录到 V=8.0 是刻意全用的：视场里能检出多暗的星取决于曝光，而
  /// 索引端漏掉的暗星会让两侧的近邻关系对不上，宁可多花十几 MB。
  final int? maxIndexStars;

  /// 每颗星取多少近邻来组三角形。索引端和图内端必须用同一个值，
  /// 否则两边算出来的三角形不是同一批星，指纹对不上。
  final int neighbours;

  _TriangleIndex? _cachedIndex;

  /// 索引构建要一秒上下，第一次用完之后缓存住。
  _TriangleIndex get _index =>
      _cachedIndex ??= _TriangleIndex.build(
        catalog,
        maxStars: maxIndexStars,
        neighbours: neighbours,
      );

  /// 提前把索引建好。
  ///
  /// 建索引是纯 CPU 的同步活儿，会卡住调用它的那个 isolate。用户挑图片、
  /// 填 API Key 的时间里提前跑掉，点「一键解析」时就不会先愣一秒。
  void warmUp() => _index;

  /// 尝试解算。失败返回 null，由调用方决定要不要回退到在线服务。
  SolveResult? solve(
    SkyAnalysis analysis, {
    void Function(double progress, String stage)? onProgress,
  }) {
    final detections = analysis.stars
        .where((star) => !star.isRejected && !star.isElongated)
        .toList()
      ..sort((a, b) => b.flux.compareTo(a.flux));
    if (detections.length < _minimumDetections) return null;

    onProgress?.call(0.05, '正在准备本机星表索引');
    final index = _index;
    if (index.triangleCount == 0) return null;
    // 索引是跨帧复用的，像面尺寸每帧都可能不同，所以每次解算都更新。
    index.frameWidth = analysis.width.toDouble();
    index.frameHeight = analysis.height.toDouble();

    onProgress?.call(0.25, '正在匹配星图三角形');
    final stars = detections
        .take(math.min(_detectionStars, detections.length))
        .toList(growable: false);
    final imageTriangles = _imageTriangles(stars);
    final grid = _DetectionGrid(stars);

    _Fit? best;
    var verifications = 0;
    for (final triangle in imageTriangles) {
      for (final candidate in index.lookup(
        triangle.r2,
        triangle.r3,
        ratioTolerance: triangle.ratioTolerance,
        limit: _candidatesPerTriangle,
      )) {
        if (verifications >= _verificationBudget) break;
        verifications++;
        final fits = _fitsFromCorrespondence(index, stars, triangle, candidate);
        // 逐个验内点：等腰情形下错配的残差可能更小，但它投影不出足够多的
        // 内点，所以不能只看残差最小的那一个。
        for (var attempt = 0;
            attempt < fits.length && attempt < _permutationAttempts;
            attempt++) {
          final fit = fits[attempt];
          final inliers = _collectInliers(index, grid, fit);
          if (inliers.length < _minimumInliers) continue;
          final refined = _fitSimilarity(
            [for (final i in inliers) _complexOf(stars[i.detectionIndex])],
            [
              for (final i in inliers)
                _Complex.from(index.skyPointOf(i.catalogVertex, fit.reference)),
            ],
            fit.flip,
          );
          final candidateFit = refined ?? fit;
          candidateFit.reference = fit.reference;
          candidateFit.inliers = inliers;
          if (best == null || inliers.length > best.inliers.length) {
            best = candidateFit;
          }
          break;
        }
        if (best != null && best.inliers.length >= _strongInliers) break;
      }
      if (best != null && best.inliers.length >= _strongInliers) break;
    }
    if (best == null) return null;

    onProgress?.call(0.7, '正在精修天球坐标');
    final wcs = _buildWcs(index, analysis, stars, best);
    if (wcs == null) return null;

    onProgress?.call(0.88, '正在标定星等零点');
    return _buildResult(index, analysis, stars, best, wcs);
  }

  static const _minimumDetections = 4;

  /// 参与匹配的检出星点数量上限。取最亮的一批：暗星定位不准，通量也
  /// 不可靠，混进来只会拖慢验证、拉低信噪比。
  static const _detectionStars = 120;

  /// 从最亮的多少颗里选「种子」去组三角形。种子按亮度排序，所以最可能
  /// 命中的三角形排在最前面，验证预算花在刀刃上。
  static const _seedStars = 40;

  static const _candidatesPerTriangle = 12;

  /// 一次解算里最多验证多少个候选对应关系。每条验证都要投影一批目录星
  /// 再数内点，是整条链路里最贵的部分，必须封顶，否则一张噪声图能把
  /// 手机卡住好几秒。
  static const _verificationBudget = 4000;

  static const _minimumInliers = 6;
  static const _strongInliers = 15;

  /// 一个候选最多试几种顶点对应。排在前面的是残差小的，正常三角形第一个
  /// 就能过；只有接近等腰、形状本身有歧义时才会往后试。
  static const _permutationAttempts = 4;

  /// 数内点时最多看视场里最亮的多少颗目录星。视场内的目录星可能有几百
  /// 颗，但正确的解一定落在最亮的那批上——检出星点本身也是挑最亮的。
  static const _maximumCatalogCandidates = 80;

  /// 合理的视场范围。解出来的视场小到 3° 以下，说明目录星根本不够密；
  /// 大到 60° 以上，说明拟合出来的尺度是错的。两种都直接判为失败，
  /// 免得把一组假的对应关系送到内点验证里去。
  static const _minimumFieldDegrees = 3.0;
  static const _maximumFieldDegrees = 60.0;

  /// 图内三角形，构造方式和索引端严格一致：最亮的若干颗当种子，每颗连同
  /// 它最近邻的 [neighbours] 颗一共 [neighbours] + 1 颗，从中任取三颗。
  ///
  /// 之所以不直接对「最亮的 N 颗」两两三点，是因为那样子三角形边长由
  /// 亮度分布决定，而索引端的边长由星间距离决定，广角照片下两者能差出
  /// 十几倍，比值指纹就再也对不上了。
  List<_ImageTriangle> _imageTriangles(List<DetectedStar> stars) {
    final triangles = <_ImageTriangle>[];
    final seeds = math.min(_seedStars, stars.length);
    final order = List<int>.generate(stars.length, (index) => index);
    for (var seed = 0; seed < seeds; seed++) {
      // 按到种子星的像素距离排序，取最近的若干颗。
      order.sort((a, b) => _pixelDistance(stars[seed], stars[a])
          .compareTo(_pixelDistance(stars[seed], stars[b])));
      final group = <int>[seed];
      for (final index in order) {
        if (index == seed) continue;
        group.add(index);
        if (group.length > neighbours) break;
      }
      if (group.length < 3) continue;

      for (var a = 0; a < group.length; a++) {
        for (var b = a + 1; b < group.length; b++) {
          final dab = _pixelDistance(stars[group[a]], stars[group[b]]);
          for (var c = b + 1; c < group.length; c++) {
            final dbc = _pixelDistance(stars[group[b]], stars[group[c]]);
            final dac = _pixelDistance(stars[group[a]], stars[group[c]]);
            // 三条边按长度排序，并记下每条边对面的顶点；比值相同时
            // 「对面顶点」的次序就是两边三角形之间的点对应关系。
            final sides = <(double, int)>[
              (dab, group[c]),
              (dbc, group[a]),
              (dac, group[b]),
            ]..sort((x, y) => x.$1.compareTo(y.$1));
            final shortest = sides[0].$1;
            if (shortest < _minimumSidePixels) continue;
            final r3 = sides[2].$1 / shortest;
            // 三点几乎共线的三角形对定位误差极其敏感，丢掉。
            if (r3 > _maximumRatio) continue;
            triangles.add(
              _ImageTriangle(
                vertices: (sides[0].$2, sides[1].$2, sides[2].$2),
                r2: sides[1].$1 / shortest,
                r3: r3,
                ratioTolerance: _ratioTolerance(shortest),
              ),
            );
          }
        }
      }
    }
    return triangles;
  }

  /// 边长越短，「半像素定位误差 / 边长」带来的比值误差越大。
  static double _ratioTolerance(double shortestSidePixels) =>
      (2.0 / shortestSidePixels).clamp(0.004, 0.08);

  static const _minimumSidePixels = 12.0;
  static const _maximumRatio = 3.5;

  /// 从一对三角形解出可能的相似变换，按残差从小到大排好。
  ///
  /// 三角形顶点数是三，而三个点的相似变换是唯一确定的，所以问题只在于
  /// **哪个顶点对哪个顶点**。比值指纹只锁住形状，锁不住这点：三条边长度
  /// 都不同时，「最短边对面的那个顶点」是唯一的，靠它就够了；可一旦有两条
  /// 边接近相等（等腰三角形在随机点集里非常常见），「哪条边最短」就会被
  /// 半像素的测量误差左右。更麻烦的是图内边长用像素算、目录边长用球面角距
  /// 算，两边可能给出不同的排序，于是各自选出不同的顶点对应，解出来的变换
  /// 整个是错的。
  ///
  /// 所以六个置换全试：配对方式只有六种，两种翻转各一次，一共十二次三点
  /// 最小二乘，纯算术，比去投影一整片天区数内点便宜得多。真正要提防的是
  /// 等腰情形下**错配的残差反而更小**（三角形自身对称），所以返回的是排好
  /// 序的一列，让调用方逐个验内点，而不是只取第一个。
  List<_Fit> _fitsFromCorrespondence(
    _TriangleIndex index,
    List<DetectedStar> stars,
    _ImageTriangle triangle,
    _CatalogTriangle candidate,
  ) {
    final (imageA, imageB, imageC) = triangle.vertices;
    final (skyA, skyB, skyC) = candidate.vertices;
    final reference = index.referenceOf(skyA);
    final image = <_Complex>[
      _complexOf(stars[imageA]),
      _complexOf(stars[imageB]),
      _complexOf(stars[imageC]),
    ];
    final sky = <_Complex>[
      _Complex.from(index.projectVertex(skyA, reference)),
      _Complex.from(index.projectVertex(skyB, reference)),
      _Complex.from(index.projectVertex(skyC, reference)),
    ];
    if (sky.any((value) => !value.isFinite)) return const [];

    final fieldScale = math.sqrt(
      index.frameWidth * index.frameWidth +
          index.frameHeight * index.frameHeight,
    );
    final fits = <_Fit>[];
    for (final order in _vertexOrders) {
      final shuffled = <_Complex>[
        sky[order[0]],
        sky[order[1]],
        sky[order[2]],
      ];
      for (final flip in const [false, true]) {
        final fit = _fitSimilarity(image, shuffled, flip);
        if (fit == null) continue;
        // 切点必须记在拟合结果上：数内点时要把目录星投影到同一个坐标系里。
        fit.reference = reference;
        // 尺度检查。错的对应也能解出一个尺度，只是往往离谱；这一步纯算术，
        // 先把明显不对的挡在门外，再送去数内点。
        final field = fieldScale * fit.a.abs;
        if (field < _minimumFieldDegrees || field > _maximumFieldDegrees) {
          continue;
        }
        fits.add(fit);
      }
    }
    fits.sort((a, b) => a.residual.compareTo(b.residual));
    return fits;
  }

  /// 三个顶点的全部六种配对方式。
  static const _vertexOrders = <List<int>>[
    [0, 1, 2],
    [0, 2, 1],
    [1, 0, 2],
    [1, 2, 0],
    [2, 0, 1],
    [2, 1, 0],
  ];

  /// 相似变换最小二乘。
  ///
  /// 模型是 `w = a·u + b`，其中 u 是像面复坐标（[flip] 为真时先取共轭，
  /// 用来适配加了天顶镜之类左右翻转的光路），w 是切平面坐标（度）。
  /// 图像 y 轴向下、天球 η 轴向上，所以普通照片对应 `flip = false`。
  ///
  /// 对 a、b 而言模型是线性的，正规方程可以直接解出来。
  static _Fit? _fitSimilarity(
    List<_Complex> image,
    List<_Complex> sky,
    bool flip,
  ) {
    final n = image.length;
    if (n < 2) return null;

    var sumUU = 0.0; // Σ|u|²
    var sumU = _Complex.zero; // Σu
    var sumW = _Complex.zero; // Σw
    var sumUW = _Complex.zero; // Σ conj(u)·w
    for (var i = 0; i < n; i++) {
      final u = flip ? image[i].conjugate : image[i];
      sumUU += u.normSquared;
      sumU += u;
      sumW += sky[i];
      sumUW += u.conjugate * sky[i];
    }

    final denominator = sumUU - sumU.normSquared / n;
    if (denominator.abs() < 1e-12) return null;
    final a = (sumUW - sumU.conjugate * sumW.scaled(1 / n))
        .scaled(1 / denominator);
    if (a.abs < 1e-12 || !a.isFinite) return null;
    final b = (sumW - a * sumU).scaled(1 / n);
    if (!b.isFinite) return null;

    final fit = _Fit(a, b, flip);
    // 用残差做一次粗筛：明显对不上的候选不值得再数内点。
    var worst = 0.0;
    for (var i = 0; i < n; i++) {
      final predicted = fit.apply(image[i]);
      final error = (predicted - sky[i]).abs;
      if (error > worst) worst = error;
    }
    fit.residual = worst;
    return fit;
  }

  /// 把目录星投影回图像，数有多少颗落在检出星点附近。
  List<_Inlier> _collectInliers(
    _TriangleIndex index,
    _DetectionGrid grid,
    _Fit fit,
  ) {
    final scale = fit.a.abs; // 度/像素
    if (scale <= 0 || !scale.isFinite) return const [];

    // 先看变换把像面中心送到了天上哪里，再以那里为中心取一圈目录星。
    final centreSky = fit.apply(
      _Complex(index.frameWidth / 2, index.frameHeight / 2),
    );
    final (centreRa, centreDec) =
        _TriangleIndex.unproject(centreSky, fit.reference);
    if (!centreRa.isFinite || !centreDec.isFinite) return const [];
    final diagonalDegrees = math.sqrt(
      index.frameWidth * index.frameWidth +
          index.frameHeight * index.frameHeight,
    ) *
        scale;
    final candidates = index.starsNearSky(
      centreRa,
      centreDec,
      diagonalDegrees / 2 + 0.5,
      limit: _maximumCatalogCandidates,
    );

    final inliers = <_Inlier>[];
    final used = <int>{};
    for (final vertex in candidates) {
      final world = index.skyPointOf(vertex, fit.reference);
      final pixel = fit.invert(_Complex.from(world));
      if (!pixel.isFinite) continue;
      // 容差按像素给：星点定位精度大约就是这个量级。
      final match = grid.nearest(
        pixel.real,
        pixel.imaginary,
        _inlierTolerancePixels,
        used,
      );
      if (match == null) continue;
      used.add(match.index);
      inliers.add(_Inlier(match.index, vertex, match.distance));
    }
    return inliers;
  }

  /// 像素容差取 3 像素：星点本身的定位精度约半像素，再留出畸变和
  /// 亚像素误差的余量。
  static const _inlierTolerancePixels = 3.0;

  static _Complex _complexOf(DetectedStar star) => _Complex(star.x, star.y);

  /// 把拟合结果落成标准 TAN 的 WCS。
  ///
  /// 切点离像面中心越远，线性模型越不准，所以迭代几轮把切点挪到中心。
  Wcs? _buildWcs(
    _TriangleIndex index,
    SkyAnalysis analysis,
    List<DetectedStar> stars,
    _Fit fit,
  ) {
    if (fit.inliers.length < 3) return null;
    final centrePixel = _Complex(analysis.width / 2, analysis.height / 2);
    final pixels = <_Complex>[
      for (final inlier in fit.inliers) _complexOf(stars[inlier.detectionIndex]),
    ];

    var reference = fit.reference;
    var current = fit;
    for (var iteration = 0; iteration < 4; iteration++) {
      // 当前拟合把像面中心送到了天上哪里？那就是更合适的切点。
      final (ra, dec) =
          _TriangleIndex.unproject(current.apply(centrePixel), reference);
      if (!ra.isFinite || !dec.isFinite) return null;
      final moved = angularSeparationDegrees(ra, dec, reference.$1, reference.$2);
      reference = (ra, dec);

      // 换切点就是换坐标系，w 的数值全变了，必须在新切点下重新投影再拟合。
      final sky = <_Complex>[];
      var degenerate = false;
      for (final inlier in fit.inliers) {
        final world = index.skyPointOf(inlier.catalogVertex, reference);
        if (!world.$1.isFinite) {
          degenerate = true;
          break;
        }
        sky.add(_Complex.from(world));
      }
      if (degenerate) return null;
      final refit = _fitSimilarity(pixels, sky, fit.flip);
      if (refit == null) return null;
      refit.reference = reference;
      refit.inliers = fit.inliers;

      final converged = moved < 1e-5;
      current = refit;
      if (converged) break;
    }

    // 拟合的零点是 ξ = η = 0 的像素，也就是 CRPIX；CRVAL 就是切点本身。
    final zero = current.invert(_Complex.zero);
    if (!zero.isFinite) return null;
    final arcsecPerPixel = 3600 * current.a.abs;
    if (arcsecPerPixel <= 0 || !arcsecPerPixel.isFinite) return null;

    // 视场大到十几度时，线性近似会把边角拉歪；这里做个上限判断，
    // 太离谱的结果宁可当解算失败，也不给用户一个错的坐标。
    final diagonalDegrees = math.sqrt(
          analysis.width * analysis.width +
              analysis.height * analysis.height,
        ) *
        current.a.abs;
    if (diagonalDegrees > 90) return null;

    final ar = current.a.real;
    final ai = current.a.imaginary;
    return Wcs(
      width: analysis.width,
      height: analysis.height,
      crval1: reference.$1 % 360,
      crval2: reference.$2,
      crpix1: zero.real + 1,
      crpix2: zero.imaginary + 1,
      // w = a·u + b，u = z 或 conj(z)；展开后即下面这组 CD。
      cd11: ar,
      cd12: current.flip ? ai : -ai,
      cd21: ai,
      cd22: current.flip ? -ar : ar,
    );
  }

  SolveResult _buildResult(
    _TriangleIndex index,
    SkyAnalysis analysis,
    List<DetectedStar> stars,
    _Fit fit,
    Wcs wcs,
  ) {
    final (centreRa, centreDec) = wcs.imageCenter;
    final radius = math.max(wcs.fieldOfViewDegrees / 2 + 0.3, 0.05);
    final catalogStars = <CatalogStar>[
      for (final vertex in index.starsNearSky(centreRa, centreDec, radius))
        index.starOf(vertex),
    ];

    final named = <SkyObject>[];
    for (final star in catalogStars) {
      final (x, y) = wcs.worldToPixel(star.ra, star.dec);
      if (x < 0 || y < 0 || x >= analysis.width || y >= analysis.height) continue;
      final name = catalog.nameOf(star);
      named.add(
        SkyObject(
          catalog.displayName(star),
          star.ra,
          star.dec,
          name?.spectralType?.isNotEmpty == true
              ? '恒星 · ${name!.spectralType}'
              : '恒星 · 本地星表',
          magnitude: star.vMagnitude,
          magnitudeBand: 'V',
          x: x,
          y: y,
          isLocal: true,
        ),
      );
    }

    // 星等零点：目录给真实 V 星等，图像给仪器星等，两者之差就是零点。
    final offsets = <double>[];
    for (final inlier in fit.inliers) {
      offsets.add(
        index.starOf(inlier.catalogVertex).vMagnitude -
            stars[inlier.detectionIndex].instrumentalMagnitude,
      );
    }
    double? zeroPoint;
    double? scatter;
    if (offsets.length >= 5) {
      offsets.sort();
      zeroPoint = _median(offsets);
      final deviations =
          offsets.map((value) => (value - zeroPoint!).abs()).toList()..sort();
      scatter = 1.4826 * _median(deviations);
    }

    final constellations = <String>[];
    final seen = <String>{};
    // 视场中心所在星座排第一，它才是「这张照片拍的是哪个星座」的答案。
    final centreConstellation = catalog.constellationAt(centreRa, centreDec);
    if (centreConstellation != null && !centreConstellation.isEmpty) {
      seen.add(centreConstellation.abbreviation);
      constellations.add(centreConstellation.abbreviation);
    }
    for (final star in catalogStars) {
      if (star.vMagnitude > 5.5) continue;
      final constellation = catalog.constellationOf(star);
      if (constellation == null || constellation.isEmpty) continue;
      if (seen.add(constellation.abbreviation)) {
        constellations.add(constellation.abbreviation);
      }
    }

    return SolveResult(
      centerRa: centreRa,
      centerDec: centreDec,
      arcsecPerPixel: wcs.arcsecPerPixel,
      namedStars: named,
      deepSkyObjects: const [],
      matchedStars: [
        for (final inlier in fit.inliers)
          GaiaMatch(
            sourceId: 'HIP ${index.starOf(inlier.catalogVertex).hip}',
            ra: index.starOf(inlier.catalogVertex).ra,
            dec: index.starOf(inlier.catalogVertex).dec,
            x: stars[inlier.detectionIndex].x,
            y: stars[inlier.detectionIndex].y,
            gMagnitude: index.starOf(inlier.catalogVertex).vMagnitude,
          ),
      ],
      magnitudeZeroPoint: zeroPoint,
      magnitudeScatter: scatter,
      catalogWarning: null,
      source: SolveSource.local,
      fieldOfViewDegrees: wcs.fieldOfViewDegrees,
      constellations: constellations,
      wcs: wcs,
      rotationDegrees: _rotationDegrees(wcs),
      matchedCount: fit.inliers.length,
    );
  }

  /// 图像旋转角（度），0 表示正北朝上。
  static double _rotationDegrees(Wcs wcs) {
    final (northX, northY) = wcs.northDirectionAt(wcs.width / 2, wcs.height / 2);
    // 图像 y 轴向下，所以「北在图像上的方向」相对「正上方」的夹角要取反。
    return math.atan2(northX, -northY) * 180 / math.pi;
  }

  static double _pixelDistance(DetectedStar a, DetectedStar b) {
    final dx = a.x - b.x;
    final dy = a.y - b.y;
    return math.sqrt(dx * dx + dy * dy);
  }

  static double _median(List<double> sorted) {
    final middle = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[middle]
        : (sorted[middle - 1] + sorted[middle]) / 2;
  }
}

/// 目录三角形索引。
///
/// 用扁平数组 + 偏移表，而不是 `Map<double, List>`：索引里有上百万个
/// 三角形，用 Map 会白白多花几十 MB 内存。
///
/// 排序键是「先 r2 桶、再 r3 桶」的两级整数键（见 [keys]）。这个顺序是
/// 查询能不能快的关键：一块天区里的三角形形状五花八门，只按 r2 找的话，
/// 一个目标会命中成千上万个「r2 勉强算接近」的假候选，真正对上的那一个
/// 混在里面根本轮不到验算——搜索预算全烧在假候选上了。按 r3 再排一遍，
/// 查询就能从最贴近目标的那几个开始往外找。
class _TriangleIndex {
  _TriangleIndex._({
    required this.catalog,
    required this.vertices,
    required this.r3Quantized,
    required this.keys,
    required this.order,
    required this.bucketStart,
  });

  final StarCatalog catalog;

  /// 每个三角形的三个顶点，指向 [StarCatalog.stars] 的下标；顺序是
  /// 「最短边对面的顶点、次长边对面的顶点、最长边对面的顶点」。
  final Int32List vertices;

  /// 最长边/最短边，放大一百万倍存成整数，省内存也便于比较。
  final Int32List r3Quantized;

  /// 排序键：`r2 桶号 * r3Steps + r3 桶号`。r2 桶号可以整除出来，
  /// r3 桶号是键对 r3Steps 取余，所以一个数组同时给出两级坐标。
  final Int32List keys;

  /// 按 [keys] 排好序后的三角形下标。
  final Int32List order;

  /// 每个 r2 桶在 [order] 里的起止位置，长度 bucketCount + 1；
  /// 桶内部已经按 r3 排好。
  final Int32List bucketStart;

  int get triangleCount => vertices.length ~/ 3;

  /// 建索引时并不知道像面尺寸，等第一帧图像进来时再补上，
  /// 用于 [_collectInliers] 估计要取多大的天区。
  double frameWidth = 1024;
  double frameHeight = 1024;

  static const bucketCount = 1200;

  /// r3 方向的细分数。比 r2 桶细得多，因为它只用来排序，不用来定界：
  /// 真正决定「算不算命中」的是 [r3Quantized] 上的精确比较。
  static const r3Steps = 2048;

  static const _ratioLow = 1.0;
  static const _ratioHigh = 3.5;
  static const _minimumSideDegrees = 0.05;
  static const _maximumRatio = 3.5;

  static int _bucketOf(double ratio) {
    final normalized = (ratio - _ratioLow) / (_ratioHigh - _ratioLow);
    return (normalized * bucketCount).floor().clamp(0, bucketCount - 1);
  }

  static int _r3BucketOf(double ratio) {
    final normalized = (ratio - _ratioLow) / (_ratioHigh - _ratioLow);
    return (normalized * r3Steps).round().clamp(0, r3Steps - 1);
  }

  static _TriangleIndex build(
    StarCatalog catalog, {
    required int? maxStars,
    required int neighbours,
  }) {
    final pool = maxStars == null || maxStars >= catalog.stars.length
        ? catalog.stars
        : catalog.stars.take(maxStars).toList(growable: false);
    if (pool.isEmpty) {
      return _TriangleIndex._(
        catalog: catalog,
        vertices: Int32List(0),
        r3Quantized: Int32List(0),
        keys: Int32List(0),
        order: Int32List(0),
        bucketStart: Int32List(bucketCount + 1),
      );
    }
    // 索引里只用池内的星，池外更暗的星即便检出来也不会拿来组三角形。
    final magnitudeLimit = pool.last.vMagnitude;

    // 存进索引的下标必须能直接索引 [StarCatalog.stars]。近邻查询返回的是
    // 星对象，它们在表里的位置和「在近邻列表里的位置」完全是两回事，
    // 混用会把三角形悄悄记到另外几颗星头上——解算会失败，而且失败得
    // 毫无线索，所以这里显式换算一次。
    final position = <int, int>{};
    for (var i = 0; i < catalog.stars.length; i++) {
      position[catalog.stars[i].hip] = i;
    }

    final tripleVertices = <int>[];
    final tripleKeys = <int>[];
    final tripleR3 = <int>[];
    final tripleR3Bucket = <int>[];

    for (final centre in pool) {
      final centreIndex = position[centre.hip]!;
      // 连同自己在内一共 neighbours + 1 颗，任取三颗组三角形。
      final near = catalog.nearestStars(
        centre.ra,
        centre.dec,
        neighbours + 1,
        magnitudeLimit: magnitudeLimit,
      );
      final group = <CatalogStar>[centre];
      final groupIndex = <int>[centreIndex];
      for (final star in near) {
        if (star.hip == centre.hip) continue;
        group.add(star);
        groupIndex.add(position[star.hip]!);
        if (group.length > neighbours) break;
      }
      if (group.length < 3) continue;

      // 比值用球面角距算，不是投影坐标。两者相差 O(θ²)，对这个尺度
      // 的三角形完全可以忽略，省掉投影让建索引快得多。
      for (var a = 0; a < group.length; a++) {
        for (var b = a + 1; b < group.length; b++) {
          final dab = angularSeparationDegrees(
            group[a].ra,
            group[a].dec,
            group[b].ra,
            group[b].dec,
          );
          for (var c = b + 1; c < group.length; c++) {
            final dbc = angularSeparationDegrees(
              group[b].ra,
              group[b].dec,
              group[c].ra,
              group[c].dec,
            );
            final dac = angularSeparationDegrees(
              group[a].ra,
              group[a].dec,
              group[c].ra,
              group[c].dec,
            );
            // 边 (a,b) 对面是 c，(b,c) 对面是 a，(a,c) 对面是 b。
            final sides = <(double, int)>[
              (dab, groupIndex[c]),
              (dbc, groupIndex[a]),
              (dac, groupIndex[b]),
            ]..sort((x, y) => x.$1.compareTo(y.$1));
            final shortest = sides[0].$1;
            if (shortest < _minimumSideDegrees) continue;
            final r3 = sides[2].$1 / shortest;
            if (r3 > _maximumRatio) continue;
            tripleVertices.addAll(sides.map((side) => side.$2));
            tripleKeys.add(_bucketOf(sides[1].$1 / shortest));
            tripleR3.add((r3 * 1000000).round());
            tripleR3Bucket.add(_r3BucketOf(r3));
          }
        }
      }
    }

    final count = tripleKeys.length;
    // 把两级坐标压成一个整数键，一次计数排序就得到全局有序的顺序。
    // 键空间是 bucketCount × r3Steps，全是小整数，计数排序比通用排序
    // 快得多，而这份顺序正是查询时省掉「扫全桶找最像的几个」的底气。
    final keys = Int32List(count);
    for (var i = 0; i < count; i++) {
      keys[i] = tripleKeys[i] * r3Steps + tripleR3Bucket[i];
    }
    final keyCount = bucketCount * r3Steps;
    final start = Int32List(keyCount + 1);
    for (var i = 0; i < count; i++) {
      start[keys[i] + 1]++;
    }
    for (var i = 0; i < keyCount; i++) {
      start[i + 1] += start[i];
    }
    // 每个 r2 桶的起点，要在 start 被当成游标消耗掉之前先抄出来。
    final bucketStart = Int32List(bucketCount + 1);
    for (var b = 0; b <= bucketCount; b++) {
      bucketStart[b] = start[b * r3Steps];
    }
    final order = Int32List(count);
    for (var i = 0; i < count; i++) {
      order[start[keys[i]]++] = i;
    }

    return _TriangleIndex._(
      catalog: catalog,
      vertices: Int32List.fromList(tripleVertices),
      r3Quantized: Int32List.fromList(tripleR3),
      keys: keys,
      order: order,
      bucketStart: bucketStart,
    );
  }

  /// 索引顶点对应的目录星。
  CatalogStar starOf(int vertex) => catalog.stars[vertex];

  /// 三颗星共用的投影切点：直接取其中一颗星的位置。
  ///
  /// 三颗星彼此不会超过十几度，用任一颗当切点，局部投影的形变都可以忽略；
  /// 真正的切点会在 [_buildWcs] 里迭代到像面中心。
  (double, double) referenceOf(int vertex) {
    final star = catalog.stars[vertex];
    return (star.ra, star.dec);
  }

  (double, double) skyPointOf(int vertex, (double, double) reference) {
    final star = catalog.stars[vertex];
    return project(star.ra, star.dec, reference);
  }

  (double, double) projectVertex(int vertex, (double, double) reference) =>
      skyPointOf(vertex, reference);

  /// 找出和 `(r2, r3)` 形状相符的目录三角形，**最像的排在前面**。
  ///
  /// 顺序就是这里全部的意义。图里量出来的比值带半像素量级的误差，于是
  /// 容差至少也有千分之几，命中集合动辄几千个；而容差本身是按最短边
  /// 长度算的，短线三角形（也是最先被试的那些）容差最大，命中集合最大。
  /// 如果按「桶号从小到大、桶内按录入顺序」吐结果，调用方取前十几个
  /// 就只能看到容差下限那一边的假候选，真正的那个在桶的另一头，永远轮
  /// 不上——现象是解算莫名其妙地失败，而且越亮的星（近邻越近、线越短）
  /// 越失败，很难从现象倒推回原因。
  ///
  /// 所以从最贴近目标的 r2 桶开始向两边走，桶内从最贴近目标的 r3 开始
  /// 向两边走。两边的「贴近」都只是排序，命中与否仍然由精确比较决定。
  Iterable<_CatalogTriangle> lookup(
    double r2,
    double r3, {
    required double ratioTolerance,
    required int limit,
  }) sync* {
    final middle = _bucketOf(r2);
    final lowest = _bucketOf(r2 - ratioTolerance);
    final highest = _bucketOf(r2 + ratioTolerance);
    final r3Scaled = r3 * 1000000;
    final tolerance = ratioTolerance * 1000000;
    // 桶只是用来排序的，边界放宽一格，免得「精确比较算命中」的三角形
    // 恰好被桶边界挡在外面。
    var r3Low = _r3BucketOf(r3 - ratioTolerance) - 1;
    var r3High = _r3BucketOf(r3 + ratioTolerance) + 1;
    if (r3Low < 0) r3Low = 0;
    if (r3High > r3Steps - 1) r3High = r3Steps - 1;
    final r3Centre = _r3BucketOf(r3);

    var produced = 0;
    for (var step = 0; step <= highest - lowest; step++) {
      for (var side = 0; side < (step == 0 ? 1 : 2); side++) {
        final bucket = step == 0 ? middle : middle + (side == 0 ? -step : step);
        if (bucket < lowest || bucket > highest) continue;
        final base = bucket * r3Steps;
        final from = bucketStart[bucket];
        final to = bucketStart[bucket + 1];
        final lowIndex = _lowerBound(from, to, base + r3Low);
        final highIndex = _lowerBound(from, to, base + r3High + 1);
        if (lowIndex >= highIndex) continue;
        var pivot = _lowerBound(lowIndex, highIndex, base + r3Centre);
        if (pivot >= highIndex) pivot = highIndex - 1;
        for (var r3Step = 0; r3Step < highIndex - lowIndex; r3Step++) {
          for (var r3Side = 0; r3Side < (r3Step == 0 ? 1 : 2); r3Side++) {
            final i = r3Step == 0
                ? pivot
                : pivot + (r3Side == 0 ? -r3Step : r3Step);
            if (i < lowIndex || i >= highIndex) continue;
            final triangle = order[i];
            if ((r3Quantized[triangle] - r3Scaled).abs() > tolerance) continue;
            final at = triangle * 3;
            yield _CatalogTriangle(
              (vertices[at], vertices[at + 1], vertices[at + 2]),
            );
            if (++produced >= limit) return;
          }
        }
      }
    }
  }

  /// 在 [from, to) 里找第一个键不小于 [target] 的位置。
  int _lowerBound(int from, int to, int target) {
    var low = from;
    var high = to;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (keys[order[middle]] < target) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low;
  }

  /// 天区里 [radius] 度内的目录星下标（指向 [StarCatalog.stars]）。
  ///
  /// [StarCatalog.starsNear] 已经按星等从亮到暗返回，所以加上 [limit]
  /// 就等于「取这片天区里最亮的 N 颗」。
  List<int> starsNearSky(
    double ra,
    double dec,
    double radius, {
    int? limit,
  }) {
    final result = <int>[];
    for (final star in catalog.starsNear(ra, dec, radius)) {
      final index = _starIndex[star.hip];
      if (index == null) continue;
      result.add(index);
      if (limit != null && result.length >= limit) break;
    }
    return result;
  }

  late final Map<int, int> _starIndex = () {
    final map = <int, int>{};
    for (var i = 0; i < catalog.stars.length; i++) {
      map[catalog.stars[i].hip] = i;
    }
    return map;
  }();

  /// 天球坐标 → 以 [reference] 为切点的标准坐标（度），TAN 投影。
  static (double, double) project(
    double ra,
    double dec,
    (double, double) reference,
  ) {
    const radians = math.pi / 180;
    final ra0 = reference.$1 * radians;
    final dec0 = reference.$2 * radians;
    final targetRa = ra * radians;
    final targetDec = dec * radians;
    final deltaRa = wrapRadians(targetRa - ra0);
    final denominator = math.sin(dec0) * math.sin(targetDec) +
        math.cos(dec0) * math.cos(targetDec) * math.cos(deltaRa);
    if (denominator <= 1e-9) return (double.nan, double.nan);
    final xi = math.cos(targetDec) * math.sin(deltaRa) / denominator / radians;
    final eta = (math.cos(dec0) * math.sin(targetDec) -
            math.sin(dec0) * math.cos(targetDec) * math.cos(deltaRa)) /
        denominator /
        radians;
    return (xi, eta);
  }

  /// [project] 的逆运算。
  static (double, double) unproject(
    _Complex point,
    (double, double) reference,
  ) {
    const radians = math.pi / 180;
    final xi = point.real * radians;
    final eta = point.imaginary * radians;
    final rho = math.sqrt(xi * xi + eta * eta);
    if (rho < 1e-12) return (reference.$1 % 360, reference.$2);
    final ra0 = reference.$1 * radians;
    final dec0 = reference.$2 * radians;
    final c = math.atan(rho);
    final dec = math.asin(
      (math.cos(c) * math.sin(dec0) +
              eta * math.sin(c) * math.cos(dec0) / rho)
          .clamp(-1.0, 1.0),
    );
    final ra = ra0 +
        math.atan2(
          xi * math.sin(c),
          rho * math.cos(dec0) * math.cos(c) -
              eta * math.sin(dec0) * math.sin(c),
        );
    return ((ra / radians) % 360, dec / radians);
  }
}

/// 检出星点的像素网格，把「找最近的检出星点」从线性扫描降成常数级。
///
/// [_collectInliers] 每验证一个候选都要做几十上百次最近邻查询，而候选数
/// 以千计；线性扫描会让解算时间随「星点数 × 候选数」一起涨，一张噪点图
/// 就能把界面拖住好几秒。
class _DetectionGrid {
  _DetectionGrid(List<DetectedStar> stars) : _stars = stars {
    for (var i = 0; i < stars.length; i++) {
      final key = _key(stars[i].x, stars[i].y);
      (_cells[key] ??= <int>[]).add(i);
    }
  }

  static const _cell = 16.0;
  static const _limit = 4096;

  final List<DetectedStar> _stars;
  final Map<int, List<int>> _cells = {};

  static int _index(double value) {
    final cell = (value / _cell).floor();
    if (cell < 0) return 0;
    return cell >= _limit ? _limit - 1 : cell;
  }

  static int _key(double x, double y) => _index(y) * _limit + _index(x);

  /// 距离 (x, y) 不超过 [radius] 且不在 [used] 里的最近星点。
  ({int index, double distance})? nearest(
    double x,
    double y,
    double radius,
    Set<int> used,
  ) {
    final span = (radius / _cell).ceil();
    final baseX = _index(x);
    final baseY = _index(y);
    int? best;
    var bestDistance = radius;
    for (var dy = -span; dy <= span; dy++) {
      for (var dx = -span; dx <= span; dx++) {
        final bucket = _cells[(baseY + dy) * _limit + (baseX + dx)];
        if (bucket == null) continue;
        for (final index in bucket) {
          if (used.contains(index)) continue;
          final star = _stars[index];
          final ox = star.x - x;
          final oy = star.y - y;
          final distance = math.sqrt(ox * ox + oy * oy);
          if (distance <= bestDistance) {
            bestDistance = distance;
            best = index;
          }
        }
      }
    }
    final found = best;
    return found == null ? null : (index: found, distance: bestDistance);
  }
}

/// 拟合出来的相似变换：`w = a·u + b`。
class _Fit {
  _Fit(this.a, this.b, this.flip);

  final _Complex a;
  final _Complex b;
  final bool flip;

  /// 投影目录星用的切点（赤经、赤纬，度）。
  (double, double) reference = (0, 0);
  List<_Inlier> inliers = const [];
  double residual = double.infinity;

  _Complex apply(_Complex pixel) =>
      a * (flip ? pixel.conjugate : pixel) + b;

  _Complex invert(_Complex sky) {
    if (a.abs < 1e-12) return const _Complex(double.nan, double.nan);
    final u = (sky - b) / a;
    return flip ? u.conjugate : u;
  }

  bool get isFinite => a.isFinite && b.isFinite;
}

/// 一个内点：第 [detectionIndex] 个检出星点 与 第 [catalogVertex] 颗目录星 对应。
class _Inlier {
  const _Inlier(this.detectionIndex, this.catalogVertex, this.distance);

  final int detectionIndex;
  final int catalogVertex;
  final double distance;
}

class _ImageTriangle {
  const _ImageTriangle({
    required this.vertices,
    required this.r2,
    required this.r3,
    required this.ratioTolerance,
  });

  final (int, int, int) vertices;
  final double r2;
  final double r3;
  final double ratioTolerance;
}

class _CatalogTriangle {
  const _CatalogTriangle(this.vertices);

  final (int, int, int) vertices;
}

/// 极简复数。用复平面表示相似变换能让公式短一大截。
class _Complex {
  const _Complex(this.real, this.imaginary);

  _Complex.from((double, double) pair)
      : real = pair.$1,
        imaginary = pair.$2;

  static const zero = _Complex(0, 0);

  final double real;
  final double imaginary;

  _Complex operator +(_Complex other) =>
      _Complex(real + other.real, imaginary + other.imaginary);

  _Complex operator -(_Complex other) =>
      _Complex(real - other.real, imaginary - other.imaginary);

  /// Dart 不允许按参数类型重载，所以标量乘法另起名字。
  _Complex scaled(double scalar) =>
      _Complex(real * scalar, imaginary * scalar);

  _Complex operator *(_Complex other) => _Complex(
        real * other.real - imaginary * other.imaginary,
        real * other.imaginary + imaginary * other.real,
      );

  _Complex operator /(_Complex other) {
    final denominator =
        other.real * other.real + other.imaginary * other.imaginary;
    if (denominator == 0) return const _Complex(double.nan, double.nan);
    return _Complex(
      (real * other.real + imaginary * other.imaginary) / denominator,
      (imaginary * other.real - real * other.imaginary) / denominator,
    );
  }

  _Complex get conjugate => _Complex(real, -imaginary);

  double get normSquared => real * real + imaginary * imaginary;

  double get abs => math.sqrt(normSquared);

  bool get isFinite => real.isFinite && imaginary.isFinite;

  @override
  String toString() =>
      '${real.toStringAsFixed(4)}${imaginary < 0 ? '-' : '+'}'
      '${imaginary.abs().toStringAsFixed(4)}i';
}
