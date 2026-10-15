import 'dart:convert';
import 'dart:typed_data';

import 'package:astrosophy/analysis.dart';
import 'package:astrosophy/model.dart';
import 'package:astrosophy/models.dart';
import 'package:astrosophy/naming.dart';
import 'package:astrosophy/report.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// 让模型挑「这张照片拍的是哪个深空天体」。
///
/// 这条线画得很清楚：候选编号、坐标、角尺寸、占像场多大，全是本机算出来的
/// **测量**，模型一个字都不许改；它只回答「这些里面哪个才是主角」。所以在
/// 下面能看到两类断言：一类是它答对了要采纳，另一类是它答得不像话时必须
/// 整条作废——**编一个天体出来是最坏的结果**，报告顶部会郑重其事地写一个
/// 画面里没有的东西，而用户没法察觉。
class _FakeClient extends http.BaseClient {
  _FakeClient(this.responder);

  final http.Response Function(http.Request request) responder;
  final requests = <http.Request>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final captured = http.Request(request.method, request.url)
      ..headers.addAll(request.headers)
      ..bodyBytes = (request as http.Request).bodyBytes;
    requests.add(captured);
    final response = responder(captured);
    return http.StreamedResponse(
      Stream.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
    );
  }
}

http.Response reply(String content) => http.Response(
      jsonEncode({
        'choices': [
          {
            'message': {'role': 'assistant', 'content': content},
          },
        ],
      }),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

const _m45 = DeepSkyCandidate(
  name: 'M 45',
  category: '疏散星团',
  angularSizeArcmin: 110,
  fieldFraction: 0.436,
  magnitude: 1.6,
  nickname: '昴星团',
);

const _ic353 = DeepSkyCandidate(
  name: 'IC 353',
  category: '星云',
  angularSizeArcmin: 180,
  fieldFraction: 0.713,
);

void main() {
  group('挑主体', () {
    test('模型选了哪个就是哪个，哪怕它尺寸更小', () async {
      // 这正是实况：IC 353（180′）比 M45（110′）大，按尺寸排出来的「主体」
      // 成了 IC 353，而用户拍的是昴星团。
      final client = _FakeClient((_) => reply('{"primary": "M 45"}'));
      final picked = await ModelService.pickPrimaryDeepSky(
        baseUrl: 'https://example.test/v1',
        apiKey: 'k',
        model: 'm',
        candidates: const [_m45, _ic353],
        httpClient: client,
      );
      expect(picked, 'M 45');
    });

    test('候选少于两个时不问，省一次往返', () async {
      final client = _FakeClient((_) => reply('{"primary": "M 45"}'));
      final picked = await ModelService.pickPrimaryDeepSky(
        baseUrl: 'https://example.test/v1',
        apiKey: 'k',
        model: 'm',
        candidates: const [_m45],
        httpClient: client,
      );
      expect(picked, isNull);
      expect(client.requests, isEmpty, reason: '只有一个天体就没有第二个答案');
    });

    test('编一个画面里没有的天体 → 整条作废', () async {
      // 最坏的情况：报告顶部写一个画面里根本没有的目标。
      final client = _FakeClient((_) => reply('{"primary": "M 42 猎户座大星云"}'));
      final picked = await ModelService.pickPrimaryDeepSky(
        baseUrl: 'https://example.test/v1',
        apiKey: 'k',
        model: 'm',
        candidates: const [_m45, _ic353],
        httpClient: client,
      );
      expect(picked, isNull);
    });

    test('差一个空格也算没对上', () async {
      // 不逐字相等的话，返回去在列表里定位不到那个天体。
      final client = _FakeClient((_) => reply('{"primary": "M45"}'));
      expect(
        await ModelService.pickPrimaryDeepSky(
          baseUrl: 'https://example.test/v1',
          apiKey: 'k',
          model: 'm',
          candidates: const [_m45, _ic353],
          httpClient: client,
        ),
        isNull,
      );
    });

    test('模型包了围栏或者多说了几句也能认出来', () async {
      final client = _FakeClient(
        (_) => reply('根据清单，这张照片拍的是：\n```json\n{"primary": "M 45"}\n```'),
      );
      expect(
        await ModelService.pickPrimaryDeepSky(
          baseUrl: 'https://example.test/v1',
          apiKey: 'k',
          model: 'm',
          candidates: const [_m45, _ic353],
          httpClient: client,
        ),
        'M 45',
      );
    });

    test('HTTP 出错、答非所问、连不上，一律当作没挑过', () async {
      for (final responder in <http.Response Function(http.Request)>[
        (_) => http.Response('nope', 500),
        (_) => http.Response('{}', 200),
        (_) => reply('我不知道该选哪个。'),
        (_) => throw http.ClientException('连不上'),
      ]) {
        final client = _FakeClient(responder);
        expect(
          await ModelService.pickPrimaryDeepSky(
            baseUrl: 'https://example.test/v1',
            apiKey: 'k',
            model: 'm',
            candidates: const [_m45, _ic353],
            httpClient: client,
          ),
          isNull,
        );
      }
    });

    test('没配 Key 或模型名就不发请求', () async {
      final client = _FakeClient((_) => reply('{"primary": "M 45"}'));
      for (final (key, model) in [('', 'm'), ('k', ''), ('  ', '  ')]) {
        expect(
          await ModelService.pickPrimaryDeepSky(
            baseUrl: 'https://example.test/v1',
            apiKey: key,
            model: model,
            candidates: const [_m45, _ic353],
            httpClient: client,
          ),
          isNull,
        );
      }
      expect(client.requests, isEmpty);
    });

    test('候选里的测量值原样送给模型，没有照片', () async {
      final client = _FakeClient((_) => reply('{"primary": "M 45"}'));
      await ModelService.pickPrimaryDeepSky(
        baseUrl: 'https://example.test/v1',
        apiKey: 'k',
        model: 'm',
        candidates: const [_m45, _ic353],
        httpClient: client,
      );
      final body = utf8.decode(client.requests.single.bodyBytes);
      expect(body, contains('M 45'));
      expect(body, contains('昴星团'));
      expect(body, contains('110'));
      // 不发图：挑主体这件事不需要看图，而少发一次图就少一次隐私上的让步。
      expect(body, isNot(contains('image')));
      expect(body, isNot(contains('base64')));
    });
  });

  group('图上画不画圈', () {
    test('180′ 又没星等的弥漫天体：留条目，但不画圈', () {
      // 用户的原话：「180′ 这种的弥漫星体就不需要在图中表示出来了，深空天体
      // 中他们有条目，但是没有加减号。」
      //
      // 判据是「又大又没星等」，两条同时成立——这正是 IC 353 的写照：180′，
      // 目录里没记星等，在手机照片上看不见，画在图上只是一个横贯整幅的大环。
      //
      // 像场取 4.2°（演示图那张的尺度）。
      expect(
        worthMarkingOnImage(sizeArcmin: 180, magnitude: null, fieldOfViewDegrees: 4.2),
        isFalse,
        reason: 'IC 353 那一种',
      );
    });

    test('大但有星等的照画——M31 的圈是有意义的', () {
      expect(
        worthMarkingOnImage(sizeArcmin: 178, magnitude: 3.5, fieldOfViewDegrees: 4.2),
        isTrue,
        reason: 'M31 也很大，但它有星等，那个圈指的是看得见的东西',
      );
    });

    test('没星等但没那么大的照画——面纱星云的弧要靠它标出来', () {
      // 70′ 在 4.2° 的视场里占 28%，圈画得出来。要是把「没星等」单独当判据，
      // 面纱星云就又没了，而那正是上一轮刚修好的事。
      expect(
        worthMarkingOnImage(sizeArcmin: 70, magnitude: null, fieldOfViewDegrees: 4.2),
        isTrue,
      );
      expect(
        worthMarkingOnImage(sizeArcmin: 60, magnitude: null, fieldOfViewDegrees: 4.2),
        isTrue,
      );
    });

    test('「太大」是相对像场说的，不是一个绝对角分', () {
      // 同一个 180′ 的天体：45° 的广角里它只是个小圈，4° 的视场里它就是
      // 绕着整幅画的一个环。
      expect(
        worthMarkingOnImage(sizeArcmin: 180, magnitude: null, fieldOfViewDegrees: 45),
        isTrue,
      );
      expect(
        worthMarkingOnImage(sizeArcmin: 180, magnitude: null, fieldOfViewDegrees: 4.2),
        isFalse,
      );
    });

    test('没有角尺寸或没有像场时不替它下结论', () {
      // 缺信息就别挡：宁可多画一个圈，也别把一个真目标藏起来。
      expect(
        worthMarkingOnImage(sizeArcmin: null, magnitude: null, fieldOfViewDegrees: 4.2),
        isTrue,
      );
      expect(
        worthMarkingOnImage(sizeArcmin: 180, magnitude: null, fieldOfViewDegrees: 0),
        isTrue,
      );
    });
  });

  group('报告用模型挑的主体', () {
    SolveResult solveWith({required List<SkyObject> objects, String? primary}) =>
        SolveResult(
          centerRa: 56.85,
          centerDec: 24.1,
          arcsecPerPixel: 15,
          namedStars: const [],
          deepSkyObjects: objects,
          matchedStars: const [],
          magnitudeZeroPoint: null,
          magnitudeScatter: null,
          catalogWarning: null,
          source: SolveSource.local,
          fieldOfViewDegrees: 4.2,
          constellations: const ['金牛座'],
          matchedCount: 20,
          primaryDeepSky: primary,
        );

    const ic353 = SkyObject('IC 353', 58.75, 25.483, '星云',
        angularSizeArcmin: 180, x: 10, y: 10);
    const m45 = SkyObject('M 45', 56.85, 24.117, '疏散星团',
        angularSizeArcmin: 110, x: 500, y: 400);

    test('没有模型意见时，本机那套按「有没有常用名」排', () {
      final entries = buildDeepSkyEntries(
        solveWith(objects: const [ic353, m45]),
      );
      // IC 353 在目录里记着 180′，比 M45 的 110′ 大——纯按尺寸排它会跑第一，
      // 而那张照片拍的是昴星团。所以本机这一档先看有没有中文常用名。
      expect(entries.first.name, 'M 45');
      expect(entries.map((entry) => entry.name), containsAll(['M 45', 'IC 353']));
    });

    test('模型挑过之后，它挑的排最前', () {
      final entries = buildDeepSkyEntries(
        solveWith(objects: const [ic353, m45], primary: 'IC 353'),
      );
      expect(entries.first.name, 'IC 353');
    });

    test('挑过的那个必须真的在画面里，否则排序不受影响', () {
      // 落到这一层的名字已经过校验（见上一组），但报告层不该无条件相信它：
      // 万一是从历史记录里读回来的旧数据、而画面里的清单变了，按一个不存在
      // 的名字排会把整个列表排乱。
      final entries = buildDeepSkyEntries(
        solveWith(objects: const [ic353, m45], primary: 'M 13'),
      );
      expect(entries.first.name, 'M 45');
      expect(entries, hasLength(2));
    });

    test('主体会一路带到头条和记录名字里', () {
      // 报告顶部的第一行就是在说「你拍到了什么」，主体挑了谁，它就该写谁。
      final solve = solveWith(objects: const [ic353, m45], primary: 'M 45');
      final headline = buildHeadlineMarkdown(analysisForHeadline(), solve);
      expect(headline, contains('昴星团'));
      // 记录名字也跟着走：M45 那张该叫「昴星团_…」而不是「IC 353_…」。
      expect(
        suggestedObservationName(
          analysis: analysisForHeadline(),
          solve: solve,
          moment: DateTime(2025, 9, 1),
        ),
        '昴星团_250901',
      );
    });
  });
}

/// 头条和命名只用到「这是不是月面」和尺寸，别的一概不看。
SkyAnalysis analysisForHeadline() => SkyAnalysis(
      width: 1024,
      height: 768,
      stars: const [],
      quality: '良好',
      background: 0.08,
      noise: 0.02,
      backgroundIndex: 20,
      saturatedFraction: 0,
      diagnostics: const [],
      preview: Uint8List(0),
      processedPreview: Uint8List(0),
      fwhm: 3,
      nonStarFraction: 0,
      maskRegions: const [],
      isLikelyStarfield: true,
      starfieldConfidence: 0.9,
      brightFlatFraction: 0,
    );
