"""把 `lib/l10n/app_<语言>.arb` 编成 `lib/strings_map.dart`。

**为什么要有这一步**：翻译表用 ARB 存——它是社区通用的格式，将来要把文案交给
译者、丢进 Weblate 这类平台，或者加一门语言，都只是多一个文件的事。但运行时
取词得是一个不依赖 `BuildContext` 的纯函数（理由见 `lib/strings.dart`），而
`gen-l10n` 生成的那套偏偏依赖 context，所以自己把这几十行编译出来。

**key 就是中文原文**，于是这个脚本要做的只有一件事：把 ARB 里的键值对原样搬进
一个 const map。加一门语言 = 多放一个 `lib/l10n/app_<code>.arb`，重跑一次这个
脚本，不必碰任何 Dart 代码。

    python tools/build_strings.py
"""

import argparse
import glob
import io
import json
import os
import re
import sys

# ARB 里带 @ 前缀的键是元信息（描述、占位符说明），和 gen-l10n 的约定一致。
# 运行时用不上，但要允许它们存在——将来真要接 Weblate，那些字段是给译者看的。
def is_metadata(key: str) -> bool:
    return key.startswith('@')


def load(path: str) -> dict[str, str]:
    with open(path, encoding='utf-8') as handle:
        data = json.load(handle)
    out: dict[str, str] = {}
    for key, value in data.items():
        if is_metadata(key):
            continue
        if not isinstance(value, str):
            raise SystemExit(f'{path}: 键 {key!r} 的值不是字符串')
        out[key] = value
    return out


def dart_string(text: str) -> str:
    """把一段文本写成 Dart 单引号字面量。

    `$` 必须转义：不转的话 Dart 会把它当插值起点，`{0}` 里的数字就会被当成变量
    名。反斜杠也要转义，否则 `\\n` 会被读成真的换行。
    """
    body = (
        text.replace('\\', '\\\\')
        .replace("'", "\\'")
        .replace('$', r'\$')
        .replace('\n', '\\n')
        .replace('\r', '\\r')
        .replace('\t', '\\t')
    )
    return f"'{body}'"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--l10n', default=os.path.join('lib', 'l10n'),
                        help='ARB 所在目录')
    parser.add_argument('--out', default=os.path.join('lib', 'strings_map.dart'),
                        help='生成的 Dart 文件')
    parser.add_argument('--check', action='store_true',
                        help='只检查生成结果是否和现有文件一致，不写盘')
    args = parser.parse_args()

    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, 'reconfigure', None)
        if reconfigure is not None:
            reconfigure(errors='replace')

    pattern = re.compile(r'^app_([A-Za-z][\w-]*)\.arb$')
    locales: list[tuple[str, str, dict[str, str]]] = []
    for path in sorted(glob.glob(os.path.join(args.l10n, 'app_*.arb'))):
        match = pattern.match(os.path.basename(path))
        if not match:
            continue
        code = match.group(1)
        locales.append((code, path, load(path)))

    if not locales:
        print(f'注意：{args.l10n} 下没有任何 app_<语言>.arb，生成空表', file=sys.stderr)

    # 源语言是中文：它的「译文」就是原文，所以不需要表——`t()` 查不到就原样
    # 返回。这里只校验一下多出来的语言有没有把话说全。
    source_keys: set[str] = set()
    for code, path, table in locales:
        if code == 'zh':
            source_keys = set(table)
    if source_keys:
        for code, path, table in locales:
            if code == 'zh':
                continue
            missing = sorted(k for k in source_keys if k not in table)
            extra = sorted(k for k in table if k not in source_keys)
            if missing:
                print(f'{path}: 缺 {len(missing)} 条译文，例如 {missing[:3]}',
                      file=sys.stderr)
            if extra:
                print(f'{path}: 有 {len(extra)} 条对不上中文原文，例如 {extra[:3]}',
                      file=sys.stderr)

    lines = [
        '// 由 tools/build_strings.py 从 lib/l10n/app_*.arb 生成，不要手改。',
        '//',
        '// 键就是中文原文（见 lib/strings.dart 里对这件事的说明）。加一门语言的',
        '// 办法是往 lib/l10n 里多放一个 app_<语言代码>.arb，然后重跑那个脚本。',
        'library;',
        '',
        '/// 语言代码 → （中文原文 → 译文）。中文不在表里：查不到就原样返回原文，',
        '/// 它就是兜底。',
        'const Map<String, Map<String, String>> kLocalizedStrings = {',
    ]
    total = 0
    for code, path, table in locales:
        if code == 'zh':
            continue
        lines.append(f"  '{code}': {{")
        for key in sorted(table):
            lines.append(f'    {dart_string(key)}: {dart_string(table[key])},')
        lines.append('  },')
        total += len(table)
        print(f'{os.path.basename(path)}: {len(table)} 条', file=sys.stderr)
    lines.append('};')
    lines.append('')
    text = '\n'.join(lines)

    if args.check:
        existing = ''
        if os.path.exists(args.out):
            with open(args.out, encoding='utf-8') as handle:
                existing = handle.read()
        if existing != text:
            print(f'{args.out} 和 ARB 不一致，需要重跑', file=sys.stderr)
            return 1
        print(f'{args.out} 已是最新', file=sys.stderr)
        return 0

    with open(args.out, 'w', encoding='utf-8', newline='\n') as handle:
        handle.write(text)
    print(f'写出 {args.out}（{total} 条译文）', file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main())
