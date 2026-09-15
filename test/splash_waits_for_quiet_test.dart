// 开门这件事,必须由「UI 线程真的安静下来了」决定,而不是由「到点了」决定。
//
// 🔴 [2026-09-15 用户令]「我可以允许多等几秒,但是不能有卡顿」。
// 155 的实测账(真机两次冷启动):
//   • 温启动:开门中途 @+1774ms 一帧 build=14.1ms;
//   • 冷启动:门刚开完 @+4693ms 一帧 build=11.1ms;
//     且 +2293→+2944ms **一帧都没有**(平台线程被 _requestTexture 整段堵住)。
//   • disableAnimations=false —— "减弱动态效果"这条解释已被实测排除。
// 结论:动画那 1290ms 只要撞上壳的活就会顿。所以判据改成"等它干完"。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String code;

  setUpAll(() {
    // 判据必须先剥注释 —— 本文件上面这段解释里就写着这些标识符。
    code = File('lib/main.dart')
        .readAsStringSync()
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');
  });

  test('锚点自身可读(阳性对照)', () {
    expect(code.contains('_splashVisibleFor'), isTrue, reason: '判定函数改名了 —— 先修锚');
    expect(File('lib/ui/frame_quiet_detector.dart').existsSync(), isTrue);
  });

  test('🔴 安静是开门的前置条件之一', () {
    expect(code.contains('if (!_uiQuiet) return true;'), isTrue,
        reason: '少了这一条,开门又会由定时器决定,等于回到 154');
    expect(code.contains('FrameQuietWatcher('), isTrue);
  });

  test('🔴 预算按实际刷新率取,不许写死 60Hz', () {
    expect(code.contains('View.of(context).display.refreshRate'), isTrue);
    expect(code.contains('frameBudgetFor('), isTrue);
    expect(
      code.contains('16667') || code.contains('16.7'),
      isFalse,
      reason: '写死 60Hz 的预算会把 120Hz 上 8.3–16.7ms 的掉帧全判成"没超"',
    );
  });

  test('🔴 等不到安静必须有上限(不许再造一个静默出口)', () {
    expect(code.contains('_quietDeadlineMs'), isTrue);
    expect(code.contains('deadline:'), isTrue);
    expect(code.contains('_splashForceHidden'), isTrue, reason: '绝对兜底也要留着');
  });

  test('🔴 那张从不显示的纹理必须等动画放完再建', () {
    expect(
      code.contains('StartupSplashGate.instance.whenDone.then'),
      isTrue,
      reason: '_requestTexture 冷启动时把平台线程堵了 651ms,球当场僵住;'
          '它建出来的纹理出货 UI 一帧都不显示,没有任何理由抢在动画前面跑',
    );
    final at = code.indexOf('_requestTexture();');
    expect(at, greaterThanOrEqualTo(0));
    final before = code.substring(0, at);
    expect(
      before.lastIndexOf('whenDone') > before.lastIndexOf('void initState'),
      isTrue,
      reason: '调用点必须在 whenDone 的回调里,不能又回到 initState 直接调',
    );
  });
}
