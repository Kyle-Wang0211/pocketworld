import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 2026-09-10 用户令:**拍摄期唯一的退出方式是左上角的返回图标。**
/// 此前 `canPop: _sfmPhase == null` —— 只在重建期挡住隐式 pop,拍摄期仍然
/// 放行 iOS 边缘右滑,一次误触就把整条采集 route pop 掉(采集中的会话最怕
/// 这个)。
///
/// 判据钉两件事,缺一不可:
///   ① 隐式返回手势被吞掉(canPop 恒为 false);
///   ② 显式退出这条路还在 —— `_exitToDrafts` 里的 `Navigator.of(context).pop`
///      不受 canPop 影响,把它一起删掉就"退不出去了"。
void main() {
  final page = File('lib/ui/official_capture/ar_capture_page.dart');

  late String code;

  setUpAll(() {
    expect(page.existsSync(), isTrue, reason: '采集页源码不在,契约无从谈起');
    code = page
        .readAsStringSync()
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');
  });

  test('① 隐式返回手势被吞掉:canPop 恒为 false', () {
    expect(code.contains('canPop: false'), isTrue, reason: '拍摄期右滑必须退不出去');
    expect(
      code.contains('canPop: _sfmPhase == null'),
      isFalse,
      reason: '这是旧写法 —— 它只挡重建期,拍摄期照样能右滑退出',
    );
  });

  test('② 显式退出这条路还在(阳性对照:别把人关在里面)', () {
    expect(
      code.contains('void _exitToDrafts()'),
      isTrue,
      reason: '左上角返回图标走的就是它',
    );
    expect(
      code.contains('Navigator.of(context).pop(true)'),
      isTrue,
      reason: '显式 pop 不受 canPop 影响;删了它拍摄页就真的出不去了',
    );
  });

  test('③ 重建期的语义没被改坏:手势折叠成「显示草稿」', () {
    expect(
      code.contains('_showDraftsDuringReconstruction()'),
      isTrue,
      reason:
          '重建进行中返回不得销毁 capture route / SfM worker,'
          '要折叠成显示草稿(见该函数处的根因注释)',
    );
  });
}
