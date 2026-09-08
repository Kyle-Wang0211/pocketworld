// 作品页长按菜单的接线契约。
//
// train_gate_test.dart 证的是判定本身对;这里证的是判定**真的接在菜单上** ——
// 纯函数写对了但没人调用,是本项目反复出现过的失败形态。
//
// 断言只打在**代码**上,不打在注释上:注释里出现 "20" 或 "开始训练" 一律不算
// 数(判据不能匹配自己刚写的注释,08-22 教训)。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final raw = File('lib/ui/me_page.dart').readAsStringSync();

  /// 去掉整行注释与行尾注释后的源码 —— 所有断言都跑在这上面。
  final code = raw
      .split('\n')
      .map((line) {
        final i = line.indexOf('//');
        return i < 0 ? line : line.substring(0, i);
      })
      .join('\n');

  test('长按菜单四栏:开始训练 / 拍摄更多照片 / 改名 / 删除', () {
    expect(code, contains("'开始训练'"));
    expect(code, contains("Text('拍摄更多照片')"));
    expect(code, contains('l.meActionRename'));
    expect(code, contains('l.meActionDelete'));
  });

  test('张数闸真的接上了,而且是同源调用不是复制阈值', () {
    // [阴性对照 2026-09-07] 第一版只断言源码里出现过 trainGateFor( ——
    // 结果把 `trainGate = TrainGate.ready` 硬塞进去、把真调用改名成
    // unusedGate,测试照样全绿。绕过闸的最省事改法恰恰保留那个字符串。
    // 所以断言必须打在**赋值链**上:trainGate 只能来自 trainGateFor,
    // trainEnabled 只能来自 trainGate。
    expect(code, contains('final trainGate = trainGateFor('));
    expect(code, contains('final trainEnabled = trainGate == TrainGate.ready'));
    // 且全文件只有这一处 trainGate 的赋值,不许有第二个来源。
    // `=(?!=)` 才是赋值 —— 不加负向前瞻会把 `trainGate == TrainGate.ready`
    // 里的比较也数进去。
    expect(RegExp(r'trainGate\s*=(?!=)').allMatches(code).length, 1);
    expect(RegExp(r'trainEnabled\s*=(?!=)').allMatches(code).length, 1);
    expect(code, contains('photoCount: photoCount'));
    expect(code, contains('hasResumableData: rebuildDir != null'));
    // 阈值只能来自 live_sfm_publish_policy.dart。me_page 自己写死 20 就是
    // 制造第二个真相 —— 将来改阈值必漏一边。
    expect(code, isNot(contains('>= 20')));
    expect(code, isNot(contains('< 20')));
    expect(code, isNot(contains('20;')));
  });

  test('张数以磁盘为准,不用保存时的快照', () {
    expect(code, contains('_countCapturePhotos('));
    expect(code, contains('record.photosDir'));
    // photoCount 只许当兜底(?? 后面),不许当主判据。
    expect(code, isNot(contains('photoCount: record.photoCount')));
  });

  test('置灰项仍然可点,并且点了必须有回答', () {
    // onTap 不能是 null —— 置灰但不可点 = 用户永远问不出为什么。
    expect(code, contains("'train_blocked'"));
    expect(code, contains("action == 'train_blocked'"));
    expect(code, contains('_showCenterToast('));
    expect(code, contains('_trainBlockedReason('));
  });

  test('提示落在屏幕正中、3 秒后自己消失', () {
    final start = code.indexOf('void _showCenterToast(');
    expect(start, greaterThanOrEqualTo(0));
    final body = code.substring(start, start + 1400);
    expect(body, contains('OverlayEntry('));
    expect(body, contains('Center('));
    expect(body, contains('Duration(seconds: 3)'));
    expect(body, contains('entry.remove()'));
    // SnackBar 贴底会被 tab bar 压住,这条提示必须在视线中心。
    expect(body, isNot(contains('SnackBar')));
  });

  test('「拍摄更多照片」接的是真动作,不是 toast 占位', () {
    expect(code, contains("action == 'capture_more'"));
    final start = code.indexOf("action == 'capture_more'");
    final body = code.substring(start, start + 1200);
    // 必须真的调补拍路由 —— 这条是本功能的心脏,只断言"有个 toast"会让
    // 把真动作换回占位提示的改法照样绿(第一版张数闸就是这样被变异骗过的)。
    expect(body, contains('extendRoute('));
    expect(body, contains('widget.officialExtendRoute'));
    // 四个不可用分支各自说原因,一个都不许吞。
    expect(body, contains('CapturePipelineKind.official'));
    expect(body, contains('activeReconstructionCaptureDir != null'));
    expect(body, contains('rebuildDir == null'));
    expect(
      RegExp(r'_showCenterToast\(').allMatches(body).length,
      greaterThanOrEqualTo(4),
    );
    // 补完照片要刷新卡片,否则用户看不到张数变化、闸也不会解灰。
    expect(body, contains('setState(() {})'));
  });

  test('补拍路由真的从 app_shell 注入到长按菜单', () {
    final shell = File('lib/ui/app_shell.dart').readAsStringSync();
    expect(shell, contains('officialExtendRoute: pushOfficialExtendRoute'));
    // MePage -> _MyWorksSection 的透传断了,菜单里就永远是 null。
    expect(code, contains('officialExtendRoute: widget.officialExtendRoute'));
  });

  test('采集会话复用目录时绝不删,且编号接着排', () {
    final sess = File(
      'lib/official_capture/capture_session.dart',
    ).readAsStringSync();
    final sessCode = sess
        .split('\n')
        .map((line) {
          final i = line.indexOf('//');
          return i < 0 ? line : line.substring(0, i);
        })
        .join('\n');
    expect(sessCode, contains('String? extendCaptureDir'));
    // 复用分支里出现 delete = 直接毁掉用户上一次拍摄的全部照片和 db。
    // 只圈**复用**分支本身:到 `} else {` 为止。把 else 分支(新建时那句合法的
    // delete)圈进来,断言就会永远红 —— 判据划错边界和判据本身写错一样坏。
    final extStart = sessCode.indexOf('if (extending) {');
    expect(extStart, greaterThanOrEqualTo(0));
    final extEnd = sessCode.indexOf('} else {', extStart);
    expect(extEnd, greaterThan(extStart));
    final extBlock = sessCode.substring(extStart, extEnd);
    expect(extBlock, isNot(contains('delete(')));
    // 编号必须接上,归零会让新照片与老照片同名覆盖(cap47 16% 色彩污染)。
    expect(sessCode, contains('_frameSeq = maxFrameSeqInNames('));
  });
}
