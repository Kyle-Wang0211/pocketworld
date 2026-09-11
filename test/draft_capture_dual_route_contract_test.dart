// 重建期那张**临时**作品页的契约。
//
// [2026-09-11 用户令]"直接删除这个 icon" —— 原来这张页套着 DraftCaptureShell
// (右下角黑色 "+" FAB)。那套壳来自早已退役的 MeRootPage;现役真作品页用的是
// 底部导航栏。build 142 把这张临时页钉成常驻页之后,用户一眼认出"这 UI 不是
// 早就删了吗"。FAB 与整个 DraftCaptureShell 已从仓库删除。
//
// 重建期本来也不允许再起一次采集(原生 SfM 会话进程唯一),所以这张页根本
// 不该有拍摄入口 —— 判据从"必须有 FAB"翻成"必须没有任何拍摄入口"。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const path = 'lib/ui/official_capture/ar_capture_page.dart';

  /// 🔴 判据必须先剥注释 —— 本文件第一版就栽在这:注释里写了"DraftCaptureShell
  /// 已删",判据当场匹配到自己的注释报红。同一个坑 2026-08-22 / 09-10 各踩过
  /// 一次,见 feedback_verification_predicate_must_not_match_own_comment。
  String stripComments(String src) => src
      .split('\n')
      .where(
        (l) => !l.trimLeft().startsWith('//') && !l.trimLeft().startsWith('///'),
      )
      .join('\n');

  test('锚点自身可读(阳性对照)', () {
    final source = stripComments(File(path).readAsStringSync());
    expect(source.contains('_buildRouteBody'), isTrue);
    expect(source.contains('MePage('), isTrue);
  });

  test('临时作品页没有任何拍摄入口', () {
    final source = stripComments(File(path).readAsStringSync());
    expect(
      source,
      isNot(contains('DraftCaptureShell')),
      reason: '那个 FAB 按用户令删除了,别捡回来',
    );
    expect(
      source,
      isNot(contains('当前任务正在重建')),
      reason: '没有拍摄按钮就没有"被拦住"这回事,这句提示跟着作废',
    );
    expect(
      File('lib/ui/draft_capture_shell.dart').existsSync(),
      isFalse,
      reason: 'FAB 的载体整份删除',
    );
    expect(File('lib/ui/me_root_page.dart').existsSync(), isFalse);
  });

  test('终态仍然退出临时页,且释放闸没被一起删掉(阳性对照)', () {
    final source = stripComments(File(path).readAsStringSync());
    expect(source, contains('_scheduleDraftTerminalExitIfNeeded();'));
    expect(
      source,
      contains('ReconstructionRouteReleaseGate'),
      reason: '终态拆解与退出仍必须串行',
    );
    expect(
      source,
      contains('if (recon != null) await recon.dispose();'),
      reason: 'pop 之前必须先还掉共享重建租约',
    );
  });

  test('回等待页的入口还在卡片上(删的是拍摄按钮,不是返回进度)', () {
    final source = stripComments(File(path).readAsStringSync());
    expect(source, contains('onActiveReconstructionTap: _showReconstructionProgress'));
  });
}
