import 'dart:io';

import 'package:astrosophy/analysis.dart';
import 'package:astrosophy/models.dart';
import 'package:astrosophy/pipeline.dart';
import 'package:astrosophy/report.dart';
import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'catalog_fixture.dart';
import 'image_fixture.dart';

/// 直接从仓库读资源的 bundle。
///
/// `flutter test` 的工作目录就是包根目录，用 dart:io 读比初始化 widget
/// binding 再走 rootBundle 简单得多，也和 test/catalog_fixture.dart 一致。
class _RepositoryAssets extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    final file = File(key);
    if (!file.existsSync()) throw FlutterError('资源不存在：$key');
    return ByteData.view(Uint8List.fromList(file.readAsBytesSync()).buffer);
  }
}

void main() {
  group('SkyWorker', () {
    late SkyWorker worker;

    setUpAll(() async {
      worker = await SkyWorker.spawn(bundle: _RepositoryAssets());
    });

    tearDownAll(() async => worker.dispose());

    test('图片在后台 isolate 里分析完再传回来', () async {
      final image = nightSky(width: 420, height: 320, noise: 3);
      scatterStars(image, count: 60);

      final analysis = await worker.analyze(encodePng(image));

      expect(analysis.width, 420);
      expect(analysis.height, 320);
      expect(analysis.compactSources, isNotEmpty);
      // 结果要能原样发回来：预览图是 Uint8List，星点是普通对象，都能过
      // isolate 边界。哪天真过不去了，这条断言会先炸。
      expect(analysis.preview, isNotEmpty);
      expect(analysis.stars.first.x, isPositive);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('本机解算在后台跑完，坐标和进度都传得回来', () async {
      // 用目录合成的真实天区，而不是渲染出来的照片：这条测试要验的是
      // 「解算结果能不能跨 isolate 传回来」，检测那一环归 analysis_test 管。
      final analysis = synthesiseField(
        catalog: loadTestCatalog(),
        centerRa: 30,
        centerDec: 15,
        degreesPerPixel: 0.006,
      );

      final stages = <String>[];
      final solve = await worker.solveLocal(
        analysis,
        onProgress: (_, stage) => stages.add(stage),
      );

      expect(solve, isNotNull);
      // 结果要如实标成「本机算的」——界面和报告都靠这个字段说明数据来源。
      expect(solve!.source, SolveSource.local);
      expect(
        angularSeparationDegrees(solve.centerRa, solve.centerDec, 30, 15),
        lessThan(0.1),
      );
      expect(solve.matchedCount, greaterThanOrEqualTo(10));
      // 进度回调要真的从后台一条条传回来。这一步曾经真的断过：先到的
      // 进度消息把登记项摘掉了，之后带回结果的那条就找不到人收，界面
      // 永远停在进度条上。
      expect(stages.length, greaterThanOrEqualTo(3));
      expect(stages.first, contains('索引'));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('交给模型的测量摘要', () {
    test('如实区分本机解算和在线解算', () {
      final analysis = SkyAnalysis(
        width: 100,
        height: 80,
        stars: const [],
        quality: '一般',
        background: 0.1,
        noise: 0.02,
        backgroundIndex: 10,
        saturatedFraction: 0,
        diagnostics: const [],
        preview: Uint8List(0),
        processedPreview: Uint8List(0),
        fwhm: 3.2,
        nonStarFraction: 0,
        maskRegions: const [],
        isLikelyStarfield: true,
        starfieldConfidence: 0.8,
        brightFlatFraction: 0,
      );

      final unsolved = buildAgentReport(analysis, null);
      expect(unsolved['solved'], isFalse);
      expect(unsolved['solve_source'], isNull);

      final local = buildAgentReport(
        analysis,
        const SolveResult(
          centerRa: 83.8,
          centerDec: -5.4,
          arcsecPerPixel: 12.5,
          namedStars: [],
          deepSkyObjects: [],
          matchedStars: [],
          magnitudeZeroPoint: null,
          magnitudeScatter: null,
          catalogWarning: null,
          source: SolveSource.local,
          fieldOfViewDegrees: 9.1,
          constellations: ['猎户座'],
          matchedCount: 27,
        ),
      );
      expect(local['solve_source'], 'local_offline');
      expect(local['constellations'], ['猎户座']);
      expect(local['matched_star_count'], 27);
      // 测光质量也要一起交出去，模型才有依据判断哪些数字能信。
      expect(local['psf_fwhm_pixels'], 3.2);
      expect(local['starfield_confidence'], 0.8);
    });
  });
}
