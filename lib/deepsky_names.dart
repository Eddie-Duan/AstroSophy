/// 深空天体的常用昵称。
///
/// 「M 45」对刚入门的人是三个字符，对爱好者是「昴星团」。星表编号是查得到的
/// 凭据，昵称才是让人一眼认出「哦是这个」的东西，所以报告里两个都要给：
/// **编号在前、昵称在后**（`M 45 昴星团`）。编号在前是有意的——昵称是口口
/// 相传的叫法，各家译法有出入，编号没有，用户拿编号去核对不会错。
///
/// 收的是**非正式常用名**：蟹状星云、马头星云、东面纱星云这种大家嘴里说的
/// 名字，不是「行星状星云」那样的类型名（类型名另有 [describeDeepSkyType]）。
/// 所以同一个天体群里的不同部分各算一条：面纱星云的东西两弧是两件东西，
/// 见到哪一块就报哪一块的名字。
///
/// 这张表是**手写的**，只收最常被提到的那批目标，不是完整译名表。查不到就
/// 只显示编号，绝不按构词法硬译一个出来：一个编造的昵称比没有昵称糟糕得多，
/// 用户会拿它当事实去搜，然后什么也搜不到。
///
/// 表里的值用中文当 key 交给 [t] 查译文，所以英文界面下报的是 Horsehead
/// Nebula 这类英文惯用名。译法取各语言天文普及读物里通行的叫法，不收只在
/// 个别译本里出现过的说法。
library;

import 'strings.dart';

/// 天体编号（`M 31`、`NGC 2244`、`IC 434`…）对应的常用昵称；没有就返回 null。
///
/// **查表在返回的时候做**，不在这张表初始化的时候做：表是顶层 `const`，值只会
/// 求值一次——那样一来用户中途换语言，昵称会冻在打开应用时那门语言上。
String? nicknameOf(String designation) {
  final key = _normalise(designation);
  if (key.isEmpty) return null;
  final nickname = _nicknames[key];
  return nickname == null ? null : t(nickname);
}

/// 从「M 16」或者「M 16 鹰状星云」里取出编号那一段，再查昵称。
///
/// 必须先抽出来再查：拿整串「M 16 鹰状星云」去查表是查不到的（表里只有
/// `M16` 这个键），查不到就会以为它没有昵称，于是又拼一遍，得到
/// 「M 16 鹰状星云 · 星团与星云」这种两截名字。
String? _nicknameOfLabel(String text) {
  final trimmed = text.trim();
  final match = RegExp(r'^[A-Za-z]+\s?\d+').firstMatch(trimmed);
  return nicknameOf(match?.group(0) ?? trimmed);
}

/// 「M 31 仙女座大星系」；没有昵称时就是原来那个编号。
///
/// 编号本身已经带昵称时不再拼一遍——在线星表回来的名字有可能已经写成
/// 「M 31 仙女座大星系」这种，重复拼出来是「M 31 仙女座大星系 仙女座大星系」。
String deepSkyLabel(String designation) {
  final nickname = _nicknameOfLabel(designation);
  if (nickname == null) return designation;
  if (designation.contains(nickname)) return designation;
  return '$designation $nickname';
}

/// 深空天体在界面上怎么写：有中文常用名就用它，没有才退回「编号 · 类型」。
///
/// 这条规则只在这里定义一次，因为同一个名字会在四个地方出现：图上标注、
/// 图内亮点列表、画面中的深空天体卡、以及报告正文。四处各写一遍，迟早会有
/// 一处漏掉——而漏掉的那一处看起来就是「这个 APP 一会儿认识它一会儿不」。
/// 曾经就真的这样：报告里写着「M 16 鹰状星云」，图上的标注却是「M 16 ·
/// 星团与星云」，同一个天体两张脸。
String deepSkyCaption(String designation, String category) {
  final nickname = _nicknameOfLabel(designation);
  if (nickname != null) {
    return designation.contains(nickname)
        ? designation
        : '$designation $nickname';
  }
  return category.isEmpty ? designation : '$designation · $category';
}

/// 编号比较时把空格、大小写和连字符都抹平：目录里写 `M 31`，用户和别的
/// 星表可能写 `M31`；`NGC 2237` 和 `NGC2237` 是同一个东西。
String _normalise(String designation) =>
    designation.replaceAll(RegExp(r'[\s\-_]'), '').toUpperCase();

/// 键一律是**去掉空格并大写**的编号。
const _nicknames = <String, String>{
  // ---- Messier ----
  'M1': '蟹状星云',
  'M6': '蝴蝶星团',
  'M7': '托勒密星团',
  'M8': '礁湖星云',
  'M11': '野鸭星团',
  'M13': '武仙座大球状星团',
  'M16': '鹰状星云',
  'M17': '天鹅座欧米伽星云',
  'M20': '三叶星云',
  'M24': '人马座恒星云',
  'M27': '哑铃星云',
  'M31': '仙女座大星系',
  'M33': '三角座星系',
  'M42': '猎户座大星云',
  'M44': '蜂巢星团',
  'M45': '昴星团',
  'M51': '涡状星系',
  'M57': '环状星云',
  'M63': '向日葵星系',
  'M64': '黑眼星系',
  'M74': '幻影星系',
  'M76': '小哑铃星云',
  'M81': '波德星系',
  'M82': '雪茄星系',
  'M83': '南风车星系',
  'M87': '室女座 A 星系',
  'M97': '猫头鹰星云',
  'M101': '风车星系',
  'M104': '草帽星系',
  'M108': '冲浪板星系',

  // ---- NGC / IC ----
  // 面纱星云是超新星遗迹，东西两弧在目录里是两个编号，中文里也是两个名字，
  // 所以分开写：拍到哪一块就报哪一块。
  'NGC6960': '西面纱星云',
  'NGC6992': '东面纱星云',
  'NGC6995': '东面纱星云',
  'NGC6979': '皮克林三角',

  'NGC104': '杜鹃座 47',
  'NGC253': '银币星系',
  'NGC281': '吃豆人星云',
  'NGC869': '英仙座双星团',
  'NGC884': '英仙座双星团',
  'NGC1499': '加利福尼亚星云',
  'NGC2024': '火焰星云',
  'IC434': '马头星云',
  'NGC2070': '蜘蛛星云',
  'NGC2237': '玫瑰星云',
  'NGC2244': '玫瑰星团',
  'NGC2264': '圣诞树星团',
  'NGC2359': '雷神头盔',
  'NGC3372': '船底座星云',
  'NGC4038': '触须星系',
  'NGC4039': '触须星系',
  'NGC4565': '针状星系',
  'NGC4755': '珠宝盒星团',
  'NGC5128': '半人马座 A',
  'NGC5139': '半人马座ω星团',
  'NGC6543': '猫眼星云',
  'NGC6888': '新月星云',
  'NGC7000': '北美洲星云',
  'NGC7293': '螺旋星云',
  'NGC7635': '气泡星云',
};
