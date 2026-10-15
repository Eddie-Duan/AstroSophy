import 'dart:io';

import 'package:astrosophy/analysis.dart';
import 'package:astrosophy/models.dart';
import 'package:astrosophy/report.dart';
import 'package:astrosophy/solver.dart';
import 'package:flutter_test/flutter_test.dart';

import 'catalog_fixture.dart';

/// 拿真照片跑一遍完整链路：分析 → 本机解算 → 报告。
///
/// 别的用例都用合成星图，因为合成星图能断言到亚像素；但合成星图是「理想的
/// 检出结果」，它证明不了这条链路在真照片上也走得通。
void main() {
  late PlateSolver solver;

  setUpAll(() {
    solver = PlateSolver(loadTestCatalog(), deepSky: loadTestDeepSky())..warmUp();
  });

  test('demo_m45 本机解算后在报告里标出 M45', () {
    final analysis = SkyAnalysis.analyze(
      File('assets/demo/demo_m45.jpg').readAsBytesSync(),
    );
    final solve = solver.solve(analysis);
    expect(solve, isNotNull, reason: '这张图是本机解算的样板，必须能解出来');
    expect(solve!.source, SolveSource.local);

    // 离线标注：不走在线链路，名字和角尺寸都来自内置目录。
    final m45 = solve.deepSkyObjects
        .where((object) => object.name == 'M 45')
        .toList();
    expect(m45, hasLength(1));
    expect(m45.first.category, '疏散星团');
    expect(m45.first.angularSizeArcmin, closeTo(110.0, 0.1));
    expect(m45.first.x, inInclusiveRange(0, analysis.width.toDouble()));
    expect(m45.first.y, inInclusiveRange(0, analysis.height.toDouble()));

    final record = buildObservationRecord(analysis, solve);
    expect(record.summary, contains('M 45'));
    expect(record.deepSky.first.name, 'M 45');
    // 110′ 对上 4.2° 的像场对角线，超过三分之一——它就是这张照片的主体，
    // 报告里必须这么说，而不是把 M45 和几十颗恒星并列。
    expect(record.deepSky.first.coverageLabel, contains('是这张照片的主体'));
  }, timeout: const Timeout(Duration(minutes: 5)));

  // 下面两张曾经解不出来。原因不在检出形态，也从不在「候选被星系的亮斑
  // 挤爆」：是图内端拿最亮的 120 颗去组三角形，而 M31 这半天区的目录里
  // 只有 58 颗星（Vesta 一带 33 颗），多出来的那几十颗把真正的近邻顶掉了。
  // 修法是按 24 → 120 几档星数各试一遍（见 `PlateSolver._imageStarRungs`），
  // 这两条用例守的就是「那一刀别被改回去」。
  test('demo_m31 本机解算并认出 M 31', () {
    final analysis = SkyAnalysis.analyze(
      File('assets/demo/demo_m31.jpg').readAsBytesSync(),
    );
    final solve = solver.solve(analysis);
    expect(solve, isNotNull, reason: '稀疏天区必须靠小档星数解出来');
    expect(solve!.source, SolveSource.local);

    // 这张图上 M31 就是中心，容差给到 1° 只是为了让断言说的是「这一片天区」
    // 而不是某一次解算的精确到小数点的结果。
    expect(solve.centerRa, closeTo(10.6847, 1.0));
    expect(solve.centerDec, closeTo(41.2691, 1.0));
    expect(solve.matchedCount, greaterThanOrEqualTo(10));
    expect(
      solve.deepSkyObjects.map((object) => object.name),
      contains('M 31'),
    );
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('demo_vesta 本机解算', () {
    final analysis = SkyAnalysis.analyze(
      File('assets/demo/demo_vesta.jpg').readAsBytesSync(),
    );
    final solve = solver.solve(analysis);
    expect(solve, isNotNull);
    expect(solve!.source, SolveSource.local);
    expect(solve.matchedCount, greaterThanOrEqualTo(10));
    // 三张演示图出自同一台相机，解出来的像素尺度也该一致——这条同时守住
    // 深层层参与解算时没把尺度算歪。
    expect(solve.arcsecPerPixel, closeTo(10.68, 0.3));
  }, timeout: const Timeout(Duration(minutes: 5)));
}
