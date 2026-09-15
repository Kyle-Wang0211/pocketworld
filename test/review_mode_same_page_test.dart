// review_mode_same_page_test.dart — 2026-09-15 用户签决「从个人页再点进项目也走这同一个页面」:
// 画廊点项目 → OfficialARCapturePage(reviewCaptureDir:) 而不是只读 PLY 查看器;页面在查看模式下
// 不开相机、装盘上的稀疏云进 refined 态;所有项目目录读取走 _pageCaptureDir(只重建/查看模式没有
// CaptureSession)。源码锚点式(过滤注释行)。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

List<String> _code(String path) => File(path)
    .readAsStringSync()
    .split('\n')
    .where(
      (l) => !l.trimLeft().startsWith('//') && !l.trimLeft().startsWith('///'),
    )
    .toList();

void main() {
  late String page, routes;
  setUpAll(() {
    page = _code('lib/ui/official_capture/ar_capture_page.dart').join('\n');
    routes = _code(
      'lib/ui/official_capture/official_gallery_routes.dart',
    ).join('\n');
  });

  test('阳性对照:锚点都在', () {
    expect(page.contains('reviewCaptureDir'), isTrue);
    expect(routes.contains('pushOfficialViewerRoute'), isTrue);
  });

  test('画廊查看路由推的是同一个页面(查看模式),老记录才退回 PLY 查看器', () {
    final i = routes.indexOf('Future<void> pushOfficialViewerRoute(');
    final body = routes.substring(i);
    final same = body.indexOf('OfficialARCapturePage(reviewCaptureDir: dir)');
    final fallback = body.indexOf('SparseCloudViewerPage(');
    expect(same, greaterThan(0));
    expect(
      fallback,
      greaterThan(same),
    ); // fallback comes after the same-page branch
    expect(body.substring(0, same).contains('record.captureDir'), isTrue);
  });

  test('查看模式:不开相机、盘上稀疏云进 refined 态、返回箭头直接 pop', () {
    expect(page.contains('unawaited(_enterReviewMode(review));'), isTrue);
    final entry = page.indexOf('final review = widget.reviewCaptureDir;');
    final camera = page.indexOf('_initCamera();', entry);
    final ret = page.indexOf('return;', entry);
    expect(
      ret,
      lessThan(camera),
    ); // the review branch returns before _initCamera()
    expect(
      page.contains(
        "cloud = await compute(loadReviewCloud, ply, debugLabel: 'review_load_sparse');",
      ),
      isTrue,
    );
    expect(page.contains('_sfmPhase = SfmPreviewPhase.refined;'), isTrue);
    expect(page.contains('_sfmPendingPop = true;'), isTrue);
    final back = page.indexOf('Future<void> _onSfmPreviewBack() async {');
    final pop = page.indexOf('if (widget.reviewCaptureDir != null) {', back);
    final drafts = page.indexOf('_showDraftsDuringReconstruction();', back);
    expect(pop, greaterThan(back));
    expect(pop, lessThan(drafts));
  });

  test('项目目录统一走 _pageCaptureDir:_session?.captureDir 只剩 getter 里那一处', () {
    final n = '_session?.captureDir'.allMatches(page).length;
    expect(n, 1);
    expect(page.contains('widget.reconstructOnlyCaptureDir ??'), isTrue);
    expect(page.contains('widget.reviewCaptureDir;'), isTrue);
    // persist, dense start, selection load, result-viewed all use the page dir
    expect('_pageCaptureDir'.allMatches(page).length, greaterThanOrEqualTo(9));
  });

  test('三种进入方式互斥的 assert 在位', () {
    expect(page.contains("'补拍、「只重建」、「查看」是三种进入方式,不能同时给'"), isTrue);
  });
}
