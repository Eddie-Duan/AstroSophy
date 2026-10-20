import 'dart:math' as math;
import 'dart:typed_data';

import 'package:astrosophy/analysis.dart';
import 'package:astrosophy/models.dart';
import 'package:astrosophy/star_trails.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('星轨方向法线能拟合出极心', () {
    const cx = 500.0;
    const cy = 400.0;
    final stars = <DetectedStar>[];
    for (var i = 0; i < 8; i++) {
      final angle = i * math.pi / 4;
      final radius = 180.0;
      stars.add(
        DetectedStar(
          cx + radius * math.cos(angle),
          cy + radius * math.sin(angle),
          1000,
          8,
          0.9,
          5,
          fwhm: 2,
          orientation: angle + math.pi / 2,
        ),
      );
    }
    final analysis = SkyAnalysis(
      width: 1200,
      height: 900,
      stars: stars,
      quality: '良好',
      background: 0.05,
      noise: 0.02,
      backgroundIndex: 5,
      saturatedFraction: 0,
      diagnostics: const [],
      preview: Uint8List(0),
      processedPreview: Uint8List(0),
      fwhm: 2,
      nonStarFraction: 0,
      maskRegions: const [],
      isLikelyStarfield: true,
      starfieldConfidence: 0.9,
      brightFlatFraction: 0,
    );
    final stats = analyzeStarTrails(analysis);
    expect(stats, isNotNull);
    expect(stats!.centerX, closeTo(cx, 25));
    expect(stats.centerY, closeTo(cy, 25));
    expect(stats.count, 8);
  });
}
