import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart' show AssetBundle, rootBundle;

import 'strings.dart';
import 'analysis.dart';
import 'astrometry.dart';
import 'catalog.dart';
import 'deepsky.dart';
import 'deepsky_names.dart';
import 'model.dart';
import 'models.dart';
import 'report.dart';
import 'smallbodies.dart';
import 'solver.dart';
import 'star_trails.dart';

/// 一次解析用哪种分析方式。
///
/// 四种方式的差别只有两件事：**照片要不要出设备**，以及**解算结果从哪来**。
/// 本机测量（星点检测、测光、画质）四种方式都会做——它不需要联网，也是
/// 在线结果回来之后仍然要用的那部分数据。
enum SkyAnalysisMode {
  /// 只在本机分析、本机解算，绝不上传。
  localOnly('local_only'),

  /// 直接上传 Astrometry.net，用在线结果出报告，不再跑本机解算。
  onlineOnly('online_only'),

  /// 当前版本：先本机解算，失败且已授权才上传。
  localFirst('local_first'),

  /// 先上传拿坐标，再用本机星历补行星、彗星、矮行星和小行星。
  onlineFirst('online_first');

  const SkyAnalysisMode(this.storageKey);

  /// 存进设置里的稳定标识，不跟着界面文案变。
  final String storageKey;

  static SkyAnalysisMode fromStorage(String? value) => values.firstWhere(
        (mode) => mode.storageKey == value,
        orElse: () => SkyAnalysisMode.localFirst,
      );

  bool get needsOnline => this != SkyAnalysisMode.localOnly;

  /// 必须联网才能跑：没有 Key/授权时这两个选项在界面上是禁用的。
  bool get requiresOnline =>
      this == SkyAnalysisMode.onlineOnly || this == SkyAnalysisMode.onlineFirst;

  String get label => switch (this) {
        SkyAnalysisMode.localOnly => t('本机解析'),
        SkyAnalysisMode.onlineOnly => t('云端解析'),
        SkyAnalysisMode.localFirst => t('本机优先'),
        SkyAnalysisMode.onlineFirst => t('云端优先'),
      };

  String get description => switch (this) {
        SkyAnalysisMode.localOnly => t('全程本机，照片不出设备。'),
        SkyAnalysisMode.onlineOnly => t('上传云端解算，用在线结果。'),
        SkyAnalysisMode.localFirst => t('先本机，失败再上云端。'),
        SkyAnalysisMode.onlineFirst => t('先云端定位，本机补天体。'),
      };
}

/// 一键解析的进度快照。
class PipelineProgress {
  const PipelineProgress(
    this.fraction,
    this.stage, {
    this.online = false,
    this.moon = false,
    this.moonOnly = false,
    this.sunOnly = false,
    this.trailOnly = false,
    this.solvedLocally = false,
    this.deep = false,
  });

  /// 0–1，界面上的进度条直接用这个值。
  final double fraction;

  /// 当前在做什么，写成人话。
  final String stage;

  /// 这一段是不是在跑在线解算。
  ///
  /// 界面拿它换进度条的配色：前面几步是「手机上在算」，照片没出过门；这一段
  /// 是「照片已经传上去了」，等的东西和等的心态都不是一回事。
  final bool online;

  /// 算到这一步时，画面上已经认出月面。
  ///
  /// 界面靠它在进度条左边挂一个标记：用户看到的进度条会一直往前走、字也会
  /// 一直换，而「这是一个月亮」这件事是整条链路上最早定下来、也最该被看到的
  /// 一个结论——它决定后面还跑不跑。
  final bool moon;

  /// 用户已经选了「直接分析月球」，这一次只报月亮。
  ///
  /// 界面靠它把进度条换成银白底加蓝斑点。这条链路和其余几种状态说的不是同
  /// 一件事：别的时候进度条在报「星图解算走到哪一步」，而这一次压根没有解算
  /// ——月亮上没有能和星表对上的点源，星点检测、星表匹配、测光全都跳过了。
  ///
  /// 它和 [moon] 是两件事：[moon] 说的是「认出来了，正等他拿主意」，
  /// [moonOnly] 说的是「他拿了主意，这一次就报月亮」。
  final bool moonOnly;

  /// 用户已经明确选了「太阳」，这一次只报日面。
  final bool sunOnly;

  /// 用户选了「星轨」：只统计拉长轨迹，不做星场解算。
  final bool trailOnly;

  /// 本机解算**已经成功**。
  ///
  /// 非空即「这张照片的天区是手机上算出来的」——它一次都没出过设备。界面靠它
  /// 换进度条的配色：这是个值得让用户一眼看到的结论，而在这之前，同样一条
  /// 进度条可能是「本机解算失败了，正准备往上传」。
  ///
  /// 判据用这个字段，不去认阶段文案。文案是给人读的，随时可能改一句话，而
  /// 颜色一旦跟着文案走，改文案就会悄悄改掉一条判断——那种错查起来很费劲。
  final bool solvedLocally;

  /// 本机解算已经用上最深那层星表（整张表，G < 11）。
  ///
  /// 界面靠它换进度条的配色：这一层要现建百万颗星的索引，等的时间比前面
  /// 两层高一个量级。和 [solvedLocally] 一样，判据是这个字段而不是阶段文案。
  final bool deep;

  @override
  String toString() => '${(fraction * 100).toStringAsFixed(0)}% · $stage';
}

/// 一键解析的产物。
class PipelineOutcome {
  const PipelineOutcome({
    required this.analysis,
    required this.solve,
    required this.explanation,
    required this.warnings,
    this.moonOnly = false,
    this.sunOnly = false,
    this.trailOnly = false,
    this.solveDuration,
  });

  final SkyAnalysis analysis;
  final SolveResult? solve;

  /// AI 解读；没配模型或解读失败时为 null。
  final String? explanation;

  /// 某一环没走通时的说明。链路不会因为一环失败就中断——本机解算不出结果
  /// 就回去问在线服务，解读失败也不影响已经算出来的坐标和测光。
  final List<String> warnings;

  /// 认出月面之后，用户选了「直接报告月亮」。
  ///
  /// 这一次**没有**做解算，也没有上传照片。界面要据此把话说明白，而不是
  /// 让用户以为「解算失败了」。
  final bool moonOnly;

  /// 这一次只报日面，没有解算也没有上传。
  final bool sunOnly;

  /// 这一次只统计星轨，没有解算。
  final bool trailOnly;

  /// 解算这一步实际花了多久（本机 + 在线回退，不含星点分析和 AI 解读）。
  ///
  /// 只给结果页的参数表用；解算没跑（例如只报告月亮）时为 null。
  final Duration? solveDuration;
}

/// 本地链路与在线回退的编排。
///
/// 用户点一次按钮，剩下的顺序由这里决定：本地分析 → 本机解算 →（失败且
/// 已授权）在线解算 → AI 解读。每一步都是可选的，配置了什么就跑什么。
class SkyPipeline {
  SkyPipeline({
    required this.worker,
    this.astrometryKey = '',
    this.allowUpload = false,
    this.modelSettings,
    this.mode = SkyAnalysisMode.localFirst,
    this.generateAgentReport = false,
    this.hint = const SolveHint(),
    this.scene = ShootingScene.auto,
  });

  final SkyWorker worker;
  final String astrometryKey;

  /// 是否允许把预览图上传到 astrometry.net。默认不允许。
  final bool allowUpload;

  final ModelSettings? modelSettings;

  /// 用户这次选的分析方式。默认「本机优先」，和旧版本行为一致。
  final SkyAnalysisMode mode;

  /// 解析完成后是否自动让 Agent 写一份解读。默认关闭，对应界面上那个勾选。
  final bool generateAgentReport;

  /// 用户选的拍摄场景对应的视场先验。默认不限制。
  final SolveHint hint;

  /// 用户选的拍摄场景。只有自动和月亮会做月面判定。
  final ShootingScene scene;

  bool get _canUpload => allowUpload && astrometryKey.trim().isNotEmpty;

  /// 没有 Key/授权时，需要联网的方式退回「本机优先」，不让整次解析直接空转。
  SkyAnalysisMode get _effectiveMode =>
      mode.needsOnline && !_canUpload ? SkyAnalysisMode.localFirst : mode;

  bool get _canExplain =>
      generateAgentReport && (modelSettings?.hasAnyModel ?? false);

  /// 进度条怎么分段。
  ///
  /// 权重按「这一步通常要等多久」给，不是按步骤数平分：在线解算要排队，
  /// 动辄一两分钟，而本地分析只要一秒。平分的话进度条前半程几乎不动，
  /// 用户反而更慌。
  List<_Stage> get _stages => switch (_effectiveMode) {
        _ when scene == ShootingScene.moon ||
                scene == ShootingScene.sun ||
                scene == ShootingScene.starTrails => [
            _Stage(t('正在分析星图'), 60),
            if (_canExplain) _Stage(t('正在生成解读'), 40),
          ],
        SkyAnalysisMode.localOnly => [
            _Stage(t('正在分析星图'), 30),
            _Stage(t('正在本机解算天区'), 54),
            if (_canExplain) _Stage(t('正在生成解读'), 16),
          ],
        SkyAnalysisMode.localFirst => [
            _Stage(t('正在分析星图'), 20),
            _Stage(t('正在本机解算天区'), 26),
            if (_canUpload) _Stage(t('正在在线解算天区'), 34, online: true),
            if (_canExplain) _Stage(t('正在生成解读'), 16),
          ],
        SkyAnalysisMode.onlineOnly => [
            _Stage(t('正在分析星图'), 25),
            _Stage(t('正在在线解算天区'), 55, online: true),
            if (_canExplain) _Stage(t('正在生成解读'), 20),
          ],
        SkyAnalysisMode.onlineFirst => [
            _Stage(t('正在分析星图'), 20),
            _Stage(t('正在在线解算天区'), 42, online: true),
            _Stage(t('正在用本机算法补全天体'), 14),
            if (_canExplain) _Stage(t('正在生成解读'), 16),
          ],
      };

  /// 跑完整条链路。
  ///
  /// [moment] 是拍摄时刻（UTC）。给不出来就是 null——行星、彗星、小行星的位置
  /// 随日期变，没有时刻这一节不出结论，但其余各步照跑。
  ///
  /// [onMoonDetected] 是认出月面之后问用户的一句话，返回 true 表示「继续寻找
  /// 其他天体」，false 表示「就报告月亮」。不传就当作用户不在场，按后者处理
  /// ——**不上传**是这两条路里唯一不可逆的那个动作，没人看着的时候不能替用户
  /// 做。
  Future<PipelineOutcome> run(
    Uint8List bytes, {
    void Function(PipelineProgress)? onProgress,
    String question = '',
    DateTime? moment,
    Future<bool> Function(SkyAnalysis analysis)? onMoonDetected,
  }) async {
    final stages = _stages;
    final total = stages.fold<int>(0, (sum, stage) => sum + stage.weight);
    final bounds = <(double, double)>[];
    var cursor = 0.0;
    for (final stage in stages) {
      final span = stage.weight / total;
      bounds.add((cursor, cursor + span));
      cursor += span;
    }

    // 本机解算成没成功。成功后进度条就换成另一套配色，一路持续到最后。
    var solvedLocally = false;
    // 用户选了「只报月亮」之后，剩下的每一步都带着这个标记——进度条换成银白
    // 底加蓝斑点，直到这一屏结束。和 [solvedLocally] 一样，一路持续到最后：
    // 中间漏带一次，颜色就会在那一瞬间翻回去。
    var moonOnlyReported = false;
    var sunOnlyReported = false;
    var trailOnlyReported = false;

    void report(int index, double local, [String? text, bool deep = false]) {
      if (index >= bounds.length) return;
      final (start, end) = bounds[index];
      onProgress?.call(
        PipelineProgress(
          start + (end - start) * local.clamp(0.0, 1.0),
          text ?? stages[index].name,
          online: stages[index].online,
          solvedLocally: solvedLocally,
          moonOnly: moonOnlyReported,
          sunOnly: sunOnlyReported,
          trailOnly: trailOnlyReported,
          deep: deep,
        ),
      );
    }

    final warnings = <String>[];

    report(0, 0);
    final detectMoon =
        scene == ShootingScene.auto || scene == ShootingScene.moon;
    final analysis = await worker.analyze(
      bytes,
      detectMoon: detectMoon,
      detectSun: scene == ShootingScene.sun,
      profile: scene == ShootingScene.wide
          ? StarDetectionProfile.wide
          : StarDetectionProfile.normal,
    );

    // 认出月面就在这里停下来问一句，而不是接着往下解算。
    //
    // 这条路是实打实踩出来的：一张月球照被当成星场送去了 astrometry.net，
    // 排队几分钟之后失败，回来还告诉用户「这张图看起来就不是以星场为主的
    // 照片，先去相册里裁掉文字、地面和建筑再试一次」——可它其实**早就认出
    // 月亮了**，圈都画在屏幕上了。
    //
    // 月亮是这个画面上唯一的、而且已经量出来的东西。它不该再把照片送出去：
    // 月球没有任何恒星尺度上的点源，星表怎么对都对不上，上传只会白等一次
    // 超时。所以这一句必须问在解算之前。
    var moonOnly = false;
    var sunOnly = false;
    var trailOnly = false;
    if (scene == ShootingScene.starTrails) {
      trailOnly = true;
      trailOnlyReported = true;
      final trails = analysis.streakCandidates.length;
      onProgress?.call(
        PipelineProgress(
          bounds.first.$2,
          t('星轨 · 检出 {0} 条拉长轨迹', [trails]),
          trailOnly: true,
        ),
      );
      warnings.add(
        trails == 0
            ? t('星轨场景：没有检出明显的拉长轨迹。')
            : t('星轨场景：只统计拉长轨迹，不做星场解算。'),
      );
      final stats = analyzeStarTrails(analysis);
      if (stats != null) {
        warnings.add(
          t('轨迹中心约 ({0}, {1}) px；检出 {2} 条轨迹，长度中位数 {3} px，最长 {4} px。',
              [
                stats.centerX.round(),
                stats.centerY.round(),
                stats.count,
                stats.medianLength.toStringAsFixed(1),
                stats.maxLength.toStringAsFixed(1),
              ]),
        );
      }
    } else if (scene == ShootingScene.sun) {
      sunOnly = true;
      sunOnlyReported = true;
      if (analysis.isSunShot) {
        final disc = analysis.sunDisc!;
        onProgress?.call(
          PipelineProgress(
            bounds.first.$2,
            t('太阳 · 半径 {0} px', [disc.radiusPixels.toStringAsFixed(0)]),
            sunOnly: true,
          ),
        );
        warnings.add(t('太阳场景：只报告日面，不寻找星场。'));
      } else {
        onProgress?.call(
          PipelineProgress(
            bounds.first.$2,
            t('没有检测到太阳'),
            sunOnly: true,
          ),
        );
        warnings.add(t('这张图里没有检测到太阳圆盘。'));
      }
    } else if (scene == ShootingScene.moon) {
      // 用户已经明确说「这次只看月亮」：有月亮就报月亮，没有就报没有，
      // 不再问「要不要继续找星星」。
      moonOnly = true;
      moonOnlyReported = true;
      if (analysis.isMoonShot) {
        final disc = analysis.moonDisc!;
        onProgress?.call(
          PipelineProgress(
            bounds.first.$2,
            t('月亮 · 亮面 {0}%', [(disc.illuminatedFraction * 100).toStringAsFixed(1)]),
            moon: true,
            moonOnly: true,
          ),
        );
        warnings.add(t('月亮场景：只报告月面，不寻找星场。'));
      } else {
        onProgress?.call(
          PipelineProgress(
            bounds.first.$2,
            t('没有检测到月亮'),
            moonOnly: true,
          ),
        );
        warnings.add(t('这张图里没有检测到月亮。'));
      }
    } else if (analysis.isMoonShot) {
      final disc = analysis.moonDisc!;
      onProgress?.call(
        PipelineProgress(
          bounds.first.$1,
          t('识别到月面 · 亮面 {0}%', [(disc.illuminatedFraction * 100).toStringAsFixed(1)]),
          moon: true,
        ),
      );
      moonOnly = !(await onMoonDetected?.call(analysis) ?? false);
      if (moonOnly) {
        // 这里就把标记立起来，并且**当场报一次进度**：用户刚点完「直接分析
        // 月球」，进度条得立刻变成银白色给出回话，而不是等下一步的 report
        // 走到才换——中间的解读阶段有时候要等好几秒。
        moonOnlyReported = true;
        onProgress?.call(
          PipelineProgress(
            bounds.first.$2,
            t('只报月亮 · 亮面 {0}%', [(disc.illuminatedFraction * 100).toStringAsFixed(1)]),
            moon: true,
            moonOnly: true,
          ),
        );
        warnings.add(
          t('这次只报告月亮：月盘、亮面占比，以及按拍摄时刻算出来的相名。想在这张图里找别的天体，重新解析时选「另觅星踪」。'),
        );
      }
    }

    final effectiveMode = _effectiveMode;
    if (mode.needsOnline && !_canUpload) {
      warnings.add(
        t('这次选的是「{0}」，但还没有可用的 Astrometry.net Key 或上传授权，已退回本机解算。',
            [mode.label]),
      );
    }

    // 进度条上的位置。四种方式的前两段顺序不同，但名字固定的那几段可以
    // 直接按下标取：分析永远是 0，在线优先时在线是 1，本机补全是 2。
    const localIndex = 1;
    final onlineIndex =
        effectiveMode == SkyAnalysisMode.localFirst ? 2 : 1;
    const enhanceIndex = 2;

    final solveWatch = Stopwatch()..start();
    SolveResult? solve;
    String? onlineError;
    SolveTrace? localTrace;

    Future<SolveResult?> runLocalSolve(
      int progressIndex, {
      bool fallback = false,
    }) async {
      report(progressIndex, 0, t('正在本机解算天区'));
      try {
        final (result, trace) = await worker.solveLocal(
          analysis,
          hint: hint,
          onProgress: (progress) =>
              report(progressIndex, progress.fraction, progress.stage, progress.deep),
        );
        localTrace = trace;
        if (result != null) {
          // 成了。从这里开始「照片没出过手机」就是既成事实，不是承诺了。
          solvedLocally = true;
          report(
            progressIndex,
            1,
            fallback ? t('在线没成功，已改用本机解算') : t('本机解算成功'),
          );
        }
        return result;
      } catch (error) {
        warnings.add(t('本机解算未能完成：{0}', [error]));
        return null;
      }
    }

    Future<SolveResult?> runOnlineSolve(int progressIndex) async {
      try {
        final result = await AstrometryService.solve(
          analysis: analysis,
          apiKey: astrometryKey,
          onProgress: (local, stage) => report(progressIndex, local, stage),
        );
        // 在线服务只给 WCS，星座是本机补的。补不上不影响坐标和测光，所以
        // 失败了只记一条提示，不把已经拿到手的解算结果丢掉。
        try {
          return await worker.decorate(result);
        } catch (error) {
          warnings.add(t('星座标注未能完成：{0}', [error]));
          return result;
        }
      } catch (error) {
        onlineError = '$error';
        warnings.add(t('在线解算未能完成：{0}', [error]));
        return null;
      }
    }

    /// 解算结果汇合之后的「本机补充」：深空主天体选择、行星/彗星/小行星。
    Future<SolveResult> enhance(
      SolveResult result, {
      required bool movingBodies,
    }) async {
      if (generateAgentReport) {
        // 这一步只重排顺序，不改任何测量。做它的理由是实况逼出来的：拍昴星团
        // 那张图里 IC 353（目录里 180′）比 M45（110′）大，按尺寸排出来的
        // 「主体」成了 IC 353。本机只能靠手写的常用名表去近似，而「M45 还是
        // IC 353」这种比较，正是模型知道而本机不知道的事。
        //
        // 它跟着「生成 Agent 报告」开关走：关掉时一次模型请求都不发。
        result = await _pickPrimary(result, modelSettings) ?? result;
      }
      if (movingBodies && moment != null) {
        // 坐标有了才能判断行星在哪——不管这份坐标是本机算的还是在线拿的，
        // 所以这一步放在两条解算路径汇合之后，而不是塞进本机解算里。
        try {
          result = await worker.annotateMovingBodies(analysis, result, moment);
        } catch (error) {
          warnings.add(t('运动天体判定未能完成：{0}', [error]));
        }
      }
      return result;
    }

    void addSolveFailureAdvice({required bool uploadAllowed}) {
      // 「星点不足」这种话用户看完还是不知道该干什么，所以这里给的是能照着
      // 做的动作：换焦段、改曝光、去设置里开在线解算。判断依据全部来自已经
      // 量出来的结果，不猜。
      warnings.addAll(
        buildSolveFailureAdvice(
          analysis,
          uploadAllowed: uploadAllowed,
          hasApiKey: astrometryKey.trim().isNotEmpty,
          onlineError: onlineError,
          attempt: localTrace,
        ),
      );
      if (effectiveMode == SkyAnalysisMode.localOnly) {
        warnings.add(
          t('本次选择「本机解析」，照片没有上传。需要在线解算时，可以改用「本机优先」或「云端优先」。'),
        );
      }
    }

    if (moonOnly || sunOnly || trailOnly) {
      // 用户选了只要盘面/轨迹：跳过解算和上传，直接走到解读那一步。
    } else if (effectiveMode == SkyAnalysisMode.onlineFirst ||
        effectiveMode == SkyAnalysisMode.onlineOnly) {
      final onlineFirst = effectiveMode == SkyAnalysisMode.onlineFirst;
      solve = await runOnlineSolve(onlineIndex);
      if (solve != null) {
        if (onlineFirst) report(enhanceIndex, 0, t('正在用本机算法补全天体'));
        solve = await enhance(
          solve,
          movingBodies: onlineFirst,
        );
        if (onlineFirst) report(enhanceIndex, 1, t('本机补充完成'));
      } else if (onlineFirst) {
        // 「在线为主」也得有下限：在线排队失败时至少把本机能算的算出来，
        // 否则用户等了几分钟只拿到一张白纸。
        warnings.add(t('在线解算没有成功，已改用本机解算。'));
        solve = await runLocalSolve(enhanceIndex, fallback: true);
        if (solve != null) {
          solve = await enhance(solve, movingBodies: true);
          report(enhanceIndex, 1, t('本机补充完成'));
        }
      }
      if (solve == null) {
        addSolveFailureAdvice(uploadAllowed: _canUpload);
      }
    } else {
      solve = await runLocalSolve(localIndex);
      if (solve == null &&
          effectiveMode == SkyAnalysisMode.localFirst &&
          _canUpload) {
        solve = await runOnlineSolve(onlineIndex);
      }
      if (solve == null) {
        addSolveFailureAdvice(uploadAllowed: _canUpload);
      } else {
        solve = await enhance(solve, movingBodies: true);
      }
    }

    solveWatch.stop();

    String? explanation;
    final settings = modelSettings;
    if (_canExplain && settings != null) {
      // 解读永远排在最后一段。解算那几段有没有跑过都不影响这件事的位置。
      report(_stages.length - 1, 0, t('正在生成解读'));
      try {
        explanation = await ModelService.explain(
          baseUrl: settings.baseUrl,
          lightKey: settings.lightKey,
          lightModel: settings.lightModel,
          strongKey: settings.strongKey,
          strongModel: settings.strongModel,
          report: buildAgentReport(
            analysis,
            solve,
            moon: moonFactsOf(analysis, moment),
          ),
          question: question,
        );
      } catch (error) {
        warnings.add(t('模型解读未能完成：{0}', [error]));
      }
    }

    // 最后这条也要带上 solvedLocally 和 moonOnly：不带的话进度条会在收尾的
    // 一瞬间翻回默认配色，像是「刚才那件事没发生过」——solvedLocally 漏带的
    // 那一次就是测试抓出来的。
    onProgress?.call(
      PipelineProgress(
        1,
        t('解析完成'),
        moon: analysis.isMoonShot,
        moonOnly: moonOnlyReported,
        sunOnly: sunOnlyReported,
        trailOnly: trailOnlyReported,
        solvedLocally: solvedLocally,
      ),
    );
    return PipelineOutcome(
      analysis: analysis,
      solve: solve,
      explanation: explanation,
      warnings: warnings,
      moonOnly: moonOnly,
      sunOnly: sunOnly,
      trailOnly: trailOnly,
      solveDuration: solve == null ? null : solveWatch.elapsed,
    );
  }

  /// 问模型「这张照片拍的是哪个深空天体」，把它的选择挂到解算结果上。
  ///
  /// 候选少于两个时直接不问：只有一个天体时「主体是谁」没有第二个答案，多问
  /// 一次只是多一次网络往返。
  ///
  /// 用轻量模型：这是个「哪个名字更耳熟」的问题，不需要推理链。
  Future<SolveResult?> _pickPrimary(
    SolveResult solve,
    ModelSettings? settings,
  ) async {
    if (solve.deepSkyObjects.length < 2) return null;
    if (settings == null) return null;
    final key = settings.lightKey.trim().isNotEmpty
        ? settings.lightKey
        : settings.strongKey;
    final model = settings.lightKey.trim().isNotEmpty
        ? settings.lightModel
        : settings.strongModel;
    if (key.trim().isEmpty || model.trim().isEmpty) return null;

    final field = solve.fieldOfViewDegrees;
    final candidates = [
      for (final object in solve.deepSkyObjects)
        DeepSkyCandidate(
          name: object.name,
          category: object.category,
          angularSizeArcmin: object.angularSizeArcmin,
          fieldFraction: object.angularSizeArcmin == null || field <= 0
              ? null
              : (object.angularSizeArcmin! / 60) / field,
          magnitude: object.magnitude,
          nickname: nicknameOf(object.name),        ),
    ];
    final picked = await ModelService.pickPrimaryDeepSky(
      baseUrl: settings.baseUrl,
      apiKey: key,
      model: model,
      candidates: candidates,
    );
    if (picked == null) return null;
    return solve.withPrimaryDeepSky(picked);
  }
}

class _Stage {
  const _Stage(this.name, this.weight, {this.online = false});

  final String name;

  /// 相对权重，不必加起来是 1。
  final int weight;

  /// 这一步在跑在线解算，进度条要换配色。
  final bool online;
}

// ---------------------------------------------------------------------------
// 后台 isolate
// ---------------------------------------------------------------------------

const _starsAsset = 'assets/catalog/stars.json';
const _namesAsset = 'assets/catalog/names.json';
const _constellationsAsset = 'assets/catalog/constellations.json';
const _gridAsset = 'assets/catalog/constellation_grid.bin';
const _deepSkyAsset = 'assets/catalog/deepsky.json';
const _smallBodiesAsset = 'assets/catalog/smallbodies.json';
const _gaiaAsset = 'assets/catalog/gaia.bin';

/// 常驻的后台解算 isolate。
///
/// 星点检测和本机天区解算都是纯 CPU 的同步活儿，放在主 isolate 上会把界面
/// 冻住好几秒——进度条恰好在这几秒里一动不动，用户看到的就是「卡死了」。
/// 所以整条本地链路丢进后台 isolate。
///
/// 之所以要**常驻**而不是每次 `compute` 一个新 isolate：本机解算的目录三角形
/// 索引建一次要一秒上下，用完就扔的话每张图都要重付一遍。后台 isolate 起来
/// 之后把星表和索引一直留着，之后每张图只剩解算本身的开销。
class SkyWorker {
  SkyWorker._(this._isolate, this._inbox, this._ready);

  final Isolate _isolate;
  final ReceivePort _inbox;
  final Completer<SendPort> _ready;

  final _pending = <int, _Pending>{};
  var _nextId = 1;
  bool _disposed = false;

  /// 起一个后台解算 isolate，并把星表数据交给它。
  ///
  /// 星表（约 1.8 MB JSON）要在后台 isolate 里解析——解析和建索引都是纯 CPU
  /// 的活儿，放主 isolate 上同样会卡。所以这里把原始文本读进来再传过去，
  /// 而不是传解析好的对象图（传对象要逐个字段复制，比传文本更贵）。
  static Future<SkyWorker> spawn({AssetBundle? bundle}) async {
    final assets = bundle ?? rootBundle;
    final stars = await assets.loadString(_starsAsset);
    final names = await assets.loadString(_namesAsset);
    final constellations = await assets.loadString(_constellationsAsset);
    final gridData = await assets.load(_gridAsset);
    final grid = gridData.buffer.asUint8List(
      gridData.offsetInBytes,
      gridData.lengthInBytes,
    );
    // 深空目录缺失不该让整条链路起不来：它只影响标注，不影响解算本身。
    final deepSky = await assets.loadString(_deepSkyAsset).catchError(
          (Object _) => '[]',
        );
    // 小天体目录同理：缺了只是回到「只认行星」，不是坏掉。
    final smallBodies = await assets.loadString(_smallBodiesAsset).catchError(
          (Object _) => '{}',
        );
    // Gaia 补充层同理：缺了只是星点稀的天区回到从前的成败边界，不是坏掉。
    final gaiaData = await assets.load(_gaiaAsset).catchError(
          (Object _) => ByteData(0),
        );
    final gaia = gaiaData.buffer.asUint8List(
      gaiaData.offsetInBytes,
      gaiaData.lengthInBytes,
    );

    final inbox = ReceivePort();
    final ready = Completer<SendPort>();
    final isolate = await Isolate.spawn(
      _skyWorkerMain,
      _WorkerBoot(
        inbox.sendPort,
        stars,
        names,
        constellations,
        grid,
        deepSky,
        smallBodies,
        gaia,
      ),
      debugName: 'astrosophy-solver',
    );
    final worker = SkyWorker._(isolate, inbox, ready);
    inbox.listen(
      worker._receive,
      onError: (Object error) => worker._fail(error),
      onDone: () => worker._fail(null),
    );
    return worker;
  }

  void _receive(Object? message) {
    if (message is! _WorkerReply) return;
    if (message.id == 0) {
      if (message.kind == 'ready' && !_ready.isCompleted) {
        _ready.complete(message.value! as SendPort);
      }
      return;
    }
    // 这里要按下标取而不是 remove：进度是同一次请求里发好几条的，先到的
    // 那条要是把登记项摘掉了，后面真正带回结果的 'done' 就找不到人收。
    final pending = _pending[message.id];
    if (pending == null) return;
    switch (message.kind) {
      case 'progress':
        pending.onProgress?.call(
          SolveProgress(
            (message.value! as num).toDouble(),
            message.stage ?? '',
            deep: message.deep,
          ),
        );
      case 'done':
        _pending.remove(message.id);
        pending.completer.complete(message.value);
      default:
        _pending.remove(message.id);
        pending.completer.completeError(
          StateError(message.value?.toString() ?? t('后台解算出错。')),
        );
    }
  }

  /// 后台 isolate 整个没了（内存不足、被系统杀掉）。挂着的请求不能一直等，
  /// 否则界面就永远停在进度条上了。
  void _fail(Object? error) {
    final pending = _pending.values.toList();
    _pending.clear();
    for (final request in pending) {
      request.completer.completeError(
        StateError(t('后台解算进程已退出：{0}', [error ?? t('原因不明')])),
      );
    }
  }

  Future<Object?> _request(
    String kind,
    Object? payload,
    void Function(SolveProgress)? onProgress,
  ) {
    if (_disposed) {
      return Future<Object?>.error(StateError(t('后台解算已经关闭。')));
    }
    final id = _nextId++;
    final pending = _Pending(onProgress);
    _pending[id] = pending;
    // 握手没完成时 _ready 还没值，先挂上；完成后再发。
    _ready.future.then((port) => port.send(
        _WorkerRequest(id, kind, payload, appLanguage.value.code)));
    return pending.completer.future;
  }

  /// 本地分析与测光。
  Future<SkyAnalysis> analyze(
    Uint8List bytes, {
    List<ImageExclusion> exclusions = const [],
    bool detectMoon = true,
    bool detectSun = false,
    StarDetectionProfile profile = StarDetectionProfile.normal,
  }) async =>
      await _request(
        'analyze',
        _AnalyzeRequest(bytes, exclusions, detectMoon, detectSun, profile),
        null,
      ) as SkyAnalysis;

  /// 本机离线解算。解不出来返回 null，由上层决定要不要回退在线服务。
  ///
  /// 连同 [SolveTrace] 一起返回：解不出来时上层要拿它说明「差在哪」，而记录
  /// 是在解算那一侧的 isolate 里填的，跨不过来，只能随结果一起送回来。
  Future<(SolveResult?, SolveTrace)> solveLocal(
    SkyAnalysis analysis, {
    void Function(SolveProgress)? onProgress,
    SolveHint hint = const SolveHint(),
  }) async =>
      await _request('solve', _SolveRequest(analysis, hint), onProgress)
          as (SolveResult?, SolveTrace);

  /// 给在线解算拿回来的结果补上星座名与连线。
  ///
  /// 走后台 isolate 是因为要查内置目录，而目录只在那边；顺带也让这次查询
  /// 不占用主 isolate——虽然它比解算本身快得多。
  Future<SolveResult> decorate(SolveResult solve) async =>
      await _request('decorate', solve, null) as SolveResult;

  /// 标出疑似运动天体（行星、太阳）。
  ///
  /// 也走后台 isolate，理由和 [decorate] 一样：判据要用星表查「这一带有没有
  /// 星」，而星表只在那边。[moment] 为 null 时那边原样返回，不做任何计算。
  Future<SolveResult> annotateMovingBodies(
    SkyAnalysis analysis,
    SolveResult solve,
    DateTime? moment,
  ) async =>
      await _request('moving', _MovingRequest(analysis, solve, moment), null)
          as SolveResult;

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _inbox.close();
    _isolate.kill(priority: Isolate.immediate);
  }
}

class _Pending {
  _Pending(this.onProgress);

  final void Function(SolveProgress)? onProgress;
  final completer = Completer<Object?>();
}

/// 「标出疑似运动天体」这一步要一起送过去的三样东西。
class _MovingRequest {
  const _MovingRequest(this.analysis, this.solve, this.moment);

  final SkyAnalysis analysis;
  final SolveResult solve;

  /// 拍摄时刻（UTC）。null 表示这张照片没有可用时刻。
  final DateTime? moment;
}

class _AnalyzeRequest {
  const _AnalyzeRequest(
    this.bytes,
    this.exclusions,
    this.detectMoon,
    this.detectSun,
    this.profile,
  );

  final Uint8List bytes;
  final List<ImageExclusion> exclusions;
  final bool detectMoon;
  final bool detectSun;
  final StarDetectionProfile profile;
}

/// 一次本机解算请求：分析结果 + 用户给的视场先验。
class _SolveRequest {
  const _SolveRequest(this.analysis, this.hint);

  final SkyAnalysis analysis;
  final SolveHint hint;
}

/// 后台 isolate 的入口。`Isolate.spawn` 要一个顶层函数。
Future<void> _skyWorkerMain(_WorkerBoot boot) async {
  final inbox = ReceivePort();
  boot.reply.send(_WorkerReply(0, 'ready', inbox.sendPort));

  final catalog = StarCatalog.parse(
    starsJson: boot.stars,
    namesJson: boot.names,
    constellationsJson: boot.constellations,
    constellationGrid: boot.grid,
    gaiaBytes: boot.gaia,
  );
  final solver = PlateSolver(
    catalog,
    deepSky: DeepSkyCatalog.parse(boot.deepSky),
    smallBodies: SmallBodyCatalog.parse(boot.smallBodies),
  );
  // 索引建一次就够，之后每张图都省下这一秒。用户还在挑图片的时候它就跑完了。
  solver.warmUp();

  await for (final message in inbox) {
    if (message is! _WorkerRequest) continue;
    // isolate 里的语言是另一份全局量，每条请求都带过来，解算阶段文案才跟得上
    // 用户在设置里换的语言。
    appLanguage.value = AppLanguage.fromCode(message.language);
    try {
      switch (message.kind) {
        case 'analyze':
          final request = message.payload! as _AnalyzeRequest;
          boot.reply.send(
            _WorkerReply(
              message.id,
              'done',
              await analyzeImageBytes(
                request.bytes,
                exclusions: request.exclusions,
                detectMoon: request.detectMoon,
                detectSun: request.detectSun,
                profile: request.profile,
              ),
            ),
          );
        case 'solve':
          final request = message.payload! as _SolveRequest;
          final result = solver.solve(
            request.analysis,
            hint: request.hint,
            onProgress: (progress) => boot.reply.send(
              _WorkerReply(
                message.id,
                'progress',
                progress.fraction,
                progress.stage,
                progress.deep,
              ),
            ),
          );
          boot.reply.send(
            _WorkerReply(
              message.id,
              'done',
              (result, solver.lastTrace ?? SolveTrace()),
            ),
          );
        case 'decorate':
          boot.reply.send(
            _WorkerReply(
              message.id,
              'done',
              solver.decorateSolve(message.payload! as SolveResult),
            ),
          );
        case 'moving':
          final request = message.payload! as _MovingRequest;
          boot.reply.send(
            _WorkerReply(
              message.id,
              'done',
              solver.annotateMovingBodies(
                request.solve,
                request.analysis,
                request.moment,
              ),
            ),
          );
        default:
          boot.reply.send(
            _WorkerReply(message.id, 'error', t('未知的后台请求：{0}', [message.kind])),
          );
      }
    } catch (error) {
      boot.reply.send(_WorkerReply(message.id, 'error', '$error'));
    }
  }
}

class _WorkerBoot {
  const _WorkerBoot(
    this.reply,
    this.stars,
    this.names,
    this.constellations,
    this.grid,
    this.deepSky,
    this.smallBodies,
    this.gaia,
  );

  final SendPort reply;
  final String stars;
  final String names;
  final String constellations;
  final Uint8List grid;
  final String deepSky;
  final String smallBodies;
  final Uint8List gaia;
}

class _WorkerRequest {
  const _WorkerRequest(this.id, this.kind, this.payload,
      [this.language = 'zh']);

  final int id;
  final String kind;
  final Object? payload;

  /// 这条请求要用哪门语言。
  ///
  /// isolate 有自己的内存空间，`appLanguage` 那个全局量在那边是另一份，改主
  /// isolate 里的它不会跟着变。而解算的阶段文案是在 isolate 里拼好、当字符串
  /// 发回来的，所以语言得跟着请求一起过去。
  final String language;
}

class _WorkerReply {
  const _WorkerReply(this.id, this.kind, [this.value, this.stage, this.deep = false]);

  final int id;

  /// `ready` / `progress` / `done` / `error`。
  final String kind;
  final Object? value;
  final String? stage;

  /// 这条进度是不是来自最深那层星表，见 [SolveProgress.deep]。
  final bool deep;
}
