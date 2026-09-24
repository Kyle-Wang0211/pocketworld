// [2026-07-31 用户签决] 预览页底部"下一步"= 启动后续处理(不再是进选区编辑)。
// 本文件钉住那条边界的约定 —— 真实实现落地时,这些断言就是它的验收条件。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/dense_stage.dart';
import 'package:pocketworld_flutter/official_capture/selection_box.dart';

class _RecordingLauncher implements DenseStageLauncher {
  _RecordingLauncher({this.available = true, this.result});
  final bool available;
  final DenseStageResult? result;
  DenseStageRequest? seen;

  @override
  bool get isAvailable => available;

  @override
  Future<DenseStageResult> start(DenseStageRequest request) async {
    seen = request;
    return result ?? const DenseStageResult.started();
  }
}

void main() {
  final defaultLauncher = denseStageLauncher;
  tearDown(() => denseStageLauncher = defaultLauncher);

  group('默认实现:诚实地报"没接"', () {
    test('本机没有这个阶段 ⇒ isAvailable = false', () {
      expect(const UnavailableDenseStageLauncher().isAvailable, isFalse);
    });

    test('刻意不返回 started —— 假装受理会让草稿永远停在跑不完的状态', () async {
      final r = await const UnavailableDenseStageLauncher().start(
        const DenseStageRequest(
          captureDir: '/tmp/x',
          sparsePlyPath: '/tmp/x/official_sfm_sparse.ply',
          pointCount: 1,
        ),
      );
      expect(r.status, DenseStageStatus.unavailable);
      expect(r.status, isNot(DenseStageStatus.started));
    });

    test('出货默认值就是它 —— 真实实现没落地前不能有人以为能跑', () {
      expect(defaultLauncher, isA<UnavailableDenseStageLauncher>());
      expect(defaultLauncher.isAvailable, isFalse);
    });
  });

  group('请求语义', () {
    test('没选区 ⇒ selection 必须是 null,不能塞兜底框', () async {
      // 兜底框是按点云 AABB 现算的、留了边距,拿它当"用户的选区"会悄悄切边。
      const req = DenseStageRequest(
        captureDir: '/tmp/x',
        sparsePlyPath: '/tmp/x/official_sfm_sparse.ply',
        pointCount: 100,
      );
      expect(req.selection, isNull);
    });

    test('选过区 ⇒ 显式带上,实现方不必去 captureDir 猜', () async {
      final box = SelectionBox.initialSquareFace(
        cx: 0,
        cy: 0,
        cz: 0,
        halfExtent: 1,
      );
      final l = _RecordingLauncher();
      await l.start(
        DenseStageRequest(
          captureDir: '/tmp/x',
          sparsePlyPath: '/tmp/x/official_sfm_sparse.ply',
          pointCount: 100,
          selection: box,
        ),
      );
      expect(l.seen!.selection!.sameAs(box), isTrue);
    });

    test('pointCount 是**裁剪前**的全量点数', () {
      // 交付永远全量、不降采样;选区是"取哪一块",不是"取多少点"。
      const req = DenseStageRequest(
        captureDir: '/tmp/x',
        sparsePlyPath: '/tmp/x/official_sfm_sparse.ply',
        pointCount: 166853,
      );
      expect(req.pointCount, 166853);
    });
  });

  group('UI 接线', () {
    final viewer = File(
      'lib/ui/official_capture/sparse_cloud_viewer_page.dart',
    ).readAsStringSync();
    final capture = File(
      'lib/ui/official_capture/ar_capture_page.dart',
    ).readAsStringSync();
    final overlay = File(
      'lib/ui/official_capture/sfm_preview_overlay.dart',
    ).readAsStringSync();

    test('"下一步"不再进选区编辑', () {
      expect(
        viewer.contains(
          'label: AppL10n.of(context).sfmNext,\n'
          '                          onTap: _enterEditing,',
        ),
        isFalse,
      );
      expect(viewer, contains('_startDenseStage'));
      expect(capture, contains('_startDenseStage'));
    });

    test('两条路都只在真选过区时带 selection', () {
      // [174] 第一次「下一步」:只在真选过区时带框;「完成稠密」(开跑过没完成):用那次运行记下的框
      // (dense_work_state.dart denseResumeSelection),不是当前编辑态的框。
      expect(viewer, contains(': (_selectionApplied ? _box : null);'));
      expect(viewer, contains('? await denseResumeSelection(_captureDir)'));
      expect(capture, contains(': (_sfmSelectionApplied ? _sfmBox : null);'));
      expect(capture, contains('? await denseResumeSelection(dir)'));
      expect(viewer, contains('selection: selection,'));
      expect(capture, contains('selection: selection,'));
      // NEGATIVE: 兜底框(AABB 算的 fallback)从来不直接进请求
      expect(viewer.contains('selection: _box,'), isFalse);
      expect(capture.contains('selection: _sfmBox,'), isFalse);
    });

    test('未接入时按钮禁用,而不是点下去弹一句"敬请期待"', () {
      expect(viewer, contains('denseStageLauncher.isAvailable'));
      expect(capture, contains('denseStageLauncher.isAvailable'));
      // 禁用态得看得出来,否则和可点的一模一样。
      expect(overlay, contains('final enabled = onTap != null;'));
      expect(overlay, contains('final VoidCallback? onTap;'));
    });

    test('进选区编辑的函数改了名 —— 旧名 _onSfmPreviewNext 会读成底部那个按钮', () {
      expect(capture.contains('_onSfmPreviewNext'), isFalse);
      expect(capture, contains('_enterSfmEditing'));
    });
  });
}
