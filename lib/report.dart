import 'analysis.dart';
import 'models.dart';

/// 交给模型的测量摘要。
///
/// 这是模型唯一能看到的东西——原始照片不上传，模型只拿这份结构化的测量
/// 结果说话。所以字段要写成「测量值 + 它有多可信」，而不是一句结论：模型
/// 拿得到散布、内点数这类信息，才能自己判断哪些数字不值得当真。
Map<String, Object?> buildAgentReport(SkyAnalysis analysis, SolveResult? solve) => {
      'quality': analysis.quality,
      'detected_stars': analysis.compactSources.length,
      'detected_sources': analysis.stars.length,
      'compact_sources': analysis.compactSources.length,
      'elongated_candidates': analysis.streakCandidates.length,
      'noise_fraction': analysis.noise,
      'background_visual_index': analysis.backgroundIndex,
      'psf_fwhm_pixels': analysis.fwhm,
      'non_star_fraction': analysis.nonStarFraction,
      'is_likely_starfield': analysis.isLikelyStarfield,
      'starfield_confidence': analysis.starfieldConfidence,
      'diagnostics': analysis.diagnostics,
      'solved': solve != null,
      // 解算是本机算的还是在线算的，直接关系到结果能不能离线和速率上限。
      'solve_source': switch (solve?.source) {
        SolveSource.local => 'local_offline',
        SolveSource.online => 'astrometry_net',
        null => null,
      },
      'center_ra_deg': solve?.centerRa,
      'center_dec_deg': solve?.centerDec,
      'arcsec_per_pixel': solve?.arcsecPerPixel,
      'field_of_view_deg': solve?.fieldOfViewDegrees,
      'rotation_deg': solve?.rotationDegrees,
      'matched_star_count': solve?.matchedCount,
      // 本地解算能直接给出星座归属；在线解算要等 SIMBAD 回来才知道。
      'constellations': solve?.constellations,
      'catalog_stars': solve?.namedStars
          .map(
            (object) => {
              'name': object.name,
              'catalog_type': object.category,
              'ra_deg': object.ra,
              'dec_deg': object.dec,
              'gaia_g_magnitude': object.magnitude,
              'catalog': object.isLocal ? 'hipparcos_local' : 'gaia_dr3',
            },
          )
          .toList(),
      'deep_sky_objects': solve?.deepSkyObjects
          .map(
            (object) => {
              'name': object.name,
              'catalog_type': object.category,
              'ra_deg': object.ra,
              'dec_deg': object.dec,
            },
          )
          .toList(),
      'catalog_warning': solve?.catalogWarning,
      'magnitude_zero_point': solve?.magnitudeZeroPoint,
      'photometry_scatter_mag': solve?.magnitudeScatter,
    };
