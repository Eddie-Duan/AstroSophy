import 'dart:math' as math;

import 'package:astrosophy/analysis.dart';
import 'package:astrosophy/catalog.dart';
import 'package:astrosophy/models.dart';
import 'package:astrosophy/solver.dart';
import 'package:flutter_test/flutter_test.dart';

import 'catalog_fixture.dart';

/// 和那张真实 83° 手机照片同量级的二阶 SIP（astrometry.net 拟合结果）。
const _sipA = <(int, int), double>{
  (2, 0): -2.62792604328e-05,
  (1, 1): 9.80539299202e-06,
  (0, 2): -7.6483545106e-07,
};
const _sipB = <(int, int), double>{
  (2, 0): 1.08359275442e-06,
  (1, 1): -2.52223771367e-05,
  (0, 2): 1.0888513567e-05,
};

const _fieldCenterRa = 330.5;
const _fieldCenterDec = 49.4;
const _fieldFov = 83.1;

/// 合成一张「带镜头畸变的 83° 星野」：用真实量级的 SIP 把目录星投到像面。
SkyAnalysis _distortedWideField(StarCatalog catalog) => synthesiseField(
      catalog: catalog,
      centerRa: _fieldCenterRa,
      centerDec: _fieldCenterDec,
      degreesPerPixel: 0.0676,
      width: 900,
      height: 1200,
      magnitudeLimit: 6.4,
      positionJitter: 0.3,
      randomSeed: 7,
      sipA: _sipA,
      sipB: _sipB,
    );

/// 先验中心相对真值偏了 [offsetDegrees] 度，滚转差 0.5°、视场差 3%。
SkyPrior _priorWithError(double offsetDegrees, {double rollError = 0.0087}) =>
    SkyPrior(
      centerRa: _fieldCenterRa +
          offsetDegrees / math.cos(_fieldCenterDec * math.pi / 180),
      centerDec: _fieldCenterDec,
      radiusDegrees: 3,
      rollRadians: rollError,
      fieldOfViewDegrees: _fieldFov * 1.03,
    );

void main() {
  test('指向先验把 83° 畸变星野解出来（曲率 + 内点验收）', () {
    final catalog = loadTestCatalog(withGaia: false);
    final analysis = _distortedWideField(catalog);
    final solver = PlateSolver(catalog);
    final result = solver.solve(
      analysis,
      hint: ShootingScene.wide.hint.copyWith(prior: _priorWithError(3)),
    );
    expect(result, isNotNull, reason: '有指向先验时，83° 畸变星野应当能解出');
    expect(result!.wcs!.hasSip, isTrue, reason: '曲率应当被拟合并保留在结果里');
    expect(result.matchedCount, greaterThanOrEqualTo(80));
    final error = angularSeparationDegrees(
      result.centerRa,
      result.centerDec,
      _fieldCenterRa,
      _fieldCenterDec,
    );
    expect(error, lessThan(0.3), reason: '中心误差 ${error.toStringAsFixed(2)}°');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('指向先验错得离谱时不会把结果带到别的天区', () {
    final catalog = loadTestCatalog(withGaia: false);
    final analysis = _distortedWideField(catalog);
    final solver = PlateSolver(catalog);
    final result = solver.solve(
      analysis,
      hint: SolveHint(
        minFieldDegrees: 8,
        maxFieldDegrees: 120,
        allowDeep: false,
        patchSolve: false,
        skipShallow: true,
        budgetMilliseconds: 800,
        brightLayers: false,
        prior: _priorWithError(30),
      ),
    );
    // 先验路径应当被内点验收挡掉；万一后面的常规路径自己解出来了，
    // 坐标也必须是对的——错先验绝不能让结果歪到别的天区。
    if (result != null) {
      final error = angularSeparationDegrees(
        result.centerRa,
        result.centerDec,
        _fieldCenterRa,
        _fieldCenterDec,
      );
      expect(error, lessThan(0.5), reason: '错先验把结果带偏了 ${error.toStringAsFixed(1)}°');
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
