// 等待页只剩一个状态位:底部等待胶囊。顶部状态 chip 在任何 phase 都不该再出现
// (2026-09-15 用户签决)。
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/l10n/app_localizations.dart';
import 'package:pocketworld_flutter/official_capture/sfm_live_recon.dart';
import 'package:pocketworld_flutter/ui/official_capture/sfm_preview_overlay.dart';

const _pillKey = ValueKey('sfm_wait_pill');

SfmLiveSnapshot _snapshotWithPoints() {
  return SfmLiveSnapshot(
    xyz: Float32List.fromList(<double>[
      0, 0, 0, //
      1, 0, 0, //
      0, 1, 0,
    ]),
    rgb: Uint8List(9),
    posesPacked: Float64List(0),
    summary: const {},
    refined: false,
    obsOffsets: Int32List(0),
    obsFrameIds: Int32List(0),
    obsXY: Float32List(0),
  );
}

Widget _host(
  SfmPreviewPhase phase, {
  String? waitLabel,
  SfmLiveSnapshot? snapshot,
  String? progressText,
  VoidCallback? onNext,
  VoidCallback? onDone,
}) {
  return MaterialApp(
    localizationsDelegates: AppL10n.localizationsDelegates,
    supportedLocales: AppL10n.supportedLocales,
    home: Scaffold(
      body: Stack(
        children: [
          SfmPreviewOverlay(
            phase: phase,
            snapshot: snapshot,
            waitLabel: waitLabel,
            progressText: progressText,
            onBack: () {},
            onDone: onDone ?? () {},
            onNext: onNext,
          ),
        ],
      ),
    ),
  );
}

/// SparseCloudView 的 sprite 构建是异步的,pumpAndSettle 未必收敛 —— 定量 pump
/// 几帧即可,断言只看 spinner / pill 这两个同步 widget。
Future<void> _settleABit(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('generating + waitLabel=null ⇒ 胶囊在,显 Calculating…', (
    tester,
  ) async {
    await tester.pumpWidget(_host(SfmPreviewPhase.generating));
    await tester.pump();

    expect(find.byKey(_pillKey), findsOneWidget);
    expect(
      find.descendant(of: find.byKey(_pillKey), matching: find.text('Calculating…')),
      findsOneWidget,
    );
  });

  testWidgets('generating + 自定 waitLabel ⇒ 原样透传', (tester) async {
    await tester.pumpWidget(
      _host(
        SfmPreviewPhase.generating,
        waitLabel: 'Time remaining · under a minute',
      ),
    );
    await tester.pump();

    expect(find.byKey(_pillKey), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(_pillKey),
        matching: find.text('Time remaining · under a minute'),
      ),
      findsOneWidget,
    );
    expect(find.text('Calculating…'), findsNothing);
  });

  testWidgets('refined ⇒ 无胶囊、无"重建完成"chip,底部按钮照旧', (tester) async {
    await tester.pumpWidget(
      _host(SfmPreviewPhase.refined, onNext: () {}),
    );
    await tester.pump();

    expect(find.byKey(_pillKey), findsNothing);
    // chip 文案是 sfmChipReconDone = "Reconstruction complete · {count} pts"。
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is Text &&
            (w.data ?? '').startsWith('Reconstruction complete'),
      ),
      findsNothing,
    );
    expect(find.text('Save Draft'), findsOneWidget);
    expect(find.text('Next'), findsOneWidget);
  });

  testWidgets('error ⇒ 无胶囊、无 "Reconstruction ended" chip', (tester) async {
    await tester.pumpWidget(_host(SfmPreviewPhase.error));
    await tester.pump();

    expect(find.byKey(_pillKey), findsNothing);
    // app_en.arb: "sfmChipReconEnded": "Reconstruction ended"
    expect(find.text('Reconstruction ended'), findsNothing);
    expect(find.text('Done'), findsOneWidget);
  });

  testWidgets('generating + 有点的 snapshot ⇒ spinner 文案消失,胶囊仍在', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(SfmPreviewPhase.generating, snapshot: _snapshotWithPoints()),
    );
    await _settleABit(tester);

    expect(find.text('正在生成最终点云…'), findsNothing);
    expect(find.byKey(_pillKey), findsOneWidget);
  });

  testWidgets('generating + snapshot=null ⇒ spinner 文案还在', (tester) async {
    await tester.pumpWidget(_host(SfmPreviewPhase.generating));
    await tester.pump();

    expect(find.text('正在生成最终点云…'), findsOneWidget);
    expect(find.byKey(_pillKey), findsOneWidget);
  });
}
