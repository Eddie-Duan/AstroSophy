import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart' show AssetBundle, rootBundle;

import 'analysis.dart';
import 'astrometry.dart';
import 'catalog.dart';
import 'model.dart';
import 'models.dart';
import 'report.dart';
import 'solver.dart';

/// 一键解析的进度快照。
class PipelineProgress {
  const PipelineProgress(this.fraction, this.stage);

  /// 0–1，界面上的进度条直接用这个值。
  final double fraction;

  /// 当前在做什么，写成人话。
  final String stage;

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
  });

  final SkyAnalysis analysis;
  final SolveResult? solve;

  /// AI 解读；没配模型或解读失败时为 null。
  final String? explanation;

  /// 某一环没走通时的说明。链路不会因为一环失败就中断——本机解算不出结果
  /// 就回去问在线服务，解读失败也不影响已经算出来的坐标和测光。
  final List<String> warnings;
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
  });

  final SkyWorker worker;
  final String astrometryKey;

  /// 是否允许把预览图上传到 astrometry.net。默认不允许。
  final bool allowUpload;

  final ModelSettings? modelSettings;

  bool get _canUpload => allowUpload && astrometryKey.trim().isNotEmpty;

  bool get _canExplain => modelSettings?.hasAnyModel ?? false;

  /// 进度条怎么分段。
  ///
  /// 权重按「这一步通常要等多久」给，不是按步骤数平分：在线解算要排队，
  /// 动辄一两分钟，而本地分析只要一秒。平分的话进度条前半程几乎不动，
  /// 用户反而更慌。
  List<_Stage> get _stages => [
        const _Stage('正在分析星图', 20),
        const _Stage('正在本机解算天区', 26),
        if (_canUpload) const _Stage('正在在线解算天区', 34),
        if (_canExplain) const _Stage('正在生成解读', 16),
      ];

  /// 跑完整条链路。
  Future<PipelineOutcome> run(
    Uint8List bytes, {
    void Function(PipelineProgress)? onProgress,
    String question = '',
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

    void report(int index, double local, [String? text]) {
      if (index >= bounds.length) return;
      final (start, end) = bounds[index];
      onProgress?.call(
        PipelineProgress(
          start + (end - start) * local.clamp(0.0, 1.0),
          text ?? stages[index].name,
        ),
      );
    }

    final warnings = <String>[];

    report(0, 0);
    final analysis = await worker.analyze(bytes);

    var index = 1;
    report(index, 0, '正在本机解算天区');
    SolveResult? solve;
    try {
      solve = await worker.solveLocal(
        analysis,
        onProgress: (local, stage) => report(index, local, stage),
      );
    } catch (error) {
      warnings.add('本机解算未能完成：$error');
    }

    if (solve == null && _canUpload) {
      index++;
      try {
        solve = await AstrometryService.solve(
          analysis: analysis,
          apiKey: astrometryKey,
          onProgress: (local, stage) => report(index, local, stage),
        );
      } catch (error) {
        warnings.add('在线解算未能完成：$error');
      }
      // 在线服务只给 WCS，星座是本机补的。补不上不影响坐标和测光，所以
      // 失败了只记一条提示，不把已经拿到手的解算结果丢掉。
      if (solve != null) {
        try {
          solve = await worker.decorate(solve);
        } catch (error) {
          warnings.add('星座标注未能完成：$error');
        }
      }
    } else if (solve == null) {
      warnings.add(
        allowUpload
            ? '本机没解出这片天区，也没有可用的 Astrometry.net API Key，已跳过在线解算。'
            : '本机没解出这片天区。如需在线解算，请在设置里填写 Astrometry.net API Key 并授权上传。',
      );
    }

    String? explanation;
    final settings = modelSettings;
    if (settings != null && settings.hasAnyModel) {
      index++;
      try {
        explanation = await ModelService.explain(
          baseUrl: settings.baseUrl,
          lightKey: settings.lightKey,
          lightModel: settings.lightModel,
          strongKey: settings.strongKey,
          strongModel: settings.strongModel,
          report: buildAgentReport(analysis, solve),
          question: question,
        );
      } catch (error) {
        warnings.add('模型解读未能完成：$error');
      }
    }

    onProgress?.call(const PipelineProgress(1, '解析完成'));
    return PipelineOutcome(
      analysis: analysis,
      solve: solve,
      explanation: explanation,
      warnings: warnings,
    );
  }
}

class _Stage {
  const _Stage(this.name, this.weight);

  final String name;

  /// 相对权重，不必加起来是 1。
  final int weight;
}

// ---------------------------------------------------------------------------
// 后台 isolate
// ---------------------------------------------------------------------------

const _starsAsset = 'assets/catalog/stars.json';
const _namesAsset = 'assets/catalog/names.json';
const _constellationsAsset = 'assets/catalog/constellations.json';
const _gridAsset = 'assets/catalog/constellation_grid.bin';

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

    final inbox = ReceivePort();
    final ready = Completer<SendPort>();
    final isolate = await Isolate.spawn(
      _skyWorkerMain,
      _WorkerBoot(inbox.sendPort, stars, names, constellations, grid),
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
          (message.value! as num).toDouble(),
          message.stage ?? '',
        );
      case 'done':
        _pending.remove(message.id);
        pending.completer.complete(message.value);
      default:
        _pending.remove(message.id);
        pending.completer.completeError(
          StateError(message.value?.toString() ?? '后台解算出错。'),
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
        StateError('后台解算进程已退出：${error ?? '原因不明'}'),
      );
    }
  }

  Future<Object?> _request(
    String kind,
    Object? payload,
    void Function(double, String)? onProgress,
  ) {
    if (_disposed) {
      return Future<Object?>.error(StateError('后台解算已经关闭。'));
    }
    final id = _nextId++;
    final pending = _Pending(onProgress);
    _pending[id] = pending;
    // 握手没完成时 _ready 还没值，先挂上；完成后再发。
    _ready.future.then((port) => port.send(_WorkerRequest(id, kind, payload)));
    return pending.completer.future;
  }

  /// 本地分析与测光。
  Future<SkyAnalysis> analyze(Uint8List bytes) async =>
      await _request('analyze', bytes, null) as SkyAnalysis;

  /// 本机离线解算。解不出来返回 null，由上层决定要不要回退在线服务。
  Future<SolveResult?> solveLocal(
    SkyAnalysis analysis, {
    void Function(double, String)? onProgress,
  }) async =>
      await _request('solve', analysis, onProgress) as SolveResult?;

  /// 给在线解算拿回来的结果补上星座名与连线。
  ///
  /// 走后台 isolate 是因为要查内置目录，而目录只在那边；顺带也让这次查询
  /// 不占用主 isolate——虽然它比解算本身快得多。
  Future<SolveResult> decorate(SolveResult solve) async =>
      await _request('decorate', solve, null) as SolveResult;

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _inbox.close();
    _isolate.kill(priority: Isolate.immediate);
  }
}

class _Pending {
  _Pending(this.onProgress);

  final void Function(double, String)? onProgress;
  final completer = Completer<Object?>();
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
  );
  final solver = PlateSolver(catalog);
  // 索引建一次就够，之后每张图都省下这一秒。用户还在挑图片的时候它就跑完了。
  solver.warmUp();

  await for (final message in inbox) {
    if (message is! _WorkerRequest) continue;
    try {
      switch (message.kind) {
        case 'analyze':
          boot.reply.send(
            _WorkerReply(
              message.id,
              'done',
              await analyzeImageBytes(message.payload! as Uint8List),
            ),
          );
        case 'solve':
          final result = solver.solve(
            message.payload! as SkyAnalysis,
            onProgress: (fraction, stage) => boot.reply.send(
              _WorkerReply(message.id, 'progress', fraction, stage),
            ),
          );
          boot.reply.send(_WorkerReply(message.id, 'done', result));
        case 'decorate':
          boot.reply.send(
            _WorkerReply(
              message.id,
              'done',
              solver.decorateSolve(message.payload! as SolveResult),
            ),
          );
        default:
          boot.reply.send(
            _WorkerReply(message.id, 'error', '未知的后台请求：${message.kind}'),
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
  );

  final SendPort reply;
  final String stars;
  final String names;
  final String constellations;
  final Uint8List grid;
}

class _WorkerRequest {
  const _WorkerRequest(this.id, this.kind, this.payload);

  final int id;
  final String kind;
  final Object? payload;
}

class _WorkerReply {
  const _WorkerReply(this.id, this.kind, [this.value, this.stage]);

  final int id;

  /// `ready` / `progress` / `done` / `error`。
  final String kind;
  final Object? value;
  final String? stage;
}
