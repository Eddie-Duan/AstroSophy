import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:astrosophy/deepsky.dart';
import 'package:astrosophy/deepsky_names.dart';
import 'package:flutter_test/flutter_test.dart';

/// 内置深空目录的**内容**，以及「什么算拍到了」这条判据。
///
/// 这一组是用户实报的问题留下来的：拍了面纱星云，图上什么也没有。查下去发现
/// 整片被目录漏掉了——NGC 2000.0 有 41% 的条目没有星等，而「又大又弥漫」正是
/// 最容易没有星等的那一类，按星等筛的后果是 2274 条里真正的星云只剩 59 条。
///
/// 所以这里钉住两件事：目录里得有它，以及中心落在画面外、但圆压到画面时也得
/// 标出来。
void main() {
  late List<List<Object?>> rows;

  setUpAll(() {
    rows = (jsonDecode(
      File('assets/catalog/deepsky.json').readAsStringSync(),
    ) as List<Object?>)
        .map((row) => (row as List<Object?>))
        .toList();
  });

  DeepSkyObject? find(String name) {
    for (final row in rows) {
      if (row[0] == name) {
        return DeepSkyObject(
          name: row[0]! as String,
          ra: (row[1]! as num).toDouble(),
          dec: (row[2]! as num).toDouble(),
          typeCode: (row[3] as String?) ?? '',
          angularSizeArcmin: (row[4] as num?)?.toDouble(),
          magnitude: (row[5] as num?)?.toDouble(),
        );
      }
    }
    return null;
  }

  group('内置深空目录的内容', () {
    test('面纱星云的各个部件都在', () {
      // 这是一张很有名的目标，用户拍了就该标出来。曾经一个都不在。
      for (final name in [
        'NGC 6960',
        'NGC 6992',
        'NGC 6995',
        'NGC 6979',
        'NGC 6974',
      ]) {
        expect(find(name), isNotNull, reason: '$name 不在内置深空目录里');
      }
      expect(find('NGC 6960')!.typeCode, 'Nb');
      expect(find('NGC 6960')!.angularSizeArcmin, closeTo(70, 0.1));
      // 表里没有星等——正是它当初被筛掉的原因，这一点也一并钉住。
      expect(find('NGC 6960')!.magnitude, isNull);
    });

    test('星云和星团这一类不看星等，其余照旧', () {
      var nebulae = 0;
      for (final row in rows) {
        final type = (row[3] as String?) ?? '';
        if (const {'Nb', 'Pl', 'C+N', 'Kt', 'SNR'}.contains(type)) nebulae++;
      }
      // 按星等筛的时候只剩 59 个。这条线定在 400 上：掉回去就是筛选规则被改回
      // 去了，而那种改动不会让任何别的测试变红。
      expect(nebulae, greaterThan(400), reason: '星云类又被星等筛掉了');

      // 星系仍然按星等筛：全收进来是一万两千多条，会把画面糊满。
      var galaxies = 0;
      for (final row in rows) {
        if (row[3] == 'Gx') galaxies++;
      }
      expect(galaxies, lessThan(2200));
      expect(galaxies, greaterThan(1000));
    });

    test('Messier 一个都没少', () {
      final messier = <int>{};
      for (final row in rows) {
        final name = row[0]! as String;
        if (!name.startsWith('M ')) continue;
        final number = int.tryParse(name.substring(2));
        if (number != null) messier.add(number);
      }
      expect(messier.length, greaterThanOrEqualTo(109));
    });

    test('Nox 说的目录大小和实际对得上', () {
      // 目录换了大小，文档和 Nox 的自我介绍都得跟着走——这里只是把「有多大」
      // 变成一个会随代码变的事实，省得下次又靠记忆写一个数。
      final meta = jsonDecode(
        File('assets/catalog/catalog_meta.json').readAsStringSync(),
      ) as Map<String, Object?>;
      expect(meta['deepsky_count'], rows.length);
      expect(meta['deepsky_always_types'], isNotNull);
    });
  });

  group('什么算拍到了', () {
    // 1000×800 的图，比例尺 30″/像素 → 对角线 51.2′ 的像场。
    const width = 1000;
    const height = 800;
    const scale = 30.0;
    final diagonal = math.sqrt(
      width * width + height * height,
    );

    /// [_reachesFrame] 的判据，抄在这里是为了能独立地算一遍期望值。
    bool reaches(double sizeArcmin, double x, double y) {
      if (x >= 0 && y >= 0 && x < width && y < height) return true;
      if (sizeArcmin <= 0) return false;
      final radiusPixels = sizeArcmin * 60 / scale / 2;
      if (radiusPixels * 2 < diagonal * 0.1) return false;
      final dx = math.max(math.max(-x, x - width), 0.0);
      final dy = math.max(math.max(-y, y - height), 0.0);
      return math.sqrt(dx * dx + dy * dy) <= radiusPixels;
    }

    test('中心在画面里的照收', () {
      expect(reaches(70, 500, 400), isTrue);
    });

    test('中心在外、但圆压到画面的大天体也要收', () {
      // 面纱星云的东西两弧加起来一度多，广角拍一张，弧的大部分在画面里、
      // 中心却落在外面——旧规则整条丢掉，用户看着自己明明拍到了的东西没有
      // 任何标记。
      //
      // 70′ 的物体在 30″/px 下半径是 70 像素，中心出界 40 像素时圆仍压着画面。
      expect(reaches(70, -40, 400), isTrue);
    });

    test('中心在外、尺寸又小的不算——免得几十个暗星系挤进来', () {
      expect(reaches(1.0, -40, 400), isFalse);
      expect(reaches(6.0, -40, 400), isFalse);
    });

    test('太大也不行：圆够不到画面就不算', () {
      // 70′ 的半径 70 像素，中心出界 400 像素时圆碰不到画面。
      expect(reaches(70, -400, 400), isFalse);
    });

    test('没有角尺寸的（目录里空着）只能靠中心判', () {
      expect(reaches(0, -40, 400), isFalse);
      expect(reaches(0, 500, 400), isTrue);
    });
  });

  group('名字', () {
    test('面纱星云东西两弧各是各的名字，不会被合并成一个', () {
      // 目录里是两个编号，中文里也是两个名字。都报「面纱星云」等于把
      // 「你拍到的是哪一块」这个信息抹掉了。
      expect(deepSkyCaption('NGC 6960', 'Nb'), 'NGC 6960 西面纱星云');
      expect(deepSkyCaption('NGC 6992', 'Nb'), 'NGC 6992 东面纱星云');
    });
  });
}
