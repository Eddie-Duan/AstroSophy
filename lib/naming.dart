import 'strings.dart';
import 'analysis.dart';
import 'deepsky_names.dart';
import 'models.dart';
import 'report.dart';

/// 给一次观测取一个能认得出的名字：「月亮_261015」「土星_250624」。
///
/// ## 为什么不让模型来起
///
/// 这个活看起来很适合交给 AI，实际上不适合，而且是不该：
///
///   * **它根本不需要判断**。名字里的两部分都是已经算出来的东西——拍了什么
///     （月面判据、行星判据、深空天体的角尺寸）和哪天拍的（拍摄时刻）。这
///     不是「理解」，是查表。让模型来做，等于把一次确定的映射换成一次随机的
///     取样。
///   * **它会编**。模型看到「一个亮斑」就能写出「木星_250624」，而照片里那
///     个亮斑是土星——名字是要跟一辈子的东西，错一次比没有名字糟糕。
///   * **它要联网、要花钱、要等**。这一步发生在每次保存和每次导出上，而
///     本机现在一两毫秒就能算完。为了一个字符串去等一次 API 往返，用户看到
///     的就是「保存卡了一下」。
///   * **它会破坏离线**。这个 APP 的核心承诺是照片不出手机。为了给文件起个
///     名字就把测量结果发出去，是拿最重要的东西换最不重要的东西。
///
/// 所以名字在本机拼。模型可以**改**它——用户跟 Agent 说「把这张改名成
/// 『第一次拍的月亮』」，那是另一回事：那是用户的意思，不是一个猜测。
///
/// ## 名字怎么拼
///
/// `拍到的东西_拍摄日期`：`月亮_261015`。日期用 YYMMDD 六位，够短又不歧义。
/// 没有拍摄时刻就只有前半截——宁可少一个字段，也不拿「今天」去冒充拍摄日。
String suggestedObservationName({
  required SkyAnalysis analysis,
  required SolveResult? solve,
  DateTime? moment,
  String? originalFilename,
}) {
  final what = _subjectOf(analysis, solve, originalFilename);
  return _withDate(what, moment);
}

/// 拍到的是什么东西。取不到就退回原文件名（去掉扩展名），再不行就是「星空」。
String _subjectOf(
  SkyAnalysis analysis,
  SolveResult? solve,
  String? originalFilename,
) {
  // 月面最先判——它有自己的判据，而且判出来了就不该再拿星场那套去猜。
  if (analysis.isMoonShot) return t('月亮');

  // 行星/小行星：整张图上最稀有的那个结论，也是最像「我拍的是它」的东西。
  final bodies = buildMovingBodyEntries(solve);
  if (bodies.isNotEmpty) return _sanitise(bodies.first.name);

  // 深空天体只在它确实是**主体**的时候才拿来当名字。画面角落挂着一个小星系
  // 是常事，拿它命名会让「仙女座大星系」这种文件名出现在一张猎户座的照片上
  // ——那比没有名字更误导。门槛取占像场对角线 10%。
  final deepSky = buildDeepSkyEntries(solve);
  if (deepSky.isNotEmpty && (deepSky.first.fieldFraction ?? 0) >= 0.1) {
    final entry = deepSky.first;
    // 有中文常用名就用常用名（「昴星团」比「M 45」好认），没有就用编号，
    // 但要把空格去掉——带空格的文件名在分享和命令行里都是麻烦。
    final nickname = nicknameOf(entry.name);
    return _sanitise(nickname ?? entry.name.replaceAll(' ', ''));
  }

  // 一片普通星场：用星座名。这是最贴切的答案——这张照片拍的就是这一片天，
  // 而不是某一颗星。
  final constellations = solve?.constellations;
  if (constellations != null && constellations.isNotEmpty) {
    return _sanitise(constellations.first);
  }

  // 没解算出天区：退回用户自己那个文件名。他的命名可能比我们能猜的任何
  // 名字都有信息。
  final fallback = _stem(originalFilename);
  if (fallback != null && fallback.isNotEmpty) return _sanitise(fallback);

  return t('星空');
}

/// 「月亮_261015」。没有拍摄时刻就只留前半截。
String _withDate(String what, DateTime? moment) =>
    moment == null ? what : '${what}_${_stamp(moment)}';

/// YYMMDD。
String _stamp(DateTime moment) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(moment.year % 100)}${two(moment.month)}${two(moment.day)}';
}

/// 重名时在后面加 (1)、(2)……
///
/// 序号从 1 开始而不是从 0：用户看到「(1)」就知道「有两个同名的，这是第一
/// 个以外的那个」，看到「(0)」得想一下。
String uniqueObservationName(String base, Iterable<String> taken) {
  final used = taken.toSet();
  if (!used.contains(base)) return base;
  for (var index = 1; index < 1000; index++) {
    final candidate = '$base($index)';
    if (!used.contains(candidate)) return candidate;
  }
  // 一千个同名的还没排上，那就带上时间戳，总之不能返回一个已经用过的名字。
  return '$base(${DateTime.now().millisecondsSinceEpoch})';
}

/// 原文件名的主干部分，去掉目录和扩展名。`null` 或只有扩展名时返回 null。
String? _stem(String? filename) {
  if (filename == null) return null;
  final lastSlash = filename.lastIndexOf(RegExp(r'[\\/]'));
  final name = lastSlash < 0 ? filename : filename.substring(lastSlash + 1);
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? name : name.substring(0, dot);
}

/// 去掉文件名里有歧义的字符。
///
/// 竖线、斜杠、冒号这些在别的系统上会被当成路径分隔符或被拒绝，问号星号
/// 会被当成通配符。名字是从外面来的（星座名、天体名、用户自己的文件名），
/// 不能假设它干净。
String _sanitise(String text) =>
    text.replaceAll(RegExp(r'[\\/:*?"<>|]'), '').trim();
