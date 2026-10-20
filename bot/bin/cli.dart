import 'dart:convert';
import 'dart:io';

import 'package:astrosophy_core/analysis.dart';
import 'package:astrosophy_core/catalog.dart';
import 'package:astrosophy_core/deepsky.dart';
import 'package:astrosophy_core/solver.dart';

/// 服务端核心的冒烟测试入口。
///
/// 用法：
///   dart run bin/cli.dart 图片.jpg --scene wide
///   dart run bin/cli.dart 图片.jpg --scene sun
Future<void> main(List<String> args) async {
  if (args.isEmpty || args.first == '--help') {
    stdout.writeln('用法: dart run bin/cli.dart <image> [--scene auto|wide|deep_sky|narrow|moon|sun]');
    return;
  }
  final path = args.first;
  var scene = ShootingScene.auto;
  final sceneIndex = args.indexOf('--scene');
  if (sceneIndex >= 0 && sceneIndex + 1 < args.length) {
    scene = ShootingScene.fromStorage(args[sceneIndex + 1]);
  }
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('找不到图片: $path');
    exitCode = 2;
    return;
  }

  final assets = _assetsDirectory();
  if (assets == null) {
    stderr.writeln('找不到 assets/catalog；先在仓库根目录运行，或设置 ASTRO_ASSETS。');
    exitCode = 2;
    return;
  }

  final catalog = await StarCatalog.loadDirectory(assets);
  final deepSky = await DeepSkyCatalog.loadFile('$assets/deepsky.json');
  final analysis = SkyAnalysis.analyze(
    file.readAsBytesSync(),
    detectMoon: scene == ShootingScene.auto || scene == ShootingScene.moon,
    detectSun: scene == ShootingScene.sun,
    profile: scene == ShootingScene.wide
        ? StarDetectionProfile.wide
        : StarDetectionProfile.normal,
  );
  stdout.writeln(jsonEncode({
    'image': path,
    'scene': scene.storageKey,
    'width': analysis.width,
    'height': analysis.height,
    'stars': analysis.stars.length,
    'candidates': analysis.solveCandidates.length,
    'fwhm': analysis.fwhm,
    'non_star_fraction': analysis.nonStarFraction,
    'starfield': analysis.isLikelyStarfield,
    'moon': analysis.moonDisc?.toJson(),
    'sun': analysis.sunDisc?.toJson(),
  }));

  if (analysis.isMoonShot || analysis.isSunShot) return;

  final solver = PlateSolver(catalog, deepSky: deepSky)..warmUp();
  final watch = Stopwatch()..start();
  final solve = solver.solve(analysis, hint: scene.hint);
  watch.stop();
  stdout.writeln(jsonEncode({
    'solve_ms': watch.elapsedMilliseconds,
    'solved': solve != null,
    if (solve != null) ...{
      'ra': solve.centerRa,
      'dec': solve.centerDec,
      'fov_degrees': solve.fieldOfViewDegrees,
      'arcsec_per_pixel': solve.arcsecPerPixel,
      'matched': solve.matchedCount,
    },
  }));
}

String? _assetsDirectory() {
  final env = Platform.environment['ASTRO_ASSETS'];
  final candidates = [
    if (env != null) env,
    'assets/catalog',
    '../assets/catalog',
    '../../assets/catalog',
  ];
  for (final path in candidates) {
    if (Directory(path).existsSync()) return path;
  }
  return null;
}
