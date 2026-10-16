import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:astrosophy/analysis.dart';
import 'package:astrosophy/history.dart';
import 'package:astrosophy/models.dart';
import 'package:astrosophy/moon_disc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 一张最小的合成 JPEG，只要能原样读回来就行。
Uint8List tinyJpeg(int seed) =>
    Uint8List.fromList(List<int>.generate(64, (index) => (index * seed) % 256));

SkyAnalysis analysisOf({
  int starCount = 3,
  String quality = '良好',
  bool isStarfield = true,
  double noise = 0.02,
  MoonDisc? moonDisc,
}) =>
    SkyAnalysis(
      width: 800,
      height: 600,
      stars: [
        for (var index = 0; index < starCount; index++)
          DetectedStar(
            100.0 + index * 20,
            150.0 + index * 30,
            5000.0 - index * 400,
            4.0 + index * 0.5,
            0.8,
            1.1,
            fwhm: 3.2,
            fluxError: 40,
          ),
      ],
      quality: quality,
      background: 0.09,
      noise: noise,
      backgroundIndex: 9,
      saturatedFraction: 0.001,
      diagnostics: const ['背景较暗'],
      preview: tinyJpeg(1),
      processedPreview: tinyJpeg(2),
      fwhm: 3.2,
      nonStarFraction: 0.01,
      maskRegions: const [],
      isLikelyStarfield: isStarfield,
      starfieldConfidence: 0.93,
      brightFlatFraction: 0.02,
      moonDisc: moonDisc,
    );

SolveResult solveOf() => const SolveResult(
      centerRa: 83.8,
      centerDec: -1.5,
      arcsecPerPixel: 12.5,
      namedStars: [
        SkyObject('参宿四', 88.79, 7.41, '红超巨星', magnitude: 0.45, isLocal: true),
      ],
      deepSkyObjects: [],
      matchedStars: [],
      magnitudeZeroPoint: 14.2,
      magnitudeScatter: 0.18,
      catalogWarning: null,
      source: SolveSource.local,
      fieldOfViewDegrees: 9.1,
      constellations: ['猎户座'],
      constellationFigures: [
        ConstellationFigure(
          name: '猎户座',
          segments: [
            [100.0, 200.0, 300.0, 400.0],
            [300.0, 400.0, 500.0, 380.0],
          ],
          labelX: 300,
          labelY: 370,
        ),
      ],
      matchedCount: 27,
    );

void main() {
  late Directory root;
  late HistoryStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('astrosophy-history-');
    store = await HistoryStore.open(root: root);
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  group('HistoryStore 保存与读取', () {
    test('存的测量结果能原样读回来', () async {
      final saved = await store.save(
        name: 'orion.jpg',
        analysis: analysisOf(),
        solve: solveOf(),
        explanation: '这是一段解读。',
      );

      final entries = await store.list();
      expect(entries.length, 1);
      final entry = entries.single;
      expect(entry.id, saved.id);
      expect(entry.name, 'orion.jpg');
      expect(entry.starCount, 3);
      expect(entry.quality, '良好');
      expect(entry.constellation, '猎户座');

      // 列表页不解图片字节——它只拿文件路径交给 Image.file 懒加载。
      // 真要打开这一条时才读。
      final analysis = await entry.readAnalysis();
      expect(analysis.width, 800);
      expect(analysis.stars.length, 3);
      expect(analysis.stars.first.instrumentalMagnitude, closeTo(4.0, 1e-9));
      expect(analysis.stars.first.fluxError, closeTo(40, 1e-9));
      expect(analysis.fwhm, closeTo(3.2, 1e-9));
      expect(analysis.diagnostics, ['背景较暗']);
      expect(analysis.preview, tinyJpeg(1));
      expect(analysis.processedPreview, tinyJpeg(2));

      final solve = entry.solve!;
      expect(solve.centerRa, closeTo(83.8, 1e-9));
      expect(solve.constellations, ['猎户座']);
      // 连线是嵌套的浮点数组，JSON 往返最容易在这里掉精度或掉层，所以
      // 逐段比一遍：从历史里打开的那张图，星座连线也得原样画出来。
      expect(solve.constellationFigures, hasLength(1));
      expect(solve.constellationFigures.single.name, '猎户座');
      expect(solve.constellationFigures.single.segments, [
        [100.0, 200.0, 300.0, 400.0],
        [300.0, 400.0, 500.0, 380.0],
      ]);
      expect(solve.constellationFigures.single.labelX, closeTo(300, 1e-9));
      expect(solve.constellationFigures.single.labelY, closeTo(370, 1e-9));
      expect(solve.magnitudeZeroPoint, closeTo(14.2, 1e-9));
      expect(solve.source, SolveSource.local);
      expect(solve.namedStars.single.name, '参宿四');
      expect(solve.namedStars.single.isLocal, isTrue);
      expect(entry.explanation, '这是一段解读。');
    });

    test('最近保存的排在前面', () async {
      await store.save(
        name: '早的',
        analysis: analysisOf(),
        solve: null,
        explanation: null,
        savedAt: DateTime(2026, 10, 1, 21, 0),
      );
      await store.save(
        name: '晚的',
        analysis: analysisOf(),
        solve: null,
        explanation: null,
        savedAt: DateTime(2026, 10, 14, 22, 39),
      );

      final entries = await store.list();
      expect(entries.map((entry) => entry.name).toList(), ['晚的', '早的']);
    });

    test('没解算的记录也能存，星座处留空而不是编一个', () async {
      await store.save(
        name: 'no-solve.jpg',
        analysis: analysisOf(),
        solve: null,
        explanation: null,
      );
      final entry = (await store.list()).single;
      expect(entry.solve, isNull);
      expect(entry.constellation, isNull);
    });

    test('删除一条记录会连图片一起删掉', () async {
      final saved = await store.save(
        name: 'a.jpg',
        analysis: analysisOf(),
        solve: null,
        explanation: null,
      );
      expect(saved.imageFile.existsSync(), isTrue);
      expect(saved.processedFile.existsSync(), isTrue);
      expect(saved.byteSize, greaterThan(0));

      await store.delete(saved);
      // 只删 JSON 会留下没人认领的图片，用户看到的是「历史空了但空间没释放」。
      expect(saved.imageFile.existsSync(), isFalse);
      expect(saved.processedFile.existsSync(), isFalse);
      expect(await store.list(), isEmpty);
      expect(await store.totalBytes(), 0);
    });

    test('同一毫秒保存两次不会互相覆盖', () async {
      final at = DateTime(2026, 10, 14, 22, 39, 12, 500);
      final first = await store.save(
        name: '第一次',
        analysis: analysisOf(),
        solve: null,
        explanation: null,
        savedAt: at,
      );
      final second = await store.save(
        name: '第二次',
        analysis: analysisOf(),
        solve: null,
        explanation: null,
        savedAt: at,
      );
      expect(first.id, isNot(second.id));
      expect((await store.list()).length, 2);
    });

    test('一条记录读坏了，其余照常显示', () async {
      await store.save(
        name: '好的',
        analysis: analysisOf(),
        solve: null,
        explanation: null,
      );
      // 模拟写到一半掉电留下的半截 JSON。
      File(p.join(store.directory.path, '20300101-000000-000.json'))
          .writeAsStringSync('{"version": 1, "name": "坏的", ');

      final entries = await store.list();
      expect(entries.length, 1);
      expect(entries.single.name, '好的');
    });

    test('图片文件丢了，档案还在', () async {
      final saved = await store.save(
        name: '图没了',
        analysis: analysisOf(),
        solve: null,
        explanation: null,
      );
      saved.imageFile.deleteSync();

      final entry = (await store.list()).single;
      expect(entry.name, '图没了');
      // 图片读不到就给空字节，由界面画占位图——直接抛异常会让整页都开不了。
      final analysis = await entry.readAnalysis();
      expect(analysis.preview, isEmpty);
      expect(analysis.stars.length, 3);
    });

    test('存档里不塞 base64 图片', () async {
      final saved = await store.save(
        name: 'a.jpg',
        analysis: analysisOf(starCount: 40),
        solve: solveOf(),
        explanation: null,
      );
      final json = File(p.join(store.directory.path, '${saved.id}.json'))
          .readAsStringSync();
      // 图片是几十上百 KB 的二进制，编码成 base64 会把它撑大三分之一，
      // 而每次列表刷新都要解码一遍。所以两个预览图字段不该出现在 JSON 里。
      expect(json, isNot(contains('preview')));
      expect(json, isNot(contains('base64')));
      final decoded = jsonDecode(json) as Map<String, Object?>;
      expect((decoded['analysis']! as Map).containsKey('preview'), isFalse);
      expect(decoded['summary'], isA<Map>());
    });
  });

  group('记录结论', () {
    test('解算成功、只检测到星点、压根不像星空，分成三档', () async {
      final solved = await store.save(
        name: '解出来了',
        analysis: analysisOf(),
        solve: solveOf(),
        explanation: null,
      );
      expect(solved.outcome, RecordOutcome.ok);

      final detected = await store.save(
        name: '只检测到',
        analysis: analysisOf(),
        solve: null,
        explanation: null,
      );
      expect(detected.outcome, RecordOutcome.partial);

      // 星点检测到了，但那张图被判定为非星空（截图、文字表格）——这种情况
      // 必须落到「未能解析」，否则用户会以为那张图多少算出了点东西。
      final notStarfield = await store.save(
        name: '不像星空',
        analysis: analysisOf(isStarfield: false),
        solve: null,
        explanation: null,
      );
      expect(notStarfield.outcome, RecordOutcome.failed);

      final nothingFound = await store.save(
        name: '啥也没有',
        analysis: analysisOf(starCount: 0),
        solve: null,
        explanation: null,
      );
      expect(nothingFound.outcome, RecordOutcome.failed);

      // 星点数和解算结果都要跨进程读回来，不是只活在内存里的那个对象。
      final listed = {for (final entry in await store.list()) entry.name: entry};
      expect(listed['解出来了']!.outcome, RecordOutcome.ok);
      expect(listed['不像星空']!.outcome, RecordOutcome.failed);
    });

    test('月亮走月面分支，单独一档，不并进「已解算」', () async {
      // 月面照片没有星点、也没有天区坐标，但月盘圆心、亮面占比、相名和盈亏
      // 全都报出来了——它绝不该落到「未能解析」（那是在说这张图白拍了）。
      // 可也不该并进「已解算」：那张照片一次天区解算都没跑过，是用户自己
      // 选的「直接报告月亮」，标成「已解算」是在说一件没发生的事。
      final moon = await store.save(
        name: '月亮',
        analysis: analysisOf(
          starCount: 0,
          isStarfield: false,
          moonDisc: const MoonDisc(
            centerX: 400,
            centerY: 300,
            radiusPixels: 180,
            litPixels: 64000,
            frameArea: 480000,
          ),
        ),
        solve: null,
        explanation: null,
      );
      expect(moon.outcome, RecordOutcome.moon);
      expect(moon.outcome.label, '月面');
      // 列表上那一行副标题：点源数恒为零，写出来像是「什么都没拍到」。
      expect(moon.moonIlluminatedFraction, closeTo(64000 / (math.pi * 180 * 180), 1e-6));
      // 也要能从磁盘读回来，不能只活在内存里的那个对象上。
      final listed = (await store.list()).single;
      expect(listed.outcome, RecordOutcome.moon);
      expect(listed.moonIlluminatedFraction, isNotNull);
    });

    test('不是月面的记录没有亮面读数列', () async {
      final plain = await store.save(
        name: '星空',
        analysis: analysisOf(),
        solve: solveOf(),
        explanation: null,
      );
      expect(plain.outcome, RecordOutcome.ok);
      expect(plain.moonIlluminatedFraction, isNull);
    });

    test('老记录没有月亮字段时，回头认测量结果里的月盘', () async {
      final saved = await store.save(
        name: '月亮',
        analysis: analysisOf(
          starCount: 0,
          isStarfield: false,
          moonDisc: const MoonDisc(
            centerX: 400,
            centerY: 300,
            radiusPixels: 180,
            litPixels: 64000,
            frameArea: 480000,
          ),
        ),
        solve: null,
        explanation: null,
      );
      // 模拟这份档案是加 moon 字段之前存下的：把摘要里那一项删掉。
      final file = File(p.join(store.directory.path, '${saved.id}.json'));
      final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      (json['summary']! as Map).remove('moon');
      file.writeAsStringSync(jsonEncode(json));

      expect((await store.list()).single.outcome, RecordOutcome.moon);
    });

    test('老记录没有星空判定字段时按星点数兜底', () async {      final saved = await store.save(
        name: '老记录',
        analysis: analysisOf(),
        solve: null,
        explanation: null,
      );
      // 模拟这份档案是加字段之前存下的：把 starfield 从摘要里删掉。
      final file = File(p.join(store.directory.path, '${saved.id}.json'));
      final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      (json['summary']! as Map).remove('starfield');
      file.writeAsStringSync(jsonEncode(json));

      // 有星点、没解算 → 中间那一档，而不是因为读不到字段就当成失败。
      expect((await store.list()).single.outcome, RecordOutcome.partial);
    });

    test('改名不会顺手改掉这条记录的结论', () async {
      final saved = await store.save(
        name: '旧名字',
        analysis: analysisOf(),
        solve: solveOf(),
        explanation: null,
      );
      final renamed = await store.rename(saved, '新名字');
      // 卡片描边的颜色全靠 outcome，改名时把它丢了就等于给记录重新判了级。
      expect(renamed.outcome, RecordOutcome.ok);
    });
  });

  group('HistoryStore 重命名', () {
    test('改名只动 JSON 里的 name，图片和 id 都不变', () async {
      final saved = await store.save(
        name: 'IMG_2043.jpg',
        analysis: analysisOf(),
        solve: solveOf(),
        explanation: '一段解读。',
      );

      final renamed = await store.rename(saved, '猎户座大星云');
      expect(renamed.name, '猎户座大星云');
      expect(renamed.id, saved.id);
      // 为了一个名字去搬图片不值得：id 一变两个图片文件名都得跟着变，
      // 中途失败还会留下半搬完的状态。
      expect(renamed.imageFile.path, saved.imageFile.path);
      expect(renamed.imageFile.existsSync(), isTrue);
      expect(renamed.processedFile.existsSync(), isTrue);

      // 列表是从 JSON 读的，所以重开一遍确认改的是文件而不是内存里的对象。
      final entry = (await store.list()).single;
      expect(entry.name, '猎户座大星云');
      expect(entry.constellation, '猎户座');
      expect(entry.explanation, '一段解读。');
      // 测量结果和解算结果一个字都不能少。
      expect(entry.solve!.centerRa, closeTo(83.8, 1e-9));
      expect((await entry.readAnalysis()).stars.length, 3);
      expect(await store.totalBytes(), greaterThan(0));
    });

    test('首尾空白会被去掉', () async {
      final saved = await store.save(
        name: '旧名字',
        analysis: analysisOf(),
        solve: null,
        explanation: null,
      );
      final renamed = await store.rename(saved, '  夏天的银河  ');
      expect(renamed.name, '夏天的银河');
      expect((await store.list()).single.name, '夏天的银河');
    });

    test('空名字不算改名，不写盘', () async {
      final saved = await store.save(
        name: '别弄丢我',
        analysis: analysisOf(),
        solve: null,
        explanation: null,
      );
      // 一条无名的记录在列表里认不出来，所以宁可什么都不做。
      expect(identical(await store.rename(saved, '   '), saved), isTrue);
      expect(identical(await store.rename(saved, ''), saved), isTrue);
      expect((await store.list()).single.name, '别弄丢我');
    });

    test('名字没变时也不写盘', () async {
      final saved = await store.save(
        name: '原样',
        analysis: analysisOf(),
        solve: null,
        explanation: null,
      );
      expect(identical(await store.rename(saved, '原样'), saved), isTrue);
    });
  });

  test('字节数写成给人看的样子', () {
    expect(formatBytes(512), '512 B');
    expect(formatBytes(2048), '2 KB');
    expect(formatBytes(3 * 1024 * 1024), '3.0 MB');
  });
}
