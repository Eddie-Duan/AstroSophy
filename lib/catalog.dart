import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart' show AssetBundle;

import 'models.dart';

/// 内置亮星目录。
///
/// 数据由 `tools/build_catalog.py` 从三份公开星表离线生成，打包进 assets：
///
/// * `stars.json`  —— 41394 颗星（Hipparcos，V < 8.0），内容是
///   `[hip, ra, dec, vmag, 星座下标]` 的数组。用数组而不是对象，
///   是因为几万颗星重复的字段名要多花好几百 KB。
/// * `names.json`  —— 只有「有名字可说」的 8972 颗星：拜耳编号、中英文
///   名、色指数、光谱型。
/// * `constellations.json` —— 88 个星座的中英文名和连线（连线由各家最亮
///   成员跑最小生成树生成，不是抄现成星图）。
/// * `constellation_grid.bin` —— 360 × 181 的字节表，给出任意天区落在
///   哪个星座，用来回答「这张照片拍的是哪片天」。
/// * `gaia.bin`  —— Gaia DR3 里亮于 G=9.0 的 13.7 万颗星，定长 7 字节一条。
///   这一层只做背景：Hipparcos 全天平均每平方度一颗星，视场 4° 的照片里
///   只有十来颗目录星，正好卡在解算出与解不出的边界上；补到两个星等之后
///   同样的天区里有四倍目录星，解算才稳定。它们没有名字，星等是 G 不是 V，
///   所以由 [CatalogStar.isGaia] 标出来，标注和测光那两处绕开。
///
/// 这里只做「加载 + 查询」，不含算法；解算逻辑在 `solver.dart`。
class StarCatalog {
  StarCatalog._({
    required this.stars,
    required this.names,
    required this.constellations,
    required this.constellationGrid,
    required this.magnitudeLimit,
  })  : byHip = {for (final star in stars) star.hip: star},
        _cells = SkyCellIndex<CatalogStar>(
          stars,
          ra: (star) => star.ra,
          dec: (star) => star.dec,
        );

  /// 按 V 星等从亮到暗排好序的恒星表。
  final List<CatalogStar> stars;

  final Map<int, StarName> names;

  /// 下标从 1 开始；下标 0 是占位空星座，对应「查不到归属」。
  final List<Constellation> constellations;

  /// 360 × 181 字节，[decIndex * 360 + raIndex]，值对应 [constellations] 下标。
  final Uint8List constellationGrid;

  /// 主星表（Hipparcos 那层）的暗端星等，约 V=8.0。
  ///
  /// 只算主星表，不算 Gaia 补充层：补充层的作用是「主星表够不着的天区
  /// 再补几颗」，把它算进来会让这个值变成补充层的上限，那就不再是这张
  /// 星表的特征了。
  final double magnitudeLimit;

  /// HIP 号索引，星表匹配后要拿它反查名字。
  final Map<int, CatalogStar> byHip;

  /// 2° × 2° 天区分桶，供 [starsNear] 用；否则每次查询都要扫四万颗星。
  final SkyCellIndex<CatalogStar> _cells;

  /// 从已经读进内存的字符串构建。测试可以绕过 Flutter 的 asset bundle。
  factory StarCatalog.parse({
    required String starsJson,
    required String namesJson,
    required String constellationsJson,
    required Uint8List constellationGrid,
    Uint8List? gaiaBytes,
  }) {
    final rawStars = (jsonDecode(starsJson) as List<Object?>);
    final rawNames = jsonDecode(namesJson) as Map<String, Object?>;
    final rawConstellations =
        jsonDecode(constellationsJson) as Map<String, Object?>;

    final constellations = <Constellation>[
      const Constellation('', '', '', []),
    ];
    rawConstellations.forEach((abbreviation, value) {
      final entry = value as Map<String, Object?>;
      final lines = <(int, int)>[];
      for (final line in (entry['lines'] as List<Object?>? ?? const [])) {
        final pair = line as List<Object?>;
        if (pair.length == 2) {
          lines.add(((pair[0] as num).toInt(), (pair[1] as num).toInt()));
        }
      }
      constellations.add(
        Constellation(
          abbreviation,
          entry['zh'] as String? ?? abbreviation,
          entry['en'] as String? ?? abbreviation,
          lines,
        ),
      );
    });

    final stars = <CatalogStar>[];
    for (final raw in rawStars) {
      final row = raw as List<Object?>;
      if (row.length < 4) continue;
      stars.add(
        CatalogStar(
          hip: (row[0] as num).toInt(),
          ra: (row[1] as num).toDouble(),
          dec: (row[2] as num).toDouble(),
          vMagnitude: (row[3] as num).toDouble(),
          constellationIndex:
              row.length > 4 ? (row[4] as num).toInt() : 0,
        ),
      );
    }
    stars.sort((a, b) => a.vMagnitude.compareTo(b.vMagnitude));
    // 主星表的暗端，要在并入 Gaia 补充层之前取——两层一起排完序之后，
    // 最暗的那颗多半是补充层里的，量的就不是主星表了。
    final mainLimit = stars.isEmpty ? 0.0 : stars.last.vMagnitude;
    if (gaiaBytes != null) stars.addAll(decodeGaiaLayer(gaiaBytes));
    stars.sort((a, b) => a.vMagnitude.compareTo(b.vMagnitude));

    final names = <int, StarName>{};
    rawNames.forEach((key, value) {
      final hip = int.tryParse(key);
      if (hip == null) return;
      final entry = value as Map<String, Object?>;
      names[hip] = StarName(
        bayer: entry['bayer'] as String?,
        english: entry['en'] as String?,
        chinese: entry['zh'] as String?,
        bv: (entry['bv'] as num?)?.toDouble(),
        spectralType: entry['sp'] as String?,
      );
    });

    return StarCatalog._(
      stars: stars,
      names: names,
      constellations: constellations,
      constellationGrid: constellationGrid,
      magnitudeLimit: mainLimit,
    );
  }

  /// 从 Flutter 资源包里加载。整个目录约 2.8 MB，只在首次解算时读一次。
  static Future<StarCatalog> load(AssetBundle bundle) async {
    final stars = await bundle.loadString('assets/catalog/stars.json');
    final names = await bundle.loadString('assets/catalog/names.json');
    final constellations =
        await bundle.loadString('assets/catalog/constellations.json');
    final grid = await bundle.load('assets/catalog/constellation_grid.bin');
    // Gaia 补充层缺了不该让整条链路起不来：它只是让稀疏天区也能解算，
    // 没有它退回原来的亮星表，功能少一点而已。
    final gaia = await bundle.load('assets/catalog/gaia.bin').then(
          (data) => data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          onError: (Object _) => Uint8List(0),
        );
    return StarCatalog.parse(
      starsJson: stars,
      namesJson: names,
      constellationsJson: constellations,
      constellationGrid: grid.buffer.asUint8List(
        grid.offsetInBytes,
        grid.lengthInBytes,
      ),
      gaiaBytes: gaia,
    );
  }

  /// 某颗星的名字信息；目录里没收录名字时返回 null。
  StarName? nameOf(CatalogStar star) => names[star.hip];

  /// 界面上显示的名字，优先级：中文名 > 英文名 > 拜耳编号 > HIP 号。
  String displayName(CatalogStar star) {
    final name = names[star.hip];
    if (name != null) {
      final label = name.chinese ?? name.english ?? name.bayer;
      if (label != null && label.isNotEmpty) return label;
    }
    return 'HIP ${star.hip}';
  }

  /// 次选名字，用来在星表里补一行「α CMa / HIP 32349」这种参照信息。
  String? alternateName(CatalogStar star) {
    final name = names[star.hip];
    if (name == null) return null;
    if (name.bayer != null && name.bayer!.isNotEmpty) return name.bayer;
    return 'HIP ${star.hip}';
  }

  Constellation? constellationAt(double ra, double dec) {
    if (constellationGrid.length < 360 * 181) return null;
    var decIndex = (dec + 90).floor();
    if (decIndex < 0) decIndex = 0;
    if (decIndex > 180) decIndex = 180;
    var raIndex = ra.floor() % 360;
    if (raIndex < 0) raIndex += 360;
    final index = constellationGrid[decIndex * 360 + raIndex];
    if (index <= 0 || index >= constellations.length) return null;
    return constellations[index];
  }

  Constellation? constellationOf(CatalogStar star) {
    final index = star.constellationIndex;
    if (index <= 0 || index >= constellations.length) return null;
    return constellations[index];
  }

  /// 以 (ra, dec) 为中心、半径 [radiusDegrees] 内的星，按星等从亮到暗。
  List<CatalogStar> starsNear(
    double ra,
    double dec,
    double radiusDegrees, {
    double magnitudeLimit = 99,
  }) {
    final radius = radiusDegrees.clamp(0.0, 179.0);
    final result = <CatalogStar>[];
    for (final star in _cells.within(ra, dec, radius)) {
      if (star.vMagnitude > magnitudeLimit) continue;
      if (angularSeparationDegrees(ra, dec, star.ra, star.dec) <= radius) {
        result.add(star);
      }
    }
    result.sort((a, b) => a.vMagnitude.compareTo(b.vMagnitude));
    return result;
  }

  /// 以 (ra, dec) 为中心最近的 [count] 颗星，按角距从近到远。
  ///
  /// 解算器要靠「每颗星和它最近的邻居」来组三角形，所以这里必须按角距
  /// 排序，不能像 [starsNear] 那样按星等排序——亮度近邻和距离近邻完全是
  /// 两回事，视场小的时候亮度近邻往往落在视场外面。
  ///
  /// 查询用「先试小半径、不够再翻倍」的办法，而不是一上来就取一个够大的
  /// 半径：全天星表大致均匀，绝大多数位置半度就够了，稀的方向才需要往外扩。
  /// 半径越小，要碰的分桶越少——建索引时每颗星都要查一次，一次查询多翻
  /// 几个桶，全天就是百万级的差别。
  List<CatalogStar> nearestStars(
    double ra,
    double dec,
    int count, {
    double maxRadiusDegrees = 20,
    double magnitudeLimit = 99,
  }) {
    var radius = _initialSearchRadius;
    while (true) {
      // 和 [starsNear] 同样的筛选，但不按星等排序：这里要的是最近，排序
      // 留给 [_closest] 按角距做。建索引时这次排序是白花的。
      final found = <CatalogStar>[];
      for (final star in _cells.within(ra, dec, radius)) {
        if (star.vMagnitude > magnitudeLimit) continue;
        if (angularSeparationDegrees(ra, dec, star.ra, star.dec) <= radius) {
          found.add(star);
        }
      }
      if (found.length > count || radius >= maxRadiusDegrees) {
        return _closest(found, ra, dec, count);
      }
      final next = radius * 2;
      radius = next > maxRadiusDegrees ? maxRadiusDegrees : next;
    }
  }

  /// 最近邻搜索的起步半径（度）。一个 2° 分桶在 0.75° 内的查询里最多只碰到
  /// 自己那一桶，所以这个值实际决定了单次查询的下限。
  static const _initialSearchRadius = 0.75;

  static List<CatalogStar> _closest(
    List<CatalogStar> stars,
    double ra,
    double dec,
    int count,
  ) {
    if (stars.length <= count) return stars;
    stars.sort((a, b) {
      final first = angularSeparationDegrees(ra, dec, a.ra, a.dec);
      final second = angularSeparationDegrees(ra, dec, b.ra, b.dec);
      return first.compareTo(second);
    });
    return stars.sublist(0, count);
  }

}

/// 2° × 2° 的天区分桶索引：把「以某点为中心、某半径内的所有条目」从
/// 「把整张表扫一遍」压成「只碰几桶」。
///
/// 赤经方向的分桶按 cos(dec) 收缩——越靠近天极，同一个赤经跨度对应的实际
/// 角距越小，同样的搜索半径要横跨更多列才不会漏。全天 41394 颗星的亮星表
/// 和两千多条的深空表共用这一份实现：两者的坐标语义完全一样，没有理由各写
/// 一遍（天极附近那段收缩逻辑尤其不值得写第二遍）。
class SkyCellIndex<T> {
  SkyCellIndex(
    Iterable<T> items, {
    required double Function(T) ra,
    required double Function(T) dec,
  }) {
    for (final item in items) {
      final key = _cellKey(_raIndex(ra(item)), _decIndex(dec(item)));
      (_cells[key] ??= <T>[]).add(item);
    }
  }

  final Map<int, List<T>> _cells = {};

  static const _cellSize = 2;

  /// 落在以 (ra, dec) 为心、[radiusDegrees] 为半径的圆里的分桶条目。
  /// 调用方还要自己按真实角距筛一遍——桶是方的，圆要自己画。
  ///
  /// 只收**和圆相交**的分桶，而不是圆的外接方框：半径 0.5° 的查询本来
  /// 会带上周围 3 × 3 个桶，按这个天区的密度那是四百多颗星，真正的目标
  /// 只有中心那几颗。星表越密，这一步省下的越多——它决定了建索引的代价
  /// 是跟着天区面积走，还是跟着要取的那几颗星走。
  List<T> within(double ra, double dec, double radiusDegrees) {
    final result = <T>[];
    final radius = radiusDegrees.clamp(0.0, 179.0);
    final decCells = (radius / _cellSize).ceil();
    final baseDec = _decIndex(dec);
    final baseRa = _raIndex(ra);
    for (var ddec = -decCells; ddec <= decCells; ddec++) {
      final cellDec = baseDec + ddec;
      if (cellDec < 0 || cellDec > 180 ~/ _cellSize) continue;
      final decLow = cellDec * _cellSize - 90;
      final decHigh = decLow + _cellSize;
      // 整行都在圆外时，这一圈的赤经分桶一个都不用看。
      final nearestDec = dec.clamp(decLow, decHigh).toDouble();
      if ((nearestDec - dec).abs() > radius) continue;
      // 越靠近天极，赤经方向的分桶被 cos(dec) 压得越窄，要多取几列才不漏。
      final shrink = math.cos((decLow + _cellSize / 2) * math.pi / 180).abs();
      final raCells = shrink < 1e-3
          ? 90
          : (radius / (_cellSize * shrink)).ceil().clamp(1, 90);
      for (var dra = -raCells; dra <= raCells; dra++) {
        // 180 个 2° 赤经分桶；Dart 的 % 对正除数总返回非负值，不用再补 360。
        final raIndex = (baseRa + dra) % 180;
        final raLow = raIndex * _cellSize.toDouble();
        if (_cellSeparation(ra, dec, nearestDec, raLow) > radius) continue;
        final bucket = _cells[_cellKey(raIndex, cellDec)];
        if (bucket != null) result.addAll(bucket);
      }
    }
    return result;
  }

  /// (ra, dec) 到这个经纬度分桶最近的那一点有多远。
  ///
  /// 分桶的两条边界互相垂直，所以「赤纬夹一下、赤经夹一下」得到的就是桶里
  /// 离查询点最近的那个点，不用再绕四条边走一遍。赤纬已经由调用方夹好，
  /// 这里只管赤经，并且要处理 0°/360° 的接缝。
  static double _cellSeparation(
    double ra,
    double dec,
    double nearestDec,
    double raLow,
  ) {
    final centre = raLow + _cellSize / 2;
    // ra 相对桶中心的带符号差，落在 [-180, 180)。桶只有 2° 宽，比半圈窄得
    // 多，所以最近点就是把这个差值夹到 ±半宽上。
    final offset = ((ra - centre) % 360 + 540) % 360 - 180;
    final nearestRa =
        offset.abs() <= _cellSize / 2 ? ra : centre + offset.clamp(-1.0, 1.0);
    return angularSeparationDegrees(ra, dec, nearestRa, nearestDec);
  }

  static int _decIndex(double dec) {
    final index = ((dec + 90) / _cellSize).floor();
    return index.clamp(0, 180 ~/ _cellSize);
  }

  static int _raIndex(double ra) {
    final index = (ra / _cellSize).floor() % 180;
    return index < 0 ? index + 180 : index;
  }

  static int _cellKey(int raIndex, int decIndex) => decIndex * 256 + raIndex;
}

/// Gaia 补充层的定长记录：赤经 3 字节、赤纬 3 字节、星等 1 字节。
///
/// 格式的另一半在 `tools/build_catalog.py` 的 `pack_gaia_star`，两边必须
/// 一起改。
const gaiaRecordBytes = 7;

/// 星等每格多少等，与打包脚本的 `GAIA_MAG_SCALE` 对应。
const _gaiaMagnitudeStep = 0.05;

/// 把 Gaia 补充层解码成恒星。
///
/// Hipparcos 到 V=8.0 只有四万一千颗，全天平均每平方度一颗，视场 4° 的照片
/// 里就十来颗目录星——刚好卡在解得出和解不出的边界上。这一层把极限往暗处
/// 推两个星等，同样的天区里目录星变成四倍，解算才站得住。
///
/// 这批星只用位置和星等：它们没有名字，星等也是 **G** 而不是 V，和
/// Hipparcos 差着零点几等，所以由 [CatalogStar.isGaia] 标出来，让测光零点
/// 和标注名字那两处绕开它们。
List<CatalogStar> decodeGaiaLayer(Uint8List bytes) {
  final count = bytes.length ~/ gaiaRecordBytes;
  final stars = <CatalogStar>[];
  for (var index = 0; index < count; index++) {
    final at = index * gaiaRecordBytes;
    final raUnits = (bytes[at] << 16) | (bytes[at + 1] << 8) | bytes[at + 2];
    final decUnits =
        (bytes[at + 3] << 16) | (bytes[at + 4] << 8) | bytes[at + 5];
    stars.add(
      CatalogStar(
        // 负号是「没有 HIP 号」的记号，顺便保证不会和真编号撞上。
        hip: -(index + 1),
        ra: raUnits / (1 << 24) * 360.0,
        dec: decUnits / (1 << 24) * 180.0 - 90.0,
        vMagnitude: bytes[at + 6] * _gaiaMagnitudeStep,
        constellationIndex: 0,
        isGaia: true,
      ),
    );
  }
  return stars;
}

/// 目录里的一颗恒星。
class CatalogStar {
  const CatalogStar({
    required this.hip,
    required this.ra,
    required this.dec,
    required this.vMagnitude,
    required this.constellationIndex,
    this.isGaia = false,
  });

  /// Hipparcos 编号，星表的稳定主键。
  final int hip;

  /// J2000 赤经（度）。
  final double ra;

  /// J2000 赤纬（度）。
  final double dec;

  /// V 波段视星等。
  final double vMagnitude;

  /// 所属星座在 [StarCatalog.constellations] 里的下标，0 表示未知。
  final int constellationIndex;

  /// 是否来自 Gaia 补充层（见 [decodeGaiaLayer]）。
  ///
  /// 这种星没有名字，[vMagnitude] 装的是 **G** 星等而不是 V 星等。两件事
  /// 都得挂在同一个标记上：给它们起名字只能编出一个假的，拿 G 去算测光
  /// 零点则会把整个零点拉偏零点几等。
  final bool isGaia;

  @override
  String toString() => 'HIP $hip (${ra.toStringAsFixed(3)}, '
      '${dec.toStringAsFixed(3)}) V=${vMagnitude.toStringAsFixed(2)}';
}

/// 一颗星的名称与物理信息，全部来自公开星表，没有的部分留空而不是猜。
class StarName {
  const StarName({
    this.bayer,
    this.english,
    this.chinese,
    this.bv,
    this.spectralType,
  });

  /// 拜耳/Flamsteed 编号，例如 `α CMa`。
  final String? bayer;

  /// 英文专名，例如 `Sirius`；只有最有名的那些星才有。
  final String? english;

  /// 中文名，例如 `天狼星`。
  final String? chinese;

  /// B-V 色指数，天文爱好者用它判断恒星表面温度。
  final double? bv;

  /// 光谱型，例如 `A1Vm`。
  final String? spectralType;
}

/// 一个星座的名字与连线。
class Constellation {
  const Constellation(
    this.abbreviation,
    this.chinese,
    this.english,
    this.lines,
  );

  /// IAU 三字母缩写，例如 `Ori`。
  final String abbreviation;

  final String chinese;
  final String english;

  /// 连线，每一段是两个 HIP 号。
  final List<(int, int)> lines;

  /// 界面上显示的名字。中文名缺失时退回缩写——缩写至少还能查。
  String get displayName => chinese.isEmpty ? abbreviation : chinese;

  bool get isEmpty => abbreviation.isEmpty;
}
