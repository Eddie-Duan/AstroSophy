import 'dart:math' as math;

import 'models.dart';

/// 一对「像面像素 → 天球坐标」的对应关系。
///
/// 只在这个文件里用，字段名和 [Wcs.worldToPixel] 的入参顺序保持一致。
class SipMatch {
  const SipMatch(this.x, this.y, this.ra, this.dec);

  final double x;
  final double y;
  final double ra;
  final double dec;
}

/// 拟合出来的曲率与它的质量。
class SipFitResult {
  const SipFitResult({
    required this.wcs,
    required this.inliers,
    required this.rms,
  });

  /// 带 SIP 项的坐标。
  final Wcs wcs;

  /// 残差在容差内的对应关系数量。
  final int inliers;

  /// 内点的均方根残差（像素）。
  final double rms;
}

/// 用一组对应关系拟合 SIP 曲率（二阶或三阶），CRVAL/CRPIX/CD 保持不变。
///
/// 推导很短：SIP 说像素修正后的坐标是
///
///     u' = u + A(u, v),   v' = v + B(u, v),   u = x + 1 - crpix1
///
/// 而目录星给出的切平面坐标 `(xi, eta)` 反算出的「理想像素偏移」是
/// `(u0, v0) = CD⁻¹·(xi, eta)`。真对应关系满足 `u0 = u'`、`v0 = v'`，
/// 于是 `A(u,v) = u0 - u`、`B(u,v) = v0 - v`——对 `u,v` 的二次/三次项
/// 做普通最小二乘即可，不需要非线性优化。
///
/// 迭代若干轮、每轮丢掉残差超过 `3σ` 的对应关系（星点错配、卫星线、噪点），
/// 最后按 [inlierTolerancePixels] 返回内点数和 RMS。
SipFitResult? fitSipDistortion(
  Wcs base,
  List<SipMatch> matches, {
  int order = 2,
  int iterations = 4,
  double inlierTolerancePixels = 3.0,
}) {
  if (matches.length < 10) return null;
  final plain = base.withoutSip;
  final determinant = plain.determinant;
  if (determinant.abs() < 1e-12) return null;

  // 要拟合的项：二次项 (2,0),(1,1),(0,2)；三阶再加四项。
  final terms = <(int, int)>[];
  for (var total = 2; total <= order; total++) {
    for (var p = 0; p <= total; p++) {
      terms.add((p, total - p));
    }
  }

  // 把每个对应关系换算成 (u, v) → (du, dv) 的样本。
  final samples = <({double u, double v, double du, double dv})>[];
  for (final match in matches) {
    final (xi, eta) = _tangentPlane(
      match.ra,
      match.dec,
      plain.crval1,
      plain.crval2,
    );
    if (!xi.isFinite || !eta.isFinite) continue;
    final uIdeal = (plain.cd22 * xi - plain.cd12 * eta) / determinant;
    final vIdeal = (-plain.cd21 * xi + plain.cd11 * eta) / determinant;
    final u = match.x + 1 - plain.crpix1;
    final v = match.y + 1 - plain.crpix2;
    samples.add((u: u, v: v, du: uIdeal - u, dv: vIdeal - v));
  }
  if (samples.length < 10) return null;

  var active = List<int>.generate(samples.length, (index) => index);
  List<double>? coefficientsA;
  List<double>? coefficientsB;
  for (var iteration = 0; iteration < iterations; iteration++) {
    final solution = _fitBothAxes(samples, active, terms);
    if (solution == null) return null;
    coefficientsA = solution.$1;
    coefficientsB = solution.$2;
    final residuals = <double>[];
    for (final index in active) {
      final sample = samples[index];
      residuals.add(
        math.sqrt(
          math.pow(_evaluate(terms, coefficientsA, sample.u, sample.v) -
                  sample.du, 2) +
              math.pow(_evaluate(terms, coefficientsB, sample.u, sample.v) -
                  sample.dv, 2),
        ),
      );
    }
    final rms = math.sqrt(
      residuals.fold<double>(0, (sum, value) => sum + value * value) /
          residuals.length,
    );
    final cutoff = math.max(1.5, 3.0 * rms);
    final kept = <int>[
      for (var i = 0; i < active.length; i++)
        if (residuals[i] <= cutoff) active[i],
    ];
    if (kept.length < 10 || kept.length == active.length) break;
    active = kept;
  }
  if (coefficientsA == null || coefficientsB == null) return null;

  final a = <(int, int), double>{
    for (var i = 0; i < terms.length; i++) terms[i]: coefficientsA[i],
  };
  final b = <(int, int), double>{
    for (var i = 0; i < terms.length; i++) terms[i]: coefficientsB[i],
  };
  final wcs = plain.withSip(a: a, b: b);

  // 内点：用拟合出来的 SIP 反算一遍残差。
  var inliers = 0;
  var sumSquares = 0.0;
  for (final sample in samples) {
    final residual = math.sqrt(
      math.pow(_evaluate(terms, coefficientsA, sample.u, sample.v) -
              sample.du, 2) +
          math.pow(_evaluate(terms, coefficientsB, sample.u, sample.v) -
              sample.dv, 2),
    );
    if (residual <= inlierTolerancePixels) {
      inliers++;
      sumSquares += residual * residual;
    }
  }
  if (inliers == 0) return null;
  return SipFitResult(
    wcs: wcs,
    inliers: inliers,
    rms: math.sqrt(sumSquares / inliers),
  );
}

/// 两组系数各自做最小二乘，共用同一套样本下标。
(List<double>, List<double>)? _fitBothAxes(
  List<({double u, double v, double du, double dv})> samples,
  List<int> active,
  List<(int, int)> terms,
) {
  final m = terms.length;
  final normal = List.generate(m, (_) => List<double>.filled(m, 0.0));
  final rhsA = List<double>.filled(m, 0.0);
  final rhsB = List<double>.filled(m, 0.0);
  for (final index in active) {
    final sample = samples[index];
    final basis = <double>[
      for (final term in terms)
        (math.pow(sample.u, term.$1) * math.pow(sample.v, term.$2)).toDouble(),
    ];
    for (var i = 0; i < m; i++) {
      for (var j = 0; j < m; j++) {
        normal[i][j] += basis[i] * basis[j];
      }
      rhsA[i] += basis[i] * sample.du;
      rhsB[i] += basis[i] * sample.dv;
    }
  }
  final solutionA = _solveLinear(normal, rhsA);
  final solutionB = _solveLinear(normal, rhsB);
  if (solutionA == null || solutionB == null) return null;
  return (solutionA, solutionB);
}

double _evaluate(
  List<(int, int)> terms,
  List<double> coefficients,
  double u,
  double v,
) {
  var sum = 0.0;
  for (var i = 0; i < terms.length; i++) {
    sum += coefficients[i] *
        math.pow(u, terms[i].$1) *
        math.pow(v, terms[i].$2);
  }
  return sum;
}

/// 高斯消元，带部分主元。矩阵很小（最多 7×7），不值得引第三方库。
List<double>? _solveLinear(List<List<double>> matrix, List<double> rhs) {
  final n = rhs.length;
  final a = [
    for (var i = 0; i < n; i++) [...matrix[i], rhs[i]],
  ];
  for (var column = 0; column < n; column++) {
    var pivot = column;
    for (var row = column + 1; row < n; row++) {
      if (a[row][column].abs() > a[pivot][column].abs()) pivot = row;
    }
    if (a[pivot][column].abs() < 1e-18) return null;
    if (pivot != column) {
      final swap = a[pivot];
      a[pivot] = a[column];
      a[column] = swap;
    }
    final diagonal = a[column][column];
    for (var row = column + 1; row < n; row++) {
      final factor = a[row][column] / diagonal;
      if (factor == 0) continue;
      for (var k = column; k <= n; k++) {
        a[row][k] -= factor * a[column][k];
      }
    }
  }
  final result = List<double>.filled(n, 0);
  for (var row = n - 1; row >= 0; row--) {
    var sum = a[row][n];
    for (var k = row + 1; k < n; k++) {
      sum -= a[row][k] * result[k];
    }
    result[row] = sum / a[row][row];
  }
  return result;
}

/// 赤道坐标 → 以 `(ra0, dec0)` 为切点的切平面坐标（度）。
(double, double) _tangentPlane(double ra, double dec, double ra0, double dec0) {
  const radians = math.pi / 180;
  final raRad = ra * radians;
  final decRad = dec * radians;
  final ra0Rad = ra0 * radians;
  final dec0Rad = dec0 * radians;
  var deltaRa = raRad - ra0Rad;
  while (deltaRa > math.pi) {
    deltaRa -= 2 * math.pi;
  }
  while (deltaRa < -math.pi) {
    deltaRa += 2 * math.pi;
  }
  final denominator = math.sin(dec0Rad) * math.sin(decRad) +
      math.cos(dec0Rad) * math.cos(decRad) * math.cos(deltaRa);
  if (denominator <= 1e-9) return (double.nan, double.nan);
  final xi = math.cos(decRad) * math.sin(deltaRa) / denominator / radians;
  final eta = (math.cos(dec0Rad) * math.sin(decRad) -
          math.sin(dec0Rad) * math.cos(decRad) * math.cos(deltaRa)) /
      denominator /
      radians;
  return (xi, eta);
}
