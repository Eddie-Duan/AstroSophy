import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpException;
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import 'analysis.dart';
import 'models.dart';

/// 解算进度回调：progress 为 0–1，stage 是给用户看的中文阶段描述。
typedef SolveProgressCallback = void Function(double progress, String stage);

/// 在线天区解算：把预览图交给 Astrometry.net，拿回 FITS 天球坐标，
/// 再去 Gaia DR3 / SIMBAD 取星名和天体类型。整条链路只在用户授权后才调用。
class AstrometryService {
  static const _api = 'https://nova.astrometry.net/api';

  static Future<SolveResult> solve({
    required SkyAnalysis analysis,
    required String apiKey,
    SolveProgressCallback? onProgress,
  }) async {
    final client = http.Client();
    try {
      onProgress?.call(0.05, '正在登录 Astrometry.net');
      final login = await client.post(
        Uri.parse('$_api/login'),
        body: {'request-json': jsonEncode({'apikey': apiKey})},
      ).timeout(const Duration(seconds: 30));
      final sessionToken = _json(login)['session'];
      if (sessionToken is! String || sessionToken.isEmpty) {
        throw StateError('Astrometry.net 未返回会话令牌，请检查 API Key。');
      }

      onProgress?.call(0.15, '正在上传分析预览图');
      final request = http.MultipartRequest('POST', Uri.parse('$_api/upload'))
        ..fields['request-json'] = jsonEncode({
          'session': sessionToken,
          'allow_commercial_use': 'n',
          'allow_modifications': 'n',
          'publicly_visible': 'n',
        })
        ..files.add(http.MultipartFile.fromBytes('file', analysis.preview,
            filename: 'sky.jpg'));
      final upload =
          _json(await client.send(request).then(http.Response.fromStream));
      final subId = upload['subid'];
      if (subId == null) throw StateError('天文解算服务未接受图片。');

      // 排队：等服务方把提交拆成具体作业。这一段往往最久，进度条慢慢爬到 0.45。
      final deadline = DateTime.now().add(const Duration(minutes: 4));
      String? jobId;
      final queuedAt = DateTime.now();
      while (DateTime.now().isBefore(deadline) && jobId == null) {
        await Future<void>.delayed(const Duration(seconds: 2));
        final elapsed = DateTime.now().difference(queuedAt).inMilliseconds;
        onProgress?.call(
          (0.2 + 0.25 * (elapsed / 60000).clamp(0.0, 1.0)).toDouble(),
          '已提交，正在排队等待解算',
        );
        final response =
            await client.get(Uri.parse('$_api/submissions/$subId')).timeout(
                  const Duration(seconds: 30),
                );
        final jobs = _json(response)['jobs'];
        if (jobs is List) {
          for (final job in jobs) {
            if (job != null) {
              jobId = '$job';
              break;
            }
          }
        }
      }
      if (jobId == null) throw TimeoutException('天区解算排队超时，请稍后再试。');

      final solvedAt = DateTime.now();
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(seconds: 2));
        final elapsed = DateTime.now().difference(solvedAt).inMilliseconds;
        onProgress?.call(
          (0.45 + 0.2 * (elapsed / 90000).clamp(0.0, 1.0)).toDouble(),
          '正在识别星图模式',
        );
        final status = _json(
          await client.get(Uri.parse('$_api/jobs/$jobId')).timeout(
                const Duration(seconds: 30),
              ),
        );
        if (status['status'] == 'failure') {
          throw StateError('星图解算失败：请检查星点数量、拖线和画面遮挡。');
        }
        if (status['status'] == 'success') break;
      }
      final finalStatus = _json(
        await client.get(Uri.parse('$_api/jobs/$jobId')).timeout(
              const Duration(seconds: 30),
            ),
      );
      if (finalStatus['status'] != 'success') {
        throw TimeoutException('星图解算超时，请稍后重试。');
      }

      onProgress?.call(0.7, '正在读取天球坐标');
      final fitsResponse = await client
          .get(Uri.parse('https://nova.astrometry.net/wcs_file/$jobId'))
          .timeout(const Duration(seconds: 45));
      if (fitsResponse.statusCode != 200) {
        throw StateError('无法读取天球坐标解算结果。');
      }
      final wcs = Wcs.parseFitsHeader(fitsResponse.bodyBytes);
      if (wcs.width != analysis.width || wcs.height != analysis.height) {
        throw StateError('解算图像尺寸与本地预览不一致，已停止坐标标注。');
      }

      onProgress?.call(0.8, '正在查询 Gaia DR3 星表');
      var gaia = <GaiaMatch>[];
      var simbadObjects = <_CatalogObject>[];
      final catalogWarnings = <String>[];
      try {
        gaia = await _queryGaia(client, wcs, analysis);
      } on Exception catch (error) {
        catalogWarnings.add('Gaia DR3 星表：$error');
      }
      onProgress?.call(0.88, '正在查询 SIMBAD 天体名称');
      try {
        simbadObjects = await _querySimbad(client, wcs, analysis);
      } on Exception catch (error) {
        catalogWarnings.add('SIMBAD 名称目录：$error');
      }

      onProgress?.call(0.94, '正在交叉匹配星名与测光');
      final matches = _crossMatch(analysis, wcs, gaia, simbadObjects);

      return SolveResult(
        centerRa: wcs.imageCenter.$1,
        centerDec: wcs.imageCenter.$2,
        arcsecPerPixel: wcs.arcsecPerPixel,
        namedStars: matches.named,
        deepSkyObjects: matches.deepSky,
        matchedStars: gaia,
        magnitudeZeroPoint: matches.zeroPoint,
        magnitudeScatter: matches.scatter,
        catalogWarning:
            catalogWarnings.isEmpty ? null : catalogWarnings.join('；'),
        source: SolveSource.online,
        fieldOfViewDegrees: wcs.fieldOfViewDegrees,
        wcs: wcs,
        matchedCount: gaia.length,
      );
    } finally {
      client.close();
    }
  }

  static Map<String, dynamic> _json(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('天文服务返回 HTTP ${response.statusCode}。');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) throw const FormatException('天文服务返回格式无效。');
    if (decoded['status'] == 'error') {
      throw StateError('${decoded['errormessage'] ?? '天文服务处理失败。'}');
    }
    return decoded;
  }

  static Future<List<GaiaMatch>> _queryGaia(
    http.Client client,
    Wcs wcs,
    SkyAnalysis analysis,
  ) async {
    final radiusDegrees = _queryRadiusDegrees(wcs, analysis);
    final center = wcs.imageCenter;
    final adql = 'SELECT TOP 1500 source_id, ra, dec, phot_g_mean_mag '
        'FROM gaiadr3.gaia_source '
        'WHERE 1=CONTAINS(POINT(\'ICRS\',ra,dec), '
        'CIRCLE(\'ICRS\',${center.$1},${center.$2},$radiusDegrees)) '
        'AND phot_g_mean_mag IS NOT NULL ORDER BY phot_g_mean_mag';
    final uri = Uri.https('gea.esac.esa.int', '/tap-server/tap/sync', {
      'REQUEST': 'doQuery',
      'LANG': 'ADQL',
      'FORMAT': 'csv',
      'QUERY': adql,
    });
    final response = await client.get(uri).timeout(const Duration(seconds: 90));
    if (response.statusCode != 200) {
      throw HttpException('Gaia DR3 星表查询返回 HTTP ${response.statusCode}。');
    }
    final lines = const LineSplitter().convert(response.body);
    if (lines.length < 2) return [];
    final result = <GaiaMatch>[];
    for (final line in lines.skip(1)) {
      final columns = parseCsvRow(line);
      if (columns.length < 4) continue;
      final sourceId = columns[0];
      final ra = double.tryParse(columns[1]);
      final dec = double.tryParse(columns[2]);
      final magnitude = double.tryParse(columns[3]);
      if (sourceId.isEmpty || ra == null || dec == null || magnitude == null) {
        continue;
      }
      final (x, y) = wcs.worldToPixel(ra, dec);
      if (x >= 0 && x < analysis.width && y >= 0 && y < analysis.height) {
        result.add(
          GaiaMatch(
            sourceId: sourceId,
            ra: ra,
            dec: dec,
            x: x,
            y: y,
            gMagnitude: magnitude,
          ),
        );
      }
    }
    return result;
  }

  static Future<List<_CatalogObject>> _querySimbad(
    http.Client client,
    Wcs wcs,
    SkyAnalysis analysis,
  ) async {
    final center = wcs.imageCenter;
    final radiusDegrees = _queryRadiusDegrees(wcs, analysis);
    final adql = 'SELECT TOP 2500 main_id, ra, dec, otype '
        'FROM basic WHERE 1=CONTAINS(POINT(\'ICRS\',ra,dec), '
        'CIRCLE(\'ICRS\',${center.$1},${center.$2},$radiusDegrees))';
    final uri = Uri.https('simbad.cds.unistra.fr', '/simbad/sim-tap/sync', {
      'REQUEST': 'doQuery',
      'LANG': 'ADQL',
      'FORMAT': 'csv',
      'QUERY': adql,
    });
    final response = await client.get(uri).timeout(const Duration(seconds: 90));
    if (response.statusCode != 200) {
      throw HttpException('SIMBAD 名称目录返回 HTTP ${response.statusCode}。');
    }
    final lines = const LineSplitter().convert(response.body);
    if (lines.isEmpty || lines.first.toLowerCase().contains('error')) {
      throw const FormatException('SIMBAD 名称目录无法解析查询结果。');
    }
    final objects = <_CatalogObject>[];
    for (final line in lines.skip(1)) {
      final columns = parseCsvRow(line);
      if (columns.length < 4) continue;
      final ra = double.tryParse(columns[1]);
      final dec = double.tryParse(columns[2]);
      if (columns[0].isEmpty || ra == null || dec == null) continue;
      objects.add(_CatalogObject(columns[0], ra, dec, columns[3]));
    }
    return objects;
  }

  /// 查询半径按视场对角线的一半再放宽，避免边缘天体漏掉。
  static double _queryRadiusDegrees(Wcs wcs, SkyAnalysis analysis) {
    final radiusArcsec =
        math.max(analysis.width, analysis.height) * wcs.arcsecPerPixel * 0.8;
    return (radiusArcsec / 3600).clamp(0.05, 5.0).toDouble();
  }

  /// 把 Gaia 位置匹配到本地检出的星点，再用 SIMBAD 补上可读名字。
  static _CrossMatch _crossMatch(
    SkyAnalysis analysis,
    Wcs wcs,
    List<GaiaMatch> gaia,
    List<_CatalogObject> simbadObjects,
  ) {
    final tolerance =
        math.max(4, math.min(analysis.width, analysis.height) * 0.004);
    final simbadStars =
        simbadObjects.where((object) => object.isStar).toList(growable: false);

    final named = <SkyObject>[];
    final usedDetections = <DetectedStar>{};
    final usedNames = <String>{};
    for (final gaiaStar in gaia) {
      if (named.length >= 60) break;
      final nearest = _nearest(analysis.stars, gaiaStar.x, gaiaStar.y);
      if (nearest == null ||
          nearest.distance > tolerance ||
          !usedDetections.add(nearest.star)) {
        continue;
      }
      final simbadStar = _nearestSimbadStar(gaiaStar.ra, gaiaStar.dec, simbadStars);
      final simbadName = simbadStar != null && usedNames.add(simbadStar.mainId)
          ? simbadStar.mainId
          : null;
      named.add(
        SkyObject(
          simbadName ?? 'Gaia DR3 ${gaiaStar.sourceId}',
          gaiaStar.ra,
          gaiaStar.dec,
          simbadStar?.objectType ?? '恒星 · Gaia DR3',
          magnitude: gaiaStar.gMagnitude,
          magnitudeBand: 'G',
          x: nearest.star.x,
          y: nearest.star.y,
        ),
      );
    }
    // Gaia 查询失败时退回到只用 SIMBAD 的星名，至少在图上能标出名字。
    if (gaia.isEmpty) {
      for (final object in simbadStars) {
        final (x, y) = wcs.worldToPixel(object.ra, object.dec);
        final nearest = _nearest(analysis.stars, x, y);
        if (nearest == null ||
            nearest.distance > tolerance ||
            !usedDetections.add(nearest.star)) {
          continue;
        }
        named.add(
          SkyObject(
            object.mainId,
            object.ra,
            object.dec,
            object.objectType,
            x: nearest.star.x,
            y: nearest.star.y,
          ),
        );
        if (named.length >= 60) break;
      }
    }

    final clusters = <SkyObject>[];
    final knownNames = <String>{};
    for (final object in simbadObjects.where((item) => item.isDeepSky)) {
      if (clusters.length >= 30 || !knownNames.add(object.mainId)) continue;
      final (x, y) = wcs.worldToPixel(object.ra, object.dec);
      if (x >= 0 && x < analysis.width && y >= 0 && y < analysis.height) {
        clusters.add(
          SkyObject(
            object.mainId,
            object.ra,
            object.dec,
            object.objectType,
            x: x,
            y: y,
          ),
        );
      }
    }

    // 用认得出名字的亮星标定 Gaia G 零点，给出近似视星等和散布。
    final offsets = <double>[];
    final usedReferenceStars = <DetectedStar>{};
    for (final match in gaia) {
      final nearest = _nearest(analysis.stars, match.x, match.y);
      if (nearest != null &&
          nearest.distance <= 4 &&
          nearest.star.confidence >= 0.25 &&
          usedReferenceStars.add(nearest.star) &&
          match.gMagnitude >= 4 &&
          match.gMagnitude <= 18) {
        offsets.add(match.gMagnitude - nearest.star.instrumentalMagnitude);
      }
    }
    double? zeroPoint;
    double? scatter;
    if (offsets.length >= 5) {
      offsets.sort();
      zeroPoint = _median(offsets);
      final deviations =
          offsets.map((value) => (value - zeroPoint!).abs()).toList()..sort();
      scatter = 1.4826 * _median(deviations);
    }
    return _CrossMatch(named, clusters, zeroPoint, scatter);
  }

  static _CatalogObject? _nearestSimbadStar(
    double ra,
    double dec,
    List<_CatalogObject> stars,
  ) {
    _CatalogObject? nearest;
    var closestArcsec = 5.0;
    for (final star in stars) {
      final distance = angularSeparationDegrees(ra, dec, star.ra, star.dec) * 3600;
      if (distance < closestArcsec) {
        closestArcsec = distance;
        nearest = star;
      }
    }
    return nearest;
  }

  static ({DetectedStar star, double distance})? _nearest(
    List<DetectedStar> stars,
    double x,
    double y,
  ) {
    final candidates =
        stars.where((star) => !star.isElongated && star.confidence >= 0.15);
    if (candidates.isEmpty) return null;
    DetectedStar? best;
    var distance = double.infinity;
    for (final star in candidates) {
      final current =
          math.sqrt(math.pow(star.x - x, 2) + math.pow(star.y - y, 2));
      if (current < distance) {
        distance = current;
        best = star;
      }
    }
    return best == null ? null : (star: best, distance: distance);
  }

  static double _median(List<double> sorted) {
    final middle = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[middle]
        : (sorted[middle - 1] + sorted[middle]) / 2;
  }
}

class _CrossMatch {
  const _CrossMatch(this.named, this.deepSky, this.zeroPoint, this.scatter);

  final List<SkyObject> named;
  final List<SkyObject> deepSky;
  final double? zeroPoint;
  final double? scatter;
}

/// SIMBAD 返回的一行天体，otype 是目录里的天体类型代码。
class _CatalogObject {
  const _CatalogObject(this.mainId, this.ra, this.dec, this.objectType);

  final String mainId;
  final double ra;
  final double dec;
  final String objectType;

  bool get isStar => const [
        '*',
        'V*',
        'SB*',
        'EB*',
        'LM*',
        'Em*',
        'Y*O',
        'PM*',
        'WD*',
        'BY*',
        'RGB*',
        'HB*',
        'OH*',
      ].any(objectType.startsWith);

  bool get isDeepSky =>
      objectType == 'G' ||
      objectType.startsWith('Cl*') ||
      objectType.startsWith('ClG') ||
      objectType.startsWith('OpC') ||
      objectType.startsWith('GlC') ||
      objectType.startsWith('Neb') ||
      objectType.startsWith('HII') ||
      objectType.startsWith('SNR');
}

/// 解析一行 CSV，处理引号包裹和转义的双引号。
List<String> parseCsvRow(String line) {
  final fields = <String>[];
  final field = StringBuffer();
  var quoted = false;
  for (var i = 0; i < line.length; i++) {
    final character = line[i];
    if (character == '"') {
      if (quoted && i + 1 < line.length && line[i + 1] == '"') {
        field.write('"');
        i++;
      } else {
        quoted = !quoted;
      }
    } else if (character == ',' && !quoted) {
      fields.add(field.toString().trim());
      field.clear();
    } else {
      field.write(character);
    }
  }
  fields.add(field.toString().trim());
  return fields;
}
