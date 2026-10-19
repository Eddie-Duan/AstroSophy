import 'dart:io';

import 'package:astrosophy/analysis.dart';
import 'package:flutter_test/flutter_test.dart';

/// 用户提供的 12 张实拍样片（01–12，按加入顺序编号）。它们覆盖了几种真实会遇到的画面：
///
/// * 望远镜/三脚架 + 地景；
/// * 屋脊、栏杆、城市灯光占掉大半画面；
/// * 星野 + 云/树；
/// * 稀疏星场 + 明显拖线；
/// * 银河 + 流星/卫星轨迹。
///
/// 这些图不一定都能本机解出（有些是 GOTO App 的截图，投影和尺度未知），
/// 所以这里只钉住**图片处理**该有的行为：别把地景/文字当星，别把有星的
/// 画面判成没星。
void main() {
  final files = Directory('assets/testbench')
      .listSync()
      .whereType<File>()
      .where((file) => file.path.toLowerCase().endsWith('.jpg'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  test('testbench 样片都在仓库里', () {
    expect(files, hasLength(12));
  });

  test('地景/建筑占满的画面不会被当成星场', () {
    final roof = files.firstWhere((file) => file.path.contains('05.jpg'));
    final analysis = SkyAnalysis.analyze(roof.readAsBytesSync());
    expect(analysis.isLikelyStarfield, isFalse);
    expect(analysis.stars.length, lessThan(20));
  });

  test('城市灯光/栏杆占大半画面时，掩膜比例会明显升高', () {
    for (final name in ['02.jpg', '04.jpg']) {
      final file = files.firstWhere((item) => item.path.contains(name));
      final analysis = SkyAnalysis.analyze(file.readAsBytesSync());
      expect(
        analysis.nonStarFraction,
        greaterThan(0.8),
        reason: '$name 的大部分画面是地景/灯光',
      );
    }
  });

  test('有星的星野不会被地景掩膜误杀', () {
    for (final name in ['03.jpg', '06.jpg', '07.jpg']) {
      final file = files.firstWhere((item) => item.path.contains(name));
      final analysis = SkyAnalysis.analyze(file.readAsBytesSync());
      expect(analysis.isLikelyStarfield, isTrue, reason: name);
      expect(analysis.solveCandidates.length, greaterThan(100), reason: name);
    }
  });

  test('城市天际线、云和屋顶仍按高掩膜处理', () {
    for (final name in ['09.jpg', '10.jpg', '11.jpg']) {
      final file = files.firstWhere((item) => item.path.contains(name));
      final analysis = SkyAnalysis.analyze(file.readAsBytesSync());
      expect(
        analysis.nonStarFraction,
        greaterThan(0.7),
        reason: '$name 的大部分是建筑/云/地景',
      );
    }
  });

  test('空白/云天空不会被当成密集星场', () {
    final file = files.firstWhere((item) => item.path.contains('12.jpg'));
    final analysis = SkyAnalysis.analyze(file.readAsBytesSync());
    expect(analysis.solveCandidates.length, lessThan(200));
    expect(analysis.nonStarFraction, lessThan(0.2));
  });
}
