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
/// 检出结果」，它证明不了这条链路在真照片上也走得通。这张 demo_m45 是仓库
/// 里唯一能本机解出来的实拍图，用它守住端到端这一段。
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
}
