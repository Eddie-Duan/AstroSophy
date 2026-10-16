import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:astrosophy/catalog.dart';
import 'package:astrosophy/models.dart';
import 'package:astrosophy/solver.dart';
import 'package:flutter_test/flutter_test.dart';

import 'catalog_fixture.dart';

/// 狮子座里一片很空的天区。全天星最少的方向之一，专挑它来看「补充层到底
/// 补上了什么」：半径 2.5° 内主星表只有一两颗星，补上 Gaia 层之后有三十来颗。
const _emptyRa = 150.0;
const _emptyDec = 2.0;
const _orionRa = 83.8;
const _orionDec = -1.5;

void main() {
  group('Gaia 补充层资产', () {
    test('定长记录解出来的星都在天上，而且都打了补充层的记号', () {
      final bytes = File('assets/catalog/gaia.bin').readAsBytesSync();
      expect(bytes.length % gaiaRecordBytes, 0, reason: '文件长度不是记录的整数倍');

      final stars = decodeGaiaLayer(bytes);
      expect(stars.length, greaterThan(100000));
      for (final star in stars) {
        expect(star.isGaia, isTrue);
        // 负号是「没有 HIP 号」的记号，不能和真编号撞上。
        expect(star.hip, lessThan(0));
        expect(star.ra, inInclusiveRange(0, 360));
        expect(star.dec, inInclusiveRange(-90, 90));
        // 打包时按 G < 11.0 截取，0.05 等一格会取到 11.0 这个端点。
        expect(star.vMagnitude, greaterThan(0));
        expect(star.vMagnitude, lessThanOrEqualTo(11.0));
      }
    });

    test('记录格式和打包脚本对得上', () {
      // 赤经 3 字节、赤纬 3 字节、星等 1 字节，全大端；这是
      // `tools/build_catalog.py` 的 `pack_gaia_star` 的另一半，改一边必须
      // 改另一边，所以这里照着公式造一条再解回来。
      const ra = 193.50817846782;
      const dec = 55.95978477892;
      const magnitude = 1.75;
      final raUnits = ((ra % 360.0) / 360.0 * (1 << 24)).round();
      final decUnits = ((dec + 90.0) / 180.0 * (1 << 24)).round();
      final bytes = Uint8List.fromList([
        (raUnits >> 16) & 0xFF,
        (raUnits >> 8) & 0xFF,
        raUnits & 0xFF,
        (decUnits >> 16) & 0xFF,
        (decUnits >> 8) & 0xFF,
        decUnits & 0xFF,
        (magnitude * 20).round(),
      ]);

      final star = decodeGaiaLayer(bytes).single;
      // 0.077″ 的格子，还原精度远好于任何一张手机照片能分辨的角距。
      expect(star.ra, closeTo(ra, 1e-4));
      expect(star.dec, closeTo(dec, 1e-4));
      expect(star.vMagnitude, closeTo(magnitude, 0.03));
    });

    test('和 catalog_meta.json 记的数量一致', () {
      final meta = jsonDecode(
        File('assets/catalog/catalog_meta.json').readAsStringSync(),
      ) as Map<String, Object?>;
      final catalog = loadTestCatalog();
      final gaia = catalog.stars.where((star) => star.isGaia).length;
      expect(gaia, meta['gaia_count']);
      expect(
        catalog.stars.length,
        (meta['star_count']! as num).toInt() + gaia,
        reason: '星表 = 主星表 + 补充层，两个数都要和 meta 对得上',
      );
      expect(catalog.magnitudeLimit, closeTo(8.0, 0.1));
    });

    test('分层界线写在资产里，和代码里那份默认值对得上', () {
      final meta = jsonDecode(
        File('assets/catalog/catalog_meta.json').readAsStringSync(),
      ) as Map<String, Object?>;
      final mid = (meta['gaia_mid_mag_limit']! as num).toDouble();
      final deep = (meta['gaia_mag_limit']! as num).toDouble();
      // 中间层必须比整层浅，否则第三层就是白建的——它唯一的存在理由就是
      // 「中间层解不出来的才轮到它」。
      expect(mid, lessThan(deep));
      final catalog = loadTestCatalog();
      expect(catalog.gaiaMidMagLimit, mid);
      expect(
        catalog.stars.where((star) => star.isGaia).length,
        greaterThan(catalog.stars.where((star) => star.isGaia && star.vMagnitude <= mid).length),
        reason: '补充层里得有比界线更暗的星，否则第三层没有任何新东西',
      );
    });

    test('补充层的星没有名字，也不计入星座归属', () {
      final catalog = loadTestCatalog();
      for (final star in catalog.stars.where((star) => star.isGaia).take(200)) {
        expect(catalog.nameOf(star), isNull);
        expect(star.constellationIndex, 0);
      }
    });
  });

  group('两层星表解算', () {
    late StarCatalog full;
    late StarCatalog shallow;

    setUpAll(() {
      full = loadTestCatalog();
      shallow = loadTestCatalog(withGaia: false);
    });

    test('并入补充层之后，浅层本来解得出的天区照解不误', () {
      // 这个用例守的是一个实测过的坑：把 Gaia 并进唯一那张星表，星多天区
      // 会从「解得出」变成「解不出」——图内端只用最亮的 120 颗检出组三角
      // 形，目录端却因为多了大量暗星而换了近邻关系，两侧枚举出来的不是同
      // 一批三角形。星图由主星表造，所以图内端看到的都是亮星。
      final analysis = synthesiseField(
        catalog: shallow,
        centerRa: _orionRa,
        centerDec: _orionDec,
        degreesPerPixel: 0.02,
      );

      final before = PlateSolver(shallow).solve(analysis);
      final after = PlateSolver(full).solve(analysis);
      expect(before, isNotNull, reason: '主星表自己必须解得出来');
      expect(after, isNotNull, reason: '加了补充层之后也必须解得出来');
      expect(
        angularSeparationDegrees(
          after!.centerRa,
          after.centerDec,
          before!.centerRa,
          before.centerDec,
        ),
        lessThan(0.02),
        reason: '两边解出来的应当是同一天区',
      );
    });

    test('星点稀到主星表凑不出三角形的天区，靠补充层解得出来', () {
      // 星图按整张星表造：画面里的星点多数比 V=8 还暗，主星表里根本没有
      // 对应的星，自然解不出来——这正是补这层星的意义。
      // 这片 5° 视场里主星表只有一两颗星，连三角形都组不出来；补上 Gaia
      // 层之后有三十来颗，解算匹配到 31 颗。
      expect(
        shallow.starsNear(_emptyRa, _emptyDec, 2.5).length,
        lessThan(full.starsNear(_emptyRa, _emptyDec, 2.5).length),
      );
      final analysis = synthesiseField(
        catalog: full,
        centerRa: _emptyRa,
        centerDec: _emptyDec,
        degreesPerPixel: 0.004,
      );

      expect(
        PlateSolver(shallow).solve(analysis),
        isNull,
        reason: '主星表在这片天区里星太少，硬解只会给出错坐标',
      );
      final solved = PlateSolver(full).solve(analysis);
      expect(solved, isNotNull, reason: '补了 Gaia 层就该解得出来');
      expect(
        angularSeparationDegrees(
          solved!.centerRa,
          solved.centerDec,
          _emptyRa,
          _emptyDec,
        ),
        lessThan(0.05),
      );
    });
  });
}
