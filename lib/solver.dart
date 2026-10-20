import 'dart:math' as math;
import 'dart:typed_data';

import 'strings.dart';
import 'analysis.dart';
import 'catalog.dart';
import 'deepsky.dart';
import 'ephemeris.dart';
import 'models.dart';
import 'moving.dart';
import 'smallbodies.dart';

/// 解算进度的一次快照。
///
/// [deep] 说的是「这一步已经动用了整张星表那一层」——百万颗星的三角形索引
/// 要现建，等待时间比前面两层高一个量级。界面据此换一套配色和一句说明：
/// 同样是「本机在算」，用户等的其实是两件很不一样的事，提前说清楚，那几十
/// 秒才不至于像是卡死了。
///
/// 判据用这个字段，不去认 [stage] 里的文案：文案是给人读的，随时会改，而
/// 颜色一旦跟着文案走，改一句话就会悄悄改掉一条判断。
class SolveProgress {
  const SolveProgress(this.fraction, this.stage, {this.deep = false});

  /// 0–1。
  final double fraction;

  /// 当前在做什么，写成人话。
  final String stage;

  /// 已经用上最深那层星表。
  final bool deep;
}

/// 一次本机解算「试了什么、差多少」的记录。
///
/// 解不出来时用户看到的不能只是「没找到」。这张照片是浅层、中间层、最深层
/// 一层层试过来的，每层里还按「图内端取多少颗星」试了好几档；「星表资产读
/// 坏了」和「天区本身对不上」在用户那里是同一句话，在这份记录里却长得完全
/// 不一样——前者某一层的星数会明显不对，后者是每层都试到了、内点数就是够
/// 不着门槛。要让判据有据可依，就只能把实际试过的记下来。
class SolveTrace {
  /// 按实际尝试的顺序记下的每一层。没轮到的层不在里面。
  final List<SolveLayerAttempt> layers = <SolveLayerAttempt>[];

  /// 所有层里最多数到的内点数，以及那一刻要求的下限。
  int bestInliers = 0;
  int bestRequired = 0;

  /// 开一层，返回的记录由调用方在跑那一层时更新。
  SolveLayerAttempt startLayer(String label, int starCount) {
    final layer = SolveLayerAttempt(label: label, starCount: starCount);
    layers.add(layer);
    return layer;
  }

  /// 记下一次验证数到的内点数和当时的下限。数内点是整条链路里唯一会给出
  /// 「差几颗」这个数字的地方，所以就在这里收。
  void noteInliers(int count, int floor) {
    if (count > bestInliers) {
      bestInliers = count;
      bestRequired = floor;
    }
    if (layers.isEmpty) return;
    final layer = layers.last;
    if (count > layer.bestInliers) layer.bestInliers = count;
  }
}

/// [SolveTrace] 里的一层。
class SolveLayerAttempt {
  SolveLayerAttempt({required this.label, required this.starCount});

  /// 「浅层」「中间层」「最深层」。
  final String label;

  /// 这一层星表里有多少颗星。资产读坏了就从这里看出来。
  final int starCount;

  /// 实际跑过的档位数（图内端取 8/16/24/120 颗那几档）。
  int rungsTried = 0;

  /// 每一档匹配实际花掉的毫秒数，按尝试顺序。
  ///
  /// 只用于诊断和测试里的性能回归：哪一档在空转、哪一层把时间吃掉了，
  /// 光看「试了几档」看不出来。
  final List<int> rungMilliseconds = <int>[];

  /// 这一层匹配累计花掉的毫秒数（不含建索引）。
  int get elapsedMilliseconds =>
      rungMilliseconds.fold(0, (sum, value) => sum + value);

  /// 这一层里最多数到的内点数。
  int bestInliers = 0;
}

/// 用户对「这张照片大概拍多大一片天」的选择。
///
/// 三角形指纹只认形状、不认尺度，所以同一组图内三角形会匹配到全天各处、
/// 各种视场大小的候选。把视场范围收窄，等于在验证之前就扔掉绝大多数假候选。
/// 实测 M31（约 4° 视场）从 5.7 s 降到 2.1 s；对窄视场和广域同样有效。
///
/// 这是**可选**的：默认 [auto] 保持 1°–120° 的宽范围，不影响任何旧照片。
class SolveHint {
  const SolveHint({
    this.minFieldDegrees = 1.0,
    this.maxFieldDegrees = 120.0,
    this.allowDeep = true,
    this.budgetMilliseconds = 0,
    this.patchSolve = false,
    this.skipShallow = false,
    this.patchGrid = 2,
  });

  /// 视场对角线下限（度）。
  final double minFieldDegrees;

  /// 视场对角线上限（度）。
  final double maxFieldDegrees;

  /// 浅层/中间层都失败后，是否还允许建最深层索引。
  ///
  /// 广域照片几乎不会需要百万颗星那层；关掉它能省掉一次几十秒的索引构建。
  final bool allowDeep;

  /// 每层匹配的墙钟上限（毫秒）。0 表示不设上限，保持旧行为。
  ///
  /// 星点上千的银河/地景照片会检出几千个候选，同一层里每个星数档都要把
  /// 验证预算跑满才能认输；选了拍摄场景之后给一个上限，避免卡几分钟。
  final int budgetMilliseconds;

  /// 整幅解不出来时，是否再按 2×2 分块试一次。
  ///
  /// 超广角/拼接片的畸变会让整幅的三角形比例对不上；切成小块之后每块都
  /// 更接近局部相似变换，地景也只影响其中一两块。
  final bool patchSolve;

  /// 是否跳过浅层，直接从中间层开始。
  ///
  /// 长焦/智能望远镜的视场里，浅层四万颗星往往一颗都进不了画面；先跑一遍
  /// 只是白等，还会把预算花在注定失败的候选上。
  final bool skipShallow;

  /// 分块解算的网格数：2 就是 2×2，3 就是 3×3。
  final int patchGrid;

  SolveHint copyWith({
    double? minFieldDegrees,
    double? maxFieldDegrees,
    bool? allowDeep,
    int? budgetMilliseconds,
    bool? patchSolve,
    bool? skipShallow,
    int? patchGrid,
  }) =>
      SolveHint(
        minFieldDegrees: minFieldDegrees ?? this.minFieldDegrees,
        maxFieldDegrees: maxFieldDegrees ?? this.maxFieldDegrees,
        allowDeep: allowDeep ?? this.allowDeep,
        budgetMilliseconds: budgetMilliseconds ?? this.budgetMilliseconds,
        patchSolve: patchSolve ?? this.patchSolve,
        skipShallow: skipShallow ?? this.skipShallow,
        patchGrid: patchGrid ?? this.patchGrid,
      );
}

/// 拍摄场景。只是把用户看得懂的说法翻译成 [SolveHint]，不参与任何测量。
enum ShootingScene {
  auto('auto'),
  starField('star_field'),
  wide('wide'),
  deepSky('deep_sky'),
  narrow('narrow'),
  starTrails('star_trails'),
  moon('moon'),
  sun('sun');

  const ShootingScene(this.storageKey);

  final String storageKey;

  static ShootingScene fromStorage(String? value) => values.firstWhere(
        (scene) => scene.storageKey == value,
        orElse: () => ShootingScene.auto,
      );

  String get label => switch (this) {
        ShootingScene.auto => t('自动'),
        ShootingScene.starField => t('星野'),
        ShootingScene.wide => t('广域'),
        ShootingScene.deepSky => t('深空'),
        ShootingScene.narrow => t('长焦'),
        ShootingScene.starTrails => t('星轨'),
        ShootingScene.moon => t('月亮'),
        ShootingScene.sun => t('太阳'),
      };

  String get description => switch (this) {
        ShootingScene.auto => t('不限视场，最稳但最慢。'),
        ShootingScene.starField => t('普通星空、星点较密。'),
        ShootingScene.wide => t('银河、地景、超广角。'),
        ShootingScene.deepSky => t('多数星云、星系。'),
        ShootingScene.narrow => t('小目标、长焦望远镜。'),
        ShootingScene.starTrails => t('只记录拉长的星点轨迹。'),
        ShootingScene.moon => t('只找月亮，随即报告。'),
        ShootingScene.sun => t('只找太阳，随即报告。'),
      };

  SolveHint get hint => switch (this) {
        ShootingScene.auto => const SolveHint(),
        ShootingScene.starField => const SolveHint(
            minFieldDegrees: 10,
            maxFieldDegrees: 120,
            allowDeep: false,
            budgetMilliseconds: 15000,
            patchSolve: true,
          ),
        ShootingScene.wide => const SolveHint(
            minFieldDegrees: 8,
            maxFieldDegrees: 120,
            allowDeep: false,
            budgetMilliseconds: 15000,
            patchSolve: true,
            patchGrid: 3,
          ),
        ShootingScene.deepSky => const SolveHint(
            minFieldDegrees: 2,
            maxFieldDegrees: 15,
            budgetMilliseconds: 15000,
          ),
        ShootingScene.narrow => const SolveHint(
            minFieldDegrees: 0.5,
            maxFieldDegrees: 8,
            budgetMilliseconds: 20000,
            patchSolve: true,
            skipShallow: true,
          ),
        ShootingScene.starTrails => const SolveHint(),
        ShootingScene.moon => const SolveHint(),
        ShootingScene.sun => const SolveHint(),
      };
}

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
/// **适用视场**：星表分三层用——浅层是 Hipparcos 到 V=8.0 的 41394 颗，中间
/// 层再补上 Gaia 里 G < 9 的那批（共约 17 万颗），最深那层用整张表（Gaia 到
/// G < 11，共约 125 万颗）。三层的分工和实测代价见 [solve]。视场里大约要有
/// 20 颗目录星才能稳定解算，浅层对应视场直径约 4.5° 以上，更窄的望远镜视场
/// 会落到后面两层。三层都解不出来时才该走在线解算。
class PlateSolver {
  PlateSolver(
    this.catalog, {
    this.deepSky,
    this.smallBodies,
    this.neighbours = 6,
  });

  final StarCatalog catalog;

  /// 内置深空目录。给了就在解算结果里带上「画面中的深空天体」，没给就只有
  /// 恒星——本机解算本来也只需要恒星表，深空目录是纯粹多给的一层信息。
  final DeepSkyCatalog? deepSky;

  /// 内置小天体目录（亮小行星、矮行星、彗星）。和深空目录一样是「多给的一层」：
  /// 没给的时候行星那条链路照旧（靠 `ephemeris.dart` 那张近似根数表），只是少掉
  /// 小行星和彗星。
  final SmallBodyCatalog? smallBodies;

  /// 每颗星取多少近邻来组三角形。索引端和图内端必须用同一个值，
  /// 否则两边算出来的三角形不是同一批星，指纹对不上。
  final int neighbours;

  /// 这一次解算的视场先验。解算本身是同步的，所以用一个字段带进去，免得
  /// 把 min/max 两个数穿过五六层调用。
  SolveHint? _activeHint;

  _TriangleIndex? _cachedIndex;

  /// 最近一次 [solve] 的过程记录。解不出来时上层拿它解释「差在哪」
  /// （见 `report.dart` 的 `describeSolveAttempt`）。每次 [solve] 开头换新的。
  SolveTrace? get lastTrace => _lastTrace;

  SolveTrace? _lastTrace;

  /// 浅层索引：只用 Hipparcos（V ≤ 8）那批星。
  ///
  /// 索引构建要一秒上下，第一次用完之后缓存住。
  _TriangleIndex get _index =>
      _cachedIndex ??= _TriangleIndex.build(
        catalog,
        pool: _shallowPool,
        neighbours: neighbours,
      );

  /// 中间层索引。
  ///
  /// 只在浅层解不出来时才建（见 [solve]），因为建它要十来秒、常驻几十 MB，
  /// 而绝大多数照片根本用不上——星点稀到浅层凑不出三角形的天区才是它的
  /// 用武之地。
  _TriangleIndex? _cachedMidIndex;

  /// 最深那一层的索引。
  ///
  /// 只在中间层也解不出来时才建：这一层是百万颗星，索引的代价比中间层高一个
  /// 量级，多数窄视场目标（Seestar 那类机器拍的星云星团）在中间层就出结果了，
  /// 不该为它们付这一份账。
  _TriangleIndex? _cachedDeepIndex;

  /// 这一层的近邻取法要跟图内端一致，所以图内端组三角形时也得用同一个值。
  ///
  /// 中间层取 4 而不是 6，是因为星数从四万涨到十七万，每颗星的三角形数
  /// C(5,3)=10 对 C(7,3)=35——索引因此小了一个量级，建得更快、常驻内存也
  /// 压得住。星点稀的天区里星本来就少，10 个三角形足够。
  static const _midNeighbours = 4;

  /// 最深那一层的近邻取法。
  ///
  /// 这层的代价和它成正比：三角形数 ≈ 星数 × C(neighbours+1, 3)，而这一层是
  /// 百万颗星，每多要一个近邻，索引就多几十 MB、建索引就多几十秒。所以它比
  /// 中间层更省——**每颗星只出一个三角形**（C(3,3) = 1）。
  ///
  /// 这么省还够用，是因为稠密不等于好认：图内端在这一层也只用它最近的 2 个
  /// 邻居组三角形，两侧用的是同一套近邻关系，一个三角形就够定位。拿最稀的
  /// 天区实测（1.9° 视场里只有二十几颗目录星、其中亮过 G<9 的只有个位数），
  /// 三个里解出两个，而且都是在第一档（8 颗）就解出来的；解不出的那个本来
  /// 就没有别的本机办法，交给在线服务即可。
  static const _deepNeighbours = 2;

  /// 有没有比浅层更深的星可用。Gaia 资产缺失时各层是同一批星，
  /// 那就没必要再跑一遍。
  bool get _hasMidLayer => _midPool.length > _shallowPool.length;
  bool get _hasDeepLayer => catalog.stars.length > _midPool.length;

  List<CatalogStar>? _cachedShallowPool;
  List<CatalogStar>? _cachedMidPool;

  /// 浅层用的星：目录里非 Gaia 的那些。目录本身按星等排好序，过滤之后
  /// 顺序不变，所以这个池子仍然是「从亮到暗」的。
  List<CatalogStar> get _shallowPool => _cachedShallowPool ??= [
        for (final star in catalog.stars)
          if (!star.isGaia) star,
      ];

  /// 中间层用的星：非 Gaia 的，加上 Gaia 里亮过界线的那些。
  List<CatalogStar> get _midPool => _cachedMidPool ??= [
        for (final star in catalog.stars)
          if (!star.isGaia || star.vMagnitude <= catalog.gaiaMidMagLimit) star,
      ];

  /// 提前把浅层索引建好。
  ///
  /// 建索引是纯 CPU 的同步活儿，会卡住调用它的那个 isolate。用户挑图片、
  /// 填 API Key 的时间里提前跑掉，点「一键解析」时就不会先愣一秒。
  void warmUp() => _index;

  /// 尝试解算。失败返回 null，由调用方决定要不要回退到在线服务。
  ///
  /// 三层，从浅到深，前一层解出来就不碰后一层：
  ///
  /// 长焦（[ShootingScene.narrow]）会用 [SolveHint.skipShallow] 直接从第二层
  /// 开始：那个视场里浅层四万颗星通常一颗都进不了画面。
  ///
  /// 1. **主星表**（Hipparcos，V ≤ 8，四万颗）。索引一秒上下，宽视场照片
  ///    基本都在这一层出结果。
  /// 2. **主星表 + Gaia 里 G ≤ [StarCatalog.gaiaMidMagLimit] 的那批**。窄视场
  ///    和星点稀的天区靠它。
  /// 3. **整张星表**（Gaia 到 G < 11，百万颗）。第三层里最难的窄视场——比如
  ///    1.3° 视场里只有十来颗 G<9 星的 M 33——只有这一层才够密。
  ///
  /// 分三层而不是一层，是因为三角形指纹要求两侧用同一套近邻关系：图内端只拿
  /// 最亮的若干颗检出组三角形，目录端一旦掺进大量暗星，同一颗亮星的近邻就换成
  /// 了它旁边那些暗星，两侧枚举出来的根本不是同一批三角形——星多的天区会因此
  /// 从「解得出」变成「解不出」。实测：把 Gaia 直接并进唯一那张星表，猎户座的
  /// 合成图在 20″/px 下失败、南天某天区也从 137ms 变成 60s 还不成功。
  ///
  /// 分三层而不是两层，是因为**后一层的代价是前一层的几倍**：整张表那一层的
  /// 三角形索引是百万级、建一次一分钟上下、常驻几十 MB。多数窄视场目标在第二
  /// 层就够了，不该为它们付第三层的账。
  ///
  /// 每一层里还要再按「图内端取多少颗星」试几档，见 [_imageStarRungs]。
  SolveResult? solve(
    SkyAnalysis analysis, {
    void Function(SolveProgress progress)? onProgress,
    SolveHint hint = const SolveHint(),
  }) {
    _activeHint = hint;
    final trace = _lastTrace = SolveTrace();
    // 候选由分析层给：那边多收了一类「形似略拉长的亮源」。这里不再自己按
    // `isElongated` 过滤——展示用的拉长候选和能拿来解算的候选不是一回事，
    // 判据写在 `SkyAnalysis.solveCandidates` 上，只留一处。
    final detections = analysis.solveCandidates.toList()
      ..sort((a, b) => b.flux.compareTo(a.flux));
    if (detections.length < _minimumDetections) return null;

    onProgress?.call(SolveProgress(0.05, t('正在准备离线解算索引')));
    if (!hint.skipShallow) {
      final index = _index;
      if (index.triangleCount == 0) return null;
      // 索引是跨帧复用的，像面尺寸每帧都可能不同，所以每次解算都更新。
      index.frameWidth = analysis.width.toDouble();
      index.frameHeight = analysis.height.toDouble();
      final shallow = _matchWithRungs(
        analysis,
        index,
        detections,
        rungs: _imageStarRungs,
        neighbours: neighbours,
        candidatesPerTriangle: _candidatesPerTriangle,
        verificationBudget: _verificationBudget,
        budgetMilliseconds: hint.budgetMilliseconds,
        progressBase: 0.25,
        progressSpan: 0.35,
        onProgress: onProgress,
        layer: trace.startLayer(t('浅层'), _shallowPool.length),
      );
      if (shallow != null) return shallow;
    }

    // 浅层星表里这半天区根本没有几颗星，再往下就是唯一的路。
    if (_hasMidLayer) {
      onProgress?.call(SolveProgress(0.58, t('正在加深星表再试一次')));
      final mid = _forFrame(
        _cachedMidIndex ??= _TriangleIndex.build(
          catalog,
          pool: _midPool,
          neighbours: _midNeighbours,
          onProgress: (fraction) => onProgress?.call(
            SolveProgress(0.58 + 0.04 * fraction, t('正在加深星表再试一次')),
          ),
        ),
        analysis,
      );
      final solved = mid == null
          ? null
          : _matchWithRungs(
              analysis,
              mid,
              detections,
              rungs: _midImageStarRungs,
              neighbours: _midNeighbours,
              candidatesPerTriangle: _deepCandidatesPerTriangle,
              verificationBudget: _deepVerificationBudget,
              budgetMilliseconds: hint.budgetMilliseconds,
              progressBase: 0.62,
              progressSpan: 0.1,
              onProgress: onProgress,
              layer: trace.startLayer(t('中间层'), _midPool.length),
            );
      if (solved != null) return solved;
    }

    if (!_hasDeepLayer || !hint.allowDeep) {
      if (hint.patchSolve) {
        return _solvePatches(analysis, hint, onProgress);
      }
      return null;
    }
    // 到了这里说明前两层都不够密。这一层的索引是本工程里最贵的一件东西，
    // 文案要让用户知道「还在跑、而且这次跑得久」，界面还会据此换一套配色
    // （见 [SolveProgress.deep]）。
    onProgress?.call(
      SolveProgress(0.72, t('正在用最深的星表再试一次'), deep: true),
    );
    final deep = _forFrame(
      _cachedDeepIndex ??= _TriangleIndex.build(
        catalog,
        pool: catalog.stars,
        neighbours: _deepNeighbours,
        onProgress: (fraction) => onProgress?.call(
          SolveProgress(0.72 + 0.06 * fraction, t('正在用最深的星表建索引'),
              deep: true),
        ),
      ),
      analysis,
    );
    if (deep == null) {
      if (hint.patchSolve) {
        return _solvePatches(analysis, hint, onProgress);
      }
      return null;
    }
    final deepResult = _matchWithRungs(
      analysis,
      deep,
      detections,
      rungs: _deepImageStarRungs,
      neighbours: _deepNeighbours,
      candidatesPerTriangle: _deepCandidatesPerTriangle,
      verificationBudget: _deepVerificationBudget,
      budgetMilliseconds: hint.budgetMilliseconds,
      progressBase: 0.78,
      progressSpan: 0.12,
      onProgress: onProgress,
      deep: true,
      layer: trace.startLayer(t('最深层'), catalog.stars.length),
    );
    if (deepResult != null) return deepResult;
    if (hint.patchSolve) {
      return _solvePatches(analysis, hint, onProgress);
    }
    return null;
  }

  /// 分块解算：整幅失败后，按 2×2 带重叠的小块再试一遍。
  ///
  /// 只用于超广角/拼接片/地景占角的照片。每块都以自己的对角线缩放场景视场，
  /// 解出来之后把 WCS 的 CRPIX 加回块偏移、把坐标从块局部搬回整幅。
  SolveResult? _solvePatches(
    SkyAnalysis analysis,
    SolveHint hint,
    void Function(SolveProgress progress)? onProgress,
  ) {
    final fullDiagonal = math.sqrt(
      analysis.width * analysis.width + analysis.height * analysis.height,
    );
    final grid = hint.patchGrid.clamp(2, 4);
    final tileFraction = grid == 2 ? 0.62 : grid == 3 ? 0.46 : 0.36;
    final tileWidth = (analysis.width * tileFraction).round().clamp(16, analysis.width);
    final tileHeight =
        (analysis.height * tileFraction).round().clamp(16, analysis.height);
    final xs = [
      for (var i = 0; i < grid; i++)
        ((analysis.width - tileWidth) * i / (grid - 1)).round(),
    ];
    final ys = [
      for (var i = 0; i < grid; i++)
        ((analysis.height - tileHeight) * i / (grid - 1)).round(),
    ];
    final total = xs.length * ys.length;
    var attempted = 0;
    final patchWatch = Stopwatch()..start();
    for (final y in ys) {
      for (final x in xs) {
        // 3×3 分块在星点极密的银河片上可能把 9 块都跑满；给整轮分块一个
        // 总上限，避免一张图在后台转十几分钟。
        if (patchWatch.elapsed > const Duration(minutes: 3)) {
          onProgress?.call(SolveProgress(0.92, t('分块解算超时')));
          return null;
        }
        attempted++;
        onProgress?.call(
          SolveProgress(
            0.82,
            t('正在分块解算 {0}/{1}', [attempted, total]),
          ),
        );
        final sub = analysis.subRegion(x, y, tileWidth, tileHeight);
        final subDiagonal = math.sqrt(
          tileWidth * tileWidth + tileHeight * tileHeight,
        );
        final ratio = fullDiagonal <= 0 ? 1.0 : subDiagonal / fullDiagonal;
        final patchHint = hint.copyWith(
          minFieldDegrees: math.max(0.05, hint.minFieldDegrees * ratio),
          maxFieldDegrees: math.max(0.1, hint.maxFieldDegrees * ratio),
          budgetMilliseconds: hint.budgetMilliseconds == 0
              ? 0
              : math.min(hint.budgetMilliseconds, 6000),
          patchSolve: false,
        );
        final patch = solve(sub, hint: patchHint);
        final patchWcs = patch?.wcs;
        if (patch == null || patchWcs == null) continue;
        final fullWcs = Wcs(
          width: analysis.width,
          height: analysis.height,
          crval1: patchWcs.crval1,
          crval2: patchWcs.crval2,
          crpix1: patchWcs.crpix1 + x,
          crpix2: patchWcs.crpix2 + y,
          cd11: patchWcs.cd11,
          cd12: patchWcs.cd12,
          cd21: patchWcs.cd21,
          cd22: patchWcs.cd22,
        );
        final (centreRa, centreDec) = fullWcs.imageCenter;
        final lifted = SolveResult(
          centerRa: centreRa,
          centerDec: centreDec,
          arcsecPerPixel: fullWcs.arcsecPerPixel,
          namedStars: [
            for (final object in patch.namedStars)
              object.at(object.x + x, object.y + y),
          ],
          deepSkyObjects: [
            for (final object in patch.deepSkyObjects)
              object.at(object.x + x, object.y + y),
          ],
          matchedStars: [
            for (final match in patch.matchedStars)
              GaiaMatch(
                sourceId: match.sourceId,
                ra: match.ra,
                dec: match.dec,
                x: match.x + x,
                y: match.y + y,
                gMagnitude: match.gMagnitude,
              ),
          ],
          magnitudeZeroPoint: patch.magnitudeZeroPoint,
          magnitudeScatter: patch.magnitudeScatter,
          catalogWarning: patch.catalogWarning,
          source: SolveSource.local,
          fieldOfViewDegrees: fullWcs.fieldOfViewDegrees,
          wcs: fullWcs,
          rotationDegrees: _rotationDegrees(fullWcs),
          matchedCount: patch.matchedCount,
        );
        // 用整幅 WCS 重新补星座、深空天体和角尺寸；块内那份名单只是一部分。
        return decorateSolve(lifted);
      }
    }
    return null;
  }

  /// 建索引时并不知道像面尺寸，解算前每帧都要补上——[_collectInliers] 靠它
  /// 估计要取多大的天区。索引是空的就当这一层不存在。
  _TriangleIndex? _forFrame(_TriangleIndex index, SkyAnalysis analysis) {
    if (index.triangleCount == 0) return null;
    index.frameWidth = analysis.width.toDouble();
    index.frameHeight = analysis.height.toDouble();
    return index;
  }

  /// 图内端参与组三角形的星数，从小到大试。
  ///
  /// 这一串刻度是量出来的，不是拍脑袋定的。三角形指纹认的是「最近的几颗
  /// 邻居」，而两侧手里的星根本不是同一批：目录端只有星表里那几颗，图内端
  /// 却有照片里所有检出。**图内端多出来的星会顶掉真邻居**，一个正确三角形
  /// 都枚举不出来。
  ///
  /// 实测（三张演示图，同一台相机：视场 4.18°、10.68″/px）：
  ///
  /// | 图内端 | demo_m45 | demo_m31 | demo_vesta |
  /// | --- | --- | --- | --- |
  /// | 24 颗 | 解出 24 | 解出 18 | 解出 14 |
  /// | 80 颗 | 解出 42 | 解出 30 | 失败 |
  /// | 120 颗 | 解出 42 | 失败 | 失败 |
  ///
  /// 决定上限的是天区里目录星有多少：M45 那一带 128 颗（比 120 还多），
  /// 120 颗图内星几乎全是目录星，怎么取都行；M31 只有 58 颗、Vesta 一带
  /// 只有 33 颗，取 120 就等于往图内端塞了几十颗目录里没有的暗星。
  ///
  /// 所以从小到大试、第一个成立就收：小档又快又准（演示图上 0.06–1.6 秒），
  /// 大档留给「图里最亮的星不是目录里最亮的星」的情形——画面里有大片星云、
  /// 过曝的亮星盘，或者一颗亮行星杵在那里的时候。
  ///
  /// 起点从 24 降到 8，是因为窄视场把上面的算术推到了另一个极端。四张
  /// Seestar 照片（对角线视场 1.45° 和 2.44°）实测：
  ///
  /// | 图内端 | IC 5146 | NGC 281 | M 20 | M 33 |
  /// | --- | --- | --- | --- | --- |
  /// | 8 颗 | 解出 6 | 失败 | 失败 | 失败 |
  /// | 12 颗 | 解出 7 | 失败 | 解出 11 | 失败 |
  /// | 16 颗 | 解出 7 | 失败 | 解出 13 | 失败 |
  /// | 24 颗 | 假解 | 解出 11 | 解出 16 | 失败 |
  /// | 120 颗 | 失败 | 失败 | 假解 | 失败 |
  ///
  /// 视场越窄，落在画面里的目录星越少（IC 5146 那一带只有十来颗），而
  /// 深叠加出来的照片里检出动辄几千颗。图内端取 24 颗，等于往里塞了十几颗
  /// 目录里根本没有的暗星——真邻居被顶掉，一个正确三角形都枚举不出来。
  /// 取 8 到 16 颗时，图内端几乎全是目录星，邻居关系这才对得上。所以小档
  /// 必须存在，而且必须排在前面。
  ///
  /// 不再多插几档：24 和 48 实测要么一起成功、要么一起失败（M31 是
  /// 24/48/80 都成、96 以上都不成；Vesta 是 32 以下都成、36 以上都不成），
  /// 多一档只是多花一次验证预算，换不来新的天区。失败的那一档很贵——它要
  /// 把预算跑满才肯认输。
  static const _imageStarRungs = [8, 16, 24, 120];

  /// 中间层星表用的是同一串刻度：那一层的星多四倍，但「图内端比目录端多出
  /// 多少颗」这件事和层数无关。窄视场反而最需要小档——中间层本来就是给
  /// 「浅层星数不够」的天区兜底的，而窄视场正是这样的天区。
  static const _midImageStarRungs = [8, 16, 24, 120];

  /// 最深那一层的刻度。
  ///
  /// 和中间层同一串。这一层的星表又密了八倍，但「图内端比目录端多出多少颗」
  /// 这件事和层数无关：同一片天区里，图内端只拿最亮的若干颗检出，目录端却也
  /// 只有那几颗——多给图内端补星补的是目录里根本没有的星，一样顶掉真邻居。
  ///
  /// 实测这一层都是第一档就命中（那三个解出来的稀天区，匹配各花 1 秒上下），
  /// 后面几档是留给「图里最亮的星不是目录里最亮的星」那种情形的。
  static const _deepImageStarRungs = [8, 16, 24, 120];

  /// 同一层索引上，按 [rungs] 逐档重试图内三角形。
  ///
  /// 每档都要重新组图内三角形、重建检出网格——这两件事的代价都和那一档的
  /// 星数同阶，真正贵的索引查询和验证不在其中。
  SolveResult? _matchWithRungs(
    SkyAnalysis analysis,
    _TriangleIndex index,
    List<DetectedStar> detections, {
    required List<int> rungs,
    required int neighbours,
    required int candidatesPerTriangle,
    required int verificationBudget,
    required int budgetMilliseconds,
    required double progressBase,
    required double progressSpan,
    required SolveLayerAttempt layer,
    void Function(SolveProgress progress)? onProgress,
    bool deep = false,
  }) {
    final layerWatch = Stopwatch()..start();
    // 0 = 不设上限：测试和旧调用方保持原行为；选了拍摄场景才给墙钟上限。
    final layerBudget =
        budgetMilliseconds <= 0 ? 1 << 30 : budgetMilliseconds;
    for (var i = 0; i < rungs.length; i++) {
      final remaining = layerBudget - layerWatch.elapsedMilliseconds;
      if (remaining <= 0) break;
      final count = math.min(rungs[i], detections.length);
      if (count < _minimumDetections) continue;
      layer.rungsTried++;
      final stars = detections.take(count).toList(growable: false);
      onProgress?.call(
        SolveProgress(
          progressBase + progressSpan * i / rungs.length,
          t('正在匹配星图三角形'),
          deep: deep,
        ),
      );
      final result = _matchFrom(
        analysis,
        index,
        stars,
        detections,
        _DetectionGrid(stars),
        neighbours: neighbours,
        candidatesPerTriangle: candidatesPerTriangle,
        verificationBudget: verificationBudget,
        budgetMilliseconds: remaining,
        // 解定下来之后可以把内点补到最大那一档的规模——那一档正是旧版在
        // 宽视场上一直用的星数，含多少暗星、有多少碰巧撞上的机会都验过。
        expansionStars: rungs.last,
        onProgress: onProgress,
        deep: deep,
        onRungDone: (elapsed) => layer.rungMilliseconds.add(elapsed),
      );
      if (result != null) return result;
    }
    return null;
  }

  /// 拿着某一层索引跑一遍完整的匹配、内点验证和坐标精修。
  ///
  /// [stars] 是这一档参与组三角形的星（最亮的若干颗），[detections] 是全部
  /// 检出候选。两者分开是因为它们回答的是两个不同的问题：组三角形只敢用最亮
  /// 的那几颗（见 [_imageStarRungs]），而「这个解到底对上了多少颗星」要在
  /// [expansionStars] 那一档的规模上回答，见 [_expandInliers]。
  SolveResult? _matchFrom(
    SkyAnalysis analysis,
    _TriangleIndex index,
    List<DetectedStar> stars,
    List<DetectedStar> detections,
    _DetectionGrid grid, {
    required int neighbours,
    required int candidatesPerTriangle,
    required int verificationBudget,
    required int budgetMilliseconds,
    required int expansionStars,
    void Function(SolveProgress progress)? onProgress,
    bool deep = false,
    void Function(int milliseconds)? onRungDone,
  }) {
    final rungWatch = Stopwatch()..start();
    void finishRung() {
      if (!rungWatch.isRunning) return;
      rungWatch.stop();
      onRungDone?.call(rungWatch.elapsedMilliseconds);
    }
    final imageTriangles = _imageTriangles(stars, neighbours);
    final diagonalPixels = math.sqrt(
      index.frameWidth * index.frameWidth +
          index.frameHeight * index.frameHeight,
    );
    // 三角形最长边一般比整幅对角线短，所以这里把场景给的视场范围放宽
    // 0.5–2 倍：只砍明显不在这个尺度上的候选，不负责精确判定。
    final minScale = diagonalPixels > 0
        ? (_activeHint?.minFieldDegrees ?? _minimumFieldDegrees) /
            diagonalPixels *
            0.5
        : null;
    final maxScale = diagonalPixels > 0
        ? (_activeHint?.maxFieldDegrees ?? _maximumFieldDegrees) /
            diagonalPixels *
            2.0
        : null;
    var verifications = 0;
    _Fit? best;
    outer:
    for (final triangle in imageTriangles) {
      if (rungWatch.elapsedMilliseconds >= budgetMilliseconds) {
        break;
      }
      for (final candidate in index.lookup(
        triangle.r2,
        triangle.r3,
        ratioTolerance: triangle.ratioTolerance,
        limit: candidatesPerTriangle,
        vertexMagnitudes: [
          stars[triangle.vertices.$1].instrumentalMagnitude,
          stars[triangle.vertices.$2].instrumentalMagnitude,
          stars[triangle.vertices.$3].instrumentalMagnitude,
        ],
        imageLongestSidePixels: triangle.longestSidePixels,
        minScaleDegreesPerPixel: minScale,
        maxScaleDegreesPerPixel: maxScale,
      )) {
        if (verifications >= verificationBudget) break;
        if ((verifications & 63) == 0 &&
            rungWatch.elapsedMilliseconds >= budgetMilliseconds) {
          break outer;
        }
        verifications++;
        final fits = _fitsFromCorrespondence(index, stars, triangle, candidate);
        // 逐个验内点：等腰情形下错配的残差可能更小，但它投影不出足够多的
        // 内点，所以不能只看残差最小的那一个。
        for (var attempt = 0;
            attempt < fits.length && attempt < _permutationAttempts;
            attempt++) {
          final fit = fits[attempt];
          final inliers = _collectInliers(index, grid, fit, stars.length);
          if (inliers.isEmpty) continue;
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
    if (best == null) {
      finishRung();
      return null;
    }

    // 解已经定下来了，这时候再把内点补全。
    //
    // 组三角形用最亮的 8 颗是为了让图内端的近邻关系和目录端对得上（见
    // [_imageStarRungs]），但「找到了」和「对上了多少颗」是两件事：小档
    // 定下来的变换拿去投影目录星，能把视场里所有亮到能被检出、又确实在目录
    // 里的星都对上。不补的话，报告里的「匹配到 N 颗星」、星等零点和散布就
    // 只按那 8 颗算——那 8 颗的职责是找到解，不是给出最终那份测量。
    //
    // 补的上限是 [expansionStars]，也就是最大那一档的规模。一次投影加查表
    // 而已，比再搜一遍三角形便宜几个数量级。
    final expanded = _expandInliers(
      index,
      detections.take(expansionStars).toList(growable: false),
      best,
    );
    if (expanded.length > best.inliers.length) {
      final refit = _fitSimilarity(
        [
          for (final inlier in expanded)
            _complexOf(detections[inlier.detectionIndex]),
        ],
        [
          for (final inlier in expanded)
            _Complex.from(index.skyPointOf(inlier.catalogVertex, best.reference)),
        ],
        best.flip,
      );
      if (refit != null) {
        refit.reference = best.reference;
        refit.inliers = expanded;
        best = refit;
      } else {
        best.inliers = expanded;
      }
    }

    onProgress?.call(SolveProgress(0.7, t('正在精修天球坐标'), deep: deep));
    final wcs = _buildWcs(index, analysis, detections, best);
    if (wcs == null) {
      finishRung();
      return null;
    }

    onProgress?.call(SolveProgress(0.88, t('正在标定星等零点'), deep: deep));
    finishRung();
    return _buildResult(index, analysis, detections, best, wcs);
  }

  /// 解定下来之后，把内点补全到给的一批检出星点上。
  ///
  /// 这一步**不设门槛**：门槛是给「还没认定的候选」用的，而这里数的是那个
  /// 已经认定的解到底对上了多少颗星。
  List<_Inlier> _expandInliers(
    _TriangleIndex index,
    List<DetectedStar> detections,
    _Fit fit,
  ) {
    final candidates = _catalogCandidates(index, fit);
    if (candidates.isEmpty) return const [];
    return _matchInliers(index, candidates, _DetectionGrid(detections), fit);
  }

  static const _minimumDetections = 4;

  /// 从最亮的多少颗里选「种子」去组三角形。种子按亮度排序，所以最可能
  /// 命中的三角形排在最前面，验证预算花在刀刃上。
  ///
  /// 这是个上限，实际取多少由 [PlateSolver._imageStarRungs] 那一档决定：
  /// 档位比它小的时候，能当种子的星也只有那么多。
  static const _seedStars = 40;

  /// 一个图内三角形最多往下送几个候选对应关系。
  ///
  /// 桶里按「比值最接近」排序，真的那个未必排第一：目录一密，和它比值几乎
  /// 一样、其实在天上另一处的三角形就多，只取十来个会被挤出去，整个天区就
  /// 这么解不出来了。取 24 是留出这个余量；反正真正封顶的是验证预算，
  /// 多看几个候选只是把它们排进队里，不会让噪声图更贵。
  static const _candidatesPerTriangle = 24;

  /// 深层星表里的对应值。星又密了几倍，同一个指纹上的假候选也多，所以要
  /// 多看几个；验证预算跟着放大，不然真正的那个还没轮到、预算就先花光了。
  /// 深层只在浅层和中层都失败后才跑，慢一点换的是「本来拿不到的结果」，值得。
  /// 实测这一层的匹配是一秒上下，预算远没有花满——真正的代价在索引，不在验证。
  static const _deepCandidatesPerTriangle = 48;
  static const _deepVerificationBudget = 8000;

  /// 一次解算里最多验证多少个候选对应关系。每条验证都要投影一批目录星
  /// 再数内点，是整条链路里最贵的部分，必须封顶，否则一张噪声图能把
  /// 手机卡住好几秒。
  static const _verificationBudget = 4000;

  /// 判定一个解成立所需的最少内点数。
  ///
  /// 这个数不能是常数。
  ///
  /// 假解是怎么来的？一个候选变换由三组对应关系**定义**，所以那三颗星必然算
  /// 内点；剩下的图内星点每落进某颗目录星附近 [_inlierTolerancePixels] 个像素
  /// 以内就再算一个。假解能凑到几个「额外的」内点，取决于「撞上一颗目录星」
  /// 这件事有多容易发生：
  ///
  ///     p ≈ 图内星点数 × π·容差² / 像面面积
  ///
  /// 试验次数就是这条候选要考虑的目录星数。两张图可以差出两三个数量级：
  ///
  /// * 400×320 的小图、视场里八十颗目录星：p ≈ 2×10⁻²，四千次候选里冒出一个
  ///   五六个内点的假解几乎是必然——这就是原来那个常数 10 想挡的东西；
  /// * 675×1200 的智能望远镜照片、视场里只有十几颗目录星：p ≈ 3×10⁻⁴，
  ///   再多凑三个内点要靠运气，概率不到十万分之一。
  ///
  /// 所以门槛按这张图自己的概率算：取最小的「额外内点数」，使得四千次候选里
  /// 蒙出这么多额外内点的期望低于 [_falseAcceptBudget]。宽视场那次算出来仍然
  /// 是九、十（和原来量出来的常数一致），窄视场那次降到六——正是智能望远镜的
  /// 视场，一颗目录星都不该浪费。
  ///
  /// 下限 [_minimumExtraInliers] 是给「p 恰好算得很小」留的保险：定义变换的
  /// 那三颗之外，至少还要有三颗独立地撞上目录星，才认这个解。
  int _inlierFloor({
    required int imageStars,
    required int catalogStars,
    required double areaPixels,
  }) {
    final seed = _definingCorrespondences;
    final trials = catalogStars - seed;
    if (trials <= 0) return _minimumInliers;
    final hit = (imageStars * math.pi * _inlierTolerancePixels *
            _inlierTolerancePixels /
            areaPixels)
        .clamp(0.0, 1.0);
    if (hit <= 0) return _minimumInliers;
    // 期望假解数 = 组合数 × p^extra × 候选总数。
    final allowance = _falseAcceptBudget / _verificationBudget;
    var combination = 1.0; // C(trials, extra)
    for (var extra = 1; extra <= trials; extra++) {
      combination = combination * (trials - extra + 1) / extra;
      if (combination * math.pow(hit, extra) <= allowance) {
        // 上限压在 [_minimumInliers] 上：这道门只在天区稀疏时放宽，
        // 任何一张图都不会比过去更严。
        final needed = math.max(extra, _minimumExtraInliers);
        return seed + math.min(needed, _minimumInliers - seed);
      }
    }
    return _minimumInliers;
  }

  /// 定义一次候选变换的那三组对应关系——它们必然算内点。
  static const _definingCorrespondences = 3;

  /// 除了那三颗以外，至少还要撞上几颗才认。
  static const _minimumExtraInliers = 3;

  /// 一张图上容忍的「假解期望数」。除以 [_verificationBudget] 之后是单次
  /// 候选的假解概率上限。
  static const _falseAcceptBudget = 1e-3;

  /// 门槛的上限。
  ///
  /// 十是原来量出来的那个固定门槛：四百乘三百二十的小图上、视场里八十颗
  /// 目录星时，[`_inlierFloor`] 算出来正好也是十。留着它当上限，是为了让
  /// 宽视场、目录密的老行为一个字节都不变——新的算法只允许在天区稀疏的
  /// 时候放宽，绝不在任何一张图上比过去更严。
  static const _minimumInliers = 10;

  /// 找到一个足够强的解就不再往下扫了。
  static const _strongInliers = 15;

  /// 变换落点附近那一圈目录星，按亮到暗排——真的对应关系都在最亮的这批里。
  List<int> _catalogCandidates(_TriangleIndex index, _Fit fit) {
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
    return index.starsNearSky(
      centreRa,
      centreDec,
      diagonalDegrees / 2 + 0.5,
      limit: _maximumCatalogCandidates,
    );
  }

  /// 把这些目录星投影回图像，数有多少颗落在检出星点附近。
  ///
  /// [floor] 是早退用的下限：剩下的目录星全中也不够，这一条候选已经没戏。
  /// 目录星按亮到暗排，真的对应关系靠前，所以这一刀通常只砍在假候选上——
  /// 而假候选是绝大多数。
  List<_Inlier> _matchInliers(
    _TriangleIndex index,
    List<int> candidates,
    _DetectionGrid grid,
    _Fit fit, {
    int floor = 1,
  }) {
    final inliers = <_Inlier>[];
    final used = <int>{};
    var seen = 0;
    for (final vertex in candidates) {
      seen++;
      if (inliers.length + (candidates.length - seen) < floor) break;
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
    _lastTrace?.noteInliers(inliers.length, floor);
    return inliers.length < floor ? const [] : inliers;
  }

  /// 验一条候选：门槛由 [_inlierFloor] 按这张图自己的概率算出来；够不着门槛
  /// 就返回空表，调用方只当「这次候选没戏」。
  List<_Inlier> _collectInliers(
    _TriangleIndex index,
    _DetectionGrid grid,
    _Fit fit,
    int imageStars,
  ) {
    final candidates = _catalogCandidates(index, fit);
    final floor = _inlierFloor(
      imageStars: imageStars,
      catalogStars: candidates.length,
      areaPixels: index.frameWidth * index.frameHeight,
    );
    if (candidates.length < floor) return const [];
    return _matchInliers(index, candidates, grid, fit, floor: floor);
  }

  /// 一个候选最多试几种顶点对应。排在前面的是残差小的，正常三角形第一个
  /// 就能过；只有接近等腰、形状本身有歧义时才会往后试。
  static const _permutationAttempts = 4;

  /// 数内点时最多看视场里最亮的多少颗目录星。视场内的目录星可能有几百
  /// 颗，但正确的解一定落在最亮的那批上——检出星点本身也是挑最亮的。
  static const _maximumCatalogCandidates = 80;

  /// 合理的视场范围。
  ///
  /// 上限 60° 是防错：解出来的视场大到这个地步，说明拟合出来的尺度是错的。
  ///
  /// 下限原来是 3°，理由是「比这更窄的天区里目录星不够密」。这个理由本身
  /// 没错，但拿它当**硬门槛**是错的：智能望远镜（Seestar S50 的对角线视场
  /// 只有 1.45°、S30 是 2.44°）拍的每一张照片都落在门槛外，于是这些机器拍
  /// 的图一张都解不出来——哪怕三角形其实已经对上了。实测四张 Seestar 照片，
  /// 把这一条放开之后 NGC 281 和 M 20 立刻就解出了正确的坐标（内点 11 和
  /// 13～18 个）。
  ///
  /// 目录星够不够密，本来就由内点验证自己回答：真正的守卫是
  /// [_inlierFloor]——它是按这张图的像面大小和视场里的目录星数算出来的。
  /// 视场小到目录星不够时，那条判据自然会把假解挡掉。所以这里只留一个
  /// 「尺度不至于离谱」的下限。
  static const _minimumFieldDegrees = 1.0;
  static const _maximumFieldDegrees = 120.0;

  /// 图内三角形，构造方式和索引端严格一致：最亮的若干颗当种子，每颗连同
  /// 它最近邻的 [neighbours] 颗一共 [neighbours] + 1 颗，从中任取三颗。
  ///
  /// [neighbours] 必须和这一趟用的索引层一致（浅层 6、深层 4），否则近邻
  /// 关系对不上，枚举出来的不是同一批三角形。
  ///
  /// 之所以不直接对「最亮的 N 颗」两两三点，是因为那样子三角形边长由
  /// 亮度分布决定，而索引端的边长由星间距离决定，广角照片下两者能差出
  /// 十几倍，比值指纹就再也对不上了。
  List<_ImageTriangle> _imageTriangles(List<DetectedStar> stars, int neighbours) {
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
                longestSidePixels: sides[2].$1,
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
        final minField = _activeHint?.minFieldDegrees ?? _minimumFieldDegrees;
        final maxField = _activeHint?.maxFieldDegrees ?? _maximumFieldDegrees;
        if (field < minField || field > maxField) {
          continue;
        }
        fits.add(fit);
      }
    }
    if (fits.isEmpty) return const [];
    fits.sort((a, b) => a.residual.compareTo(b.residual));
    // 同一次对应关系的十二种次序里，只有残差和最好的那个相当的才值得数内点。
    // 顶点接错了的拟合残差会大出一截，而「数内点」是整条链路最贵的一步——
    // 目录一密，每条候选的花费就直接决定了验证预算能覆盖多少个候选。
    //
    // 下限取两个像素是为了等腰三角形：那时几种次序本来就分不开，残差都很小，
    // 该留的都得留下，不能因为「最好的是零残差」就把它们一起丢掉。
    final allowance = math.max(
      fits.first.residual * 2,
      _inlierTolerancePixels * 2 * fits.first.a.abs,
    );
    return [
      for (final fit in fits)
        if (fit.residual <= allowance) fit,
    ];
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
    // 上限跟 SolveHint 的最大视场一致（120°）；原来的 90° 会把手机超广角
    // 和宽幅拼接片直接判死。
    final diagonalDegrees = math.sqrt(
          analysis.width * analysis.width +
              analysis.height * analysis.height,
        ) *
        current.a.abs;
    if (diagonalDegrees > 120) return null;

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
      // Gaia 补充层只做背景，不起名字：它们没有中文名也没有拜耳编号，
      // 硬标出来只能是「HIP -12345」这种编造的名字，而图上标注一个字都
      // 错不得。它们照样参与解算和测光，只是不上图。
      if (star.isGaia) continue;
      final (x, y) = wcs.worldToPixel(star.ra, star.dec);
      if (x < 0 || y < 0 || x >= analysis.width || y >= analysis.height) continue;
      final name = catalog.nameOf(star);
      named.add(
        SkyObject(
          catalog.displayName(star),
          star.ra,
          star.dec,
          name?.spectralType?.isNotEmpty == true
              ? t('恒星 · {0}', [name!.spectralType])
              : t('恒星'),
          magnitude: star.vMagnitude,
          magnitudeBand: 'V',
          x: x,
          y: y,
          isLocal: true,
        ),
      );
    }

    // 星等零点：目录给真实 V 星等，图像给仪器星等，两者之差就是零点。
    //
    // 只拿 Hipparcos 那层算：Gaia 补充层装的是 G 星等，和 V 差着零点几等，
    // 混进来会让整条零点跟着内点的成分漂移——同一天区换一张图，零点就可能
    // 变一次，而用户看到的是一颗星报出的星等，那必须是个稳定的数。
    final offsets = <double>[];
    for (final inlier in fit.inliers) {
      final star = index.starOf(inlier.catalogVertex);
      if (star.isGaia) continue;
      offsets.add(
        star.vMagnitude - stars[inlier.detectionIndex].instrumentalMagnitude,
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

    final decoration = _decorate(wcs, centreRa, centreDec, catalogStars);

    return SolveResult(
      centerRa: centreRa,
      centerDec: centreDec,
      arcsecPerPixel: wcs.arcsecPerPixel,
      namedStars: named,
      deepSkyObjects: _localDeepSky(wcs, centreRa, centreDec, radius),
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
      constellations: decoration.constellations,
      constellationFigures: decoration.figures,
      wcs: wcs,
      rotationDegrees: _rotationDegrees(wcs),
      matchedCount: fit.inliers.length,
    );
  }

  /// 画面里落进了哪些深空天体，坐标已经投影成像素。
  ///
  /// 判定分两种，因为同一把尺子量不了所有情况：
  ///
  ///   * **中心落在画面内** —— 用户确实把镜头对上了它，直接收。
  ///   * **中心在外面，但天体的圆压到了画面** —— 只有够大的天体才算。这条是
  ///     补上来的：面纱星云的东西两弧加起来能有一度多，广角拍一张，弧的
  ///     大部分在画面里、中心却落在外头，按旧规则整条都被丢掉，用户看着自己
  ///     明明拍到了的东西在图上没有任何标记。
  ///
  /// 为什么还留着「够大才算」这个条件：如果按圆圈算而不加门槛，广角照片里
  /// 会有几十个只有边缘擦过去的暗星系挤进来，把真正主体淹掉。
  /// 内置目录里落进画面的深空天体，大的排在前面。
  ///
  /// **本机和在线两条路都调它**，这是刻意的：一份「画面里有哪些深空天体」的名单
  /// 不应该取决于这一次是哪种解算方式。放在线那条路原先不查内置目录，名单完全由
  /// SIMBAD 给，于是同一个天区换一种解算方式会得到两份不同的名单——用户拍 M33 的
  /// 那张，在线时名单里没有 M33，而旁边的小星云在，就是因为这个。
  ///
  /// 像素坐标用 [Wcs.width]/[Wcs.height] 判边界：这两个值就是建 WCS 时那份图像的
  /// 尺寸（见 `_buildWcs`），所以本机路上在线解算拿回来的 WCS 用同一套判据都成立。
  List<SkyObject> _localDeepSky(
    Wcs wcs,
    double centreRa,
    double centreDec,
    double radius,
  ) {
    final catalog = deepSky;
    if (catalog == null) return const [];
    final objects = <SkyObject>[];
    for (final object in catalog.near(centreRa, centreDec, radius)) {
      final (x, y) = wcs.worldToPixel(object.ra, object.dec);
      if (!_reachesFrame(
        x: x,
        y: y,
        sizeArcmin: object.angularSizeArcmin,
        arcsecPerPixel: wcs.arcsecPerPixel,
        width: wcs.width,
        height: wcs.height,
      )) {
        continue;
      }
      objects.add(object.toSkyObject(x, y));
      // 广角照片里两三千条目录天体能有一两百个落进画面，全标出来会把星点、
      // 星座线一起淹掉。[catalog.near] 已经按角尺寸从大到小排好，所以先丢掉的
      // 是小的那些——留下的是画面里最显眼的东西。
      if (objects.length >= _maxDeepSkyObjects) break;
    }
    return objects;
  }

  /// 这个天体要不要标。
  ///
  /// 中心在画面内的一律要；中心在外面的，只有「圆压到画面」并且「够大」才要。
  /// 「够大」的门槛取像场对角线的 10%，和报告里 `fieldFraction` 的「这张照片的
  /// 主体」用的是同一条线——两处说法不一致的话，同一个天体会在图上被标出来、
  /// 却在报告里被说成「只占百分之几，偏小」。
  ///
  /// 本机和在线两条路都调它。在线那条拿回来的天体原本没有角尺寸，是
  /// [_sizedDeepSky] 从内置目录里按位置补上的，补完再判，规则和本机一致。
  static bool _reachesFrame({
    required double x,
    required double y,
    required double? sizeArcmin,
    required double arcsecPerPixel,
    required int width,
    required int height,
  }) {
    if (x >= 0 && y >= 0 && x < width && y < height) return true;
    if (sizeArcmin == null || sizeArcmin <= 0 || arcsecPerPixel <= 0) return false;
    final radiusPixels = sizeArcmin * 60 / arcsecPerPixel / 2;
    final diagonal = math.sqrt(width * width + height * height);
    if (radiusPixels * 2 < diagonal * _outOfFrameSizeFraction) return false;
    // 到画面的最短距离（中心在画面外时为正）。
    final dx = math.max(math.max(-x, x - width), 0.0);
    final dy = math.max(math.max(-y, y - height), 0.0);
    return math.sqrt(dx * dx + dy * dy) <= radiusPixels;
  }

  static const _outOfFrameSizeFraction = 0.1;

  static const _maxDeepSkyObjects = 30;

  /// 星座名与星座连线。
  ///
  /// 名字回答「这张照片拍的是哪片天」，连线让人在图上直接认出星座的轮廓——
  /// 这两样 astrometry.net 的标注图上都有，这里用内置目录自己算一份。
  ///
  /// 投影必须在这里做：连线数据存的是 HIP 星对，只存在于后台 isolate 的
  /// 星表里，界面拿不到也没必要拿。把投影后的像素线段随结果带出去，界面
  /// 就只负责画。
  _Decoration _decorate(
    Wcs wcs,
    double centreRa,
    double centreDec,
    List<CatalogStar> catalogStars,
  ) {
    // 视场中心所在星座排第一，它才是「这张照片拍的是哪个星座」的答案。
    final centreConstellation = catalog.constellationAt(centreRa, centreDec);
    final centreAbbreviation = centreConstellation?.isEmpty ?? true
        ? ''
        : centreConstellation!.abbreviation;

    final names = <String>[];
    final seen = <String>{};
    if (centreAbbreviation.isNotEmpty) {
      seen.add(centreAbbreviation);
      names.add(centreConstellation!.displayName);
    }
    for (final star in catalogStars) {
      if (star.vMagnitude > 5.5) continue;
      final constellation = catalog.constellationOf(star);
      if (constellation == null || constellation.isEmpty) continue;
      if (seen.add(constellation.abbreviation)) {
        names.add(constellation.displayName);
      }
    }

    // 连线本身走全天 88 个星座，而不是只走视场里那几颗星所属的星座：星座
    // 边界划分的是恒星归属，而连线画的是图形轮廓，两者在边界附近并不重合。
    final figures = <ConstellationFigure>[];
    for (final constellation in catalog.constellations) {
      if (constellation.isEmpty) continue;
      final segments = <List<double>>[];
      var sumX = 0.0;
      var sumY = 0.0;
      for (final (hipA, hipB) in constellation.lines) {
        final first = catalog.byHip[hipA];
        final second = catalog.byHip[hipB];
        if (first == null || second == null) continue;
        final (ax, ay) = wcs.worldToPixel(first.ra, first.dec);
        final (bx, by) = wcs.worldToPixel(second.ra, second.dec);
        final clipped = _clipToImage(ax, ay, bx, by, wcs.width, wcs.height);
        if (clipped == null) continue;
        segments.add(clipped);
        sumX += (clipped[0] + clipped[2]) / 2;
        sumY += (clipped[1] + clipped[3]) / 2;
      }
      if (segments.isEmpty) continue;
      figures.add(
        ConstellationFigure(
          name: constellation.displayName,
          segments: segments,
          labelX: sumX / segments.length,
          labelY: sumY / segments.length,
        ),
      );
    }

    // 视场大到几十度时能框进十几个星座，全画出来只剩一团线，反而看不出
    // 哪个是哪个。中心星座钉在最前——指标条上写着「星座：猎户座」，图上
    // 就必须能找到猎户座。
    figures.sort((a, b) {
      final first = a.name == centreConstellation?.displayName ? 1 : 0;
      final second = b.name == centreConstellation?.displayName ? 1 : 0;
      if (first != second) return second - first;
      return b.segments.length.compareTo(a.segments.length);
    });
    if (figures.length > _maxFigures) {
      figures.removeRange(_maxFigures, figures.length);
    }

    return _Decoration(names, figures);
  }

  /// 视场里最多画几个星座的连线。
  static const _maxFigures = 8;

  /// 把一条线段裁到图像矩形内；整条都在框外时返回 null。
  ///
  /// 视场边缘的星座线往往只有一个端点在画面里，不裁的话会在标注图上拉出
  /// 几条飞到画面外的长线。用 Liang–Barsky 按参数裁剪，只留框内那一段。
  static List<double>? _clipToImage(
    double x1,
    double y1,
    double x2,
    double y2,
    int width,
    int height,
  ) {
    // worldToPixel 对落在切平面背后的点返回 ±1e9 这种哨兵值，带着它做参数
    // 运算会算出 NaN，所以先按量级剔掉。图像本身只有几千像素，这个上限
    // 不可能误伤真实坐标。
    if (!_isSane(x1) || !_isSane(y1) || !_isSane(x2) || !_isSane(y2)) {
      return null;
    }

    final dx = x2 - x1;
    final dy = y2 - y1;
    var enter = 0.0;
    var leave = 1.0;
    final edges = [-dx, dx, -dy, dy];
    final offsets = [
      x1,
      width - x1,
      y1,
      height - y1,
    ];
    for (var edge = 0; edge < 4; edge++) {
      final normal = edges[edge];
      final offset = offsets[edge];
      if (normal == 0) {
        // 平行于这条边：只要在边内侧就整条保留，在外侧就整条丢掉。
        if (offset < 0) return null;
        continue;
      }
      final ratio = offset / normal;
      if (normal < 0) {
        if (ratio > leave) return null;
        if (ratio > enter) enter = ratio;
      } else {
        if (ratio < enter) return null;
        if (ratio < leave) leave = ratio;
      }
    }
    return [
      x1 + enter * dx,
      y1 + enter * dy,
      x1 + leave * dx,
      y1 + leave * dy,
    ];
  }

  static bool _isSane(double value) => value.isFinite && value.abs() < 1e6;

  /// 给只带 WCS 的结果补上星座名与连线。
  ///
  /// 在线解算返回的结果里这两个字段都是空的——星座归属是本机拿内置目录算的。
  /// 而视场窄的望远镜照片多半本机解不出来、正好都走这条在线路径，所以这里
  /// 必须补上，只照顾本机解算那一支的话用户撞上的恰好是缺口。
  SolveResult decorateSolve(SolveResult result) {
    final wcs = result.wcs;
    if (wcs == null) return result;
    final (centreRa, centreDec) = wcs.imageCenter;
    final radius = math.max(wcs.fieldOfViewDegrees / 2 + 0.3, 0.05);
    final decoration = _decorate(
      wcs,
      centreRa,
      centreDec,
      catalog.starsNear(centreRa, centreDec, radius),
    );
    return result.withConstellationDecoration(
      decoration.constellations,
      decoration.figures,
      deepSkyObjects: _sizedDeepSky(result),
    );
  }

  /// 标出疑似运动天体（行星、小行星、彗星、太阳）。
  ///
  /// [moment] 为 null 就原样返回：这些天体的位置随日期变，没有拍摄时刻就没有
  /// 判据可说，这时候报任何东西都是猜。
  ///
  /// 判据的前一半落在这里——「星表在这一带没有星」。所以这件事必须由持有星表
  /// 的一侧来做，`moving.dart` 只管几何。放在 [solve] 之外而不是塞进去，是因为
  /// 在线解算拿回来的坐标同样要过这一道，塞进 solve 就只能覆盖本机那条路。
  SolveResult annotateMovingBodies(
    SolveResult result,
    SkyAnalysis analysis,
    DateTime? moment,
  ) {
    final wcs = result.wcs;
    if (wcs == null || moment == null) return result;

    // 太阳也从同一组根数白拿一个：地心看到的太阳方向就是地球日光心方向的
    // 反方向，不需要为它在表里单占一行。
    final sun = sunPosition(moment);
    final predictions = <PredictedBody>[
      ...predictedBodies(moment),
      sun,
      // 小行星和彗星来自另一份表（构建时抓的内置目录），亮度先筛一道再比位置。
      // 顺序不能反：全部 939 颗彗星一起比，8 角分容差下随机吻合的期望接近 5 个。
      ...?smallBodies?.visibleBodies(moment, sunRa: sun.ra, sunDec: sun.dec),
    ];

    final findings = matchMovingBodies(
      analysis: analysis,
      wcs: wcs,
      predictions: predictions,
      magnitudeZeroPoint: result.magnitudeZeroPoint,
      // 半径从角分换成度：目录那边的接口是按度收的。查的是全部星表（含 Gaia
      // 补充层）——一颗 Gaia 星被拍到了也同样是恒星，不是行星。
      hasCatalogStarNear: (ra, dec, radiusArcmin) =>
          catalog.starsNear(ra, dec, radiusArcmin / 60).isNotEmpty,
    );

    final unmatched = _unidentifiedComponents(
      smallBodies,
      moment,
      findings,
      wcs,
      analysis,
    );
    if (findings.isEmpty && unmatched.isEmpty) return result;
    return result.withMovingBodies([...findings, ...unmatched]);
  }

  /// 画面里那几颗「位置算得出来、图上却没认出来」的亮小天体。
  ///
  /// 这一条专门为了不静默省略。内置目录里那 21 颗是逐个挑出来的，用户很可能正是
  /// 冲着其中某一颗去的：冥王星只有 14.6 等、阅神星 18.6 等，手机根本拍不到——
  /// 报告里什么都不说，用户只会以为这个 APP 不认识它。所以拍不到的也要说一句
  /// 「它今天在这张照片的这个位置，但亮度 X 等，这个器材拍不到」。
  ///
  /// 只对那 21 颗逐个做，不对 939 颗彗星做：彗星本来就是「够亮才参与比对」，
  /// 给每一张照片都来一段「今天有 400 颗彗星在画面里但你看不见」，那不是在告知，
  /// 是在淹没。
  ///
  /// 一次最多给 3 颗，按亮度取最亮的：广角照片里同时落进四五颗主带小行星是
  /// 常事，全列出来这条提示就变成了噪声。
  List<MovingBodySuspicion> _unidentifiedComponents(
    SmallBodyCatalog? catalog,
    DateTime moment,
    List<MovingBodySuspicion> findings,
    Wcs wcs,
    SkyAnalysis analysis,
  ) {
    if (catalog == null || catalog.components.isEmpty) return const [];
    final identified = {
      for (final body in findings)
        if (body.detected) body.name,
    };
    final found = <MovingBodySuspicion>[];
    for (final body in catalog.components) {
      if (identified.contains(body.name)) continue;
      final position = positionOf(body, moment);
      if (position == null) continue;
      final (x, y) = wcs.worldToPixel(position.ra, position.dec);
      if (!x.isFinite || !y.isFinite) continue;
      if (x < 0 || y < 0 || x > analysis.width || y > analysis.height) continue;
      found.add(
        MovingBodySuspicion(
          name: body.name,
          ra: position.ra,
          dec: position.dec,
          x: x,
          y: y,
          separationArcsec: 0,
          magnitude: magnitudeOf(body, moment),
          distanceAu: position.distanceAu,
          kind: body.kind,
          // 关键：没有检出，所以图上一个记号都不画。
          detected: false,
          magnitudeIsRough: !body.magnitudeIsReliable,
          catalogBuilt: catalog.built.isEmpty ? null : catalog.built,
        ),
      );
    }
    found.sort((a, b) => (a.magnitude ?? 99).compareTo(b.magnitude ?? 99));
    return found.take(3).toList();
  }

  /// 给在线解算带回来的深空天体补上角尺寸。
  ///
  /// SIMBAD 只给名字和类型，不给尺寸，所以在线路径的「占了画面多大」那一段
  /// 本来是空的。本机目录里有尺寸，按坐标对一下就能补——对不上就留空，
  /// 报告里写「尺寸未知」，不拿一个近邻的数凑上去。
  /// 给在线解算拿回来的深空天体补角尺寸，再按「圆有没有压到画面」筛一遍。
  ///
  /// 在线那条路的名字和坐标来自 SIMBAD，SIMBAD 不给角尺寸——它连「这个天体
  /// 多大」都不知道，所以位置对不对、标不标得出来，只能靠内置目录按位置补。
  /// 补上尺寸之后就和本机那条路用同一个判据（[_reachesFrame]），两条路对于
  /// 「什么算拍到了」不会各说各话。
  List<SkyObject> _sizedDeepSky(SolveResult result) {
    final catalog = deepSky;
    final wcs = result.wcs;
    if (catalog == null || wcs == null) return result.deepSkyObjects;
    final (centreRa, centreDec) = wcs.imageCenter;
    final radius = math.max(wcs.fieldOfViewDegrees / 2 + 0.3, 0.05);

    // 先摆内置目录里落进画面的那些，大的在前。
    //
    // 顺序是有意的，也是这次改动的要点。在线那条路的天体名单原先**完全**由
    // SIMBAD 决定（内置目录只用来补角尺寸），而 SIMBAD 的返回顺序跟着主名走，
    // 和「哪个醒目」没有半点关系——[_maxDeepSkyObjects] 条的上限先被一批小星云
    // 占满时，画面里最大的那个天体就掉了。用户拍 M33 的那张就是这么丢的：旁边
    // 的小星云进了名单，M33 没有，而内置目录里明明有它（`M 33`，带角尺寸和星等）。
    // 内置目录对「这片天区有哪些 NGC/IC/Messier 天体」是完整的，所以名单先由它
    // 来定；SIMBAD 独有的那些补在后面，不会因此消失。
    final kept = _localDeepSky(wcs, centreRa, centreDec, radius);

    // 再把 SIMBAD 有、内置目录没有的补上——行星状星云、暗星云这类内置目录不收的
    // 目标，全丢会显得这份名单漏了东西。它们没有角尺寸（SIMBAD 不给），按位置去
    // 内置目录找得到就补，找不到就空着：宁可写「尺寸未知」，也不编一个数出来。
    for (final object in result.deepSkyObjects) {
      if (kept.length >= _maxDeepSkyObjects) break;
      if (kept.any((known) => _isSameObject(
          known.ra, known.dec, object.ra, object.dec))) {
        continue;
      }
      final size = object.angularSizeArcmin ??
          catalog.angularSizeNear(object.ra, object.dec);
      if (!_reachesFrame(
        x: object.x,
        y: object.y,
        sizeArcmin: size,
        arcsecPerPixel: wcs.arcsecPerPixel,
        width: wcs.width,
        height: wcs.height,
      )) {
        continue;
      }
      kept.add(
        object.angularSizeArcmin != null
            ? object
            : _withAngularSize(object, size),
      );
    }
    return kept;
  }

  /// 两条路说的是不是同一个天体。
  ///
  /// 按位置比，不按名字：同一个目标在 SIMBAD 里叫 `NGC  598`、在内置目录里叫
  /// `M 33`，名字对不上，位置却精确到角秒。容差取 1 角分——比这更远的就是两个
  /// 不同的天体了（那个距离上不会有第二个 NGC 目标）。
  static bool _isSameObject(
    double ra,
    double dec,
    double otherRa,
    double otherDec,
  ) =>
      angularSeparationDegrees(ra, dec, otherRa, otherDec) <= 1.0 / 60.0;

  static SkyObject _withAngularSize(SkyObject object, double? size) =>
      SkyObject(
        object.name,
        object.ra,
        object.dec,
        object.category,
        magnitude: object.magnitude,
        magnitudeBand: object.magnitudeBand,
        x: object.x,
        y: object.y,
        isLocal: object.isLocal,
        angularSizeArcmin: size,
      );

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

/// 一次解算算出来的星座信息：名字给指标条，连线给标注图。
class _Decoration {
  const _Decoration(this.constellations, this.figures);

  final List<String> constellations;
  final List<ConstellationFigure> figures;
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
    required this.longestSideMicroDegrees,
    required this.keys,
    required this.order,
    required this.bucketStart,
    required this.triangleCount,
  });

  final StarCatalog catalog;

  /// 每个三角形的三个顶点，指向 [StarCatalog.stars] 的下标；顺序是
  /// 「最短边对面的顶点、次长边对面的顶点、最长边对面的顶点」。
  final Int32List vertices;

  /// 最长边/最短边，放大一百万倍存成整数，省内存也便于比较。
  final Int32List r3Quantized;

  /// 最长边的角距（微度）。和 [r3Quantized] 一起构成「形状 + 尺度」指纹：
  /// 形状负责找候选，尺度负责在候选进入拟合之前就把明显不对的扔掉。
  final Int32List longestSideMicroDegrees;

  /// 排序键：`r2 桶号 * r3Steps + r3 桶号`。r2 桶号可以整除出来，
  /// r3 桶号是键对 r3Steps 取余，所以一个数组同时给出两级坐标。
  final Int32List keys;

  /// 按 [keys] 排好序后的三角形下标。
  final Int32List order;

  /// 每个 r2 桶在 [order] 里的起止位置，长度 bucketCount + 1；
  /// 桶内部已经按 r3 排好。
  final Int32List bucketStart;

  /// 三角形个数。
  ///
  /// 不能拿 `vertices.length ~/ 3` 当个数：[vertices] 是按「每颗星最多几个
  /// 三角形」的上界开好的，比实际用掉的长。见 [build]。
  final int triangleCount;

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

  /// 建一层索引。
  ///
  /// [pool] 是这一层允许拿来组三角形的星，也是近邻查询的取值域——池外的星
  /// 就算比池内某颗更近也不能算近邻，否则图内端（只看得到最亮的若干颗检出）
  /// 和目录端枚举出来的就不是同一批三角形。调用方按星表分层给：[PlateSolver]
  /// 浅层给非 Gaia 的那些，深层给整张表。
  static _TriangleIndex build(
    StarCatalog catalog, {
    required List<CatalogStar> pool,
    required int neighbours,
    void Function(double fraction)? onProgress,
  }) {
    if (pool.isEmpty) {
      return _TriangleIndex._(
        catalog: catalog,
        vertices: Int32List(0),
        r3Quantized: Int32List(0),
        longestSideMicroDegrees: Int32List(0),
        keys: Int32List(0),
        order: Int32List(0),
        bucketStart: Int32List(bucketCount + 1),
        triangleCount: 0,
      );
    }
    // 池里最暗的那颗。近邻查询先用它当星等上限缩小扫描范围，再按池的
    // 成员资格精确过滤——同一个星等上限下，池外可能还混着别的层的星。
    final magnitudeLimit = pool.last.vMagnitude;
    final wholeCatalog = pool.length >= catalog.stars.length;
    final inPool = wholeCatalog ? null : <int>{for (final star in pool) star.hip};
    // 多要一倍再筛：按星等上限取回来的近邻里，可能有一部分并不属于这一层
    // （浅层尤其如此，8 等上下的 Gaia 星就卡在边上），筛掉之后还得凑够数。
    // 池子就是整张表时不存在筛掉的可能，按需求量取就行——这一步每颗星都
    // 要跑一遍，多取一倍等于建索引时间翻倍。
    final scan = wholeCatalog ? neighbours + 1 : (neighbours + 1) * 2;

    // 存进索引的下标必须能直接索引 [StarCatalog.stars]。近邻查询返回的是
    // 星对象，它们在表里的位置和「在近邻列表里的位置」完全是两回事，
    // 混用会把三角形悄悄记到另外几颗星头上——解算会失败，而且失败得
    // 毫无线索，所以这里显式换算一次。
    final position = <int, int>{};
    for (var i = 0; i < catalog.stars.length; i++) {
      position[catalog.stars[i].hip] = i;
    }

    // 每颗星最多产出 C(neighbours+1, 3) 个三角形，先按这个上界把数组开好。
    //
    // 不用可增长的 List<int>：最深那层是百万颗星、百万个三角形，可增长数组每
    // 扩容一次都要「新开一块 + 搬一遍」，峰值内存能到最终占用的一倍以上——在
    // 手机上就是一次 OOM。按上界一次开好，浪费的部分是常数比例（实测约两成），
    // 换来的是内存曲线平滑、峰值可预测。
    final capacity = pool.length * _trianglesPerStar(neighbours);
    final tripleVertices = Int32List(capacity * 3);
    final tripleKeys = Int32List(capacity);
    final tripleR3 = Int32List(capacity);
    final tripleR3Bucket = Int32List(capacity);
    final tripleLongest = Int32List(capacity);
    var count = 0;

    // 建索引是纯 CPU 的同步活儿，最深那层要几十秒。进度条在这段时间里一动
    // 不动的话，用户看到的就是「卡死了」——所以每处理一小批就报一次。
    final reportEvery = pool.length ~/ 40 + 1;
    var processed = 0;

    for (final centre in pool) {
      if (++processed % reportEvery == 0) {
        onProgress?.call(processed / pool.length);
      }
      final centreIndex = position[centre.hip]!;
      // 连同自己在内一共 neighbours + 1 颗，任取三颗组三角形。
      final near = catalog.nearestStars(
        centre.ra,
        centre.dec,
        scan,
        magnitudeLimit: magnitudeLimit,
      );
      final group = <CatalogStar>[centre];
      final groupIndex = <int>[centreIndex];
      for (final star in near) {
        if (star.hip == centre.hip) continue;
        if (inPool != null && !inPool.contains(star.hip)) continue;
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
            //
            // 三条边按长短排一下。这里不建表再 sort：每个三角形都要走一遍，
            // 最深那层就是几百万次，三次比较加几次交换比一次列表分配加一次
            // 排序便宜得多。
            var shortest = dab;
            var middle = dbc;
            var longest = dac;
            var shortVertex = groupIndex[c];
            var middleVertex = groupIndex[a];
            var longVertex = groupIndex[b];
            if (shortest > middle) {
              (shortest, middle) = (middle, shortest);
              (shortVertex, middleVertex) = (middleVertex, shortVertex);
            }
            if (middle > longest) {
              (middle, longest) = (longest, middle);
              (middleVertex, longVertex) = (longVertex, middleVertex);
            }
            if (shortest > middle) {
              (shortest, middle) = (middle, shortest);
              (shortVertex, middleVertex) = (middleVertex, shortVertex);
            }
            if (shortest < _minimumSideDegrees) continue;
            final r3 = longest / shortest;
            if (r3 > _maximumRatio) continue;
            final at = count * 3;
            tripleVertices[at] = shortVertex;
            tripleVertices[at + 1] = middleVertex;
            tripleVertices[at + 2] = longVertex;
            tripleKeys[count] = _bucketOf(middle / shortest);
            tripleR3[count] = (r3 * 1000000).round();
            tripleR3Bucket[count] = _r3BucketOf(r3);
            tripleLongest[count] = (longest * 1000000).round();
            count++;
          }
        }
      }
    }

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
      // 这两个数组是按下界开好的，比实际用的长——`triangleCount` 才是准数。
      vertices: tripleVertices,
      r3Quantized: tripleR3,
      longestSideMicroDegrees: tripleLongest,
      keys: keys,
      order: order,
      bucketStart: bucketStart,
      triangleCount: count,
    );
  }

  /// 一颗星最多能产出多少个三角形：连同自己在内 neighbours + 1 颗，任取三颗。
  static int _trianglesPerStar(int neighbours) {
    final n = neighbours + 1;
    return n * (n - 1) * (n - 2) ~/ 6;
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
  ///
  /// 给了 [vertexMagnitudes]（图内端三个顶点、槽位与 [_CatalogTriangle] 一致
  /// 的仪器星等）时，还会把「三个顶点的亮度次序也对得上」的候选提到前面。
  /// 形状相符但亮度次序对不上的三角形几乎全是巧合——星表一深，这种巧合
  /// 就把真正的那个挤到验证队列的末尾，代价是几千次白跑的内点投影。
  Iterable<_CatalogTriangle> lookup(
    double r2,
    double r3, {
    required double ratioTolerance,
    required int limit,
    List<double>? vertexMagnitudes,
    double? imageLongestSidePixels,
    double? minScaleDegreesPerPixel,
    double? maxScaleDegreesPerPixel,
  }) sync* {
    final hasScale =
        imageLongestSidePixels != null &&
        imageLongestSidePixels > 0 &&
        minScaleDegreesPerPixel != null &&
        maxScaleDegreesPerPixel != null;
    final imageSide = imageLongestSidePixels;
    final minScale = minScaleDegreesPerPixel;
    final maxScale = maxScaleDegreesPerPixel;
    bool scaleFits(int triangle) {
      if (!hasScale) return true;
      final scale =
          longestSideMicroDegrees[triangle] / 1000000 / imageSide!;
      return scale >= minScale! && scale <= maxScale!;
    }
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

    // 亮度次序可信的候选先收着，剩下的留作兜底。扫描范围比 [limit] 宽：
    // 真正的那个未必落在最贴近的几个里，但一定在这条容差带里。
    final preferred = vertexMagnitudes == null ? null : <int>[];
    final fallback = preferred == null ? null : <int>[];
    final scanLimit = preferred == null ? limit : limit * _lookupScanFactor;

    var produced = 0;
    outer:
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
            if (!scaleFits(triangle)) continue;
            if (preferred == null) {
              final at = triangle * 3;
              yield _CatalogTriangle(
                (vertices[at], vertices[at + 1], vertices[at + 2]),
                longestSideMicroDegrees[triangle] / 1000000,
              );
              if (++produced >= limit) return;
              continue;
            }
            if (_magnitudesAgree(triangle, vertexMagnitudes!)) {
              preferred.add(triangle);
            } else {
              fallback!.add(triangle);
            }
            if (preferred.length + fallback!.length >= scanLimit) break outer;
          }
        }
      }
    }
    if (preferred == null) return;

    for (final list in [preferred, fallback!]) {
      for (final triangle in list) {
        if (!scaleFits(triangle)) continue;
        final at = triangle * 3;
        yield _CatalogTriangle(
          (vertices[at], vertices[at + 1], vertices[at + 2]),
          longestSideMicroDegrees[triangle] / 1000000,
        );
        if (++produced >= limit) return;
      }
    }
  }

  /// 候选三角形的亮度次序和图内端对得上吗。
  ///
  /// 只比次序，不比绝对值：仪器星等和目录星等之间差着一个未知的测光零点，
  /// 而零点是个常数，不影响谁比谁亮。两边都差不到 [_magnitudeSlack] 等的
  /// 那一对就不作数——图内端的仪器星等本来就有噪声，浅层的 V 和深层的 G
  /// 波段之间还差着一个跟恒星颜色有关的系统项。留下这么大的余量之后，
  /// 还能判出「次序反了」的，就基本可以确定是巧合而不是真对应。
  bool _magnitudesAgree(int triangle, List<double> wanted) {
    final at = triangle * 3;
    final a = catalog.stars[vertices[at]].vMagnitude;
    final b = catalog.stars[vertices[at + 1]].vMagnitude;
    final c = catalog.stars[vertices[at + 2]].vMagnitude;
    return _pairAgrees(a, b, wanted[0], wanted[1]) &&
        _pairAgrees(b, c, wanted[1], wanted[2]) &&
        _pairAgrees(a, c, wanted[0], wanted[2]);
  }

  static bool _pairAgrees(double x, double y, double u, double v) {
    final sky = x - y;
    final image = u - v;
    if (sky.abs() < _magnitudeSlack || image.abs() < _magnitudeSlack) {
      return true;
    }
    return sky.sign == image.sign;
  }

  /// 亮度次序过滤时要多看几倍的候选。
  static const _lookupScanFactor = 6;

  /// 亮度差小到这个程度就不拿来判次序，见 [_magnitudesAgree]。
  static const _magnitudeSlack = 0.4;

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
    required this.longestSidePixels,
  });

  final (int, int, int) vertices;
  final double r2;
  final double r3;
  final double ratioTolerance;

  /// 最长边在图像上的像素长度；配合目录端最长边的角距，就是这一对三角形的
  /// 像素比例尺。用它可以在做 12 次拟合之前就把尺度明显不对的候选扔掉。
  final double longestSidePixels;
}

class _CatalogTriangle {
  const _CatalogTriangle(this.vertices, this.longestSideDegrees);

  final (int, int, int) vertices;
  final double longestSideDegrees;
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
