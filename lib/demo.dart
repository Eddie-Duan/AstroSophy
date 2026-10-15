import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

import 'exif.dart';

/// APP 自带的四张演示星图。
///
/// 第一次打开的人手里不一定正好有星空照片，而没有照片就看不到这个 APP
/// 能做什么——只能对着一张空白页猜。四张演示图覆盖了四种典型情况：一个
/// 大面积延展的星系、一个亮星密集的疏散星团、一片星点稀疏的天区，以及一张
/// 以行星为主角的照片。第三张尤其有用，它能让人直观看到本机解算在星少时
/// 是怎么退回在线解算的；第四张带上了拍摄时刻，行星那一节才有判据可用。
///
/// 原图是拍摄者在手机上的截图，底部带着相机的信息条（设备、时间、地点）。
/// 那些内容在入库前已经裁掉：设备信息对使用这个 APP 没有帮助，而坐标是
/// 私人信息，不该跟着 APK 一起发出去。裁掉的同时也把 EXIF 一起丢了，所以
/// 拍摄时刻只能跟着条目写下来（见 [DemoImage.moment]）。
class DemoImage {
  const DemoImage({
    required this.asset,
    required this.title,
    required this.subtitle,
    this.moment,
  });

  final String asset;
  final String title;
  final String subtitle;

  /// 拍摄时刻；文件里读不到（EXIF 已在裁图时丢失）时由这里给出。
  ///
  /// 没有它，行星那一节无从判断——行星的位置随日期变，缺了时刻就只能不
  /// 出结论。其余各步不受影响。
  final CaptureMoment? moment;
}

/// 演示图列表。
///
/// 用 `final` 而不是 `const`：土星那条要带 `DateTime`，而它没有 const 构造。
final demoImages = <DemoImage>[
  const DemoImage(
    asset: 'assets/demo/demo_m31.jpg',
    title: '仙女座大星系 M31',
    subtitle: '旋涡星系，画面左下同时能看到它的伴星系 M110',
  ),
  const DemoImage(
    asset: 'assets/demo/demo_m45.jpg',
    title: '昴星团 M45',
    subtitle: '疏散星团，亮星周围蓝色的雾状是反射星云',
  ),
  const DemoImage(
    asset: 'assets/demo/demo_vesta.jpg',
    title: '灶神星所在的天区',
    subtitle: '主带小行星，星点稀疏——适合看本机解算星少时怎么退回在线',
  ),
  DemoImage(
    asset: 'assets/demo/demo_saturn.jpg',
    title: '土星所在的天区',
    subtitle: '画面正中最亮的那一点就是土星，它周围的点全是恒星',
    moment: CaptureMoment(
      // 拍摄者给的当地时间：2026-09-01 22:38，东八区。
      local: DateTime(2026, 9, 1, 22, 38),
      offset: const Duration(hours: 8),
      source: CaptureTimeSource.demo,
    ),
  ),
  DemoImage(
    asset: 'assets/demo/demo_moon.jpg',
    title: '月亮',
    subtitle: '一张月球照：画面上除了它几乎什么都没有，走的是月面那条链路',
    moment: CaptureMoment(
      // 拍摄者给的当地时间：2026-06-25 19:38，东八区。这张图的 EXIF 也在
      // 入库时丢了，但时刻对月面分析是必需的——盈亏只能由它决定，而且它是
      // 图上量出来的那个亮面占比的唯一独立校验。
      local: DateTime(2026, 6, 25, 19, 38),
      offset: const Duration(hours: 8),
      source: CaptureTimeSource.demo,
    ),
  ),
];

/// 读出演示图的字节。
Future<Uint8List> loadDemoImage(DemoImage image) async {
  final data = await rootBundle.load(image.asset);
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}
