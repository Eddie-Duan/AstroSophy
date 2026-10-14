import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

/// APP 自带的三张演示星图。
///
/// 第一次打开的人手里不一定正好有星空照片，而没有照片就看不到这个 APP
/// 能做什么——只能对着一张空白页猜。三张演示图覆盖了三种典型情况：一个
/// 大面积延展的星系、一个亮星密集的疏散星团、一片星点稀疏的天区。最后
/// 那张尤其有用，它能让人直观看到本机解算在星少时是怎么退回在线解算的。
///
/// 原图是拍摄者在手机上的截图，底部带着相机的信息条（设备、时间、地点）。
/// 那些内容在入库前已经裁掉：设备信息对使用这个 APP 没有帮助，而坐标是
/// 私人信息，不该跟着 APK 一起发出去。
class DemoImage {
  const DemoImage({
    required this.asset,
    required this.title,
    required this.subtitle,
  });

  final String asset;
  final String title;
  final String subtitle;
}

const demoImages = <DemoImage>[
  DemoImage(
    asset: 'assets/demo/demo_m31.jpg',
    title: '仙女座大星系 M31',
    subtitle: '旋涡星系，画面左下同时能看到它的伴星系 M110',
  ),
  DemoImage(
    asset: 'assets/demo/demo_m45.jpg',
    title: '昴星团 M45',
    subtitle: '疏散星团，亮星周围蓝色的雾状是反射星云',
  ),
  DemoImage(
    asset: 'assets/demo/demo_vesta.jpg',
    title: '灶神星所在的天区',
    subtitle: '主带小行星，星点稀疏——适合看本机解算星少时怎么退回在线',
  ),
];

/// 读出演示图的字节。
Future<Uint8List> loadDemoImage(DemoImage image) async {
  final data = await rootBundle.load(image.asset);
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}
