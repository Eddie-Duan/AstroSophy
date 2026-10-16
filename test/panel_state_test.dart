import 'package:astrosophy/main.dart';
import 'package:flutter_test/flutter_test.dart';

/// 结果页列表「一进来先展开哪一组」的默认值。
///
/// 这是用户打开结果页看到的第一眼，判错了就是一片空白——而一片空白和「这张
/// 图什么都没算出来」长得一模一样。
void main() {
  group('结果页列表的初始展开状态', () {
    test('画面里有深空天体时，只展开深空天体', () {
      final collapsed = initialCollapsedGroups(deepSkyObjectCount: 3);
      // 「深空天体」这一组的 id 是 'deepSky'，不在收起名单里它就默认展开。
      expect(collapsed, isNot(contains('deepSky')));
      // 星点动辄几十项，一上来全展开会把主角淹掉。
      expect(collapsed, contains('named'));
      expect(collapsed, contains('unnamed'));
      expect(collapsed, contains('streaks'));
    });

    test('画面里没有深空天体时，展开亮星组', () {
      final collapsed = initialCollapsedGroups(deepSkyObjectCount: 0);
      // 这时候列表里只剩星点，再全收起来，用户看到的就是一片空白加三个
      // 折叠条，像是什么都没算出来。
      expect(collapsed, isNot(contains('named')));
      expect(collapsed, contains('unnamed'));
      expect(collapsed, contains('streaks'));
    });

    test('收起的那几组就是列表里那三组，没有拼错的名字', () {
      final collapsed = initialCollapsedGroups(deepSkyObjectCount: 0);
      expect(collapsed.difference(groupIds.toSet()), isEmpty);
    });
  });
}
