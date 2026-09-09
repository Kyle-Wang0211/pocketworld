import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 2026-09-07 未命名(24) 真机定罪:快门节奏被重建队列绑架。
///
/// 上游 stella_vslam 的 `mapper_is_skipping_localBA()` 是**罕见的背压逃生阀**
/// (30 fps 视频、一个关键帧几十毫秒,只有建图线程压垮到放弃局部 BA 才为真)。
/// 我曾把它接成 `remainingCount != 0`(SfM 队列非空)。我们一张 12MP 重建要
/// 1.1–4.1 s ⇒ 这个闸几乎全程关闭,只在每帧落地后开几十毫秒:
///   • 20/20 次快门落在上一帧 `add_frame rc=ok` 之后 23–303 ms 内;
///   • 到达该闸的 196 个 tick 里 178 个被它挡下,通过的 18 个**全部**开火,
///     skipNotMoved / skipPaced / skipMinDistance / skipBlurry 全为 0。
/// 用户体感:"移动到一个位置系统不拍,停一两秒就给这个视角拍了。"
///
/// 判据:**拍摄与重建解耦** —— 自动拍的决策路径里不许出现任何重建侧信号。
/// 相机自己的取图事务(awaitingCaptureBaseline)与快门队列生命周期
/// (mapperAccepting)不属此列:前者是"上一张实际拍在哪"的前提,后者是
/// finish/dispose 的生命周期闸,两者都与重建无关。
void main() {
  final controller = File('lib/official_capture/auto_capture_controller.dart');
  final page = File('lib/ui/official_capture/ar_capture_page.dart');

  // 重建侧的标识符:出现在决策路径上就是耦合。
  const reconSignals = <String>[
    'remainingCount',
    'queuedCount',
    '_sfmRecon',
    'SfmLiveRecon',
    'mapperIdleProvider',
  ];

  String stripComments(String src) =>
      src.split('\n').where((l) => !l.trimLeft().startsWith('//')).join('\n');

  test('自动拍控制器里没有任何重建侧信号', () {
    expect(controller.existsSync(), isTrue);
    final code = stripComments(controller.readAsStringSync());
    final hits = reconSignals.where(code.contains).toList();
    expect(hits, isEmpty, reason: '重建侧信号回到了快门决策路径:$hits —— 拍摄必须与重建解耦');
  });

  test('上游的 mapperSkippingLocalBA 取健康态字面 false,不接任何代理', () {
    final code = stripComments(controller.readAsStringSync());
    expect(
      code.contains('mapperSkippingLocalBA: false'),
      isTrue,
      reason:
          '本工程的建图侧没有「放弃局部 BA」这个状态,'
          '上游健康态取值就是 false;接任何代理都是移位前提',
    );
  });

  // 2026-09-09 未命名(1) 之后的第三刀:评估 ≠ 开火。
  //
  // `awaitingCaptureBaseline`(上一张还在取图事务里)本身不是耦合 —— 那一张
  // 最终落在哪还不知道,这时再开火就是把 09-06 的连拍搬回来。但它原来排在
  // **所有几何之前**:一张照片在飞的 0.4–0.7 s 里,几何一个字节都不算,
  // skipAwaitingCapture 的计数因此既包含"本来就不该拍"的帧,也包含"本来该拍
  // 却被挡住"的帧,两者混在一起,这条路径值多少钱永远量不出来。
  //
  // 解耦 = 把闸后移到**唯一那条 fire 出口**的前一行:几何照算,理由照报,
  // 行为一个字节不变(仍然不开火),而 skipAwaitingCapture 的计数从此就是
  // 「优化取图事务最多能多拍几张」的真上界。
  //
  // 不跨基准携带意图:闸放行的那一刻用的是**当前帧**的几何,不是在飞期间某
  // 一帧攒下来的"想拍"。携带它就是连拍。
  test('取图事务这道闸排在唯一 fire 出口的前一行(评估与开火分离)', () {
    final governor = File('lib/official_capture/auto_capture_governor.dart');
    expect(governor.existsSync(), isTrue);
    final lines = stripComments(
      governor.readAsStringSync(),
    ).split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();

    final fireAt = <int>[
      for (var i = 0; i < lines.length; i++)
        if (lines[i] == 'return AutoCaptureDecision.fire;') i,
    ];
    expect(fireAt.length, 1, reason: '出口不止一个就没法用排版保证「在飞期间不开火」:$fireAt');

    expect(
      lines[fireAt.single - 1],
      'if (awaitingCaptureBaseline) '
      'return AutoCaptureDecision.skipAwaitingCapture;',
      reason:
          '这道闸必须紧贴 fire 出口:排在几何前面 ⇒ 评估被开火绑架;'
          '排在 fire 之后 ⇒ 在飞期间会连拍',
    );

    final gateCount = lines
        .where((l) => l.contains('awaitingCaptureBaseline)'))
        .length;
    expect(gateCount, 1, reason: '闸只许有一处,多一处就有旁路');

    // 排序变了,skipAwaitingCapture 这个计数的**含义**就变了 ⇒ 遥测必须自报
    // 口径,否则跨版本的同名计数会被混进一次分析。这个字符串同时是装机自证
    // 的探针(纯语句移位不产生新符号,sha 对 Dart AOT 又是空的)。
    final telemetry = File('lib/official_capture/auto_capture_telemetry.dart');
    expect(telemetry.existsSync(), isTrue);
    expect(
      stripComments(
        telemetry.readAsStringSync(),
      ).contains("'decision_gate_order': 'geometry_before_awaiting_capture'"),
      isTrue,
      reason:
          '判决顺序的口径标签没了 —— 读者无从知道 skipAwaitingCapture '
          '是哪一套口径',
    );
  });

  test('页面不再把重建队列喂给治理器', () {
    expect(page.existsSync(), isTrue);
    final code = stripComments(page.readAsStringSync());
    // 页面自己当然还持有 _sfmRecon(它要驱动重建),但不许把它接进治理器构造。
    final wiring = RegExp(r'mapper\w*Provider\s*:\s*[^,]*').allMatches(code);
    for (final m in wiring) {
      final line = m.group(0)!;
      expect(
        reconSignals.any(line.contains),
        isFalse,
        reason: '治理器的 provider 接到了重建侧:$line',
      );
    }
  });
}
