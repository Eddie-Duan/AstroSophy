/// 界面文字的多语言查表。
///
/// 用起来就一个函数：把原来的中文字面量套上 [t]。
///
/// ```dart
/// Text('未能解析')                 →  Text(t('未能解析'))
/// Text('匹配 ${n} 颗星')           →  Text(t('匹配 {0} 颗星', [n]))
/// ```
///
/// **为什么不用 Flutter 官方的 `gen-l10n`**：那套生成的 `AppLocalizations.of(context)`
/// 要靠 `BuildContext`，而这个工程里将近一半的文字根本不在 widget 树里——报告是
/// 纯函数拼出来的 Markdown、解算跑在 isolate 里（它的阶段文案还是当字符串跨端口
/// 传出来的）、Agent 的工具描述是给模型看的、导出的分享文本要写给别的程序。为了
/// 让那些地方也能查表，取词这件事必须是一个不依赖环境的纯函数。
///
/// **为什么中文原文就是 key**：省掉给几百条消息起名字的活，而且漏翻的时候退回
/// 中文原文，屏幕上出现的是「未能解析」而不是 `report.unresolved.label`。翻译表
/// 存在 `lib/l10n/app_<语言>.arb` 里——ARB 是社区通用的格式，将来要加一门语言
/// 只要多放一个文件、重跑一次 `tools/build_strings.py`，不必碰任何 Dart 代码。
library;

import 'package:flutter/foundation.dart';

import 'strings_map.dart';

/// 界面语言。
enum AppLanguage {
  /// 简体中文。也是缺省值：翻译表缺席时全部文案退回中文原文，所以中文永远是
  /// 那个「一定能显示出来」的兜底。
  zh('zh', '简体中文', 'Chinese (Simplified)'),

  /// 英文。
  en('en', 'English', 'English');

  const AppLanguage(this.code, this.nativeName, this.englishName);

  /// 语言代码，也是 `app_<code>.arb` 的文件名里那一段。
  final String code;

  /// 用这门语言自己的写法称呼它——语言选择器里要显示「简体中文」而不是
  /// 「Chinese (Simplified)」，用户找的是自己认识的那几个字。
  final String nativeName;

  /// 用英文怎么称呼它。给别的地方（比如导出的报告里记一笔）留的。
  final String englishName;

  static AppLanguage fromCode(String? code) => values.firstWhere(
        (language) => language.code == code,
        orElse: () => AppLanguage.zh,
      );
}

/// 当前界面语言。
///
/// 做成全局的可监听量而不是塞进 `InheritedWidget`，是因为上面说的那半个工程拿不到
/// `BuildContext`：报告生成、Agent 工具描述、isolate 里的进度文案都要读它，而它们
/// 散在整条链路各处，一层层往下传参数只会把每个签名都弄脏。
///
/// 界面那侧挂个 `ValueListenableBuilder` 就能跟着换；非 widget 的地方直接读当前值。
///
/// **跨 isolate 的文案不靠这个**：isolate 有自己的内存空间，那边读到的永远是
/// 初始值。所以语言要跟着任务一起传进去，见 `pipeline.dart` 里 `_WorkerBoot` 和
/// `SkyJob` 上那个 `language` 字段。
final ValueNotifier<AppLanguage> appLanguage =
    ValueNotifier<AppLanguage>(AppLanguage.zh);

/// 按当前语言翻译 [template]；没有译文就原样返回。
///
/// [args] 依次填进模板里的 `{0}`、`{1}`……占位符。用位置而不是名字，是因为 key
/// 就是中文原文、没法给参数起名；而中文语序和英文不同（「匹配 12 颗星」在英文里
/// 是「12 stars matched」，数字跑到前面去了），所以译文里的占位符顺序可以随意
/// 调换，这一点必须靠位置参数才做得到。
String t(String template, [List<Object?> args = const []]) {
  final text = kLocalizedStrings[appLanguage.value.code]?[template] ?? template;
  if (args.isEmpty) return _unescapeBraces(text);
  final filled = text.replaceAllMapped(
    RegExp(r'\{(\d+)\}'),
    (match) {
      final index = int.parse(match[1]!);
      return index < args.length ? '${args[index]}' : match[0]!;
    },
  );
  return _unescapeBraces(filled);
}

/// 带单复数的那十几条。
///
/// 中文没有单复数，所以这类模板在中文表里只有一条；英文表里另给一条
/// `<中文模板>#one`，[count] 为 1 时优先用它。用后缀而不是 ICU 的完整语法，是因为
/// 需要这功能的只有十几条（「12 颗星」/「1 star」这种），为它们把另外几百条都拖进
/// 一套复数规则里不划算。
String tn(String template, int count, [List<Object?> args = const []]) {
  final table = kLocalizedStrings[appLanguage.value.code];
  if (count == 1 && table?['$template#one'] != null) {
    return t('$template#one', args);
  }
  return t(template, args);
}

/// 把 `{{`、`}}` 还原成字面的花括号。
///
/// 只有两条消息里带 JSON 例子（给模型看的工具描述），它们本身就有花括号，
/// 不转义的话会被当成占位符吃掉。
String _unescapeBraces(String text) {
  if (!text.contains('{{') && !text.contains('}}')) return text;
  return text.replaceAllMapped(
    RegExp(r'\{\{|\}\}'),
    (match) => match[0]!.substring(0, 1),
  );
}
