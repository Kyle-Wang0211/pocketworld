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

  String stripComments(String src) => src
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('//'))
      .join('\n');

  test('自动拍控制器里没有任何重建侧信号', () {
    expect(controller.existsSync(), isTrue);
    final code = stripComments(controller.readAsStringSync());
    final hits = reconSignals.where(code.contains).toList();
    expect(
      hits,
      isEmpty,
      reason: '重建侧信号回到了快门决策路径:$hits —— 拍摄必须与重建解耦',
    );
  });

  test('上游的 mapperSkippingLocalBA 取健康态字面 false,不接任何代理', () {
    final code = stripComments(controller.readAsStringSync());
    expect(
      code.contains('mapperSkippingLocalBA: false'),
      isTrue,
      reason: '本工程的建图侧没有「放弃局部 BA」这个状态,'
          '上游健康态取值就是 false;接任何代理都是移位前提',
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
