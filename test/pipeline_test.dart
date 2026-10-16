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

    test('用户确认的图像遮罩可安全跨 isolate 应用', () async {
      final image = nightSky(width: 420, height: 320, noise: 2);
      drawStar(image, 100, 100, amplitude: 230);
      drawStar(image, 300, 220, amplitude: 230);

      final analysis = await worker.analyze(
        encodePng(image),
        exclusions: const [
          ImageExclusion(x: 0.1, y: 0.2, width: 0.2, height: 0.2),
        ],
      );

      expect(
        analysis.stars.any((star) => (star.x - 100).abs() < 6),
        isFalse,
      );
      expect(
        analysis.stars.any((star) => (star.x - 300).abs() < 6),
        isTrue,
      );
      expect(analysis.maskRegions, hasLength(1));
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
      final (solve, trace) = await worker.solveLocal(
        analysis,
        onProgress: (progress) => stages.add(progress.stage),
      );

      expect(solve, isNotNull);
      // 结果要如实标成「本机算的」——界面和报告都靠这个字段说明数据来源。
      expect(solve!.source, SolveSource.local);
      expect(
        angularSeparationDegrees(solve.centerRa, solve.centerDec, 30, 15),
        lessThan(0.1),
      );
      expect(solve.matchedCount, greaterThanOrEqualTo(10));
      // 过程记录也要跨 isolate 传得回来：它是在解算那一侧的 isolate 里填的，
      // 上层拿不到它，失败时就只剩一句「没找到」。
      expect(trace.layers, isNotEmpty);
      expect(trace.layers.first.starCount, greaterThan(0));
      // 进度回调要真的从后台一条条传回来。这一步曾经真的断过：先到的
      // 进度消息把登记项摘掉了，之后带回结果的那条就找不到人收，界面
      // 永远停在进度条上。
      expect(stages.length, greaterThanOrEqualTo(3));
      expect(stages.first, contains('索引'));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('认出月面之后先问一句', () {
    late SkyWorker worker;

    setUpAll(() async {
      worker = await SkyWorker.spawn(bundle: _RepositoryAssets());
    });

    tearDownAll(() async => worker.dispose());

    /// 一张以月面为主的合成图：一片夜空加一个半径 45 像素的圆亮斑。
    ///
    /// 这个尺寸是实测出来的：它会被判成月面（占画面 5%，判据的门槛在
    /// 0.5%），而真实那张月球照只占 1.1%。
    Uint8List moonImage() {
      final image = nightSky(width: 400, height: 300);
      scatterStars(image, count: 40);
      drawBlob(image, 200, 150, 45);
      return encodePng(image);
    }

    test('选了「直接报告月亮」就不解算，也不再给「先去裁掉文字」那种建议', () async {
      // 这是用户实报的 bug 原样复现：月亮已经认出来了（圈都画在屏幕上），
      // 管线还是把照片当成星场送去 astrometry.net，排队几分钟后失败，回来
      // 告诉用户「这张图看起来就不是以星场为主的照片，先去相册里裁掉文字、
      // 地面和建筑再试一次」——而它早就知道那是月亮了。
      var asked = false;
      final outcome = await SkyPipeline(worker: worker).run(
        moonImage(),
        onMoonDetected: (analysis) async {
          asked = true;
          expect(analysis.isMoonShot, isTrue);
          return false;
        },
      );

      expect(asked, isTrue);
      expect(outcome.moonOnly, isTrue);
      expect(outcome.solve, isNull);
      expect(
        outcome.warnings.any((warning) => warning.contains('只报告月亮')),
        isTrue,
      );
      // 月亮这条路上不该出现「这不是星场」和「本机没能认出这片天区」那套话。
      expect(
        outcome.warnings.any((warning) => warning.contains('裁掉文字')),
        isFalse,
      );
      expect(
        outcome.warnings.any((warning) => warning.contains('本机没能认出')),
        isFalse,
      );
    });

    test('没人回答时按「只报告月亮」处理', () async {
      // 上传是这条路上唯一不可逆的动作。界面不在场（比如解析已放到后台、
      // 用户翻到别处去了）就不能替用户点头。
      final outcome = await SkyPipeline(worker: worker).run(moonImage());
      expect(outcome.moonOnly, isTrue);
      expect(outcome.solve, isNull);
    });

    test('选了「继续寻找其他天体」就照常往下解算', () async {
      final outcome = await SkyPipeline(worker: worker).run(
        moonImage(),
        onMoonDetected: (_) async => true,
      );
      expect(outcome.moonOnly, isFalse);
      // 合成图上没有真实星场，解算必然失败——这时才是该给解算失败建议的
      // 时候。
      expect(outcome.solve, isNull);
      expect(
        outcome.warnings.any((warning) => warning.contains('本机没能认出')),
        isTrue,
      );
    });

    test('进度里带上月亮标记，字里写明亮面占比', () async {      // 进度条左边那个标记就靠这个字段。它要在**问用户之前**就报上来——
      // 用户是在看着进度条的时候被问到的，标记和问题是同一件事的两半。
      final progresses = <PipelineProgress>[];
      await SkyPipeline(worker: worker).run(
        moonImage(),
        onProgress: progresses.add,
        onMoonDetected: (_) async => false,
      );

      final moonProgress =
          progresses.where((progress) => progress.moon).toList();
      expect(moonProgress, isNotEmpty);
      expect(moonProgress.first.stage, contains('月面'));
      expect(moonProgress.first.stage, contains('%'));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('本机解算成功之后，进度上带出「照片没出过设备」这个结论', () async {
      // 进度条换红色调就靠 solvedLocally 这个字段，而且判据必须是它、
      // 不能去认阶段文案——文案是给人读的，改一句话就会悄悄改掉一条判断。
      //
      // 用真照片（M31 那张本机解得出来），因为这条结论只有在解算真的成功
      // 时才会出现。
      final progresses = <PipelineProgress>[];
      final outcome = await SkyPipeline(worker: worker).run(
        Uint8List.fromList(
          File('assets/demo/demo_m31.jpg').readAsBytesSync(),
        ),
        onProgress: progresses.add,
      );

      expect(outcome.solve, isNotNull);
      expect(outcome.solve!.source, SolveSource.local);
      expect(
        progresses.any((progress) => progress.solvedLocally),
        isTrue,
        reason: '本机解出来之后进度上该带上这个标记',
      );
      // 标记一旦出现就一直带着：后面几步也是「照片在本机」。
      final firstSolved = progresses.indexWhere((p) => p.solvedLocally);
      expect(
        progresses.skip(firstSolved).every((p) => p.solvedLocally),
        isTrue,
      );
    }, timeout: const Timeout(Duration(minutes: 5)));
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
