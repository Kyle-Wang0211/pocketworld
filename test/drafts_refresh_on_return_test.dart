// 拍摄/查看返回草稿页必须重算胶囊(源码钉子)。
//
// [2026-08-10 用户实机指认,复发多次] "拍摄完成后在等待页看到点云,回到草稿页
// 卡片是'未完成',必须再点进一次 3D viewer 再退出才变'完成'。"
// 定罪:pop 之后草稿页没有任何 build —— 屏幕停在 finalize 开始时(PLY 未写)
// 的红胶囊;信号回调"已在草稿页"早退不 setState;根草稿页拿不到
// activeReconstructionCaptureDir ⇒ 轮询不开 ⇒ 无自愈;点卡片的
// markResultViewed 是唯一会 _emit 的动作(所以"点一次才变")。
// 修:①信号无条件刷;②查看器返回也刷(与续跑路径同纪律)。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final src = File('lib/ui/me_page.dart').readAsStringSync();

  test('_showDraftsFromSignal:已在草稿页也必须空刷,不许早退', () {
    expect(
      RegExp(r'if \(!mounted \|\| !_showProjects\) return;').hasMatch(src),
      isFalse,
      reason:
          '信号回调回到了"已在草稿页就早退"的旧写法 ⇒ 拍完返回不重算胶囊,'
          '红色"未完成"冻结在屏幕上(用户复发多次的 bug)',
    );
    // 早退去掉后必须存在"else 空刷"分支。
    expect(src.contains('setState(() {});'), isTrue, reason: '信号到来时缺少空刷分支');
  });

  test('_openSparseCloud:查看器返回后必须重算(与续跑路径同纪律)', () {
    final fn = src.substring(
      src.indexOf('Future<void> _openSparseCloud'),
      src.indexOf('Future<String?> _resolveRecoverableCaptureDir'),
    );
    expect(
      fn.contains('if (mounted) setState(() {});'),
      isTrue,
      reason:
          '查看器返回后的重算被删了 ⇒ markResultViewed 之后的状态'
          '(胶囊消失/转绿)要等下一次偶然 build 才生效',
    );
  });
}
