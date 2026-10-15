import 'dart:io';
import 'dart:typed_data';

import 'package:astrosophy/analysis.dart';
import 'package:astrosophy/demo.dart';
import 'package:astrosophy/moon.dart';
import 'package:astrosophy/moon_disc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as imglib;

/// 从仓库直接读演示图。`flutter test` 的工作目录就是包根目录。
Uint8List readAsset(String path) => File(path).readAsBytesSync();

/// Rec.709 亮度，和 analysis.dart 里口径一致。
double luminanceOf(imglib.Pixel pixel) =>
    (0.2126 * pixel.r + 0.7152 * pixel.g + 0.0722 * pixel.b) / 255.0;

/// 整帧的 0–255 灰度，月面测量吃的是这个。
Uint8List grayscaleOf(imglib.Image image) {
  final gray = Uint8List(image.width * image.height);
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      gray[y * image.width + x] = (luminanceOf(image.getPixel(x, y)) * 255)
          .round()
          .clamp(0, 255);
    }
  }
  return gray;
}

void main() {
  group('演示星图', () {
    test('五张都在仓库里，且都能解码', () {
      expect(demoImages.length, 5);
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

    test('五张演示图覆盖了不同的难度', () {
      // 五种目标性质不同：星系、疏散星团、稀疏星场、一颗亮行星、一张月亮。
      // 星点密度差一个量级，本机解算在这几种情况下的表现很不一样——演示图
      // 要是全挑星点密集的，用户第一次试就会觉得「本机解算总是成功」，真拍起来
      // 才发现不是。土星那张还多带一样东西：拍摄时刻，行星那一节才有判据。
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
          reason: '五张演示图的星点密度太接近（$densities），'
              '这样演示不出本机解算在不同星场下的差别');
    });

    test('只有月球那张量得出月面，其余四张都量不出', () {
      // 这是「这是不是一张月球照」那条判据在**真图**上的正反对照。合成图能
      // 证明算式对，证明不了真实照片里的噪声、暗角和渐变不会把它骗过去——
      // 而这条判据一旦误报，用户的一张星野照会被当成月亮走另一条链路。
      for (final image in demoImages) {
        final decoded = imglib.decodeImage(readAsset(image.asset))!;
        final disc = measureMoonDisc(
          gray: grayscaleOf(decoded),
          width: decoded.width,
          height: decoded.height,
        );
        if (image.asset.endsWith('demo_moon.jpg')) {
          expect(disc, isNotNull, reason: '月球那张该量得出来');
          // 86.1% 是这张图上量出来的数（盈凸月）。容差给得松一点：换一台机器、
          // 换一次解码，边缘那几个像素的归属会动。
          expect(disc!.illuminatedFraction, closeTo(0.861, 0.03));
          expect(disc.radiusPixels, closeTo(45.3, 1.5));
        } else {
          expect(disc, isNull, reason: '${image.asset} 不是月面');
        }
      }
    });

    test('月亮那张：图上量出的亮面占比和星历算出来的对得上', () {
      // 两条路径完全独立——一边是数像素，一边是算天体力学。它们能对得上，才
      // 说明两边都没错。这条断言还真的抓过一个错：阈值原来取「背景与峰值的
      // 中点」，量出 60.8%，和星历差了 22 个百分点。查下去发现是那个阈值把
      // 明暗界线那条本来就暗的过渡带整个判成了暗面——错在图上，不在星历。
      // 改成「天空均值 + 2σ」之后差距收到 3.5 个百分点（见 moon_disc.dart）。
      //
      // 剩下这 3.5 个百分点不再往下追：星历那头是 Meeus 48.4 的简化式（省掉
      // 长周期项，自身精度约 0.005），图上那头受阈值、暗角、大气抖动影响。
      // 而且拍摄时刻是手写的，近满月时 k 每天变几个百分点——差一天就够解释
      // 这点零头。所以容差给 4 个百分点：够收住这个真实的差，又足以在真正
      // 量错时报警（原来的 22 个百分点差得远远的）。
      final moon = demoImages.firstWhere(
        (image) => image.asset.endsWith('demo_moon.jpg'),
      );
      final moment = moon.moment;
      expect(moment, isNotNull, reason: '月球这张必须带拍摄时刻');
      final utc = moment!.utc;
      expect(utc, isNotNull, reason: '要有时区才谈得上和星历比');

      final phase = moonPhaseAt(utc!);
      final decoded = imglib.decodeImage(readAsset(moon.asset))!;
      final disc = measureMoonDisc(
        gray: grayscaleOf(decoded),
        width: decoded.width,
        height: decoded.height,
      )!;

      expect(disc.illuminatedFraction,
          closeTo(phase.illuminatedFraction, 0.04),
          reason: '图上量 ${disc.illuminatedFraction}，星历算 '
              '${phase.illuminatedFraction}');

      // 顺带钉住方向：这个时刻是盈的。单张图看盈亏有镜像歧义，只有靠时刻
      // 才定得下来——这正是月球照必须带拍摄时刻的原因。
      expect(phase.waxing, isTrue);
      // 两边的名字也得是一样的，否则界面会一边写「盈凸」一边写别的。
      expect(phase.name, '盈凸月');
    });
  });

  group('分析入口的定性分流', () {
    test('月球那张走月面分支，星点流程完全没跑', () {
      final analysis =
          SkyAnalysis.analyze(readAsset('assets/demo/demo_moon.jpg'));
      expect(analysis.isMoonShot, isTrue);
      expect(analysis.moonDisc, isNotNull);
      // 分流要是没做，这张图会被当成正常星场、在月面上「检出」13 颗星，
      // 报告里的星等和噪声就全成了编的。所以这里必须一个点源都没有。
      expect(analysis.stars, isEmpty);
      expect(analysis.solverExtras, isEmpty);
      expect(analysis.isLikelyStarfield, isFalse);
      expect(analysis.maskRegions, isEmpty);
      // 缩放后的图上量出来还是那一个月亮。
      expect(analysis.moonDisc!.illuminatedFraction, closeTo(0.861, 0.05));
      // 说明文字要讲到「盈亏单张图看不出来」这件事，否则用户会以为
      // 亮面占比就是月相。
      expect(
        analysis.diagnostics.any((item) => item.contains('在盈还是在亏')),
        isTrue,
      );
    });

    test('另外四张演示图不会被月面判据抢走', () {
      // 误报的代价比漏报大：一张星野照被当成月亮，就走不进解算了。
      for (final image in demoImages) {
        if (image.asset.endsWith('demo_moon.jpg')) continue;
        final analysis = SkyAnalysis.analyze(readAsset(image.asset));
        expect(analysis.isMoonShot, isFalse,
            reason: '${image.asset} 被当成月面了');
      }
    });

    test('月面字段能存进历史再读回来', () {
      final analysis =
          SkyAnalysis.analyze(readAsset('assets/demo/demo_moon.jpg'));
      final restored = SkyAnalysis.fromJson(
        analysis.toJson(),
        preview: analysis.preview,
        processedPreview: analysis.processedPreview,
      );
      expect(restored.isMoonShot, isTrue);
      expect(restored.moonDisc!.illuminatedFraction,
          closeTo(analysis.moonDisc!.illuminatedFraction, 1e-9));
      expect(restored.moonDisc!.centerX, closeTo(analysis.moonDisc!.centerX, 1e-9));
    });
  });
}
