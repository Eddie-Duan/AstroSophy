import 'package:astrosophy/deepsky_names.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('深空天体昵称', () {
    test('编号怎么写的都能查到', () {
      // 目录里写 `M 31`，用户和别的星表可能写 `M31`；NGC 也是。同一个东西
      // 不该因为多一个空格就查不到。
      for (final spelling in ['M 45', 'M45', 'm 45', 'M-45']) {
        expect(nicknameOf(spelling), '昴星团', reason: spelling);
      }
      for (final spelling in ['NGC 2237', 'NGC2237', 'ngc_2237']) {
        expect(nicknameOf(spelling), '玫瑰星云', reason: spelling);
      }
      expect(nicknameOf('IC 434'), '马头星云');
    });

    test('收的是常用名，不是类型名', () {
      // 这一条是在钉住这张表的**性质**：里面装的应该是「蟹状星云」这类口头
      // 名字，而不是「行星状星云」「疏散星团」这种类型名。类型名另有
      // describeDeepSkyType，两者混在一起，报告里就会出现
      // 「NGC 6543 行星状星云」这种把编号和类型名并排的废话。
      const typeNames = {
        '行星状星云',
        '疏散星团',
        '球状星团',
        '星系',
        '星云',
        '超新星遗迹',
      };
      for (final designation in [
        'M 1', 'M 6', 'M 13', 'M 31', 'M 42', 'M 45', 'M 57',
        'NGC 104', 'NGC 5139', 'NGC 7293',
      ]) {
        final nickname = nicknameOf(designation);
        expect(nickname, isNotNull, reason: designation);
        expect(typeNames.contains(nickname), isFalse,
            reason: '$designation 查到的「$nickname」是类型名，不是昵称');
      }
    });

    test('同一片星云的不同部分各是各的名字', () {
      // 面纱星云是超新星遗迹，东西两弧在目录里是两个编号，中文里也是两个
      // 名字。全都报「面纱星云」等于把「你拍到的是哪一块」这个信息抹掉了。
      expect(nicknameOf('NGC 6960'), '西面纱星云');
      expect(nicknameOf('NGC 6992'), '东面纱星云');
      expect(nicknameOf('NGC 6960'),
          isNot(nicknameOf('NGC 6992')));
    });

    test('界面上只有一个地方决定这个天体怎么写', () {
      // 曾经真的出现过两张脸：报告里写「M 16 鹰状星云」，图上的标注却是
      // 「M 16 · 星团与星云」。根子是那句话在四个地方各写了一遍。现在四处
      // 都调 deepSkyCaption，所以只要它对了，到处都是对的。
      expect(deepSkyCaption('M 16', '星团与星云'), 'M 16 鹰状星云');
      expect(deepSkyCaption('M 45', '疏散星团'), 'M 45 昴星团');
      expect(deepSkyCaption('NGC 6960', '超新星遗迹'), 'NGC 6960 西面纱星云');
      // 没收录的才退回「编号 · 类型」。
      expect(deepSkyCaption('NGC 9999', '星系'), 'NGC 9999 · 星系');
      // 类型缺失时不留一个孤零零的分隔符。
      expect(deepSkyCaption('NGC 9999', ''), 'NGC 9999');
    });

    test('名字里已经带昵称时不再拼一遍', () {
      expect(deepSkyCaption('M 16 鹰状星云', '星团与星云'), 'M 16 鹰状星云');
    });

    test('没收录的编号不给编一个名字', () {
      // 硬译一个出来是最坏的结果：用户会拿它当事实去搜，然后什么也搜不到。
      expect(nicknameOf('NGC 9999'), isNull);
      expect(nicknameOf('2MASS J12345678+1234567'), isNull);
      expect(nicknameOf(''), isNull);
      expect(nicknameOf('   '), isNull);
    });

    test('标签是「编号 昵称」，没昵称时就是编号', () {
      expect(deepSkyLabel('M 45'), 'M 45 昴星团');
      expect(deepSkyLabel('NGC 6960'), 'NGC 6960 西面纱星云');
      expect(deepSkyLabel('NGC 9999'), 'NGC 9999');
    });

    test('已经带昵称的名字不会再拼一遍', () {
      // 在线星表回来的名字有可能已经写成这样，再拼一次就是
      // 「M 45 昴星团 昴星团」；而 deepSkyCaption 还要拿它去查表，查不到
      // 就会退回「编号 · 类型」，变成「M 16 鹰状星云 · 星团与星云」。
      expect(deepSkyLabel('M 45 昴星团'), 'M 45 昴星团');
      expect(deepSkyCaption('M 16 鹰状星云', '星团与星云'), 'M 16 鹰状星云');
    });
  });
}
