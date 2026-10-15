import 'package:flutter/material.dart';

import 'theme.dart';

/// 一个够用的 Markdown 渲染器。
///
/// 模型返回的解读天生就是 Markdown：标题、**粗体**、项目符号、代码块。直接
/// 塞进 `Text` 会把这些记号原样显示出来——一屏的 `##` 和 `**` 比什么都难看，
/// 而且用户会以为程序坏了。
///
/// 自己写而不引 `flutter_markdown`：那个包已经停止维护，而这里要处理的语法
/// 只有模型实际会用的那几种。一个几百行的转换器，比一个长期没人管的依赖更好
/// 交代，也和这个项目「图表全部自绘、不引图表库」的选择一致。
///
/// 支持的范围：`#` 标题、`**粗体**`、`*斜体*`、`` `行内代码` ``、`==高亮==`、
/// 围栏代码块、`-` / `1.` 列表（含缩进）、`>` 引用、`---` 分隔线、
/// `[文字](链接)`。
///
/// 链接只显示文字，不做跳转：这个 APP 没有打开浏览器的能力，也不该因为一段
/// 模型输出就把用户切走。真正需要点的地方（Astrometry.net 之类）在别处有按钮。
///
/// 不支持的语法不会报错，就当普通文字原样显示——渲染器最糟糕的失败方式是
/// 把内容吞掉。
class MarkdownText extends StatelessWidget {
  const MarkdownText(this.source, {super.key});

  final String source;

  @override
  Widget build(BuildContext context) {
    final blocks = parseMarkdown(source);
    if (blocks.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var index = 0; index < blocks.length; index++)
          Padding(
            // 第一块不加上间距，否则整段内容会被卡片的内边距再顶下来一截。
            padding: EdgeInsets.only(top: index == 0 ? 0 : blocks[index].topGap),
            child: blocks[index].build(context),
          ),
      ],
    );
  }
}

/// 正文的字号与行高。行高给得比默认宽：解读是连着读的段落，挤在一起很快
/// 就丧失阅读欲望。
TextStyle bodyStyle(BuildContext context) =>
    DefaultTextStyle.of(context).style.copyWith(fontSize: 13.5, height: 1.62);

/// 把一个 Markdown 文本切成块。公开出来是为了能单独测解析结果，不必为了
/// 断言「这是不是一段代码块」去搭一棵 widget 树。
List<MarkdownBlock> parseMarkdown(String source) {
  final lines = source.replaceAll('\r\n', '\n').split('\n');
  final blocks = <MarkdownBlock>[];
  final paragraph = <String>[];

  void flushParagraph() {
    if (paragraph.isEmpty) return;
    blocks.add(MarkdownBlock.paragraph(paragraph.join('\n')));
    paragraph.clear();
  }

  var index = 0;
  while (index < lines.length) {
    final line = lines[index];
    final trimmed = line.trim();

    // 围栏代码块：从 ``` 到下一个 ```（或文件结束）之间的所有行都原样保留，
    // 里面再像标题也不解析——代码块的作用就是不解释。
    if (trimmed.startsWith('```')) {
      flushParagraph();
      final language = trimmed.substring(3).trim();
      final code = <String>[];
      index++;
      while (index < lines.length && !lines[index].trim().startsWith('```')) {
        code.add(lines[index]);
        index++;
      }
      // 跳过收尾的那个 ```；没写收尾时就停在文件末尾。
      if (index < lines.length) index++;
      blocks.add(MarkdownBlock.code(code.join('\n'), language));
      continue;
    }

    if (trimmed.isEmpty) {
      flushParagraph();
      index++;
      continue;
    }

    if (isRule(trimmed)) {
      flushParagraph();
      blocks.add(const MarkdownBlock.rule());
      index++;
      continue;
    }

    final heading = headingOf(trimmed);
    if (heading != null) {
      flushParagraph();
      blocks.add(MarkdownBlock.heading(heading.$1, heading.$2));
      index++;
      continue;
    }

    if (trimmed.startsWith('>')) {
      flushParagraph();
      final quoted = <String>[];
      while (index < lines.length && lines[index].trim().startsWith('>')) {
        quoted.add(lines[index].trim().replaceFirst(RegExp(r'^>\s?'), ''));
        index++;
      }
      blocks.add(MarkdownBlock.quote(quoted.join('\n')));
      continue;
    }

    final item = listItemOf(line);
    if (item != null) {
      flushParagraph();
      final entries = <MarkdownListItem>[];
      while (index < lines.length) {
        final next = listItemOf(lines[index]);
        if (next == null) break;
        entries.add(next);
        index++;
      }
      blocks.add(MarkdownBlock.list(entries));
      continue;
    }

    // 表格要连着两行都以竖线包起来才算，单单一行的竖线多半只是正文里
    // 「A|B」这种写法，把它当表格会吃掉一段正常的话。
    if (isTableRow(line) &&
        index + 1 < lines.length &&
        isTableRow(lines[index + 1])) {
      flushParagraph();
      final rows = <List<String>>[];
      while (index < lines.length && isTableRow(lines[index])) {
        final cells = splitTableRow(lines[index]);
        if (!isTableSeparator(cells)) rows.add(cells);
        index++;
      }
      blocks.add(MarkdownBlock.table(padRows(rows)));
      continue;
    }

    paragraph.add(line);
    index++;
  }
  flushParagraph();
  return blocks;
}

/// 一行是不是 `---` 这样的分隔线。
bool isRule(String trimmed) {
  if (trimmed.length < 3) return false;
  final marker = trimmed[0];
  if (marker != '-' && marker != '*' && marker != '_') return false;
  for (final code in trimmed.codeUnits) {
    if (code != marker.codeUnitAt(0)) return false;
  }
  return true;
}

/// `## 标题` → `(2, '标题')`；不是标题则返回 null。
///
/// `#` 后面必须跟空格，否则 `#1 号点` 这种句子会被当成标题吞掉。
(int, String)? headingOf(String trimmed) {
  var level = 0;
  while (level < trimmed.length && trimmed[level] == '#') {
    level++;
  }
  if (level == 0 || level > 6) return null;
  if (level >= trimmed.length || trimmed[level] != ' ') return null;
  return (level, trimmed.substring(level).trim());
}

/// `- 内容`、`  * 内容`、`3. 内容` → 列表项；不是列表项则返回 null。
MarkdownListItem? listItemOf(String line) {
  final match = RegExp(r'^(\s*)([-*+]|\d{1,2}[.)])\s+(.*)$').firstMatch(line);
  if (match == null) return null;
  // 缩进按两格一层。模型有时用四格，也按两层算——多缩一层只是多空一点，
  // 而少算一层会让子项和父项看起来是同一级。
  final indent = (match.group(1)!.length ~/ 2).clamp(0, 4);
  final marker = match.group(2)!;
  final ordered = !'-*+'.contains(marker[0]);
  return MarkdownListItem(
    text: match.group(3)!.trim(),
    indent: indent,
    ordered: ordered,
    number: ordered ? int.tryParse(marker.replaceAll(RegExp(r'[.)]'), '')) : null,
  );
}

/// 一行是不是 Markdown 表格的一行：首尾都用竖线包起来。
bool isTableRow(String line) {
  final trimmed = line.trim();
  return trimmed.length >= 2 &&
      trimmed.startsWith('|') &&
      trimmed.endsWith('|');
}

/// 拆开表格行，去掉首尾那两个竖线。
List<String> splitTableRow(String line) {
  final trimmed = line.trim();
  return trimmed
      .substring(1, trimmed.length - 1)
      .split('|')
      .map((cell) => cell.trim())
      .toList(growable: false);
}

/// `| --- | :---: |` 这行只是排版用的分隔符，内容里不该出现。
bool isTableSeparator(List<String> cells) => cells.isNotEmpty &&
    cells.every((cell) => RegExp(r'^:?-{2,}:?$').hasMatch(cell));

/// 把长短不齐的行补齐到同样的列数。
///
/// [Table] 要求每一行的格子数一致，而模型写的表格经常缺最后一列。补齐比
/// 让整段渲染崩掉划算得多。
List<List<String>> padRows(List<List<String>> rows) {
  var columns = 0;
  for (final row in rows) {
    if (row.length > columns) columns = row.length;
  }
  return [
    for (final row in rows)
      [
        ...row,
        for (var index = row.length; index < columns; index++) '',
      ],
  ];
}

/// 解析出来的一个块。
sealed class MarkdownBlock {
  const MarkdownBlock();

  const factory MarkdownBlock.paragraph(String text) = MarkdownParagraph;
  const factory MarkdownBlock.heading(int level, String text) = MarkdownHeading;
  const factory MarkdownBlock.list(List<MarkdownListItem> items) = MarkdownList;
  const factory MarkdownBlock.quote(String text) = MarkdownQuote;
  const factory MarkdownBlock.code(String text, String language) =
      MarkdownCode;
  const factory MarkdownBlock.table(List<List<String>> rows) = MarkdownTable;
  const factory MarkdownBlock.rule() = MarkdownRule;

  /// 与上一块之间的间距。
  double get topGap;

  Widget build(BuildContext context);
}

class MarkdownParagraph extends MarkdownBlock {
  const MarkdownParagraph(this.text);

  final String text;

  @override
  double get topGap => 8;

  @override
  Widget build(BuildContext context) => SelectableText.rich(
        TextSpan(children: inlineSpans(text, bodyStyle(context))),
      );
}

class MarkdownHeading extends MarkdownBlock {
  const MarkdownHeading(this.level, this.text);

  final int level;
  final String text;

  // 标题上面的留白要比段落大，否则整篇看起来是一坨；一级标题再大一点，
  // 让「新的一个问题开始了」一眼可见。
  @override
  double get topGap => level <= 2 ? 18 : 14;

  @override
  Widget build(BuildContext context) {
    final base = bodyStyle(context).copyWith(
      fontSize: switch (level) {
        1 => 16.5,
        2 => 15.0,
        _ => 14.0,
      },
      fontWeight: FontWeight.w700,
      height: 1.35,
      color: level <= 2 ? kMint : null,
    );
    return SelectableText.rich(
      TextSpan(children: inlineSpans(text, base)),
    );
  }
}

class MarkdownList extends MarkdownBlock {
  const MarkdownList(this.items);

  final List<MarkdownListItem> items;

  @override
  double get topGap => 8;

  @override
  Widget build(BuildContext context) {
    final style = bodyStyle(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var index = 0; index < items.length; index++)
          Padding(
            padding: EdgeInsets.only(
              top: index == 0 ? 0 : 4,
              left: items[index].indent * 14,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 记号占固定宽度，正文才不会被不同的记号长度推来推去。
                SizedBox(
                  width: 22,
                  child: Text(
                    items[index].marker,
                    style: style.copyWith(color: kMint),
                  ),
                ),
                Expanded(
                  child: SelectableText.rich(
                    TextSpan(
                      children: inlineSpans(items[index].text, style),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class MarkdownQuote extends MarkdownBlock {
  const MarkdownQuote(this.text);

  final String text;

  @override
  double get topGap => 8;

  @override
  Widget build(BuildContext context) {
    final style = bodyStyle(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
      decoration: const BoxDecoration(
        border: Border(left: BorderSide(color: kMint, width: 2.5)),
      ),
      child: SelectableText.rich(
        TextSpan(
          children: inlineSpans(
            text,
            style.copyWith(color: const Color(0xFFB2C0D2)),
          ),
        ),
      ),
    );
  }
}

class MarkdownCode extends MarkdownBlock {
  const MarkdownCode(this.text, this.language);

  final String text;
  final String language;

  @override
  double get topGap => 8;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFF0A1421),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF22334A)),
        ),
        // 代码行可能很长，横向滚动而不是折行——折了就看不出缩进了。
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SelectableText(
            text,
            style: bodyStyle(context).copyWith(
              fontFamily: 'monospace',
              fontSize: 12,
              height: 1.45,
            ),
          ),
        ),
      );
}

class MarkdownTable extends MarkdownBlock {
  const MarkdownTable(this.rows);

  final List<List<String>> rows;

  @override
  double get topGap => 10;

  @override
  Widget build(BuildContext context) {
    final style = bodyStyle(context);
    final header = style.copyWith(fontWeight: FontWeight.w700, color: kMint);
    return SingleChildScrollView(
      // 列多了卡片装不下，横向滚动比把每格挤成竖排字好读。
      scrollDirection: Axis.horizontal,
      child: Table(
        // 列宽按内容定，再给一个下限：只有一个字的表头（比如「星等」下面
        // 写「4.1」）挤成一条竖缝会很难读。
        defaultColumnWidth: const MinColumnWidth(
          IntrinsicColumnWidth(),
          FixedColumnWidth(46),
        ),
        border: TableBorder.all(color: const Color(0xFF22334A), width: 0.8),
        children: [
          for (var row = 0; row < rows.length; row++)
            TableRow(
              children: [
                for (final cell in rows[row])
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 5,
                    ),
                    // 这里用 Text 而不是 SelectableText：单元格宽度是按内容
                    // 算出来的，可选中文本在这个约束下容易和表格的固有宽度
                    // 打架；一格里几个字也不值得为选中多担一层风险。
                    child: Text(
                      cell,
                      softWrap: false,
                      style: row == 0 ? header : style,
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class MarkdownRule extends MarkdownBlock {
  const MarkdownRule();

  @override
  double get topGap => 14;

  @override
  Widget build(BuildContext context) => const Divider(height: 1);
}

/// 列表里的一项。
class MarkdownListItem {
  const MarkdownListItem({
    required this.text,
    required this.indent,
    required this.ordered,
    this.number,
  });

  final String text;

  /// 缩进层级，0 是最外层。
  final int indent;

  final bool ordered;

  /// 有序列表里写着的序号；解析不出来时退回按位置数。
  final int? number;

  /// 画在正文左边的记号。
  String get marker =>
      ordered ? '${number ?? 1}.' : (indent == 0 ? '·' : '–');
}

/// 把一行文字切成带样式的片段，处理粗体、斜体、行内代码和链接。
///
/// 用手写扫描而不是正则替换：这几条规则的边界互相重叠（`**` 和 `*`、`_` 在
/// 标识符里），正则叠起来读不懂也调不动，一段顺序扫描反而把优先级写得很清楚。
List<InlineSpan> inlineSpans(String text, TextStyle base) {
  final spans = <InlineSpan>[];
  final buffer = StringBuffer();

  void flush() {
    if (buffer.isEmpty) return;
    spans.add(TextSpan(text: buffer.toString(), style: base));
    buffer.clear();
  }

  // 成对记号：起始标记、结束标记、给中间那段文字加的样式。
  const markers = <(String, String)>[
    ('**', '**'),
    ('__', '__'),
    ('==', '=='),
    ('`', '`'),
    ('*', '*'),
    ('_', '_'),
  ];

  var index = 0;
  while (index < text.length) {
    final rest = text.substring(index);
    var matched = false;

    for (final (open, close) in markers) {
      if (!rest.startsWith(open)) continue;
      // 单个下划线不在词中间生效：`magnitude_zero_point` 这种字段名是天文
      // 数据里最常见的东西，把中间那个下划线当斜体标记会把整行切成两半。
      if (open == '_' && index > 0 && _isWordCharacter(text[index - 1])) {
        continue;
      }
      final end = rest.indexOf(close, open.length);
      // end == open.length 说明中间是空的（`****`），那多半不是记号。
      if (end <= open.length) continue;
      flush();
      spans.add(
        TextSpan(
          text: rest.substring(open.length, end),
          style: _styleFor(open, base),
        ),
      );
      index += end + close.length;
      matched = true;
      break;
    }
    if (matched) continue;

    if (rest.startsWith('[')) {
      final labelEnd = rest.indexOf('](');
      final targetEnd = labelEnd < 0 ? -1 : rest.indexOf(')', labelEnd + 2);
      if (labelEnd > 0 && targetEnd > labelEnd) {
        flush();
        spans.add(
          TextSpan(
            text: rest.substring(1, labelEnd),
            style: base.copyWith(
              color: kMint,
              decoration: TextDecoration.underline,
              decorationColor: kMint,
            ),
          ),
        );
        index = targetEnd + 1;
        continue;
      }
    }

    buffer.write(text[index]);
    index++;
  }
  flush();
  return spans;
}

TextStyle _styleFor(String marker, TextStyle base) => switch (marker) {
      '**' || '__' => base.copyWith(fontWeight: FontWeight.w700),
      // 高亮：天体名用它标出来。
      //
      // 不借用行内代码（`` ` ``）来达到同样效果：那是等宽加底色，用来写字段名
      // 的；把一个中文星名塞进去，看着像出错信息。这个记号在 Markdown 的
      // 各种方言里就是「高亮」，语义对得上。
      '==' => base.copyWith(color: kMint, fontWeight: FontWeight.w600),
      '`' => base.copyWith(
          fontFamily: 'monospace',
          fontSize: (base.fontSize ?? 14) - 1.5,
          backgroundColor: const Color(0xFF22334A),
        ),
      _ => base.copyWith(fontStyle: FontStyle.italic),
    };

bool _isWordCharacter(String character) =>
    RegExp(r'[A-Za-z0-9_]').hasMatch(character);
