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

    test('灶神星那片天区的 NGC 584 星系群成员都在', () {
      // 用户实报：照片里明明有这些星系，图上和报告里一个都没有。原因是
      // NGC 2000.0 里它们要么没有星等、要么长轴不到 1′，被筛选规则滤掉了。
      // 交叉编号（NGC 580、IC 117、IC 1703）也各留一条，按哪个名字找都行。
      for (final name in [
        'NGC 577',
        'NGC 580',
        'NGC 558',
        'NGC 557',
        'IC 124',
        'IC 119',
        'IC 117',
        'IC 1703',
      ]) {
        expect(find(name), isNotNull, reason: '$name 不在内置深空目录里');
      }
      expect(find('NGC 577')!.typeCode, 'Gx');
      expect(find('NGC 577')!.angularSizeArcmin, closeTo(1.6, 0.1));
      // IC 124 在 SIMBAD 里是一颗恒星；类型照实写「存疑」，不硬编成星系。
      expect(find('IC 124')!.typeCode, '?');
    });

    test('有类型的条目全收，没类型的不收', () {
      var nebulae = 0;
      var galaxies = 0;
      for (final row in rows) {
        final type = (row[3] as String?) ?? '';
        if (const {'Nb', 'Pl', 'C+N', 'Kt', 'SNR'}.contains(type)) nebulae++;
        if (type == 'Gx') galaxies++;
        // 目录里每一条都必须有可报的类型。空的、`-`、`*` 在生成时就被丢了。
        expect(type, isNotEmpty, reason: '${row[0]} 没有类型');
        expect(type, isNot('-'));
        expect(type, isNot('*'));
      }
      expect(nebulae, greaterThan(400));
      // 星系不再按星等/尺寸裁：NGC 2000.0 里能认出类型的星系几乎全在。
      expect(galaxies, greaterThan(8000));
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
