// live_wait_page_wiring_test.dart — source-anchored contract of the "关灯了,点云还在原地" wait page
// (2026-09-15): the white interim cloud goes up in the SAME setState that raises the cover page (before
// freezeAndDrain), the overlay draws `_sfmSnapshot ?? _sfmLiveSnapshot`, the countdown is planned at the
// tap and finished after persist, and the refined cloud still takes precedence. Style: same as
// finish_hides_camera_immediately_test.dart (non-comment lines of ar_capture_page.dart).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<String> lines;
  late String src;
  late List<String> body; // _finalizeRecording
  setUpAll(() {
    final f = File('lib/ui/official_capture/ar_capture_page.dart');
    expect(f.existsSync(), isTrue);
    lines = f
        .readAsStringSync()
        .split('\n')
        .where(
          (l) =>
              !l.trimLeft().startsWith('//') && !l.trimLeft().startsWith('///'),
        )
        .toList();
    src = lines.join('\n');
    final start = lines.indexWhere(
      (l) => l.contains('Future<void> _finalizeRecording({'),
    );
    expect(start, greaterThanOrEqualTo(0));
    final end = lines.indexWhere(
      (l) => l.contains('_finalizingRecording = false;'),
      start,
    );
    expect(end, greaterThan(start));
    body = lines.sublist(start, end + 1);
  });
  int at(String pat) => body.indexWhere((l) => l.contains(pat));

  test('阳性对照:锚点都在', () {
    expect(src.contains('_sfmLiveSnapshot'), isTrue);
    expect(src.contains('await _shutterQueue.freezeAndDrain();'), isTrue);
    expect(src.contains('_beginSparseEta('), isTrue);
  });

  test('白云在盖页那一个 setState 里、排空之前就上屏', () {
    final cover = at('_sfmPhase = SfmPreviewPhase.generating;');
    final white = at('_sfmLiveSnapshot = live == null');
    final drain = at('await _shutterQueue.freezeAndDrain();');
    expect(cover, greaterThanOrEqualTo(0));
    expect(white, greaterThan(cover));
    expect(white, lessThan(drain));
    // same setState: no closing "});" between cover and white
    expect(body.sublist(cover, white).any((l) => l.trim() == '});'), isFalse);
  });

  test('倒计时在点按那一刻规划(排空之前),持久化后收尾', () {
    final plan = at('_beginSparseEta(');
    final drain = at('await _shutterQueue.freezeAndDrain();');
    expect(plan, greaterThanOrEqualTo(0));
    expect(plan, lessThan(drain));
    final persistIdx = lines.indexWhere(
      (l) => l.contains("_etaMark('sparse.persist');"),
    );
    final finishIdx = lines.indexWhere(
      (l) => l.contains('_finishSparseEta(ok: persistOk)'),
      persistIdx,
    );
    expect(persistIdx, greaterThanOrEqualTo(0));
    expect(finishIdx, greaterThan(persistIdx));
  });

  test('覆盖层画的是 refined 优先、否则实时白云;倒计时文案从 committed 标签来', () {
    final flat = src.replaceAll(RegExp(r'\s+'), ' ');
    expect(
      flat.contains(
        '_denseReviewSnapshot ?? _sfmSnapshot ?? _sfmLiveSnapshot,',
      ),
      isTrue,
    );
    expect(flat.contains(': _sparseWaitLabel(context),'), isTrue);
    // the label commits on the ticker, never inside build
    final ticker = lines.indexWhere(
      (l) => l.contains('void _startSfmStageTicker()'),
    );
    final commit = lines.indexWhere(
      (l) => l.contains(
        '_sparseEta?.labelAt(DateTime.now().millisecondsSinceEpoch);',
      ),
      ticker,
    );
    expect(commit, greaterThan(ticker));
    final build = lines.indexWhere(
      (l) => l.contains('String? _sparseWaitLabel(BuildContext context)'),
    );
    final buildEnd = lines.indexWhere((l) => l.trim() == '}', build);
    expect(
      lines.sublist(build, buildEnd).any((l) => l.contains('labelAt(')),
      isFalse,
    );
  });

  test('拍摄位姿起始态与白云同一 setState 落定,并透传给覆盖层', () {
    final cover = at('_sfmPhase = SfmPreviewPhase.generating;');
    final start = at('_sfmPerspectiveStart = live == null');
    expect(start, greaterThan(cover));
    expect(body.sublist(cover, start).any((l) => l.trim() == '});'), isFalse);
    expect(src.contains('initialPerspective: _sfmPerspectiveStart,'), isTrue);
    final overlay = File(
      'lib/ui/official_capture/sfm_preview_overlay.dart',
    ).readAsStringSync();
    expect(overlay.contains('initialPerspective: initialPerspective,'), isTrue);
  });

  test('五个阶段都有事件挂点:排空/phase1/refine/取色/落盘', () {
    for (final id in [
      'sparse.drain',
      'sparse.phase1',
      'sparse.refine',
      'sparse.colorize',
      'sparse.persist',
    ]) {
      expect(src.contains("_etaMark('$id'"), isTrue, reason: id);
    }
    // failure ends the countdown without saving priors
    final failed = lines.indexWhere(
      (l) => l.contains('case SfmLiveFailed(:final stage, :final message):'),
    );
    expect(lines[failed + 1].contains('_finishSparseEta(ok: false)'), isTrue);
  });
  _baIterTests();
}

// ── [BA-ITER 2026-09-16] core iteration progress feeds the countdown ─────────
void _baIterTests() {
  test('全局 BA 迭代进度:事件接到页面、frame 猜测阶段退位、迭代阶段随轮数增长、refined 收两段', () {
    final src = File(
      'lib/ui/official_capture/ar_capture_page.dart',
    ).readAsStringSync();
    final flat = src.replaceAll(RegExp(r'\s+'), ' ');
    expect(flat.contains("const EtaStage('sparse.refine_iter', 0),"), isTrue);
    expect(flat.contains('case SfmLiveFinalizeProgress('), isTrue);
    expect(
      flat.contains('_etaRefineProgress(stage, round, iter, maxIter);'),
      isTrue,
    );
    expect(flat.contains("eta.setUnits('sparse.refine', 0);"), isTrue);
    expect(flat.contains("eta.setUnits('sparse.refine_iter', units);"), isTrue);
    expect(
      flat.contains(
        "_etaMark('sparse.refine'); _etaMark('sparse.refine_iter');",
      ),
      isTrue,
    );
    // per-job counters reset when a job is planned
    expect(flat.contains('_etaRefineSwitched = false;'), isTrue);
  });
}
