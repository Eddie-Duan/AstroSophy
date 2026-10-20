import 'dart:convert';
import 'dart:io';

import 'strings.dart';
import 'catalog.dart';
import 'models.dart';

/// 内置深空目录：NGC 2000.0 里全部有类型的 NGC/IC 条目，约一万条。
///
/// 数据由 `tools/build_catalog.py` 从 NGC 2000.0（VII/118）离线生成，
/// 每条是 `[主名, 赤经, 赤纬, 类型码, 长轴角分, 视星等]`。
///
/// 「有类型」是唯一的门槛：没有类型码、类型写作 `-`、或者其实就是恒星的
/// 条目不收——它们没有可报的类型。星等和角尺寸可能为空，报告里写「未知」。
///
/// 这张表和在线路径（SIMBAD）回答的是同一个问题——「这块天区里有什么」，
/// 但离线表多给一样 SIMBAD 不给的东西：**角尺寸**。有了角尺寸才能说清楚
/// 「M31 占了这张照片的三分之一，M57 只占百分之二」，而这正是用户判断
/// 自己拍的是全景还是特写、器材配不配得上的依据。
///
/// 名字优先用 Messier 编号：`NGC 224` 写成 `M 31`，爱好者才认得出。
class DeepSkyCatalog {
  DeepSkyCatalog._(this.objects)
      : _index = SkyCellIndex<DeepSkyObject>(
          objects,
          ra: (object) => object.ra,
          dec: (object) => object.dec,
        );

  /// 全部条目，按赤经排序（和资产文件里的顺序一致）。
  final List<DeepSkyObject> objects;

  final SkyCellIndex<DeepSkyObject> _index;

  /// 从已经读进内存的字符串构建。测试可以绕过 Flutter 的 asset bundle。
  factory DeepSkyCatalog.parse(String json) {
    final rows = jsonDecode(json) as List<Object?>;
    final objects = <DeepSkyObject>[];
    for (final raw in rows) {
      final row = raw as List<Object?>;
      if (row.length < 4) continue;
      final name = row[0] as String?;
      if (name == null || name.isEmpty) continue;
      objects.add(
        DeepSkyObject(
          name: name,
          ra: (row[1] as num).toDouble(),
          dec: (row[2] as num).toDouble(),
          typeCode: row[3] as String? ?? '',
          angularSizeArcmin: (row.length > 4 ? row[4] as num? : null)?.toDouble(),
          magnitude: (row.length > 5 ? row[5] as num? : null)?.toDouble(),
        ),
      );
    }
    return DeepSkyCatalog._(objects);
  }

  static Future<DeepSkyCatalog> loadFile(String path) async =>
      DeepSkyCatalog.parse(await File(path).readAsString());

  bool get isEmpty => objects.isEmpty;

  /// 以 (ra, dec) 为中心、半径 [radiusDegrees] 内的深空天体，大的排在前面。
  ///
  /// 按角尺寸而不是按星等排序：标在图上的是一个圆圈，圆圈越大越显眼，而
  /// 用户想先看到的就是画面里最大的那个东西。
  List<DeepSkyObject> near(double ra, double dec, double radiusDegrees) {
    final radius = radiusDegrees.clamp(0.0, 179.0);
    final found = <DeepSkyObject>[
      for (final object in _index.within(ra, dec, radius))
        if (angularSeparationDegrees(ra, dec, object.ra, object.dec) <= radius)
          object,
    ];
    found.sort((a, b) => (b.angularSizeArcmin ?? 0)
        .compareTo(a.angularSizeArcmin ?? 0));
    return found;
  }

  /// 离 (ra, dec) 最近、且在 [toleranceDegrees] 之内的那个天体的角尺寸。
  ///
  /// 在线解算拿回来的深空天体只有名字，SIMBAD 不给角尺寸。本机目录里有，
  /// 按位置对一下就能补上——补不上返回 null，报告里就写「尺寸未知」，
  /// 不编一个数出来。
  double? angularSizeNear(
    double ra,
    double dec, {
    double toleranceDegrees = 5.0 / 60.0,
  }) {
    DeepSkyObject? best;
    var bestDistance = toleranceDegrees;
    for (final object in _index.within(ra, dec, toleranceDegrees)) {
      final distance = angularSeparationDegrees(ra, dec, object.ra, object.dec);
      if (distance < bestDistance) {
        bestDistance = distance;
        best = object;
      }
    }
    return best?.angularSizeArcmin;
  }
}

/// 深空目录里的一个天体。
class DeepSkyObject {
  const DeepSkyObject({
    required this.name,
    required this.ra,
    required this.dec,
    required this.typeCode,
    this.angularSizeArcmin,
    this.magnitude,
  });

  /// 主名。Messier 目标写成 `M 31`，其余写成 `NGC 224` / `IC 434`。
  final String name;

  /// J2000 赤经、赤纬（度）。
  final double ra;
  final double dec;

  /// NGC 2000.0 的原始类型码（`Gx`、`OC`……），中文翻译见 [describeDeepSkyType]。
  final String typeCode;

  /// 长轴角尺寸（角分）；目录里没有留空。
  final double? angularSizeArcmin;

  /// 视星等。NGC 2000.0 里少数条目记的是照相星等（偏蓝），见目录说明。
  final double? magnitude;

  /// 中文类型名；类型码为空或认不出时返回空串。
  String get category => describeDeepSkyType(typeCode);

  /// 是不是 Messier 目标——报告里值得按名字提一句的那一类。
  bool get isMessier => name.startsWith('M ');

  /// 转成图上要标的 [SkyObject]。像素坐标由调用方按 WCS 投影后补上。
  SkyObject toSkyObject(double x, double y) => SkyObject(
        name,
        ra,
        dec,
        category,
        magnitude: magnitude,
        magnitudeBand: 'V',
        x: x,
        y: y,
        isLocal: true,
        angularSizeArcmin: angularSizeArcmin,
      );

  @override
  String toString() => t('{0}（{1}）{2}', [name, category, angularSizeArcmin == null ? '' : ' ${angularSizeArcmin!.toStringAsFixed(1)}′']);
}

/// NGC 2000.0 的类型码翻成中文。
///
/// 这是它自己的一套写法，和 SIMBAD 的 `otype`（`G`、`OpC`……）不是一回事，
/// 所以不能和 `astrometry.dart` 里那张表合并——`Gb` 在这里是球状星团，
/// 在 SIMBAD 的写法里对应的却是 `GlC`。
///
/// 认不出来的代码原样返回：**不猜**。写错的中文类型比留一个代码糟糕，
/// 用户会拿它当事实。
String describeDeepSkyType(String code) {
  final trimmed = code.trim();
  if (trimmed.isEmpty) return '';
  final name = _deepSkyTypes[trimmed];
  // 表里存的是中文当 key，这里查译文——在返回的时候查，见 deepsky_names.dart
  // 里对同一个坑的说明。
  return name == null ? trimmed : t(name);
}

const _deepSkyTypes = <String, String>{
  'Gx': '星系',
  'OC': '疏散星团',
  'Gb': '球状星团',
  'Pl': '行星状星云',
  'Nb': '星云',
  'C+N': '星团与星云',
  'SNR': '超新星遗迹',
  'D*': '双星',
  '***': '聚星',
  'Ast': '星群',
  'Kt': '星际结',
  'PD': '疑为不存在',
  '?': '类型存疑',
};
