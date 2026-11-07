// ignore_for_file: prefer_const_constructors, avoid_print

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:astrosophy/analysis.dart';
import 'package:astrosophy/catalog.dart';
import 'package:astrosophy/models.dart';
import 'package:astrosophy/solver.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../test/catalog_fixture.dart';

void main() {
  test('prior benchmark', () {
    final catalog = loadTestCatalog();
    final analysis = SkyAnalysis.analyze(Uint8List.fromList(File('build/repro/starfield_fail.jpg').readAsBytesSync()));
    final original = Wcs(width: 1600, height: 2133, crval1: 331.021666549, crval2: 51.5265389357, crpix1: 855.233988444, crpix2: 1052.2214152, cd11: -0.00429700471147, cd12: -0.0378061435476, cd21: 0.0377990344631, cd22: -0.00428372628617,
      sipA: const {(2, 0): -2.62792604328e-05, (1, 1): 9.80539299202e-06, (0, 2): -7.6483545106e-07},
      sipB: const {(2, 0): 1.08359275442e-06, (1, 1): -2.52223771367e-05, (0, 2): 1.0888513567e-05});
    final truth = original.rescaledTo(analysis.width, analysis.height);
    final (truthRa, truthDec) = truth.imageCenter;
    final truthFov = truth.fieldOfViewDegrees;
    final truthRoll = math.atan2(-truth.cd12, -truth.cd11);
    final solver = PlateSolver(catalog);
    final fastFail = ShootingScene.wide.hint.copyWith(
      patchSolve: false, skipShallow: true, allowDeep: false,
      budgetMilliseconds: 1500, brightLayers: false,
    );
    // 真实照片里的「指向误差」：中心偏 radius 度，roll 差 rollError，fov 差 fovError
    SkyPrior makePrior(double radius, {double rollError = 0.0087, double fovError = 0.03, bool withRoll = true, bool withFov = true}) {
      return SkyPrior(
        centerRa: truthRa + radius / math.cos(truthDec * math.pi / 180),
        centerDec: truthDec,
        radiusDegrees: radius,
        rollRadians: withRoll ? truthRoll + rollError : null,
        fieldOfViewDegrees: withFov ? truthFov * (1 + fovError) : null,
      );
    }
    void run(String label, SkyPrior? prior, {bool measureSip = false}) {
      final watch = Stopwatch()..start();
      final result = solver.solve(analysis, hint: fastFail.copyWith(prior: prior));
      watch.stop();
      var extra = '';
      if (result != null) {
        final err = angularSeparationDegrees(result.centerRa, result.centerDec, truthRa, truthDec);
        extra = 'centerErr=${err.toStringAsFixed(2)}° fov=${result.fieldOfViewDegrees.toStringAsFixed(1)} matched=${result.matchedCount}';
        if (measureSip) {
          final nSip = countInliers(catalog, analysis, result.wcs!, 3.0);
          final nLinear = countInliers(catalog, analysis, result.wcs!.withoutSip, 3.0);
          extra = '$extra | 3px内点 SIP=$nSip 线性=$nLinear';
        }
      } else {
        extra = 'FAILED';
      }
      print('BENCH|$label|${result != null}|${watch.elapsedMilliseconds}ms|$extra');
    }
    run('A 无先验（默认路径，2s 快速失败版）', null);
    run('B 仅中心 3°', makePrior(3, withRoll: false, withFov: false));
    run('C 中心3°+视场(EXIF)', makePrior(3, withRoll: false));
    run('D 中心3°+滚转(IMU)', makePrior(3, withFov: false));
    run('E 中心3°+滚转+视场', makePrior(3), measureSip: true);
    run('F 中心1°+滚转+视场', makePrior(1));
    run('G 中心5°+滚转+视场', makePrior(5));
    run('H 中心10°+滚转+视场', makePrior(10));
    run('I 中心3° 滚转差2°', makePrior(3, rollError: 0.035));
    run('J 中心3° 视场差6%', makePrior(3, fovError: 0.06));
    run('K 先验错30°（应拒绝）', makePrior(30));
    expect(true, isTrue);
  }, timeout: const Timeout(Duration(minutes: 20)));
}

int countInliers(StarCatalog catalog, SkyAnalysis analysis, Wcs wcs, double tolerance) {
  final (ra, dec) = wcs.imageCenter;
  final stars = catalog.starsNear(ra, dec, wcs.fieldOfViewDegrees / 2 + 2, magnitudeLimit: 6.2);
  final detections = analysis.solveCandidates;
  var count = 0;
  for (final star in stars) {
    final (px, py) = wcs.worldToPixel(star.ra, star.dec);
    if (!px.isFinite || px < 0 || py < 0 || px >= analysis.width || py >= analysis.height) continue;
    var best = tolerance * tolerance;
    for (final d in detections) {
      final dx = d.x - px, dy = d.y - py;
      final dd = dx * dx + dy * dy;
      if (dd < best) best = dd;
    }
    if (best < tolerance * tolerance) count++;
  }
  return count;
}
