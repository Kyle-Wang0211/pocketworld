// dense_progress_bar_test.dart — the bar must never change the layout of the viewer's Stack.
//
// Regression for build 159 (2026-09-15): an idle `SizedBox.shrink()` as a non-positioned child collapsed the
// viewer's loose-fit Stack to 0×0 and the page went black. The negative control below reproduces that
// collapse on purpose so the test is known to bite.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pocketworld_flutter/dense/dense_progress_bar.dart';
import 'package:pocketworld_flutter/dense/dense_stage_progress.dart';

Widget _page(Widget bar) {
  return MaterialApp(
    home: Scaffold(
      body: Stack(
        children: [
          Positioned.fill(child: Container(key: const Key('cloud'), color: Colors.black)),
          bar,
          Positioned(left: 0, right: 0, bottom: 16, child: Container(key: const Key('button'), height: 48, color: Colors.white)),
        ],
      ),
    ),
  );
}

void main() {
  setUp(() => denseStageProgress.value = null);

  testWidgets('idle bar keeps the Stack full-size (the cloud layer stays visible)', (tester) async {
    await tester.pumpWidget(_page(DenseProgressBar(captureDir: '/cap/a', onView: (_) {})));
    final cloud = tester.getSize(find.byKey(const Key('cloud')));
    expect(cloud.width, greaterThan(100));
    expect(cloud.height, greaterThan(100));
    expect(tester.getSize(find.byKey(const Key('button'))).width, cloud.width);
    expect(find.byType(Positioned), findsWidgets);
  });

  testWidgets('negative control: a non-positioned shrink box collapses this Stack (why the bar must be Positioned)', (tester) async {
    await tester.pumpWidget(_page(const SizedBox.shrink()));
    final cloud = tester.getSize(find.byKey(const Key('cloud')));
    expect(cloud.width, 0);
    expect(cloud.height, 0);
  });

  testWidgets('progress for another capture is not shown; for this capture it is', (tester) async {
    denseStageProgress.value = const DenseStageProgress(captureDir: '/cap/b', state: DenseStageState.running, phase: 'infer', done: 3, total: 10);
    await tester.pumpWidget(_page(DenseProgressBar(captureDir: '/cap/a', onView: (_) {})));
    expect(find.textContaining('稠密处理中'), findsNothing);
    expect(tester.getSize(find.byKey(const Key('cloud'))).width, greaterThan(100));
    denseStageProgress.value = const DenseStageProgress(captureDir: '/cap/a', state: DenseStageState.running, phase: 'infer', done: 3, total: 10);
    await tester.pump();
    expect(find.textContaining('推理深度 3/10'), findsOneWidget);
    expect(tester.getSize(find.byKey(const Key('cloud'))).width, greaterThan(100));
  });

  testWidgets('done state offers 查看 with the PLY path', (tester) async {
    String? opened;
    denseStageProgress.value = const DenseStageProgress(captureDir: '/cap/a', state: DenseStageState.done, phase: 'done', outPly: '/cap/a/official_dense.ply', points: 42);
    await tester.pumpWidget(_page(DenseProgressBar(captureDir: '/cap/a', onView: (p) => opened = p)));
    await tester.tap(find.text('查看'));
    expect(opened, '/cap/a/official_dense.ply');
  });
}
