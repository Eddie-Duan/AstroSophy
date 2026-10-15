import 'package:astrosophy/moon.dart';
import 'package:flutter_test/flutter_test.dart';

/// 月相算式。
///
/// 参照值是 JPL Horizons（DE441）打出来的**同一时刻**的地心视黄经照亮比例
/// （`Illu%`，quantity 10，中心为地心地球 500@399）。取这个量而不是黄经本身，
/// 有两个原因：
///
///   * 它是这条算式真正要产出的东西，别的都只是中间量；
///   * Horizons 的黄经是「视黄经」，含章动；本实现按第 48.4 式只算几何量，
///     两者差的正是章动那十几角秒。而**章动在太阳和月亮上几乎一样，做角距
///     时自己抵掉了**，所以照亮比例上不受它影响——拿它当参照不用再抄一份
///     章动表。
///
/// 复现命令见 docs/TECHNICAL.md 里的说明。
void main() {
  group('月相', () {
    // (UTC 时刻, Horizons Illu%)
    final reference = [
      (DateTime.utc(2000, 1, 1, 12, 0), 0.2300638),
      (DateTime.utc(2026, 9, 1, 0, 0), 0.8417700),
      (DateTime.utc(2026, 9, 18, 19, 0), 0.4945178),
    ];

    test('亮面占比对得上 JPL Horizons', () {
      for (final (moment, expected) in reference) {
        final phase = moonPhaseAt(moment);
        // 48.4 自身的精度是「小数点后第二位」，这里留 0.006 的余量：
        // 再紧就会把公式的固有误差当成回归来报。
        expect(
          phase.illuminatedFraction,
          closeTo(expected, 0.006),
          reason: '$moment',
        );
      }
    });

    test('边界：新月附近接近 0，满月附近接近 1', () {
      // 2026-09-11 前后的新月、2026-09-26 前后的满月（同一条朔望月）。
      expect(moonPhaseAt(DateTime.utc(2026, 9, 11, 3, 30)).illuminatedFraction,
          lessThan(0.02));
      expect(moonPhaseAt(DateTime.utc(2026, 9, 26, 12, 0)).illuminatedFraction,
          greaterThan(0.98));
    });

    test('盈亏方向与亮面占比的走向一致', () {
      // 这条不依赖任何外部数值，只用算式自己的一致性：相隔一天的两点，盈的
      // 时候占比在涨、亏的时候在跌。新月和满月附近变化太小，跳过。
      var moment = DateTime.utc(2026, 8, 20);
      var checked = 0;
      for (var day = 0; day < 40; day++) {
        final today = moonPhaseAt(moment);
        final tomorrow = moonPhaseAt(moment.add(const Duration(days: 1)));
        final k = today.illuminatedFraction;
        if (k > 0.08 && k < 0.92) {
          expect(
            tomorrow.illuminatedFraction > k,
            today.waxing,
            reason: '$moment：占比 $k → ${tomorrow.illuminatedFraction}，'
                '盈亏标记是 ${today.waxing}',
          );
          checked++;
        }
        moment = moment.add(const Duration(days: 1));
      }
      expect(checked, greaterThan(20), reason: '大部分日子都该落在可比的区间里');
    });

    test('盈是上弦、亏是下弦——同一个 k 两个名字', () {
      // 上面那条参照里 2026-09-18 是上弦（k≈0.49，盈）。
      expect(moonPhaseAt(DateTime.utc(2026, 9, 18, 19, 0)).name, '上弦月');
      // 2026-09-01 是满月过后几天（k≈0.84，亏）。
      final waning = moonPhaseAt(DateTime.utc(2026, 9, 1, 0, 0));
      expect(waning.waxing, isFalse);
      expect(waning.name, '亏凸月');
    });

    test('百分数写法四舍五入', () {
      expect(moonPhaseAt(DateTime.utc(2026, 9, 1, 0, 0)).fractionLabel, '84%');
    });
  });
}
