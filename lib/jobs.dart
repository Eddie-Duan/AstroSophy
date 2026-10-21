import 'dart:async';

import 'package:flutter/foundation.dart';

import 'strings.dart';
import 'analysis.dart';
import 'exif.dart';
import 'models.dart';
import 'pipeline.dart';
import 'solver.dart';

/// 一次解析任务。
///
/// 它和「界面」是分开的两样东西，这是这一整块改动的要点：解析动辄要跑
/// 一两分钟（在线解算排队更久），而用户在这段时间里想干的往往是别的事——
/// 去看上一张的结果、翻翻记录、或者干脆再挑一张图。如果解析的状态挂在
/// 页面对象上，用户一离开它就断了，「保存并退出」也就无从谈起。
class SkyJob {
  SkyJob({
    required this.id,
    required this.bytes,
    required this.filename,
    this.moment,
    this.question = '',
    this.mode = SkyAnalysisMode.localFirst,
    this.generateAgentReport = false,
    this.scene = ShootingScene.auto,
  });

  final String id;

  /// 这一张图的字节。留在任务里，所以界面走了以后它还在。
  final Uint8List bytes;

  /// 用户那张图的原始文件名，用来在认不出天体时给记录兜个底。
  final String filename;

  final CaptureMoment? moment;
  final String question;

  /// 这一次选的分析方式。任务离开界面之后，管线仍要按用户选的那条路走。
  final SkyAnalysisMode mode;

  /// 是否在解析结束后自动生成 Agent 解读。
  final bool generateAgentReport;

  /// 拍摄场景，用来给解算一个视场先验。
  final ShootingScene scene;

  PipelineProgress? progress;
  PipelineOutcome? outcome;
  String? error;

  /// 完成之后自动存进观星记录时用的名字。没自动存就是 null。
  String? archiveName;

  /// 用户在看着这次解析吗。
  ///
  /// 非 [detached] 时界面会填 [askMoon]；用户点了「保存并退出」或者去挑别的
  /// 图，就置为 true，于是解析完成时自动存进记录。
  bool detached = false;

  /// 认出月面时问用户的那一句。界面不在场时是 null，按「只报告月亮」处理。
  Future<bool> Function(SkyAnalysis analysis)? askMoon;

  bool get running => outcome == null && error == null;

  double get fraction => progress?.fraction ?? 0;

  String get stage {
    if (error != null) return t('解析中断');
    return progress?.stage ?? t('正在准备');
  }

  /// 给用户认这一条的一句话：「月亮_261015」或者那张图原来的名字。
  String get label => archiveName ?? filename;
}

/// 后台解析的总管。
///
/// 只做编排，不自己算：真正跑链路的那件事由 App 传进来（它才知道 worker、
/// Key 和模型设置），落盘存档也一样。这样这个文件可以单独测。
class JobCenter extends ChangeNotifier {
  JobCenter({required this.runPipeline, required this.archive});

  /// 跑一次完整链路。三个回调分别给进度、给月面提问。
  final Future<PipelineOutcome> Function(
    SkyJob job,
    void Function(PipelineProgress) onProgress,
    Future<bool> Function(SkyAnalysis analysis) onMoon,
  ) runPipeline;

  /// 把跑完的结果存进观星记录，返回存下来的名字。
  final Future<String?> Function(SkyJob job, PipelineOutcome outcome) archive;

  final List<SkyJob> _jobs = [];
  int _next = 0;

  /// 全部任务，新的在后面。
  List<SkyJob> get jobs => List.unmodifiable(_jobs);

  /// 还在跑的那些。首页那条「后台正在解析」就靠它。
  List<SkyJob> get runningJobs =>
      [for (final job in _jobs) if (job.running) job];

  bool get hasRunning => _jobs.any((job) => job.running);

  SkyJob start({
    required Uint8List bytes,
    required String filename,
    CaptureMoment? moment,
    String question = '',
    SkyAnalysisMode mode = SkyAnalysisMode.localFirst,
    bool generateAgentReport = false,
    ShootingScene scene = ShootingScene.auto,
  }) {
    final job = SkyJob(
      id: 'job-${++_next}',
      bytes: bytes,
      filename: filename,
      moment: moment,
      question: question,
      mode: mode,
      generateAgentReport: generateAgentReport,
      scene: scene,
    );
    _jobs.add(job);
    notifyListeners();
    unawaited(_execute(job));
    return job;
  }

  /// 跑完就把它从名单里摘掉。用户已经看过结果了，留着一个跑完的任务只会
  /// 让首页那条横幅永远挂着。
  void forget(SkyJob job) {
    if (_jobs.remove(job)) notifyListeners();
  }

  /// 用户点了「保存并退出」：界面不再看着它，但解析继续。
  Future<void> detach(SkyJob job) async {
    job.detached = true;
    // 撤回还没回答的月面提问。人都不看了，不能挂在那里等一个永远不来的
    // 回答——按「只报告月亮」放开，这条链路才能跑完并被存下来。
    job.askMoon = null;
    notifyListeners();
    // 要是它其实已经跑完了，那就现在存。
    if (!job.running && job.archiveName == null && job.outcome != null) {
      await _archive(job, job.outcome!);
    }
  }

  /// 界面重新看着它。
  void attach(SkyJob job, Future<bool> Function(SkyAnalysis) askMoon) {
    job.detached = false;
    job.askMoon = askMoon;
    notifyListeners();
  }

  Future<void> _execute(SkyJob job) async {
    try {
      final outcome = await runPipeline(
        job,
        (progress) {
          job.progress = progress;
          notifyListeners();
        },
        (analysis) async => await job.askMoon?.call(analysis) ?? false,
      );
      job.outcome = outcome;
      job.progress = PipelineProgress(
        1,
        t('解析完成'),
        solvedLocally: outcome.solve?.source == SolveSource.local,
        online: outcome.solve?.source == SolveSource.online,
        moon: outcome.analysis.isMoonShot,
        moonOnly: outcome.moonOnly,
        sunOnly: outcome.sunOnly,
        trailOnly: outcome.trailOnly,
        solved: outcome.solve != null,
      );
      // 没人在看的时候替用户存下来。
      //
      // 「保存并退出」的承诺就是「结果不会丢」——不存的话，用户回来只看到
      // 一条什么都没留下的横幅。反过来，用户还在看的时候**不**自动存：
      // 那时他手上正握着「保存」按钮，替他存一次会让他以为按错了什么。
      if (job.detached) await _archive(job, outcome);
    } catch (error) {
      job.error = '$error';
    }
    notifyListeners();
  }

  Future<void> _archive(SkyJob job, PipelineOutcome outcome) async {
    try {
      job.archiveName = await archive(job, outcome);
    } catch (error) {
      job.error = t('解析完成，但存进观星记录失败：{0}', [error]);
    }
  }
}
