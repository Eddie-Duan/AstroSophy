import 'dart:io';
import 'dart:typed_data';

import 'package:astrosophy/demo.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as imglib;

/// 从仓库直接读演示图。`flutter test` 的工作目录就是包根目录。
Uint8List readAsset(String path) => File(path).readAsBytesSync();

/// Rec.709 亮度，和 analysis.dart 里口径一致。
double luminanceOf(imglib.Pixel pixel) =>
    (0.2126 * pixel.r + 0.7152 * pixel.g + 0.0722 * pixel.b) / 255.0;

void main() {
  group('演示星图', () {
    test('四张都在仓库里，且都能解码', () {
      expect(demoImages.length, 4);
      for (final image in demoImages) {
        expect(File(image.asset).existsSync(), isTrue,
            reason: '${image.asset} 不存在——pubspec.yaml 里的 assets 少登记了？');
        final decoded = imglib.decodeImage(readAsset(image.asset));
        expect(decoded, isNotNull, reason: '${image.asset} 解不出图');
        expect(decoded!.width, greaterThan(600));
      }
    });

    test('每张演示图都有给人看的标题和说明', () {
      for (final image in demoImages) {
        expect(image.title.trim(), isNotEmpty);
        expect(image.subtitle.trim(), isNotEmpty);
        // 说明要真的说明点什么。太短的副标题多半是占位符忘了改。
        expect(image.subtitle.length, greaterThan(8),
            reason: '${image.title} 的说明太短');
      }
    });

    test('底部不带相机信息条', () {
      // 原图是手机截图，底部压着一条相机信息条（设备名、拍摄时间、
      // 经纬度）。经纬度是私人信息，不该跟着 APK 发出去，所以入库前裁掉了。
      //
      // 判据：一行里出现大量亮像素就是文字。星点一行只有一两个，星系核心
      // 那种大面积亮区属于照片本身，所以只看底部这一段——信息条要是还在，
      // 那几行会有四五十个以上的亮像素。
      for (final image in demoImages) {
        final decoded = imglib.decodeImage(readAsset(image.asset))!;
        var worst = 0;
        var worstRow = 0;
        for (var y = decoded.height - 60; y < decoded.height; y++) {
          var bright = 0;
          for (var x = 0; x < decoded.width; x += 2) {
            if (luminanceOf(decoded.getPixel(x, y)) > 150 / 255) bright++;
          }
          if (bright > worst) {
            worst = bright;
            worstRow = y;
          }
        }
        // 实测四张分别是 3 / 1 / 1 / 3 个亮像素，这里留了四倍余量。
        expect(worst, lessThan(12),
            reason: '${image.asset} 第 $worstRow 行有 $worst 个亮像素，'
                '底部的信息条可能没裁干净');
      }
    });

    test('四张演示图覆盖了不同的难度', () {
      // 四种目标性质不同：星系、疏散星团、稀疏星场、一颗亮行星。星点密度差
      // 一个量级，本机解算在这几种情况下的表现很不一样——演示图要是全挑星点
      // 密集的，用户第一次试就会觉得「本机解算总是成功」，真拍起来才发现不是。
      // 最后那张还多带一样东西：拍摄时刻，行星那一节才有判据。
      final densities = <String, double>{};
      for (final image in demoImages) {
        final decoded = imglib.decodeImage(readAsset(image.asset))!;
        var bright = 0;
        for (var y = 0; y < decoded.height; y += 2) {
          for (var x = 0; x < decoded.width; x += 2) {
            if (luminanceOf(decoded.getPixel(x, y)) > 140 / 255) bright++;
          }
        }
        densities[image.asset] = bright / (decoded.width * decoded.height / 4);
      }
      final values = densities.values.toList()..sort();
      expect(values.first, lessThan(values.last / 2),
          reason: '三张演示图的星点密度太接近（$densities），'
              '这样演示不出本机解算在不同星场下的差别');
    });
  });
}
