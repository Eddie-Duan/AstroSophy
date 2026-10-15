import 'dart:typed_data';

import 'package:astrosophy/crop.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as imglib;

/// 裁剪：选中的那一块，才是送去分析和上传的那一块。
///
/// 这是用户提的实际问题：Seestar 那类设备会在画面下方压一条水印和信息条，
/// 整张图送去解算会被那条水印带偏。裁剪要真的改字节，不能只是显示上画个框。
void main() {
  /// 造一张左半黑右半白的图，这样裁哪儿一眼就能从像素上看出来。
  Uint8List halfAndHalf({int width = 200, int height = 100}) {
    final image = imglib.Image(width: width, height: height);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final value = x < width ~/ 2 ? 20 : 230;
        image.setPixelRgb(x, y, value, value, value);
      }
    }
    return Uint8List.fromList(imglib.encodePng(image));
  }

  group('裁剪字节', () {
    test('裁右半：出来的图只剩亮的那半', () {
      final cropped = cropImageBytes(
        halfAndHalf(),
        const CropRect(left: 0.5, top: 0, right: 1, bottom: 1),
      )!;
      final decoded = imglib.decodePng(cropped)!;
      expect(decoded.width, 100);
      expect(decoded.height, 100);
      // 左上角现在是原来右半部分那个亮像素，不是黑底。
      expect(decoded.getPixel(0, 0).r, greaterThan(200));
    });

    test('裁下方那条水印带走：图变矮，宽度不变', () {
      // 这正是用户要修的场景。
      final cropped = cropImageBytes(
        halfAndHalf(),
        const CropRect(left: 0, top: 0, right: 1, bottom: 0.8),
      )!;
      final decoded = imglib.decodePng(cropped)!;
      expect(decoded.width, 200);
      expect(decoded.height, 80);
    });

    test('整幅的话不裁，省一次重编码', () {
      // 没动框就按原样走：重编一次 PNG 只会让图更大、还丢精度。
      expect(cropImageBytes(halfAndHalf(), CropRect.full), isNull);
    });

    test('太小的区域不裁，避免裁出一个没用的碎片', () {
      expect(
        cropImageBytes(
          halfAndHalf(),
          const CropRect(left: 0, top: 0, right: 0.01, bottom: 0.01),
        ),
        isNull,
      );
    });

    test('越界的框被夹回来，不越界读像素', () {
      final cropped = cropImageBytes(
        halfAndHalf(),
        const CropRect(left: -0.5, top: -0.5, right: 1.5, bottom: 1.5),
      );
      // 夹回来就是整幅，于是不裁。
      expect(cropped, isNull);
    });

    test('解不出图的字节返回 null，不炸', () {
      expect(
        cropImageBytes(
          Uint8List.fromList([1, 2, 3, 4]),
          const CropRect(left: 0, top: 0, right: 1, bottom: 0.5),
        ),
        isNull,
      );
    });
  });

  group('裁剪框', () {
    test('整幅的判定不受浮点误差影响', () {
      // 拖过一圈之后右边界常常是 0.99999996 这种数，按 == 判会以为不是整幅，
      // 于是白裁一次。
      expect(
        const CropRect(left: 0, top: 0, right: 0.9999999, bottom: 1).isFull,
        isTrue,
      );
      expect(
        const CropRect(left: 0, top: 0, right: 0.9, bottom: 1).isFull,
        isFalse,
      );
    });

    test('夹回 0–1 之间', () {
      final clamped = const CropRect(left: -0.2, top: 0.5, right: 1.3, bottom: 2)
          .clamp();
      expect(clamped.left, 0);
      expect(clamped.right, 1);
      expect(clamped.bottom, 1);
      expect(clamped.top, 0.5);
    });
  });
}
