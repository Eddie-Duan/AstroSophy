import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'strings.dart';
import 'analysis.dart';
import 'models.dart';
import 'widgets.dart';

/// 导出带标注的 PNG。
///
/// ## 为什么不是截屏
///
/// 直觉的做法是把看图那块 `RepaintBoundary` 截下来，但那样得到的是**屏幕**
/// 上那一小块的像素：分辨率跟着手机走（通常比原图小一个档次），而且用户放大
/// 到 4 倍时只截得到放大后的一个角，圆圈和名字的比例也全变了。
///
/// 这里改成照原始图像尺寸**重画一遍**：圈、编号、名字全部用同一个
/// [DetectedStarsPainter] 在 1:1 的画布上画一次。导出的是「这张照片的分析
/// 结果图」，和屏幕上放多大、滚到哪里都没有关系。
///
/// 画的是**当前勾选**的那一套：用户把某一组圆圈隐去了，导出的图里就没有那
/// 一组；深空天体、运动天体的标注同理。他看到的和拿到的是同一张图。
/// 导出图的长边目标像素数。
///
/// 以前导出的是分析尺寸（最长边 1200）那张图，文字按 10–11 逻辑像素画，落到
/// 文件里就是 10–11 个像素。用户把图存进相册、发给别人之后，字只占图宽的
/// 不到 1%，看上去又小又糊——而在 APP 里看图时，同样一行字占了屏幕宽度的
/// 约 2.5%，所以「APP 里好好的，保存出来就不行」。
///
/// 现在按长边 2400 渲染：字号同时按 [referenceDisplayWidth] 放大，保存出来
/// 的字与 APP 里看到的大小一致，像素也够多，放大看仍然清楚。
const _exportLongSide = 2400.0;

/// APP 里看图那块的大致逻辑宽度。
///
/// 标注的字号（10–11）是按这个宽度设计的。用图宽除以它，就能把「屏幕上
/// 的字」换算成「图里的字」——两者在最终画面上的相对大小因此保持一致。
const _referenceDisplayWidth = 390.0;

Future<Uint8List> renderAnnotatedPng({
  required SkyAnalysis analysis,
  required Uint8List baseImage,
  required List<SkyObject> namedStars,
  required List<SkyObject> objects,
  List<ConstellationFigure> figures = const [],
  List<MovingBodySuspicion> bodies = const [],
  Set<int> hidden = const {},
  Wcs? wcs,
  double arcsecPerPixel = 0,
  bool numbers = true,
}) async {
  final codec = await ui.instantiateImageCodec(baseImage);
  final frame = await codec.getNextFrame();
  final image = frame.image;

  // 画布按分析结果的尺寸给，不按解码出来的图像尺寸：分析时那张图被缩到
  // 最长边 1200 像素，所有坐标都在那个尺寸下算出来的。两者一般相等，但
  // 相等不该是**假设**——万一对不上，标注会整体错位。
  final size = Size(analysis.width.toDouble(), analysis.height.toDouble());

  // 像素倍率：让长边到 2400 左右；原本就很小的图最多放 3 倍，避免把
  // 像素直接拉成色块。
  final longSide = math.max(size.width, size.height);
  final pixelRatio = (_exportLongSide / longSide).clamp(1.0, 3.0);
  // 标注倍率：让字号回到「APP 里那块 390 逻辑像素宽的图」上的相对大小。
  final uiScale = (size.width / _referenceDisplayWidth).clamp(1.0, 6.0);

  final outputWidth = (size.width * pixelRatio).round();
  final outputHeight = (size.height * pixelRatio).round();

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  // 先按逻辑尺寸画，再整体放大到输出像素。字号、线宽都随 [uiScale] 一起
  // 变大，所以放大只增加清晰度，不改变构图和相对大小。
  canvas.scale(pixelRatio);
  canvas.drawImageRect(
    image,
    Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    Offset.zero & size,
    Paint(),
  );

  DetectedStarsPainter(
    analysis: analysis,
    namedStars: namedStars,
    objects: objects,
    figures: figures,
    bodies: bodies,
    wcs: wcs,
    hidden: hidden,
    arcsecPerPixel: arcsecPerPixel,
    numbers: numbers,
    uiScale: uiScale,
    // 不在导出图里画选中环：那是界面上的临时状态（「我正看着这一颗」），
    // 不是分析结论。导出的是最终成图。
    selected: null,
    selectedObjectName: null,
  ).paint(canvas, size);

  final picture = recorder.endRecording();
  final rendered = await picture.toImage(outputWidth, outputHeight);
  final data = await rendered.toByteData(format: ui.ImageByteFormat.png);

  image.dispose();
  rendered.dispose();
  picture.dispose();

  if (data == null) {
    throw StateError(t('导出失败：渲染出的图拿不到像素数据。'));
  }
  return data.buffer.asUint8List();
}

/// 把导出的 PNG 落到磁盘，返回文件。
///
/// 落在应用自己的文档目录里而不是临时目录：临时目录会被系统随时清掉，而
/// 用户可能先关掉分享面板、过一会儿再想找这张图。
Future<File> saveAnnotatedPng(Uint8List png, {required String fileName}) async {
  final documents = await getApplicationDocumentsDirectory();
  final directory = Directory('${documents.path}/exports');
  if (!directory.existsSync()) {
    await directory.create(recursive: true);
  }
  final file = File('${directory.path}/$fileName');
  await file.writeAsBytes(png, flush: true);
  return file;
}

/// 把导出的图交给系统分享面板。
///
/// 用户自己选「存到相册」「存到文件」还是直接发出去。不自己往某个目录里写
/// 然后显示一行路径——那个路径在手机的文件管理器里要点好几层才找得到，
/// 等于没下载。
Future<void> shareExportedFile(
  File file, {
  String? text,
  Rect? origin,
}) async {
  await Share.shareXFiles(
    [XFile(file.path, mimeType: 'image/png')],
    text: text,
    sharePositionOrigin: origin,
  );
}
