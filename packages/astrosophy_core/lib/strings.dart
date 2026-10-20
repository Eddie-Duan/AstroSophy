/// 无 Flutter 依赖的文案层。CLI/bot 只跑中文；参数占位符仍按 `{0}` 替换。
String t(String template, [List<Object?> args = const []]) {
  if (args.isEmpty) return _unescapeBraces(template);
  final filled = template.replaceAllMapped(
    RegExp(r'\{(\d+)\}'),
    (match) {
      final index = int.parse(match[1]!);
      return index < args.length ? '${args[index]}' : match[0]!;
    },
  );
  return _unescapeBraces(filled);
}

String tn(String template, int count, [List<Object?> args = const []]) =>
    t(template, args);

String _unescapeBraces(String text) {
  if (!text.contains('{{') && !text.contains('}}')) return text;
  return text.replaceAllMapped(
    RegExp(r'\{\{|\}\}'),
    (match) => match[0]!.substring(0, 1),
  );
}
