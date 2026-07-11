// draft_reentry_check.dart — 草稿任务卡重入契约的纯 Dart 断言(修2)。
//
// 运行(纯 Dart VM,repo 根目录下):
//   dart tool/draft_reentry_check.dart
//
// 背景:handoff §0:9 "用户在草稿页点击当前正在重建的同一任务卡时,必须
// 回到原等待页看进度,不得启动第二个重建任务" 在 2026-07-10 真机上踩坏
// (route 被隐式 pop → worker 被 dispose → 卡片点击落到 SnackBar 分支)。
// 路由决策已提纯为 lib/me/draft_card_action.dart 的纯函数,本脚本穷举
// 断言其契约:
//   1. finalize 进行中 + 点同一卡 → 回原等待页(reopenActiveReconstruction),
//      哪怕磁盘上已有半成品 PLY / db;
//   2. finalize 完成后(无活跃重建)+ 点击 → 打开成品(PLY 查看器 / GLB 详情);
//   3. 重建被打断(有 db 无 PLY,无活跃重建)→ 提供"继续重建"确认;
//   4. 无成品无可恢复数据 → none(原底部弹窗已删,修3);
//   5. 有活跃重建时,其他卡绝不提供续跑(避免双原生 SfM 会话)。

import 'dart:io';

import 'package:pocketworld_flutter/me/draft_card_action.dart';

int _failures = 0;

void check(String name, Object? actual, Object? expected) {
  final ok = actual == expected;
  stdout.writeln(
    '${ok ? 'PASS' : 'FAIL'}  $name'
    '${ok ? '' : '  (expected $expected, got $actual)'}',
  );
  if (!ok) _failures++;
}

const dirA = '/var/mobile/Containers/Data/App/X/Documents/captures/cap_A';
const dirB = '/var/mobile/Containers/Data/App/X/Documents/captures/cap_B';

void main() {
  // ── 契约 1:finalize 进行中,点同一任务卡 → 回原等待页 ────────────
  check(
    '进行中+同卡 → 回原等待页',
    draftCardActionFor(
      recordCaptureDir: dirA,
      hasArtifact: false,
      sparsePlyExists: false,
      sfmDbExists: true, // db 一定在(正在重建)
      activeReconstructionCaptureDir: dirA,
      hasActiveReconstructionCallback: true,
    ),
    DraftCardAction.reopenActiveReconstruction,
  );
  // 同卡优先级最高:即使磁盘上已有(旧的/半成品)PLY 也必须回等待页,
  // 绝不打开半成品。
  check(
    '进行中+同卡+磁盘已有PLY → 仍回原等待页(不开半成品)',
    draftCardActionFor(
      recordCaptureDir: dirA,
      hasArtifact: false,
      sparsePlyExists: true,
      sfmDbExists: true,
      activeReconstructionCaptureDir: dirA,
      hasActiveReconstructionCallback: true,
    ),
    DraftCardAction.reopenActiveReconstruction,
  );
  // 路径写法差异(尾斜杠)不得让重入守卫静默失败。
  check(
    '进行中+同卡(active 带尾斜杠)→ 仍回原等待页',
    draftCardActionFor(
      recordCaptureDir: dirA,
      hasArtifact: false,
      sparsePlyExists: false,
      sfmDbExists: true,
      activeReconstructionCaptureDir: '$dirA/',
      hasActiveReconstructionCallback: true,
    ),
    DraftCardAction.reopenActiveReconstruction,
  );

  // ── 契约 2:finalize 完成后点击 → 打开成品 ──────────────────────
  check(
    '完成后(PLY 已持久化)→ 打开点云成品',
    draftCardActionFor(
      recordCaptureDir: dirA,
      hasArtifact: false,
      sparsePlyExists: true,
      sfmDbExists: true, // db 还在也一样:成品优先
      activeReconstructionCaptureDir: null,
      hasActiveReconstructionCallback: false,
    ),
    DraftCardAction.openSparseCloud,
  );
  check(
    'GLB 成品 → 打开作品详情',
    draftCardActionFor(
      recordCaptureDir: dirA,
      hasArtifact: true,
      sparsePlyExists: true,
      sfmDbExists: false,
      activeReconstructionCaptureDir: null,
      hasActiveReconstructionCallback: false,
    ),
    DraftCardAction.openWorkDetail,
  );

  // ── 契约 3:被打断的重建 → 提供断点续跑 ─────────────────────────
  check(
    '有 db 无 PLY 且无活跃重建 → 提供继续重建',
    draftCardActionFor(
      recordCaptureDir: dirA,
      hasArtifact: false,
      sparsePlyExists: false,
      sfmDbExists: true,
      activeReconstructionCaptureDir: null,
      hasActiveReconstructionCallback: false,
    ),
    DraftCardAction.offerResume,
  );

  // ── 契约 4:无成品无可恢复数据 → none(修3:弹窗已删)────────────
  check(
    '无 PLY 无 db → none(不再弹底部提示)',
    draftCardActionFor(
      recordCaptureDir: dirA,
      hasArtifact: false,
      sparsePlyExists: false,
      sfmDbExists: false,
      activeReconstructionCaptureDir: null,
      hasActiveReconstructionCallback: false,
    ),
    DraftCardAction.none,
  );

  // ── 契约 5:活跃重建期间,别的卡绝不起第二个重建 ─────────────────
  check(
    '进行中+点另一张可恢复卡 → 不提供续跑(none)',
    draftCardActionFor(
      recordCaptureDir: dirB,
      hasArtifact: false,
      sparsePlyExists: false,
      sfmDbExists: true,
      activeReconstructionCaptureDir: dirA,
      hasActiveReconstructionCallback: true,
    ),
    DraftCardAction.none,
  );
  check(
    '进行中+点另一张已有成品的卡 → 正常打开成品',
    draftCardActionFor(
      recordCaptureDir: dirB,
      hasArtifact: false,
      sparsePlyExists: true,
      sfmDbExists: false,
      activeReconstructionCaptureDir: dirA,
      hasActiveReconstructionCallback: true,
    ),
    DraftCardAction.openSparseCloud,
  );

  // ── 防御:callback 缺失(不该发生,但守卫必须安全降级)────────────
  check(
    '同卡但 callback 缺失 → 降级为可恢复判定(不崩、不静默吞)',
    draftCardActionFor(
      recordCaptureDir: dirA,
      hasArtifact: false,
      sparsePlyExists: false,
      sfmDbExists: true,
      activeReconstructionCaptureDir: dirA,
      hasActiveReconstructionCallback: false,
    ),
    // active 非空 → 不提供续跑(契约 5),PLY 又不存在 → none。
    DraftCardAction.none,
  );
  check(
    'record.captureDir 为 null → none',
    draftCardActionFor(
      recordCaptureDir: null,
      hasArtifact: false,
      sparsePlyExists: false,
      sfmDbExists: false,
      activeReconstructionCaptureDir: dirA,
      hasActiveReconstructionCallback: true,
    ),
    DraftCardAction.none,
  );

  stdout.writeln(_failures == 0 ? '\nALL PASS' : '\n$_failures FAILURE(S)');
  if (_failures > 0) exitCode = 1;
}
