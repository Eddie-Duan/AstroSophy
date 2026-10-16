import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:astrosophy/analysis.dart';
import 'package:flutter_test/flutter_test.dart';

/// 临时探针：把一次分析的全部检出结果和掩膜区域导出成 JSON，
/// 好在 Python 里画对比图，并看清「亮星是被谁吃掉的」。
void main() {
  test('dump', () {
    final source = Platform.environment['PROBE_IMAGE'];
    final output = Platform.environment['PROBE_OUT'];
    if (source == null || output == null) return;
    final analysis = SkyAnalysis.analyze(
      Uint8List.fromList(File(source).readAsBytesSync()),
    );

    void write(String name, Object? json) => File('$output/$name').writeAsStringSync(
          const JsonEncoder().convert(json),
        );

    write('analysis.json', {
      'width': analysis.width,
      'height': analysis.height,
      'fwhm': analysis.fwhm,
      'nonStarFraction': analysis.nonStarFraction,
      'saturatedFraction': analysis.saturatedFraction,
      'brightFlatFraction': analysis.brightFlatFraction,
      'quality': analysis.quality,
      'isLikelyStarfield': analysis.isLikelyStarfield,
      'diagnostics': analysis.diagnostics,
      'starCount': analysis.stars.length,
      'elongatedCount': analysis.stars.where((s) => s.isElongated).length,
      'compactCount': analysis.compactSources.length,
      'solverCandidates': analysis.solveCandidates.length,
      'streakCount': analysis.streakCandidates.length,
      'stars': [
        for (final star in analysis.stars)
          {
            'x': star.x,
            'y': star.y,
            'flux': star.flux,
            'fwhm': star.fwhm,
            'axisRatio': star.axisRatio,
            'confidence': star.confidence,
            'mag': star.instrumentalMagnitude,
          },
      ],
      'maskRegions': [
        for (final region in analysis.maskRegions)
          {
            'x': region.x,
            'y': region.y,
            'w': region.width,
            'h': region.height,
            'kind': region.kind.name,
          },
      ],
      'rejectedLarge': const <Object>[],
    });
  }, timeout: const Timeout(Duration(minutes: 10)));
}
