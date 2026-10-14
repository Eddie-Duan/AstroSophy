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
        _cells = _buildCells(stars);

  /// 按 V 星等从亮到暗排好序的恒星表。
  final List<CatalogStar> stars;

  final Map<int, StarName> names;

  /// 下标从 1 开始；下标 0 是占位空星座，对应「查不到归属」。
  final List<Constellation> constellations;

  /// 360 × 181 字节，[decIndex * 360 + raIndex]，值对应 [constellations] 下标。
  final Uint8List constellationGrid;

  final double magnitudeLimit;

  /// HIP 号索引，星表匹配后要拿它反查名字。
  final Map<int, CatalogStar> byHip;

  /// 2° × 2° 天区分桶，供 [starsNear] 用；否则每次查询都要扫四万颗星。
  final Map<int, List<CatalogStar>> _cells;

  static const _cellSize = 2;

  /// 从已经读进内存的字符串构建。测试可以绕过 Flutter 的 asset bundle。
  factory StarCatalog.parse({
    required String starsJson,
    required String namesJson,
    required String constellationsJson,
    required Uint8List constellationGrid,
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
      magnitudeLimit: stars.isEmpty ? 0 : stars.last.vMagnitude,
    );
  }

  /// 从 Flutter 资源包里加载。整个目录约 1.8 MB，只在首次解算时读一次。
  static Future<StarCatalog> load(AssetBundle bundle) async {
    final stars = await bundle.loadString('assets/catalog/stars.json');
    final names = await bundle.loadString('assets/catalog/names.json');
    final constellations =
        await bundle.loadString('assets/catalog/constellations.json');
    final grid = await bundle.load('assets/catalog/constellation_grid.bin');
    return StarCatalog.parse(
      starsJson: stars,
      namesJson: names,
      constellationsJson: constellations,
      constellationGrid: grid.buffer.asUint8List(
        grid.offsetInBytes,
        grid.lengthInBytes,
      ),
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
    final result = <CatalogStar>[];
    final radius = radiusDegrees.clamp(0.0, 179.0);
    final decCells = (radius / _cellSize).ceil();
    final baseDec = _cellIndex(dec);
    final baseRa = _raIndex(ra);
    for (var ddec = -decCells; ddec <= decCells; ddec++) {
      final cellDec = baseDec + ddec;
      if (cellDec < 0 || cellDec > 180 ~/ _cellSize) continue;
      // 越靠近天极，赤经方向的分桶被 cos(dec) 压得越窄，要多取几列才不漏星。
      final cellDecCentre = cellDec * _cellSize - 90 + _cellSize / 2;
      final shrink = math.cos(cellDecCentre * math.pi / 180).abs();
      final raCells = shrink < 1e-3
          ? 90
          : (radius / (_cellSize * shrink)).ceil().clamp(1, 90);
      for (var dra = -raCells; dra <= raCells; dra++) {
        // 180 个 2° 赤经分桶；Dart 的 % 对正除数总返回非负值，不用再补 360。
        final bucket = _cells[_cellKey((baseRa + dra) % 180, cellDec)];
        if (bucket == null) continue;
        for (final star in bucket) {
          if (star.vMagnitude > magnitudeLimit) continue;
          if (angularSeparationDegrees(ra, dec, star.ra, star.dec) <= radius) {
            result.add(star);
          }
        }
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
  /// 查询用「先试小半径、不够再翻倍」的办法：全天星表大致均匀，绝大多数
  /// 位置一次 3° 就够了，只有星特别稀的方向才需要往外扩。
  List<CatalogStar> nearestStars(
    double ra,
    double dec,
    int count, {
    double maxRadiusDegrees = 20,
    double magnitudeLimit = 99,
  }) {
    var radius = 3.0;
    while (true) {
      final found =
          starsNear(ra, dec, radius, magnitudeLimit: magnitudeLimit);
      if (found.length > count || radius >= maxRadiusDegrees) {
        return _closest(found, ra, dec, count);
      }
      final next = radius * 2;
      radius = next > maxRadiusDegrees ? maxRadiusDegrees : next;
    }
  }

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

  static int _cellIndex(double dec) {
    final index = ((dec + 90) / _cellSize).floor();
    return index.clamp(0, 180 ~/ _cellSize);
  }

  static int _raIndex(double ra) {
    final index = (ra / _cellSize).floor() % 180;
    return index < 0 ? index + 180 : index;
  }

  static int _cellKey(int raIndex, int decIndex) => decIndex * 256 + raIndex;

  static Map<int, List<CatalogStar>> _buildCells(List<CatalogStar> stars) {
    final cells = <int, List<CatalogStar>>{};
    for (final star in stars) {
      final key = _cellKey(_raIndex(star.ra), _cellIndex(star.dec));
      (cells[key] ??= <CatalogStar>[]).add(star);
    }
    return cells;
  }
}

/// 目录里的一颗恒星。
class CatalogStar {
  const CatalogStar({
    required this.hip,
    required this.ra,
    required this.dec,
    required this.vMagnitude,
    required this.constellationIndex,
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

  bool get isEmpty => abbreviation.isEmpty;
}
