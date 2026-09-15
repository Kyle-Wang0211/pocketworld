// dense_stage_panel_test.dart — the status block must never change the viewer Stack's layout, and it must show
// the right thing per state. Negative control reproduces the build-159 collapse on purpose.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pocketworld_flutter/dense/dense_stage_progress.dart';
import 'package:pocketworld_flutter/dense/dense_stage_panel.dart';

Widget _page(Widget status) {
  return MaterialApp(
    home: Scaffold(
      body: Stack(
        children: [
          Positioned.fill(child: Container(key: const Key('cloud'), color: Colors.black)),
          status,
          Positioned(left: 24, right: 24, bottom: 16, child: Container(key: const Key('button'), height: 48, color: Colors.white)),
        ],
      ),
    ),
  );
}

Widget _status({String captureDir = '/cap/a'}) =>
    DenseStagePanel(captureDir: captureDir, densePlyPath: '$captureDir/official_dense.ply', onView: (_) {});

void main() {
  setUp(() => denseStageProgress.value = null);

  testWidgets('idle status keeps the Stack full-size', (tester) async {
    await tester.pumpWidget(_page(_status()));
    final cloud = tester.getSize(find.byKey(const Key('cloud')));
    expect(cloud.width, greaterThan(100));
    expect(cloud.height, greaterThan(100));
  });

  testWidgets('negative control: a non-positioned shrink box collapses this Stack', (tester) async {
    await tester.pumpWidget(_page(const SizedBox.shrink()));
    expect(tester.getSize(find.byKey(const Key('cloud'))).width, 0);
  });

  testWidgets('running: spinner, phase line with elapsed, progress bar; other capture ignored', (tester) async {
    denseStageProgress.value = DenseStageProgress(captureDir: '/cap/b', state: DenseStageState.running, phase: 'infer', done: 3, total: 10, startedAt: DateTime.now());
    await tester.pumpWidget(_page(_status()));
    expect(find.textContaining('正在生成'), findsNothing);
    denseStageProgress.value = DenseStageProgress(captureDir: '/cap/a', state: DenseStageState.running, phase: 'infer', done: 3, total: 10, startedAt: DateTime.now().subtract(const Duration(seconds: 83)));
    await tester.pump();
    expect(find.text('正在生成稠密点云…'), findsOneWidget);
    expect(find.textContaining('推理深度 3/10 · 已用 1 分 23 秒'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(tester.getSize(find.byKey(const Key('cloud'))).width, greaterThan(100));
    denseStageProgress.value = null;
    await tester.pump();
  });

  testWidgets('done: points + duration; failed: short message only', (tester) async {
    final t0 = DateTime(2026, 9, 15, 20, 0);
    denseStageProgress.value = DenseStageProgress(captureDir: '/cap/a', state: DenseStageState.done, phase: 'done', points: 1234567, startedAt: t0, finishedAt: t0.add(const Duration(minutes: 3, seconds: 12)));
    await tester.pumpWidget(_page(_status()));
    expect(find.text('稠密点云已生成 · 1234567 点 · 3 分 12 秒'), findsOneWidget);
    denseStageProgress.value = DenseStageProgress(captureDir: '/cap/a', state: DenseStageState.failed, phase: 'failed', message: DenseStageProgress.shorten('Invalid argument(s): boom <- Context num_variables: 7 <- runPwDenseJob'));
    await tester.pump();
    expect(find.text('稠密处理失败'), findsOneWidget);
    expect(find.text('Invalid argument(s): boom'), findsOneWidget);
    expect(find.textContaining('num_variables'), findsNothing);
  });

  test('fraction is monotone across phases and shorten caps the text', () {
    double f(String phase, int d, int t) => DenseStageProgress(captureDir: 'x', state: DenseStageState.running, phase: phase, done: d, total: t).fraction!;
    expect(f('session', 0, 1) <= f('images', 0, 10), isTrue);
    expect(f('images', 10, 10) <= f('infer', 0, 97), isTrue);
    expect(f('infer', 97, 97) <= f('fuse', 0, 97), isTrue);
    expect(f('fuse', 97, 97), 1.0);
    expect(DenseStageProgress.shorten('a' * 200).length, 91);
    expect(formatDenseDuration(const Duration(seconds: 59)), '59 秒');
    expect(formatDenseDuration(const Duration(minutes: 65)), '1 小时 5 分');
  });
}
