/// True only when a terminal reconstruction is still presenting the temporary
/// Drafts surface. That route must be released so the real Drafts root—and its
/// fully enabled capture action—becomes visible.
bool shouldAutoExitReconstructionDrafts({
  required bool showingDrafts,
  required bool reconstructionTerminal,
  required bool recordActionInProgress,
}) {
  return showingDrafts && reconstructionTerminal && !recordActionInProgress;
}

/// 钉在原地的草稿页上,"这条重建还在跑"对外的**全部**表现。
///
/// 🔴 build 142 事故(2026-09-11 用户报"只有未命名(6)点不进去"):终态之后
/// 我只把 `blockedMessage` 解除了,漏掉另外三处 —— `activeReconstructionCaptureDir`
/// 仍指着刚拍完那一场,于是那张卡被判成「活跃重建同卡」,点击落进
/// `DraftCardAction.reopenActiveReconstruction`,而它的实现
/// (`_showReconstructionProgress`)第一行就是 `if (_sfmPhase == null) return;`
/// —— **静默 return**。同一个回调还挂在拍摄按钮上,所以拍摄按钮也是死键;
/// 这一页又没有返回图标、右滑已被吞掉 ⇒ 用户被关在里面。
///
/// 修法不是再补一个 `? :`(那是第五处、第六处的开始),而是把"拦截"做成
/// **一个不可分割的值**:两个构造器各自一次性给全,调用方只能整套换,
/// 漏不掉其中一处。参见
/// [[feedback_implicit_contract_must_be_lifted_into_the_type]] 同一修法。
class ReconstructionDraftIntercepts {
  /// 重建还在跑:拍摄被拦、卡片是"活跃重建同卡"、回调回等待页。
  const ReconstructionDraftIntercepts.reconstructing(String? captureDir)
    : activeCaptureDir = captureDir,
      blockedMessage = '当前任务正在重建',
      reopensWaitPage = true;

  /// 终态之后:三样**同时**熄灭。卡片落回普通判定(有 PLY 就开点云查看器),
  /// 拍摄按钮落回普通退出。
  const ReconstructionDraftIntercepts.finished()
    : activeCaptureDir = null,
      blockedMessage = null,
      reopensWaitPage = false;

  /// 传给 MePage 的"哪一场正在重建";null = 没有任何一场在跑。
  final String? activeCaptureDir;

  /// 拍摄按钮被拦时显示的话;null = 不拦。
  final String? blockedMessage;

  /// 卡片/拍摄按钮是否应该走"回等待页"那条分支。
  final bool reopensWaitPage;
}
