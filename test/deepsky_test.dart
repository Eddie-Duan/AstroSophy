import 'package:astrosophy/catalog.dart';
import 'package:astrosophy/deepsky.dart';
import 'package:astrosophy/models.dart';
import 'package:astrosophy/solver.dart';
import 'package:flutter_test/flutter_test.dart';

import 'catalog_fixture.dart';

/// 猎户座里的 M78。选它做「本机解算能不能标出深空目标」的考场，是因为
/// 它自己就是一片亮星星场中心，本机星表够密，能解出来；而它周围几度内
/// 还散着 M42、M43、NGC 1981，正好检验会不会一次标好几个。
const _m78Ra = 86.675;
const _m78Dec = 0.05;

void main() {
  late DeepSkyCatalog deepSky;

  setUpAll(() => deepSky = loadTestDeepSky());

  group('深空目录资产', () {
    test('载入了整张离线深空目录', () {
      expect(deepSky.objects.length, greaterThan(2500));
      for (final object in deepSky.objects) {
        expect(object.name, isNotEmpty);
        expect(object.ra, inInclusiveRange(0, 360));
        expect(object.dec, inInclusiveRange(-90, 90));
        // 星等和角尺寸**可以**不填：目录现在收全部有类型的条目，而
        // NGC 2000.0 本来就有四成条目没有星等。类型本身不能空——那才是
        // 收进目录的门槛（空的、`-`、`*` 都在生成时被丢掉了）。
        expect(object.typeCode, isNotEmpty,
            reason: '${object.name} 没有类型');
      }
      // 至少要有这么多真的是带齐了两样的，否则上面那条会因为「几乎全是空值」
      // 而变得没有约束力。
      final complete = deepSky.objects
          .where((object) =>
              object.magnitude != null && object.angularSizeArcmin != null)
          .length;
      expect(complete, greaterThan(2000));
    });

    test('110 个 Messier 目标一个不少', () {
      final numbers = <int>{};
      for (final object in deepSky.objects) {
        if (!object.isMessier) continue;
        final number = int.tryParse(object.name.substring(2));
        expect(number, isNotNull, reason: '${object.name} 不是合法的 Messier 编号');
        numbers.add(number!);
      }
      expect(numbers, hasLength(110));
      expect(numbers.difference({for (var i = 1; i <= 110; i++) i}), isEmpty);
    });

    test('Messier 目标报 M 编号，NGC 编号不重复出现', () {
      expect(deepSky.objects.any((object) => object.name == 'M 31'), isTrue);
      // NGC 224 就是 M31，两条都列出来只会让报告里出现两个一样的东西。
      expect(deepSky.objects.any((object) => object.name == 'NGC 224'), isFalse);
    });

    test('几个著名目标的坐标、角尺寸和星等对得上', () {
      DeepSkyObject find(String name) =>
          deepSky.objects.firstWhere((object) => object.name == name);

      final m31 = find('M 31');
      expect(m31.angularSizeArcmin, closeTo(178.0, 0.1));
      expect(m31.magnitude, closeTo(3.5, 0.1));
      expect(m31.category, '星系');
      // NGC 2000.0 的 B2000 坐标和 J2000 差在角分量级，标注圆圈完全够用。
      expect(angularSeparationDegrees(m31.ra, m31.dec, 10.6847, 41.2692),
          lessThan(0.1));

      final m45 = find('M 45');
      expect(m45.angularSizeArcmin, closeTo(110.0, 0.1));
      expect(m45.category, '疏散星团');

      final m57 = find('M 57');
      expect(m57.category, '行星状星云');
      expect(m57.angularSizeArcmin, closeTo(2.5, 0.1));
    });
  });

  group('DeepSkyCatalog 查询', () {
    test('near 按角尺寸从大到小，M31 排在最前', () {
      final found = deepSky.near(10.68, 41.27, 2.0);
      expect(found, isNotEmpty);
      expect(found.first.name, 'M 31');
      expect(found.map((object) => object.name), containsAll(['M 32', 'M 110']));
      // 目录里现在允许没有角尺寸的条目（那几类不看星等收进来的星云星团），
      // 它们排在最后，所以比大小的时候要跳过空值。
      var previous = double.infinity;
      for (final object in found) {
        final size = object.angularSizeArcmin;
        if (size == null) continue;
        expect(size, lessThanOrEqualTo(previous));
        previous = size;
      }
    });

    test('半径之外的一个都不返回', () {
      final found = deepSky.near(10.68, 41.27, 0.2);
      for (final object in found) {
        expect(
          angularSeparationDegrees(10.68, 41.27, object.ra, object.dec),
          lessThanOrEqualTo(0.2 + 1e-9),
        );
      }
    });

    test('天极附近不漏目标', () {
      // NGC 188 在赤纬 +85.3°，是目录里最靠北的几条之一。天极附近的赤经
      // 分桶被 cos(dec) 压到极窄，分桶逻辑少取几列就会整片漏掉。
      final found = deepSky.near(11.0, 85.33, 3.0);
      expect(found.map((object) => object.name), contains('NGC 188'));
    });

    test('angularSizeNear 只在容差内认账', () {
      expect(deepSky.angularSizeNear(10.6847, 41.2692), closeTo(178.0, 0.1));
      // 差 1° 早就不在同一个目标上了，宁可返回 null 也不能拿邻居的数顶上。
      expect(deepSky.angularSizeNear(11.68, 41.27), isNull);
    });

    test('对目录里没有的天区不编一个尺寸出来', () {
      // 南天极附近一片空的字段，目录里什么都没有。
      expect(deepSky.angularSizeNear(0, -89.9), isNull);
    });
  });

  group('NGC 2000.0 类型码', () {
    test('常见类型都翻成中文', () {
      expect(describeDeepSkyType('Gx'), '星系');
      expect(describeDeepSkyType('OC'), '疏散星团');
      expect(describeDeepSkyType('Gb'), '球状星团');
      expect(describeDeepSkyType('Pl'), '行星状星云');
      expect(describeDeepSkyType('Nb'), '星云');
      expect(describeDeepSkyType('C+N'), '星团与星云');
      expect(describeDeepSkyType('D*'), '双星');
    });

    test('目录里出现的类型码全都认得', () {
      for (final object in deepSky.objects) {
        if (object.typeCode.isEmpty) continue;
        expect(
          object.category,
          isNot(object.typeCode),
          reason: '${object.name} 的类型码 ${object.typeCode} 没有中文名',
        );
      }
    });

    test('认不出来的代码原样返回，不猜一个中文类型', () {
      expect(describeDeepSkyType('Xy'), 'Xy');
      expect(describeDeepSkyType(''), '');
    });
  });

  group('本机解算的深空标注', () {
    late StarCatalog catalog;
    late PlateSolver solver;

    setUpAll(() {
      catalog = loadTestCatalog();
      solver = PlateSolver(catalog, deepSky: deepSky);
    });

    test('解出天区之后，画面里的深空天体跟着标出来', () {
      final analysis = synthesiseField(
        catalog: catalog,
        centerRa: _m78Ra,
        centerDec: _m78Dec,
        degreesPerPixel: 0.008,
      );
      final result = solver.solve(analysis);
      expect(result, isNotNull, reason: '理想星图必须能解出来');

      final wcs = result!.wcs!;
      expect(result.deepSkyObjects, isNotEmpty);
      expect(result.deepSkyObjects.map((object) => object.name),
          contains('M 78'));

      for (final object in result.deepSkyObjects) {
        // 标出来的位置必须和 WCS 自洽：把像素坐标反投影回去，应当就是
        // 这个天体自己的天球坐标。差得多说明投影用错了中心或尺度。
        final (ra, dec) = wcs.pixelToWorld(object.x, object.y);
        expect(
          angularSeparationDegrees(ra, dec, object.ra, object.dec),
          lessThan(0.01),
          reason: '${object.name} 的像素位置和它的坐标对不上',
        );
        expect(object.x, inInclusiveRange(0, analysis.width.toDouble()));
        expect(object.y, inInclusiveRange(0, analysis.height.toDouble()));
        // 角尺寸是离线目录多给的那一样东西，必须带出来。
        expect(object.angularSizeArcmin, isNotNull);
      }
    });

    test('不带深空目录的解算器不产出深空天体', () {
      // 深空标注是解算之外多给的一层；没有目录时结果里就该是空的，
      // 而不是退回到在线路径或者凭空造一个。
      final plain = PlateSolver(catalog);
      final analysis = synthesiseField(
        catalog: catalog,
        centerRa: _m78Ra,
        centerDec: _m78Dec,
        degreesPerPixel: 0.008,
      );
      expect(plain.solve(analysis)!.deepSkyObjects, isEmpty);
    });

    test('在线结果按坐标补上角尺寸，补不到就留空', () {
      // SIMBAD 不给角尺寸，所以在线路径的「占了画面多大」本来是空的。
      // 本机目录里有，按位置对一下就能补。
      final online = SolveResult(
        centerRa: _m78Ra,
        centerDec: _m78Dec,
        arcsecPerPixel: 28.8,
        namedStars: const [],
        deepSkyObjects: [
          const SkyObject('M 78', _m78Ra, _m78Dec, '反射星云', x: 512, y: 384),
          // 目录里查不到的位置（南天极），尺寸应当原样留空。
          const SkyObject('某暗云', 0, -89.9, '暗星云', x: 100, y: 100),
        ],
        matchedStars: const [],
        magnitudeZeroPoint: null,
        magnitudeScatter: null,
        catalogWarning: null,
        fieldOfViewDegrees: 10.2,
        // decorateSolve 要先有 WCS 才动手（没有坐标就无从投影），
        // 至于解算方式，这件事和补尺寸无关。
        wcs: Wcs.fromPixels(
          width: 1024,
          height: 768,
          centerRa: _m78Ra,
          centerDec: _m78Dec,
          degreesPerPixel: 0.008,
        ),
      );

      final decorated = solver.decorateSolve(online);
      // 按名字取，不按次序取：名单里现在还包含内置目录里落进视场的其他天体
      // （见 `_localDeepSky`），次序不再等于「SIMBAD 给的顺序」。
      final byName = {
        for (final object in decorated.deepSkyObjects) object.name: object,
      };
      // SIMBAD 给的那个在有内置目录的天区里查得到，角尺寸补上了。
      expect(byName['M 78']!.angularSizeArcmin, closeTo(8.0, 0.1));
      // 南天极那个查不到，原样留空——宁可写「尺寸未知」，也不编一个数出来。
      expect(byName['某暗云']!.angularSizeArcmin, isNull);
    });
  });
}
