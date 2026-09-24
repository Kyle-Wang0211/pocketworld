// dense_same_page_wiring_test.dart — 2026-09-15 用户令「稠密接同一页并逐帧出点」:页面跟随全局
// denseStageProgress(只认本项目目录),运行中显示逐帧长出的稠密云 + 稠密倒计时胶囊、隐藏下一步/编辑;
// 结束后"完成";失败回到稀疏云可重试;查看模式若盘上已有稠密 PLY 直接显示它。源码锚点式(过滤注释)。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _code(String path) => File(path)
    .readAsStringSync()
    .split('\n')
    .where(
      (l) => !l.trimLeft().startsWith('//') && !l.trimLeft().startsWith('///'),
    )
    .join('\n');

void main() {
  late String page, overlay, eta;
  setUpAll(() {
    page = _code('lib/ui/official_capture/ar_capture_page.dart');
    overlay = _code('lib/ui/official_capture/sfm_preview_overlay.dart');
    eta = _code('lib/ui/official_capture/dense_wait_eta.dart');
  });

  test('阳性对照', () {
    expect(page.contains('denseStageProgress'), isTrue);
    expect(overlay.contains('denseRunning'), isTrue);
    expect(eta.contains('class DenseWaitEta'), isTrue);
  });

  test('页面订阅全局稠密进度并在 dispose 里退订;只认本项目目录', () {
    final cls = page.indexOf('class _OfficialARCapturePageState');
    final init = page.indexOf('void initState() {', cls);
    final add = page.indexOf(
      'denseStageProgress.addListener(_onDenseProgress);',
      init,
    );
    final disp = page.indexOf('void dispose() {', cls);
    final rem = page.indexOf(
      'denseStageProgress.removeListener(_onDenseProgress);',
      disp,
    );
    expect(add, greaterThan(init));
    expect(rem, greaterThan(disp));
    final on = page.indexOf('void _onDenseProgress() {');
    final guard = page.indexOf('p.captureDir != _pageCaptureDir) return;', on);
    expect(guard, greaterThan(on));
  });

  test('显示优先级:稠密实时云 > 盘上稠密 > 稀疏 > 拍摄末版白云;失败时稠密云让位', () {
    expect(
      page.contains(
        // [172] `_denseReviewSnapshot` (the dense PLY decoded on re-entry) is gone: re-entry with a
        // valid tree shows the tree over the sparse snapshot (see reopen_work_page_test.dart).
        '_denseSnapshotFor(denseStageProgress.value) ??\n                  _sfmSnapshot ??\n                  _sfmLiveSnapshot,',
      ),
      isTrue,
    );
    final f = page.indexOf(
      'SfmLiveSnapshot? _denseSnapshotFor(DenseStageProgress? p) {',
    );
    expect(
      page.indexOf('if (p.state == DenseStageState.failed) return null;', f),
      greaterThan(f),
    );
  });

  test('运行中:胶囊显示稠密倒计时,下一步/编辑隐藏;结束后下一步/编辑仍隐藏(底部只剩完成)', () {
    expect(page.contains('denseRunning: _denseRunningHere,'), isTrue);
    expect(
      page.contains(
        'waitLabel: _denseRunningHere\n                  ? _denseWaitLabel(context)\n                  : _sparseWaitLabel(context),',
      ),
      isTrue,
    );
    final next = page.indexOf('onNext:');
    expect(
      page
          .substring(next, next + 200)
          .contains(
            '!_denseRunningHere &&\n                      !_denseDoneHere &&',
          ),
      isTrue,
    );
    final edit = page.indexOf('onEnterEditing:');
    expect(
      page
          .substring(edit, edit + 200)
          .contains(
            '!_denseRunningHere &&\n                      !_denseDoneHere &&',
          ),
      isTrue,
    );
    // overlay: pill on while dense runs, bottom buttons off
    expect(
      overlay.contains(
        'if ((phase == SfmPreviewPhase.generating || denseRunning) && !editing)',
      ),
      isTrue,
    );
    expect(
      overlay.contains('if (canFinish && !editing && !denseRunning)'),
      isTrue,
    );
  });

  // [172] user 2026-09-24 「有树秒开，没树就停在稀疏点云的展示页面」: this used to pin 「查看模式:盘上有
  // official_dense.ply 就装它」(decode the dense PLY on re-entry, which never finished on the phone in
  // build 171). [174] user 2026-09-24 「永远不会重新训练稠密。如果有那就是 bug」: a complete dense PLY
  // is "done" — re-entry looks for a valid tree, else builds one from that PLY; it never trains.
  test('查看模式:只认有效八叉树或用现成稠密 PLY 建树,不解码稠密 PLY、不训练', () {
    final r = page.indexOf('Future<void> _enterReviewMode(String dir) async {');
    final end = page.indexOf("static const String _kEtaPriorLogName", r);
    final body = page.substring(r, end);
    expect(body.contains("DenseLodCache.instance.findValid(densePly)"), isTrue);
    expect(body.contains('_reviewTreeDir = tree;'), isTrue);
    // the only dense decode left is the tests' negative-control switch
    expect(
      RegExp(r"debugReviewCloudLoader\(densePly").allMatches(body).length,
      1,
    );
    expect(body.indexOf('if (OfficialARCapturePage.debugLegacyDenseReviewLoad'), greaterThan(0));
    expect(body.contains("compute(loadReviewCloud, densePly"), isFalse);
    // [174] the tree is built (through the shared cache) only from a COMPLETE dense PLY; never a run
    expect(body.contains('final denseComplete = densePlyComplete(densePly);'), isTrue);
    expect(body.contains('_watchDenseLod(doneThisSession ? p.outPly! : densePly);'), isTrue);
    expect(body.contains('denseStageLauncher.start('), isFalse);
    expect(body.contains('_startDenseStage('), isFalse);
    // NEGATIVE: the checker sees the sparse load it should see
    expect(body.contains("debugReviewCloudLoader(ply, 'review_load_sparse')"), isTrue);
  });

  test('稠密倒计时观察器:阶段单元数按 phase 总数校正,结束记尺子,只在成功时存先验', () {
    // whitespace- and trailing-comma-insensitive (dart format wraps calls)
    final flat = eta.replaceAll(RegExp(r'\s+'), '').replaceAll(',)', ')');
    expect(flat.contains('eta.setUnits(id,p.total);'), isTrue);
    expect(flat.contains("'job':'dense'"), isTrue);
    final fin = flat.indexOf('void_finish({requiredboolok}){');
    expect(fin, greaterThan(0));
    expect(flat.indexOf('if(ok){', fin), greaterThan(fin));
    expect(flat.contains('label.value??=eta.labelAt('), isTrue); // commit once
  });
}
