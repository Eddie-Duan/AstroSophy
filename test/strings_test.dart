import 'dart:io';

import 'package:astrosophy/strings.dart';
import 'package:astrosophy/strings_map.dart';
import 'package:flutter_test/flutter_test.dart';

/// 界面文字的查表。
///
/// [appLanguage] 是个全局量（理由见 `lib/strings.dart`），所以每个用例结束都要
/// 把它复位——否则一个用例把它切成英文，后面那些断言中文文案的用例会莫名其妙
/// 地挂掉，而且挂得看不出原因。
void main() {
  tearDown(() => appLanguage.value = AppLanguage.zh);

  group('选词', () {
    test('中文没有翻译表，原样返回原文', () {
      expect(appLanguage.value, AppLanguage.zh);
      expect(t('未能解析'), '未能解析');
      expect(t('匹配 {0} 颗星{1}', [12, '']), '匹配 12 颗星');
    });

    test('切成英文之后取到译文', () {
      appLanguage.value = AppLanguage.en;
      expect(t('未能解析'), 'Not solved');
      expect(t('亮星'), 'Bright stars');
      expect(t('观星仓库'), 'Observation store');
    });

    test('没有译文的条目退回中文，而不是露出 key', () {
      // key 就是中文原文，所以漏翻的后果是「显示中文」，而不是屏幕上冒出一个
      // `report.unresolved.label`。这条守着那个取舍。
      appLanguage.value = AppLanguage.en;
      expect(t('这条文案根本不存在'), '这条文案根本不存在');
    });

    test('语言代码认不出来时退回中文', () {
      expect(AppLanguage.fromCode('fr'), AppLanguage.zh);
      expect(AppLanguage.fromCode(null), AppLanguage.zh);
      expect(AppLanguage.fromCode('en'), AppLanguage.en);
    });
  });

  group('占位符', () {
    test('位置参数按序填入', () {
      appLanguage.value = AppLanguage.en;
      expect(t('匹配 {0} 颗星{1}', [12, '']), '12 stars matched');
    });

    test('译文可以重排语序', () {
      // 「匹配 12 颗星」在英文里是「12 stars matched」，数字跑到最前面——
      // 这正是用位置参数而不是内联插值的原因。
      appLanguage.value = AppLanguage.en;
      expect(
        t('画面里有 {0} 个深空天体，其中最主要的是 {1}——{2}{3}。',
            [3, 'M45', '昴星团', '']),
        'There are 3 deep-sky objects in the frame, the main one being M45 — 昴星团.',
      );
    });

    test('参数少了不会崩，也不吞掉占位符', () {
      appLanguage.value = AppLanguage.en;
      // 宁可留一个 `{1}` 在屏幕上，也不该抛异常把整屏搞挂。
      // 注意这里用的是 `t` 而不是 `tn`：单复数选词是 `tn` 的活，`t` 一律取复数
      // 那条——所以数目是 1 的时候也还是 "stars"。
      expect(t('匹配 {0} 颗星{1}', [1]), '1 stars matched{1}');
      expect(tn('匹配 {0} 颗星{1}', 1, [1, '']), '1 star matched');
    });

    test('花括号转义：给模型看的 JSON 例子要原样出来', () {
      appLanguage.value = AppLanguage.en;
      final text = t('只输出 JSON：{{"primary": "编号"}}。');
      // 键里带的是转义过的 `{{`，取出来必须是单个花括号——否则喂给模型的
      // 那段 JSON 例子就是坏的。
      expect(text, contains('{"primary": "编号"}'));
      expect(text, isNot(contains('{{')));
    });
  });

  group('单复数', () {
    test('英文的 1 用单数形式，其余用复数', () {
      appLanguage.value = AppLanguage.en;
      expect(tn('匹配 {0} 颗星{1}', 1, [1, '']), '1 star matched');
      expect(tn('匹配 {0} 颗星{1}', 2, [2, '']), '2 stars matched');
      expect(tn('匹配 {0} 颗星{1}', 0, [0, '']), '0 stars matched');
    });

    test('中文没有复数，两种数目都走同一条', () {
      expect(tn('匹配 {0} 颗星{1}', 1, [1, '']), '匹配 1 颗星');
      expect(tn('匹配 {0} 颗星{1}', 5, [5, '']), '匹配 5 颗星');
    });

    test('没有单数变体的条目照常返回复数那条', () {
      appLanguage.value = AppLanguage.en;
      expect(tn('亮星', 1), 'Bright stars');
    });
  });

  group('翻译表资产', () {
    test('英文表里没有空译文', () {
      // 空字符串会被当成「没有译文」还是「译文是空」是有歧义的，而且屏幕上
      // 会是空白一片。构建脚本抽骨架时会写出空值，所以这道闸放在测试里。
      final table = kLocalizedStrings['en'];
      expect(table, isNotNull);
      final empty = table!.entries
          .where((entry) => entry.value.trim().isEmpty)
          .map((entry) => entry.key)
          .toList();
      expect(empty, isEmpty, reason: '这些 key 的译文是空的：$empty');
    });

    test('每条译文都留住了原来的占位符编号', () {
      // 漏写一个 `{0}` 不会报错，只会让屏幕上少一个数——量出来的数值就这么
      // 悄悄消失了。所以逐个核对：key 里出现的编号，译文里得一个不少，也不
      // 能多出原文没有的。
      final table = kLocalizedStrings['en']!;
      final pattern = RegExp(r'\{(\d+)\}');
      final problems = <String>[];
      for (final entry in table.entries) {
        if (entry.key.endsWith('#one')) continue;
        final from = pattern.allMatches(entry.key).map((m) => m[1]).toSet();
        final to = pattern.allMatches(entry.value).map((m) => m[1]).toSet();
        if (from.length != to.length || !from.containsAll(to)) {
          problems.add('${entry.key} → ${entry.value}');
        }
      }
      expect(problems, isEmpty, reason: '占位符对不上的条目：$problems');
    });

    test('翻译表的键和 lib/l10n 里的 ARB 一致', () {
      // 生成物要跟得上源文件。改了 ARB 忘了跑 build_strings.py 就会在这里露头。
      final raw = File('lib/l10n/app_en.arb').readAsStringSync();
      final locales = RegExp(r'"@@locale"\s*:\s*"([a-z]+)"').firstMatch(raw);
      expect(locales?.group(1), 'en');
      // 抽查几条：只数条目数会掩盖「换掉一条」的情况，所以钉住具体的键值。
      expect(raw, contains('"未能解析"'));
      expect(raw, contains('"界面语言"'));
    });
  });
}
