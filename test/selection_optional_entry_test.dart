// [SEL-ENTRY / SEL-PREVIEW / SEL-DISCARD 2026-07-30 用户签决] 选区变成可选动作。
//
// 四条规格:
//   ① 预览页右上角一个 icon 进入选区编辑;
//   ② 编辑态该 icon 变成"返回",回到预览 —— 所以用户**不必**选区;
//   ③ 用了选区,预览呈现的点云就是选区后的范围;
//   ④ 退到草稿页时,若改过选区,弹"编辑记录是否保存"。
//
// ③ 有一个易漏的前提:overlay 此前在非编辑态传 `selectionBox: null`,框在预览里
// 完全不起作用。剔除逻辑写得再对,只要那一行还在,预览也不会变 —— 所以这里
// 专门钉住"浏览态也把框传下去"。
//
// ④ 的编辑是事务性的:拖动只更新内存预览，“完成”才提交正式记录。回滚仍
// 显式写回基线，用于兼容清理由旧版本提前落盘的记录。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/selection_box.dart';

void main() {
  group('SelectionBox.sameAs —— "改过没有"的判据', () {
    final a = SelectionBox.initialSquareFace(
      cx: 0,
      cy: 0,
      cz: 0,
      halfExtent: 1,
    );

    test('自反', () => expect(a.sameAs(a), isTrue));

    test('浮点抖动不算修改', () {
      expect(a.sameAs(a.copyWith(cx: 1e-12)), isTrue);
    });

    test('真实位移算修改', () {
      expect(a.sameAs(a.copyWith(cx: 0.01)), isFalse);
    });

    test('尺寸变化算修改', () {
      expect(a.sameAs(a.copyWith(sx: a.sx * 0.5)), isFalse);
    });

    test('朝向变化算修改 —— 只比中心和尺寸会漏判旋转', () {
      final rotated = a.copyWith(
        rot: <double>[0, -1, 0, 1, 0, 0, 0, 0, 1], // 绕 Z 转 90°
      );
      expect(a.sameAs(rotated), isFalse);
    });
  });

  group('① ② 右上角开关', () {
    final overlay = File(
      'lib/ui/official_capture/sfm_preview_overlay.dart',
    ).readAsStringSync();

    test('浏览态入口有自己的 key,便于 UI 测试定位', () {
      expect(overlay, contains("'sfm_preview_enter_editing'"));
    });

    test('编辑态不在这里出按钮 —— 否则和工具层的"保存"重叠', () {
      // SelectionToolsLayer 自己在右上角画"保存"、左上角画"返回"。
      expect(overlay, contains('!editing &&'));
      expect(overlay.contains("'sfm_preview_exit_editing'"), isFalse);
      expect(overlay.contains('onExitEditing'), isFalse);
    });

    test('只在 refined 且真有云可编辑时出现', () {
      expect(overlay, contains('phase == SfmPreviewPhase.refined &&'));
    });

    test('底部仍保留"保存草稿" —— 不选区也能直接交付', () {
      expect(overlay, contains('sfmSaveDraft'));
    });
  });

  group('③ 预览呈现选区后的范围', () {
    test('浏览态也把 selectionBox 传给视图(此前传的是 null)', () {
      final overlay = File(
        'lib/ui/official_capture/sfm_preview_overlay.dart',
      ).readAsStringSync();
      expect(
        overlay.contains('selectionBox: editing ? selectionBox : null'),
        isFalse,
        reason: '这一行会让预览里的框完全失效,剔除逻辑再对也没用',
      );
      expect(overlay, contains('selectionBox: selectionBox,'));
    });

    test('painter 按 editing 取反决定剔除还是染红', () {
      final view = File(
        'lib/ui/official_capture/sparse_cloud_view.dart',
      ).readAsStringSync();
      expect(view, contains('cullOutsideSelection: !widget.editing'));
      // 剔除必须发生在写入投影/排序数组之前,否则白付一遍代价。
      final loopIdx = view.indexOf('final outsideSelection =');
      final cullIdx = view.indexOf(
        'if (outsideSelection && cullOutsideSelection) continue;',
      );
      final writeIdx = view.indexOf('vxA[m] = vx;');
      expect(loopIdx, greaterThan(-1));
      expect(cullIdx, greaterThan(loopIdx));
      expect(cullIdx, lessThan(writeIdx), reason: '这条路径每帧跑十几万次,剔除放在投影之后等于白算');
    });

    test('编辑态仍染红不剔除 —— 用户要看见自己切掉了什么', () {
      final view = File(
        'lib/ui/official_capture/sparse_cloud_view.dart',
      ).readAsStringSync();
      expect(view, contains('argb = kSelectionOutColor;'));
    });
  });

  group('④ 退出时的保存裁决', () {
    final page = File(
      'lib/ui/official_capture/ar_capture_page.dart',
    ).readAsStringSync();

    test('拖动只更新内存，只有“完成”可以提交正式选区记录', () {
      final changedStart = page.indexOf('void _onSfmBoxChanged(');
      final changedEnd = page.indexOf('void _resetSfmBoxSize()', changedStart);
      final changedBody = page.substring(changedStart, changedEnd);
      expect(changedBody, isNot(contains('saveTo(')));
      expect(changedBody, isNot(contains('Timer(')));

      final doneStart = page.indexOf('Future<void> _exitSfmEditing()');
      final doneEnd = page.indexOf(
        'Future<void> _cancelSfmEditing()',
        doneStart,
      );
      expect(
        page.substring(doneStart, doneEnd),
        contains('await _persistSfmBox('),
      );
    });

    test('返回草稿走裁决入口,不再直接显现草稿层', () {
      expect(page, contains('onBack: () => unawaited(_onSfmPreviewBack())'));
      expect(page, contains('_confirmLeaveWithSelectionEdits'));
    });

    test('三个选项都在:保存 / 不保存 / 取消', () {
      expect(page, contains("pop('keep')"));
      expect(page, contains("pop('discard')"));
      expect(page, contains("pop('cancel')"));
    });

    test('没改过就不弹窗 —— 进出编辑态不该被打断', () {
      expect(page, contains('if (baseline == null) return true;'));
    });

    test('"不保存"是回滚写盘,不是跳过写盘', () {
      // 防御性回写/删除兼容旧版本可能已经提前落盘的记录。
      expect(page, contains('await _persistSfmBox('));
      expect(page, contains('baseline,'));
    });

    test('首次编辑前没有正式选区时,"不保存"恢复为无选区', () {
      // 初始显示用的兜底框不是用户保存的选区。第一次改动必须同时记住
      // “当时没有正式选区”，退页选择“不保存”时删除记录并恢复未应用状态。
      expect(page, contains('final previousApplied = _sfmSelectionApplied;'));
      expect(page, contains('_sfmBoxBaselineWasAbsent = !previousApplied;'));
      expect(page, contains('applied: !_sfmBoxBaselineWasAbsent'));
      expect(
        page,
        contains('_sfmSelectionApplied = !_sfmBoxBaselineWasAbsent;'),
      );
    });

    test('取消 / 点外部关闭都必须留在原页', () {
      expect(
        page,
        contains("if (choice == null || choice == 'cancel') return false;"),
      );
      expect(page, contains('barrierDismissible: false'));
    });

    test('基线在第一次修改前抓,不是进编辑态时抓', () {
      expect(
        page,
        contains('_sfmBoxBaseline == null && !_sfmBoxBaselineWasAbsent'),
      );
    });
  });
}
