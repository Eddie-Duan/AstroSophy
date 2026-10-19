import 'dart:async';
import 'dart:typed_data';

import 'package:astrosophy/analysis.dart';
import 'package:astrosophy/exif.dart';
import 'package:astrosophy/jobs.dart';
import 'package:astrosophy/models.dart';
import 'package:astrosophy/pipeline.dart';
import 'package:flutter_test/flutter_test.dart';

/// 后台解析：「保存并退出」之后，结果要真的落在仓库里。
///
/// 这一组测试只测编排，不测链路——[JobCenter] 把「怎么算」留给外面传进来的
/// 回调，所以这里可以拿一个假链路把「谁在什么时机存了盘」单独验出来。

SkyAnalysis analysisOf() => SkyAnalysis(
      width: 100,
      height: 80,
      stars: const [],
      quality: '良好',
      background: 0.08,
      noise: 0.02,
      backgroundIndex: 10,
      saturatedFraction: 0,
      diagnostics: const [],
      preview: Uint8List(0),
      processedPreview: Uint8List(0),
      fwhm: 3,
      nonStarFraction: 0,
      maskRegions: const [],
      isLikelyStarfield: true,
      starfieldConfidence: 0.9,
      brightFlatFraction: 0,
    );

PipelineOutcome outcomeOf() => PipelineOutcome(
      analysis: analysisOf(),
      solve: null,
      explanation: null,
      warnings: const [],
    );

void main() {
  group('后台解析编排', () {
    test('解析期间进度一路写进任务里，界面回来时看得到', () async {
      // 进度不能只走回调——回调的接收方是「当时正在看的那个界面」，而用户
      // 可能已经走了。写进任务里，「回到这次解析」时才补得上中间那段。
      final seen = <double>[];
      final center = JobCenter(
        runPipeline: (job, onProgress, onMoon) async {
          await Future<void>.delayed(Duration.zero);
          onProgress(const PipelineProgress(0.3, '正在本机解算天区'));
          seen.add(job.fraction);
          await Future<void>.delayed(Duration.zero);
          onProgress(const PipelineProgress(0.7, '正在本机解算天区'));
          seen.add(job.fraction);
          return outcomeOf();
        },
        archive: (job, outcome) async => '月亮_261015',
      );

      final job = center.start(bytes: Uint8List(0), filename: 'IMG_1.jpg');
      expect(job.running, isTrue);
      expect(job.fraction, 0);

      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(seen, [0.3, 0.7]);
      expect(job.running, isFalse);
      expect(job.outcome, isNotNull);
      expect(job.fraction, 1);
      expect(job.stage, '解析完成');
    });

    test('本机解算成功后最终进度仍带红色标记', () async {
      // 任务收尾时会覆盖成「解析完成」；以前这一步把 solvedLocally 丢了，
      // 进度条最后又变回薄荷绿。这里钉住收尾也要带着来源。
      final center = JobCenter(
        runPipeline: (job, onProgress, onMoon) async => PipelineOutcome(
          analysis: analysisOf(),
          solve: const SolveResult(
            centerRa: 10,
            centerDec: 20,
            arcsecPerPixel: 2,
            namedStars: [],
            deepSkyObjects: [],
            matchedStars: [],
            magnitudeZeroPoint: null,
            magnitudeScatter: null,
            catalogWarning: null,
            source: SolveSource.local,
          ),
          explanation: null,
          warnings: const [],
        ),
        archive: (job, outcome) async => null,
      );

      final job = center.start(bytes: Uint8List(0), filename: 'IMG_local.jpg');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(job.progress, isNotNull);
      expect(job.progress!.solvedLocally, isTrue);
      expect(job.progress!.online, isFalse);
    });

    test('界面还看着的时候不自动存——用户手上握着保存按钮', () async {
      var archived = 0;
      final center = JobCenter(
        runPipeline: (job, onProgress, onMoon) async => outcomeOf(),
        archive: (job, outcome) async {
          archived++;
          return '月亮_261015';
        },
      );
      final job = center.start(bytes: Uint8List(0), filename: 'IMG_1.jpg');
      center.attach(job, (analysis) async => false);

      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(job.outcome, isNotNull);
      expect(archived, 0);
      expect(job.archiveName, isNull);
    });

    test('点了「保存并退出」，跑完之后自动进记录', () async {
      var archived = 0;
      final center = JobCenter(
        runPipeline: (job, onProgress, onMoon) async {
          // 让链路「跑一会儿」，好让用户在中间离开。
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return outcomeOf();
        },
        archive: (job, outcome) async {
          archived++;
          return '土星_250624';
        },
      );
      final job = center.start(bytes: Uint8List(0), filename: 'IMG_2.jpg');
      center.attach(job, (analysis) async => false);
      await center.detach(job);

      expect(job.detached, isTrue);
      // 还没跑完，先不存。
      expect(archived, 0);

      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(archived, 1);
      expect(job.archiveName, '土星_250624');
      // 存下来的名字要能被横幅显示出来，用户才知道这条记录叫什么。
      expect(job.label, '土星_250624');
    });

    test('已经跑完再点「保存并退出」，立刻补存一次', () async {
      var archived = 0;
      final center = JobCenter(
        runPipeline: (job, onProgress, onMoon) async => outcomeOf(),
        archive: (job, outcome) async {
          archived++;
          return '月亮_261015';
        },
      );
      final job = center.start(bytes: Uint8List(0), filename: 'IMG_3.jpg');
      center.attach(job, (analysis) async => false);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(job.running, isFalse);
      expect(archived, 0);

      await center.detach(job);
      expect(archived, 1);
    });

    test('离开时撤回还没回答的月面提问，按只报告月亮放开', () async {
      // 人都不看了，那个提问不能一直挂在那里等——链路的 onMoon 回调必须
      // 有个答案才会往下走。
      var answeredWith = <bool>[];
      final center = JobCenter(
        runPipeline: (job, onProgress, onMoon) async {
          answeredWith.add(await onMoon(analysisOf()));
          return outcomeOf();
        },
        archive: (job, outcome) async => '月亮_261015',
      );
      final job = center.start(bytes: Uint8List(0), filename: 'IMG_4.jpg');
      // 界面在场，但永远不会有人去点那个按钮。
      center.attach(job, (analysis) => Completer<bool>().future);
      await center.detach(job);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(answeredWith, [false]);
      expect(job.outcome, isNotNull);
    });

    test('链路自己炸了也不会把任务卡在「正在解析」上', () async {
      final center = JobCenter(
        runPipeline: (job, onProgress, onMoon) async =>
            throw StateError('在线解算超时'),
        archive: (job, outcome) async => null,
      );
      final job = center.start(bytes: Uint8List(0), filename: 'IMG_5.jpg');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(job.running, isFalse);
      expect(job.error, contains('在线解算超时'));
      expect(job.stage, '解析中断');
    });

    test('存档失败也照样结束，错误记在任务上', () async {
      final center = JobCenter(
        runPipeline: (job, onProgress, onMoon) async => outcomeOf(),
        archive: (job, outcome) async => throw StateError('磁盘满了'),
      );
      final job = center.start(bytes: Uint8List(0), filename: 'IMG_6.jpg');
      center.attach(job, (analysis) async => false);
      await center.detach(job);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(job.error, contains('磁盘满了'));
      expect(job.archiveName, isNull);
    });

    test('跑完的任务可以从名单里摘掉', () async {
      final center = JobCenter(
        runPipeline: (job, onProgress, onMoon) async => outcomeOf(),
        archive: (job, outcome) async => null,
      );
      final job = center.start(bytes: Uint8List(0), filename: 'IMG_7.jpg');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(center.jobs, hasLength(1));

      center.forget(job);
      expect(center.jobs, isEmpty);
      expect(center.hasRunning, isFalse);
    });

    test('任务留着原始文件名和拍摄时刻，界面回来时能复原', () {
      // 「回到这次解析」靠的就是这些：界面走了以后，只有任务里还留着这些
      // 才能把整屏复原成离开时的样子。
      final moment = CaptureMoment(
        local: DateTime(2026, 10, 15, 19, 38),
        offset: const Duration(hours: 8),
        source: CaptureTimeSource.demo,
      );
      final center = JobCenter(
        runPipeline: (job, onProgress, onMoon) async => outcomeOf(),
        archive: (job, outcome) async => null,
      );
      final job = center.start(
        bytes: Uint8List.fromList([7, 7, 7]),
        filename: 'IMG_20261015.jpg',
        moment: moment,
      );
      expect(job.filename, 'IMG_20261015.jpg');
      expect(job.moment!.local.hour, 19);
      expect(job.bytes, [7, 7, 7]);
    });
  });
}
