import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:astrosophy/analysis.dart';
import 'package:astrosophy/history.dart';
import 'package:astrosophy/models.dart';
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

  test('字节数写成给人看的样子', () {
    expect(formatBytes(512), '512 B');
    expect(formatBytes(2048), '2 KB');
    expect(formatBytes(3 * 1024 * 1024), '3.0 MB');
  });
}
