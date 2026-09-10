// 终态之后,"这条重建还在跑"的**全部**表现必须同时消失。
//
// 用户 2026-09-11 报:"为什么所有作品都可以点进去看 3d viewer,只有未命名(6)
// 点不进去?" —— 未命名(6) 就是刚拍完那一场。根因不是点云坏了(PLY 15975 点
// 已落盘),是 build 142 终态之后只解除了拍摄拦截文案,`activeReconstructionCaptureDir`
// 仍指着它 ⇒ 卡片被判成「活跃重建同卡」⇒ 走 reopenActiveReconstruction ⇒
// 那个回调在 _sfmPhase == null 时静默 return ⇒ 点了一动不动。
//
// 判据分两层:纯值语义 + 与真正的卡片决策函数合起来跑一遍(端到端的那半)。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/me/draft_card_action.dart';
import 'package:pocketworld_flutter/ui/reconstruction_draft_route_state.dart';

void main() {
  const dir = '/Documents/captures_official/cap_1789057622885398';

  group('值语义', () {
    test('重建中:三样拦截同时在(阳性对照)', () {
      const i = ReconstructionDraftIntercepts.reconstructing(dir);
      expect(i.activeCaptureDir, dir);
      expect(i.blockedMessage, isNotNull);
      expect(i.reopensWaitPage, isTrue);
    });

    test('终态后:三样拦截同时熄灭', () {
      const i = ReconstructionDraftIntercepts.finished();
      expect(i.activeCaptureDir, isNull, reason: '卡片不能再被判成「活跃重建同卡」');
      expect(i.blockedMessage, isNull, reason: '拍摄按钮不能再挂过时提示');
      expect(i.reopensWaitPage, isFalse, reason: '不能再调那个会静默 return 的回调');
    });
  });

  group('接上真正的卡片决策', () {
    test('🔴 终态后点刚拍完那张卡 → 打开点云查看器,不是被 reopen 吞掉', () {
      const i = ReconstructionDraftIntercepts.finished();
      expect(
        draftCardActionFor(
          recordCaptureDir: dir,
          hasArtifact: false,
          sparsePlyExists: true,
          sfmDbExists: true,
          activeReconstructionCaptureDir: i.activeCaptureDir,
          hasActiveReconstructionCallback: i.reopensWaitPage,
        ),
        DraftCardAction.openSparseCloud,
      );
    });

    test('阳性对照:重建还在跑时,同一张卡仍必须回等待页', () {
      const i = ReconstructionDraftIntercepts.reconstructing(dir);
      expect(
        draftCardActionFor(
          recordCaptureDir: dir,
          hasArtifact: false,
          // 重建期磁盘上可能已经有半成品 PLY —— 契约要求先判活跃重建。
          sparsePlyExists: true,
          sfmDbExists: true,
          activeReconstructionCaptureDir: i.activeCaptureDir,
          hasActiveReconstructionCallback: i.reopensWaitPage,
        ),
        DraftCardAction.reopenActiveReconstruction,
      );
    });

    test('终态后别的卡照常开(它们本来就没坏 —— 用户说"所有作品都能点进去")', () {
      const i = ReconstructionDraftIntercepts.finished();
      expect(
        draftCardActionFor(
          recordCaptureDir: '/Documents/captures_official/cap_1789045251403847',
          hasArtifact: false,
          sparsePlyExists: true,
          sfmDbExists: true,
          activeReconstructionCaptureDir: i.activeCaptureDir,
          hasActiveReconstructionCallback: i.reopensWaitPage,
        ),
        DraftCardAction.openSparseCloud,
      );
    });
  });

  group('接线判据(源码层,先剥注释)', () {
    late String code;
    setUpAll(() {
      final f = File('lib/ui/official_capture/ar_capture_page.dart');
      expect(f.existsSync(), isTrue);
      code = f
          .readAsStringSync()
          .split('\n')
          .where(
            (l) =>
                !l.trimLeft().startsWith('//') &&
                !l.trimLeft().startsWith('///'),
          )
          .join('\n');
    });

    test('锚点自身可读(阳性对照:锚没了要报锚没了,不是报判据失败)', () {
      expect(
        code.contains('return DraftCaptureShell('),
        isTrue,
        reason: '钉住的草稿页锚点改名了 —— 先修锚,别把它读成回归',
      );
    });

    test('四个出口都走 intercepts,不再各判各的', () {
      expect(code.contains('blockedMessage: intercepts.blockedMessage'), isTrue);
      expect(
        code.contains('activeReconstructionCaptureDir: intercepts.activeCaptureDir'),
        isTrue,
      );
      expect(
        code.contains('activeReconstructionCaptureDir: _session?.captureDir'),
        isFalse,
        reason: '这是 build 142 的写法 —— 终态后它仍指着刚拍完那一场',
      );
      expect(
        code.contains(
          "blockedMessage: _draftsPinnedAfterTerminal ? null : '当前任务正在重建'",
        ),
        isFalse,
        reason: '同上:只解一处的旧写法',
      );
    });

    test('🔴 终态后拍摄按钮必须有真出口(别把人关在这一页)', () {
      expect(
        code.contains('onCaptureTap: intercepts.reopensWaitPage\n            ? _showReconstructionProgress\n            : _exitToDrafts'),
        isTrue,
        reason: '这一页没有返回图标、右滑被 PopScope 吞掉,拍摄按钮是唯一出口',
      );
      expect(
        code.contains('onCaptureTap: _showReconstructionProgress,'),
        isFalse,
        reason: 'build 142 的写法 —— 终态后它静默 return,按钮是死键',
      );
    });
  });
}
