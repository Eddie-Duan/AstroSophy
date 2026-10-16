"""把 `lib/` 里的中文字面量套上 `t(...)`，并抽出翻译表的骨架。

一次性脚本，但留在这里：下次新增文案时如果懒得手写 `t(...)`，它可以再跑一遍
（幂等的——已经套上 `t(` 的地方不会再动）。

**为什么要有它**：六百多条消息，手工改既慢又会漏；而改错的代价很高——套错一层
括号、或者把注释里的中文也改了，都会变成一堆编译错误。所以这里写了一个真正的
Dart 词法扫描器（字符串、插值、行注释、块注释都认，插值里的字符串也递归进去），
而不是拿正则硬套。

**它做三件事**：

1. `'文字'` → `t('文字')`；带插值的 `'共 ${n} 颗'` → `t('共 {0} 颗', [n])`。
   插值变成**位置占位符**，译文才能重排语序（中文「匹配 12 颗星」在英文里是
   「12 stars matched」，数字跑到前面去了）。
2. 相邻字面量的隐式拼接（Dart 允许 `'前半' '后半'`）合并成**一条**消息——
   它们在屏幕上是同一句话，拆成两条就翻译不出完整的句子了。
3. 该去 `const` 的地方去掉：`t()` 是运行时查表，`const Text('中文')` 这样写
   编译不过。

**它不动的东西**：

* 注释里的中文（占全部中文的四分之三）。
* `enum X { a('中文') }` 里的中文——那是 const 参数，套不了 `t()`；改成在展示的
  地方套（`t(outcome.label)` 就行，因为那个字段的值**就是**中文原文这个 key）。
* `SKIP_DECLARATIONS` 里那几张表——它们是顶层 const，而且值只在首次求值时算
  一遍，套上 `t()` 会把语言冻住。改成在查询函数返回的地方套。

    python tools/migrate_strings.py            # 先看报告
    python tools/migrate_strings.py --write    # 真的改
"""

import argparse
import io
import json
import os
import re
import sys

# 一个字符串要不要翻译，看它有没有「中文语境」的字符。汉字之外还得算上中文标点
# 和全角形式：`'（{0}）'`、`' · '` 这类片段一个汉字都没有，可在英文里该是半角的
# `()` 与 ` · `，漏掉它们屏幕上就会留下全角括号。U+3000–303F 是中文标点，
# U+FF01–FF60 是全角形式。
CJK = re.compile(r'[\u4e00-\u9fff\u3000-\u303f\ufe30-\ufe4f\uff01-\uff60]')
IDENT_CHAR = re.compile(r'[A-Za-z_0-9$]')
# 标识符要整段吃下去，但**不能把 `$` 算进去**：Dart 的标识符里没有 `$`，它永远
# 是插值的起点。早先两头都写错——先是用单字符类，`$id` 被拆成 `$i` 加字面量里的
# `d`；改成 `[A-Za-z_$][A-Za-z_0-9$]*` 之后又走到另一个极端，`$what$sizePart`
# 被当成一整个名字，生成的代码里冒出 `Undefined name 'what$sizePart'`。
IDENT = re.compile(r'[A-Za-z_][A-Za-z_0-9]*')

# 顶层/静态初始化里不能套 `t()`，两个原因：Dart 要求它们必须是编译期常量，而
# `t()` 是运行时查表；就算把 `const` 去掉写成 `final`，它也只在**第一次用到时
# 求值一次**——用户中途换语言，那些文字会冻在旧语言上。
#
# 这几张表都是「用代码查名字」的数据（'Cl*' → '星团'），正确的做法是留着中文
# 当 key，在**查询函数返回的地方**套 `t()`，那样每次调用才重新查表。
SKIP_DECLARATIONS = {
    'astrometry.dart': ['_objectTypes'],
    'deepsky.dart': ['_deepSkyTypes'],
    'deepsky_names.dart': ['_nicknames'],
}


# ---------------------------------------------------------------- 词法扫描


def scan(text: str):
    """扫一遍 Dart 源码。

    返回 `(literals, comments)`。每个字面量是

        {'start', 'end', 'quote', 'raw', 'triple', 'depth', 'parent', 'parts'}

    `parts` 是内容分段：`('text', 原文)` / `('expr', 源码)`。`depth` 是嵌在别的
    字符串插值里的层数，`parent` 是最内层那个外层字面量的起始位置（没有就是
    `None`）——两者一起决定「哪些字面量属于同一句话」。

    用正则做不到这件事：它分不清 `'a\\'b'`、`'$x'`、`'''多行'''`，数不出注释，
    更看不进 `${...}` 里面——而 `${cond ? '中文' : ''}` 这种写法这份源码里就有。
    """
    literals: list[dict] = []
    comments: list[tuple[int, int]] = []
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c == '/' and text[i + 1:i + 2] == '/':
            j = text.find('\n', i)
            j = n if j < 0 else j
            comments.append((i, j))
            i = j
            continue
        if c == '/' and text[i + 1:i + 2] == '*':
            level = 1
            j = i + 2
            while j < n and level > 0:
                if text.startswith('/*', j):
                    level += 1
                    j += 2
                elif text.startswith('*/', j):
                    level -= 1
                    j += 2
                else:
                    j += 1
            comments.append((i, j))
            i = j
            continue
        if _starts_string(text, i):
            i = _scan_string(text, i, 0, None, literals, comments)
            continue
        i += 1
    return literals, comments


def _starts_string(text: str, i: int) -> bool:
    c = text[i]
    if c in '\'"':
        return True
    if c in 'rR' and text[i + 1:i + 2] in ('\'', '"'):
        # `r'…'` 是 raw 字符串，但 `r` 单独出现（变量名）不是。
        return i == 0 or not IDENT_CHAR.match(text[i - 1])
    return False


def _scan_string(text, i, depth, parent, literals, comments) -> int:
    """[i] 指向引号或 `r` 前缀，返回字面量之后的位置。"""
    raw = text[i] in 'rR'
    start = i
    if raw:
        i += 1
    quote = text[i]
    triple = text.startswith(quote * 3, i)
    close = quote * (3 if triple else 1)
    j = i + len(close)
    n = len(text)
    parts: list[tuple[str, str]] = []
    buffer: list[str] = []
    while j < n:
        if not raw and text[j] == '\\':
            buffer.append(text[j:j + 2])
            j += 2
            continue
        if text.startswith(close, j):
            j += len(close)
            break
        if not raw and text[j] == '$':
            if text[j + 1:j + 2] == '{':
                if buffer:
                    parts.append(('text', ''.join(buffer)))
                    buffer = []
                expr_start = j + 2
                # 插值里可以再出现字符串（`${cond ? '中文' : ''}`），所以这里
                # 得递归扫——拿花括号计数硬找配对的 `}` 会被里面的字符串骗到。
                expr_end = _scan_interpolation(
                    text, expr_start, start, depth + 1, literals, comments)
                parts.append(('expr', text[expr_start:expr_end]))
                j = expr_end + 1
                continue
            match = IDENT.match(text, j + 1)
            if match:
                if buffer:
                    parts.append(('text', ''.join(buffer)))
                    buffer = []
                parts.append(('expr', text[j + 1:match.end()]))
                j = match.end()
                continue
        buffer.append(text[j])
        j += 1
    if buffer:
        parts.append(('text', ''.join(buffer)))
    literals.append({
        'start': start, 'end': j, 'quote': quote, 'raw': raw, 'triple': triple,
        'depth': depth, 'parent': parent, 'parts': parts,
    })
    return j


def _scan_interpolation(text, i, parent, depth, literals, comments) -> int:
    """扫 `${…}` 的内容，返回配对 `}` 的位置。"""
    n = len(text)
    level = 0
    while i < n:
        c = text[i]
        if c == '/' and text[i + 1:i + 2] == '/':
            j = text.find('\n', i)
            i = n if j < 0 else j
            continue
        if _starts_string(text, i):
            i = _scan_string(text, i, depth, parent, literals, comments)
            continue
        if c == '{':
            level += 1
        elif c == '}':
            if level == 0:
                return i
            level -= 1
        i += 1
    return i


# ---------------------------------------------------------------- 文本工具


def dart_unescape(text: str) -> str:
    """把 Dart 的转义还原成运行时真正的那串字符。"""
    out = []
    i = 0
    while i < len(text):
        c = text[i]
        if c != '\\' or i + 1 >= len(text):
            out.append(c)
            i += 1
            continue
        nxt = text[i + 1]
        simple = {'n': '\n', 'r': '\r', 't': '\t', 'b': '\b', 'f': '\f',
                  'v': '\v', '0': '\0', "'": "'", '"': '"', '\\': '\\', '$': '$'}
        if nxt in simple:
            out.append(simple[nxt])
            i += 2
            continue
        if nxt == 'u' and text[i + 2:i + 3] == '{':
            close = text.find('}', i + 3)
            out.append(chr(int(text[i + 3:close], 16)))
            i = close + 1
            continue
        if nxt == 'u':
            out.append(chr(int(text[i + 2:i + 6], 16)))
            i += 6
            continue
        if nxt == 'x':
            out.append(chr(int(text[i + 2:i + 4], 16)))
            i += 4
            continue
        out.append(nxt)
        i += 2
    return ''.join(out)


def dart_escape(text: str) -> str:
    """把一段文本写成 Dart 单引号字面量。`$` 必须转义，否则会被当插值。"""
    body = (text.replace('\\', '\\\\').replace("'", "\\'").replace('$', r'\$')
            .replace('\n', '\\n').replace('\r', '\\r').replace('\t', '\\t'))
    return f"'{body}'"


# ---------------------------------------------------------------- 结构判断


def declaration_spans(text: str, path: str):
    """[SKIP_DECLARATIONS] 里那几张表的整段区间。

    判据是「名字后面紧跟 `=`，而且本行前面有 `const`/`final`」——早先写成
    「`const|final` 后面允许跨行的任意 token 再接名字」，结果 `_objectTypes`
    那次匹配到的是**上一段文档注释里的**「逐个 `final entry in _objectTypes`」，
    跳过区间落在了注释上，真正的表反倒没跳过：套上 `t()` 之后就成了「常量表达式
    里调用方法」，十几条编译错误。
    """
    literals, comments = scan(text)
    spans = []
    for name in SKIP_DECLARATIONS.get(os.path.basename(path), []):
        found = False
        for match in re.finditer(r'\b' + re.escape(name) + r'\s*=', text):
            at = match.start()
            if any(lit['start'] <= at < lit['end'] for lit in literals):
                continue
            if any(s <= at < e for s, e in comments):
                continue
            line_start = text.rfind('\n', 0, at) + 1
            keyword = None
            for kw in re.finditer(r'\b(?:const|final)\b', text[line_start:at]):
                keyword = line_start + kw.start()
            if keyword is None:
                continue
            i = match.end()
            depth = 0
            while i < len(text):
                c = text[i]
                if c in '([{':
                    depth += 1
                elif c in ')]}':
                    depth -= 1
                elif c == ';' and depth == 0:
                    i += 1
                    break
                i += 1
            spans.append((keyword, i))
            found = True
        if not found:
            print(f'警告：{path} 里找不到要跳过的 {name}', file=sys.stderr)
    return spans


def enum_spans(text: str):
    """所有 `enum X { … }` 的区间。里面的中文是 const 参数，套不了 `t()`。"""
    spans = []
    for match in re.finditer(r'\benum\s+\w+[^{]*\{', text):
        level = 1
        j = match.end()
        while j < len(text) and level > 0:
            if text[j] == '{':
                level += 1
            elif text[j] == '}':
                level -= 1
            j += 1
        spans.append((match.start(), j))
    return spans


def enclosing_consts(text, literals, comments, pos):
    """所有真正**包住** [pos] 的 `const` 关键字位置。

    早先的写法是从字面量往回扫，看到 `const` 且括号余额不为负就算数——那是错的：
    `f(a: const [], b: '中文')` 里那个 `const` 和后面的字面量同处一层参数列表，
    往回扫既碰不到 `;` 也碰不到负数，于是被误判成「管着它」，删掉之后源码就散架。

    正确的判据是**从 `const` 往后扫**：它修饰的表达式到括号余额回到 0 就结束。
    字面量落在那段区间里，才真的被它管着。
    """
    found = []
    for match in re.finditer(r'\bconst\b', text):
        at = match.start()
        if any(lit['start'] <= at < lit['end'] for lit in literals):
            continue
        if any(s <= at < e for s, e in comments):
            continue
        if at > 0 and (IDENT_CHAR.match(text[at - 1]) or text[at - 1] == '.'):
            continue
        if IDENT_CHAR.match(text[at + 5:at + 6] or ''):
            continue
        level = 0
        i = at + 5
        while i < len(text):
            c = text[i]
            if c in '([{':
                level += 1
            elif c in ')]}':
                if level == 0:
                    break
                level -= 1
                if level == 0:
                    break
            elif c == ';' and level == 0:
                break
            i += 1
        if at >= pos or i <= pos:
            continue
        found.append(at)
    return found


def bracket_counts(text: str):
    """数一遍代码里 `()[]` 的个数（字面量和注释里的也算）。

    用来验证改写没有吃掉或多吃源码：这次改写每加一条 `t('…')` 就恰好引入一对
    `()`——带参数时再加一对 `[]`，而参数是原样搬过去的、自平衡。所以括号数目的
    增减必须**精确等于**「替换文本里的减掉被替换原文里的」；对不上就说明有东西
    被吃掉了或者挪了位置，宁可不写盘。

    **为什么数原文而不是数掩掉字面量之后的**：嵌在插值里的字面量（
    `'${cond ? '中文' : ''}'`）套上 `t()` 之后，那对括号落在**外层字面量的区间
    里面**——掩掉字面量就把它一起掩掉了，增减就永远是 0，等于没检查。
    """
    return {ch: text.count(ch) for ch in '()[]'}


def already_wrapped(text: str, lit) -> bool:
    """这个字面量是不是已经是 `t(...)` / `tn(...)` 的第一个参数了。

    不能只判断「前面几个字符是不是 `t(`」——`Text(` 也以 `t(` 结尾（`Tex` + `t(`），
    于是屏幕上那些 `Text('中文')` 会被整批误判成「改过了」，一条都不改；而紧挨着
    它的下一片字符串又被改掉，拼出来的源码就成了 `'中文' t('中文')`。

    所以要退到括号前面，把**整个标识符**取出来比。
    """
    i = lit['start'] - 1
    while i >= 0 and text[i] in ' \t\r\n':
        i -= 1
    if i < 0 or text[i] != '(':
        return False
    j = i - 1
    while j >= 0 and IDENT_CHAR.match(text[j]):
        j -= 1
    return text[j + 1:i] in ('t', 'tn')


def extract_keys(path: str) -> set[str]:
    """把**已经迁好**的源码里所有 `t('…')` / `tn('…')` 的 key 收出来。

    单独一个入口，而不是靠迁移那一趟顺手记：迁移是幂等的，重跑时那些「早就套好
    了」的消息一条都不会再报，于是顺手记下来的只有这一趟新加的几条——第一版就是
    这么把六百多条的表覆盖成了七条。
    """
    if os.path.basename(path) in ('strings.dart', 'strings_map.dart'):
        # 查表机制自己那几行不算消息：`t('$template#one')` 出现在 `tn` 的实现里，
        # 收进去只会给翻译表添一条谁也不会显示的 `{0}#one`。
        return set()
    text = io.open(path, encoding='utf-8').read()
    literals, comments = scan(text)
    keys = set()
    for lit in literals:
        if lit['raw'] or lit['triple']:
            continue
        if any(s <= lit['start'] < e for s, e in comments):
            continue
        if lit['parent'] is not None:
            continue
        if not already_wrapped(text, lit):
            continue
        args = 0
        parts = []
        for kind, value in lit['parts']:
            if kind == 'text':
                parts.append(dart_unescape(value))
            else:
                # 占位符的编号只数插值，不能拿 `enumerate` 的下标——文本段落也会
                # 占一个下标，插值不在开头时编号就整体偏了（`（亮面 {0}）。` 会被
                # 收成 `（亮面 {1}）。`，翻译表里对不上号）。
                parts.append('{%d}' % args)
                args += 1
        keys.add(''.join(parts))
    return keys


# ---------------------------------------------------------------- 主流程


def migrate_file(path: str, write: bool):
    """返回 (改了的地方数, key 集合, const→final 的说明列表)。"""
    text = io.open(path, encoding='utf-8').read()
    original = text
    keys: set[str] = set()
    transitions: list[str] = []
    count = 0

    initial_literals, _ = scan(text)
    max_depth = max((lit['depth'] for lit in initial_literals), default=0)

    # 从最内层往外扫：嵌在插值里的字符串先处理掉，外层那趟才能把插值的源码
    # 原样搬进参数列表——那时它里面已经是 `t('…')` 了。
    #
    # 层号要显式往下走。早先写成「每次取当前最大深度」，而给内层套上 `t()` 之后
    # 它**仍然是内层**（只是外面多了个 `t(`），最大深度没变——于是每轮都在同一层
    # 空转，最外层那些真正要改的 577 条一条也没轮到。
    for target in range(max_depth, -1, -1):
        literals, comments = scan(text)
        enums = enum_spans(text)
        skipped = declaration_spans(text, path)

        def usable(lit):
            return (lit['depth'] == target
                    and not lit['raw'] and not lit['triple']
                    and not any(s <= lit['start'] < e for s, e in comments)
                    and not any(s <= lit['start'] < e for s, e in enums)
                    and not any(s <= lit['start'] < e for s, e in skipped)
                    and not already_wrapped(text, lit))

        candidates = [lit for lit in literals if usable(lit)]
        if not candidates:
            continue

        # 相邻字面量（中间只有空白）属于同一句话，合并成一条消息；即使某一片
        # 的内容全是插值、自己一个中文字都没有——`'前半' '${cond ? '…' : ''}'`
        # 这种在屏幕上是连着念的，拆开就翻译不出完整的句子。
        groups: list[list[dict]] = []
        for lit in candidates:
            previous = groups[-1] if groups else None
            if (previous
                    and previous[-1]['parent'] == lit['parent']
                    and text[previous[-1]['end']:lit['start']].strip() == ''):
                previous.append(lit)
            else:
                groups.append([lit])

        edits = []
        for group in groups:
            key_parts = []
            arg_sources = []
            for lit in group:
                for kind, value in lit['parts']:
                    if kind == 'expr':
                        arg_sources.append(value)
                        key_parts.append(f'{{{len(arg_sources) - 1}}}')
                    else:
                        # 字面的花括号要转义，否则会被当成占位符
                        key_parts.append(dart_unescape(value)
                                         .replace('{', '{{').replace('}', '}}'))
            key = ''.join(key_parts)
            if not CJK.search(key):
                continue
            keys.add(key)
            call = (f't({dart_escape(key)})' if not arg_sources
                    else f't({dart_escape(key)}, [{", ".join(arg_sources)}])')
            edits.append((group[0]['start'], group[-1]['end'], call))
            count += 1

        if not edits:
            continue

        # const：`t()` 不是编译期常量，包着它的 const 得去掉；包的要是变量声明
        # （`static const _apiTemplates = …`），const 换成 final。
        #
        # 判断「是不是变量声明」只能在 `const` 之后**开头**匹配，不能要求 `=` 紧挨
        # 着字面量：`static const _tools = <Map<String, Object?>>[ {…}, {…} ]` 里
        # 那个 `=` 后面还隔着大半个表。早先写成 fullmatch 到字面量，于是判定失败、
        # 走了「删掉 const」那条路，留下 `static _tools = …` 这种没有声明关键字的
        # 残骸。
        const_edits = {}
        for start, _, _ in edits:
            for at in enclosing_consts(text, literals, comments, start):
                if re.match(r'\s*(?:[\w<>\[\],\s\.\?]+\s+)?\w+\s*=',
                            text[at + 5:]):
                    const_edits[at] = (at, at + 5, 'final')
                    transitions.append(f'{path}: {text[at:start].strip()[:70]}')
                else:
                    const_edits[at] = (at, at + 6, '')

        merged = edits + list(const_edits.values())
        merged.sort(key=lambda item: item[0])
        for a, b in zip(merged, merged[1:]):
            if a[1] > b[0]:
                raise SystemExit(
                    f'{path}: 编辑区间重叠 [{a[0]},{a[1]}) 和 [{b[0]},{b[1]})，'
                    '拒绝写盘')

        before = bracket_counts(text)
        expected = {ch: 0 for ch in '()[]'}
        for start, end, replacement in merged:
            for ch in '()[]':
                expected[ch] += replacement.count(ch) - text[start:end].count(ch)
        out = text
        for start, end, replacement in reversed(merged):
            out = out[:start] + replacement + out[end:]
        after = bracket_counts(out)
        for ch in '()[]':
            if after[ch] - before[ch] != expected[ch]:
                raise SystemExit(
                    f'{path}: 改写后 {ch!r} 的数目变了 '
                    f'{after[ch] - before[ch]}（应为 {expected[ch]}）——'
                    '源码结构被破坏，拒绝写盘')
        text = out

    if text == original:
        return 0, keys, transitions

    if "import 'strings.dart';" not in text:
        lines = text.split('\n')
        at = None
        for index, line in enumerate(lines):
            if (line.startswith("import '")
                    and not line.startswith("import 'package:")
                    and not line.startswith("import 'dart:")):
                at = index
                break
        if at is None:
            for index, line in enumerate(lines):
                if line.startswith("import 'dart:"):
                    at = index + 1
        if at is None:
            at = 1
        lines.insert(at, "import 'strings.dart';")
        text = '\n'.join(lines)

    if write:
        with io.open(path, 'w', encoding='utf-8', newline='') as handle:
            handle.write(text)
    return count, keys, transitions


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lib', default='lib', help='要处理的目录')
    parser.add_argument('--write', action='store_true', help='真的写回文件')
    parser.add_argument('--extract-only', action='store_true',
                        help='不改代码，只从现有 t(\'…\') 里把 key 全收出来')
    parser.add_argument('--keys', default=os.path.join('tools', '.cache', 'i18n_keys.txt'),
                        help='抽出所有 key 写到这里（每行一条，排序去重）')
    args = parser.parse_args()

    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, 'reconfigure', None)
        if reconfigure is not None:
            reconfigure(errors='replace')

    all_keys: set[str] = set()
    transitions: list[str] = []
    total = 0
    touched: list[str] = []
    for root, _, names in os.walk(args.lib):
        if os.path.basename(root) == 'l10n':
            continue
        for name in sorted(names):
            if not name.endswith('.dart'):
                continue
            path = os.path.join(root, name)
            if args.extract_only:
                all_keys |= extract_keys(path)
                continue
            count, keys, moved = migrate_file(path, args.write)
            if count:
                touched.append(f'{path}: {count} 条')
                total += count
                all_keys |= keys
            transitions += moved

    if args.extract_only:
        os.makedirs(os.path.dirname(args.keys), exist_ok=True)
        with io.open(args.keys, 'w', encoding='utf-8', newline='\n') as handle:
            for key in sorted(all_keys):
                handle.write(json.dumps(key, ensure_ascii=False) + '\n')
        print(f'从现有源码里收出 {len(all_keys)} 个 key，写出 {args.keys}')
        return 0

    for line in touched:
        print(line)
    print()
    print(f'文件 {len(touched)} 个，套上 t() 的消息 {total} 条，'
          f'去重后 key {len(all_keys)} 条')
    if transitions:
        print(f'const 换成 final 的 {len(transitions)} 处：')
        for line in sorted(set(transitions)):
            print('   ', line)

    if args.write and all_keys:
        os.makedirs(os.path.dirname(args.keys), exist_ok=True)
        with io.open(args.keys, 'w', encoding='utf-8', newline='\n') as handle:
            for key in sorted(all_keys):
                handle.write(key.replace('\n', '\\n') + '\n')
        print(f'写出 {args.keys}')
    elif not args.write:
        print('（--dry-run，没有写盘；加 --write 才真的改）')
    return 0


if __name__ == '__main__':
    sys.exit(main())
