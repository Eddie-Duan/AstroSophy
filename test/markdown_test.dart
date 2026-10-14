import 'package:astrosophy/markdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一段典型的模型输出：模型不会只用一种语法，标题、粗体、列表、引用、
/// 代码块、表格经常一起出现。
const _sample = '''
## 结论

这张照片**确实**拍到了猎户座，中心位于 RA 05h 35m。

- 匹配了 27 颗星
- 星等零点 14.2 ± 0.18
  - 参考星 12 颗

1. 先看坐标是不是合理
2. 再看测光散布

> 注意：单张照片无法确认拉长亮点到底是卫星还是抖动。

```dart
final wcs = result.wcs;
```

| 天体 | 星等 |
| --- | --- |
| 参宿四 | 0.45 |
| 参宿七 | 0.18 |

---

参见 [Astrometry.net](https://astrometry.net/) 的说明。
''';

/// 把树上所有可见的文字收上来。断言「没有裸露的语法」时，逐个 widget 去
/// find 太脆，一次收完再统一检查更稳。
List<String> _renderedStrings(WidgetTester tester) {
  final texts = <String>[];
  for (final element in find.byType(Text).evaluate()) {
    final widget = element.widget as Text;
    final data = widget.data;
    if (data != null) texts.add(data);
    final span = widget.textSpan;
    if (span != null) texts.add(span.toPlainText());
  }
  for (final element in find.byType(SelectableText).evaluate()) {
    final widget = element.widget as SelectableText;
    final data = widget.data;
    if (data != null) texts.add(data);
    final span = widget.textSpan;
    if (span != null) texts.add(span.toPlainText());
  }
  return texts;
}

Future<void> _pump(WidgetTester tester, String source) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: MarkdownText(source)),
        ),
      ),
    );

void main() {
  group('parseMarkdown 分块', () {
    test('标题只认井号加空格', () {
      expect(headingOf('## 结论'), (2, '结论'));
      expect(headingOf('# 一级'), (1, '一级'));
      expect(headingOf('###### 六级'), (6, '六级'));
      // 没有空格就不是标题：#1 号点源这种句子不能被吞掉。
      expect(headingOf('#1 号点源'), isNull);
      // 七个井号超出 Markdown 的范围，当普通文字。
      expect(headingOf('####### 七级'), isNull);
      expect(headingOf('普通一行'), isNull);
    });

    test('分隔线要求整行同一个记号', () {
      expect(isRule('---'), isTrue);
      expect(isRule('****'), isTrue);
      expect(isRule('___'), isTrue);
      // 带空格的连字符是列表项，不是分隔线。
      expect(isRule('- - -'), isFalse);
      expect(isRule('--'), isFalse);
    });

    test('列表项认得出有序、无序和缩进', () {
      final bullet = listItemOf('- 匹配了 27 颗星');
      expect(bullet, isNotNull);
      expect(bullet!.ordered, isFalse);
      expect(bullet.indent, 0);
      expect(bullet.marker, '·');
      expect(bullet.text, '匹配了 27 颗星');

      final nested = listItemOf('  - 参考星 12 颗');
      expect(nested!.indent, 1);
      expect(nested.marker, '–');

      final ordered = listItemOf('2. 再看测光散布');
      expect(ordered!.ordered, isTrue);
      expect(ordered.number, 2);
      expect(ordered.marker, '2.');

      expect(listItemOf('这是一句话'), isNull);
    });

    test('一段完整的输出切成预期的那几块', () {
      final blocks = parseMarkdown(_sample);
      expect(blocks.whereType<MarkdownHeading>().length, 1);
      expect(blocks.whereType<MarkdownHeading>().first.level, 2);
      expect(blocks.whereType<MarkdownHeading>().first.text, '结论');
      expect(blocks.whereType<MarkdownList>().length, 2);
      expect(blocks.whereType<MarkdownQuote>().length, 1);
      expect(blocks.whereType<MarkdownCode>().length, 1);
      expect(blocks.whereType<MarkdownCode>().first.text, 'final wcs = result.wcs;');
      expect(blocks.whereType<MarkdownCode>().first.language, 'dart');
      expect(blocks.whereType<MarkdownTable>().length, 1);
      expect(blocks.whereType<MarkdownRule>().length, 1);

      // 表格里的那行 | --- | 只是排版用的分隔符，不该被当成一行内容。
      final rows = blocks.whereType<MarkdownTable>().first.rows;
      expect(rows.length, 3);
      expect(rows.first, ['天体', '星等']);
      expect(rows.last, ['参宿七', '0.18']);
    });

    test('表格列数不齐时补齐，而不是让渲染崩掉', () {
      final rows = padRows([
        ['a', 'b', 'c'],
        ['d'],
      ]);
      expect(rows[0].length, 3);
      expect(rows[1], ['d', '', '']);
    });

    test('只有一行的竖线不当表格', () {
      final blocks = parseMarkdown('| 单行 | 不算表格 |\n这就是普通的一句话。');
      expect(blocks.whereType<MarkdownTable>(), isEmpty);
      expect(blocks.whereType<MarkdownParagraph>().length, 1);
    });

    test('没写收尾的代码块也吃到文件结束', () {
      final blocks = parseMarkdown('```\n第一行\n第二行');
      expect(blocks.whereType<MarkdownCode>().length, 1);
      expect(blocks.whereType<MarkdownCode>().first.text, '第一行\n第二行');
    });

    test('正文里的下划线不是斜体', () {
      final spans = inlineSpans(
        '字段 magnitude_zero_point 没被切开',
        const TextStyle(),
      );
      final text = spans.map((span) => (span as TextSpan).text).join();
      expect(text, '字段 magnitude_zero_point 没被切开');
      expect(
        spans.every((span) => (span as TextSpan).style?.fontStyle == null),
        isTrue,
        reason: '整行都不该出现斜体',
      );
    });
  });

  group('MarkdownText 渲染', () {
    testWidgets('解读里的语法记号不会裸露在屏幕上', (tester) async {
      await _pump(tester, _sample);
      final texts = _renderedStrings(tester);
      expect(texts, isNotEmpty);

      for (final marker in ['##', '**', '```', '| ---']) {
        for (final text in texts) {
          expect(
            text.contains(marker),
            isFalse,
            reason: '「$marker」原样显示出来了：$text',
          );
        }
      }
      // 记号去掉了，内容要还在。
      expect(texts.any((text) => text.contains('结论')), isTrue);
      expect(texts.any((text) => text.contains('确实拍到了猎户座')), isTrue);
      expect(texts.any((text) => text.contains('参宿四')), isTrue);
      // 链接只显示文字，不显示地址。
      expect(texts.any((text) => text.contains('Astrometry.net')), isTrue);
      expect(texts.any((text) => text.contains('https://')), isFalse);
    });

    testWidgets('空解读不占地方，也不抛异常', (tester) async {
      await _pump(tester, '   \n  \n');
      expect(find.byType(MarkdownText), findsOneWidget);
      expect(_renderedStrings(tester), isEmpty);
    });

    testWidgets('只有一行普通文字也能正常渲染', (tester) async {
      await _pump(tester, '就一句话。');
      expect(_renderedStrings(tester), contains('就一句话。'));
    });
  });
}
