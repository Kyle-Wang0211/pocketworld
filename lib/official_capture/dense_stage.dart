// dense_stage.dart — 稀疏预览之后那一段("开始处理")的接口边界。
//
// [2026-07-31 用户签决] 预览页底部的"下一步"不再是进选区编辑(选区已降级成
// 右上角的可选入口),而是启动后续处理。本文件只定义**边界**:设备上还没有
// 稠密/TSDF 的任何实现(整条重建搬上手机的签决分四阶段,稠密那阶段零实现),
// 真实实现落地时替换 [denseStageLauncher] 即可,UI 侧一行不用改。
//
// 两条来自既有签决的硬约束,实现方必须遵守:
//   · 纯本地。云端训练/上传线 2026-07-13 已整条删除(第一性原理绝对纯本地),
//     这里**不是**它的复活入口。
//   · 交付永远全量,不降采样;选区是"取哪一块",不是"取多少点"。
import 'selection_box.dart';

/// 启动后续处理所需的全部输入。
///
/// 显式带上 [selection] 而不是让实现方自己去 captureDir 读盘:选区是**可选**
/// 动作,null 表示用户没选区 ⇒ 处理整朵点云。让调用方把这件事说清楚,实现方
/// 就不会把"盘上恰好有个旧框"当成用户的意图。
class DenseStageRequest {
  const DenseStageRequest({
    required this.captureDir,
    required this.sparsePlyPath,
    required this.pointCount,
    this.selection,
    this.recordId,
  });

  /// 采集会话根目录(photos/ 与各阶段产物都在里面)。
  final String captureDir;

  /// 稀疏点云 PLY 的绝对路径。
  final String sparsePlyPath;

  /// [sparsePlyPath] 的总点数(未经选区裁剪)。
  final int pointCount;

  /// 用户的选区;null = 没选区,处理全量。
  final SelectionBox? selection;

  /// 草稿记录 id(有的话)。实现方可据此把产物挂回 ScanRecord.artifactPath。
  final String? recordId;
}

enum DenseStageStatus {
  /// 已受理,处理在后台跑。
  started,

  /// 本机还没有这个阶段的实现。
  unavailable,

  /// 受理失败(输入不合法、资源不足等),[DenseStageResult.message] 说明原因。
  failed,
}

class DenseStageResult {
  const DenseStageResult(this.status, {this.message});

  const DenseStageResult.started()
    : status = DenseStageStatus.started,
      message = null;

  final DenseStageStatus status;
  final String? message;
}

/// 后续处理的启动器。
abstract interface class DenseStageLauncher {
  /// 本机是否具备这个阶段的实现。UI 用它决定"下一步"是否可点 —— 一个点下去
  /// 只会告诉你"还没做"的按钮,不如一开始就是灰的。
  bool get isAvailable;

  /// 受理请求并**立即**返回。这里不等处理跑完:稠密段是分钟级的,UI 不能被
  /// 它挂住(拍摄期实测热降频下实时 mapping 已经能破 2s/帧)。
  Future<DenseStageResult> start(DenseStageRequest request);
}

/// 默认实现:诚实地报告"没接"。
///
/// 刻意**不**返回 started —— 假装受理成功会让草稿卡片停在一个永远不会完成的
/// 状态上,那比按钮直接是灰的更糟。
class UnavailableDenseStageLauncher implements DenseStageLauncher {
  const UnavailableDenseStageLauncher();

  @override
  bool get isAvailable => false;

  @override
  Future<DenseStageResult> start(DenseStageRequest request) async =>
      const DenseStageResult(DenseStageStatus.unavailable);
}

/// 全局注入点。真实实现落地时在启动路径上赋值一次即可;测试里可以随意替换。
DenseStageLauncher denseStageLauncher = const UnavailableDenseStageLauncher();
