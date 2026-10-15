import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:astrosophy/analysis.dart';
import 'package:astrosophy/models.dart';
import 'package:astrosophy/solver.dart';
import 'package:flutter_test/flutter_test.dart';

import 'catalog_fixture.dart';

/// 临时探针：找出让 demo_m31 / demo_vesta 解不出来的那个量。
///
/// 已经排除的解释：
///   * 「星系本体被检成一块大区域挤进候选」——最亮的 120 颗里一颗都不落在
///     掩膜区域内（最大区域只有 187 像素）；
///   * 「星系上的假点源背景偏高」——最亮 120 颗脚下的背景中位数和整帧一样；
///   * 「最亮的那批是挤在盘面上的杂点」——它们的最近邻间距和随机取样没区别。
///
/// 剩下最像的解释：**图内端参与组三角形的星，比目录端多得多**。相机视场
/// 4.18°（由 demo_m45 反解），M31 天区这个视场里只有 58 颗目录星，而图内
/// 最亮的 120 颗必然混进几十颗目录里没有的暗星——两边枚举出来的三角形就
/// 不是同一批。M45 能解，正因为那个天区里目录星有 128 颗，比 120 还多。
///
/// 所以这里扫「图内端用多少颗」：如果图内端缩小到和目录端一个量级就解得
/// 出来，那这一刀就落在候选集合上，而不是落在检出形态上。
void main() {
  test('probe', () {
    final catalog = loadTestCatalog();
    final solver = PlateSolver(catalog, deepSky: loadTestDeepSky())..warmUp();

    for (final name in ['demo_m45', 'demo_m31', 'demo_vesta']) {
      final analysis = SkyAnalysis.analyze(
        File('assets/demo/$name.jpg').readAsBytesSync(),
      );
      final candidates = [...analysis.solveCandidates]
        ..sort((a, b) => b.flux.compareTo(a.flux));
      // ignore: avoid_print
      print('== $name  候选 ${candidates.length} 颗，'
          '解算补充 ${analysis.solverExtras.length} 颗');

      final started = DateTime.now();
      final solved = solver.solve(analysis);
      final ms = DateTime.now().difference(started).inMilliseconds;
      // ignore: avoid_print
      print('   整帧解算 → ${solved == null ? '失败' : '解出 '
          '${solved.matchedCount} 颗，'
          '${solved.arcsecPerPixel.toStringAsFixed(2)}″/px，'
          '视场 ${solved.fieldOfViewDegrees.toStringAsFixed(2)}°'} ${ms}ms');
      // ignore: avoid_print
      print('   trace=${solver.debugTrace}');
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}

/// 换掉参与解算的检出集合。
///
/// 手工构造而不是走 `copyWith`：解算补充（形似略拉长的亮源）也得能一起换掉，
/// 否则这个扫描量到的不是「用多少颗」，而是「加了补充之后有多少颗」。
SkyAnalysis _withStars(SkyAnalysis analysis, List<DetectedStar> stars) =>
    SkyAnalysis(
      width: analysis.width,
      height: analysis.height,
      stars: stars,
      quality: analysis.quality,
      background: analysis.background,
      noise: analysis.noise,
      backgroundIndex: analysis.backgroundIndex,
      saturatedFraction: analysis.saturatedFraction,
      diagnostics: analysis.diagnostics,
      preview: analysis.preview,
      processedPreview: analysis.processedPreview,
      fwhm: analysis.fwhm,
      nonStarFraction: analysis.nonStarFraction,
      maskRegions: analysis.maskRegions,
      isLikelyStarfield: analysis.isLikelyStarfield,
      starfieldConfidence: analysis.starfieldConfidence,
      brightFlatFraction: analysis.brightFlatFraction,
      solverExtras: const [],
    );

// 保留：数据集里那三个天区的目录星数是这样量出来的（视场 4.18°，10.68″/px）。
// M45 128 颗、M31 58 颗、Vesta 一带 33 颗——用 `catalog.starsNear` 数出来。
// ignore: unused_element
double _fieldRadiusDegrees(int width, int height, double arcsecPerPixel) =>
    math.sqrt(math.pow(width / 2, 2) + math.pow(height / 2, 2)) *
    arcsecPerPixel /
    3600;

// ignore: unused_element
final _unusedBytes = Uint8List(0);
