import BackgroundTasks
import UIKit

/// iOS 26 background-continuation umbrella for the SfM finalize.
///
/// The reconstruction finalize (incremental register + BA + colorize + persist)
/// runs in a Dart worker isolate for ~1 min. If the user backgrounds the app
/// mid-finalize, iOS suspends the isolate and the solve stalls → no PLY → the
/// draft can't open. A `BGContinuedProcessingTask` grants continued background
/// execution (with a system progress UI) so the finalize completes regardless.
///
/// Ported (simplified) from the validated glomapbench2 umbrella recipe
/// (2026-07-04, iPhone 14 Pro iOS 26.5). The constraints it encodes:
///   1. dasd SILENTLY DROPS a submit made from the background — only submit
///      from a foreground user action.
///   2. identifier MUST be the exact-case bundle-id prefix.
///   3. >30s without a STRICTLY-INCREASING completedUnitCount = the system
///      kills it — the handler ticks monotonic progress every 2s.
/// A single umbrella covers all active reconstruction job IDs. Foreground
/// round-trips never recycle it: completing one card and submitting another is
/// visible as duplicate Dynamic Island tasks and violates user expectations.
/// Always setTaskCompleted(success: true): a NO leaves a system "task failed"
/// tombstone card the app can't remove; the umbrella being recycled ≠ failure.
@available(iOS 26.0, *)
final class ReconUmbrella {
  static let shared = ReconUmbrella()

  private let identifier = "com.kyle.PocketWorld.recon"  // exact-case bundle prefix
  private let lock = NSLock()
  private var activeJobs = Set<String>()
  private var handlerFired = false  // handler currently holding the one grant
  private var registered = false
  private var lastSubmit = Date(timeIntervalSince1970: 0)
  // ──【案④ 2026-07-11】真实进度通道:Dart 在 finalize 阶段边界推
  // (phase1 done → 0.10 / refined → 0.75 / colorize done → 0.85 /
  // persist ok → 0.95)。合成爬行曲线保留为"底"(iOS 30s 严格递增
  // 看门狗的保险),handler 每 tick 取 max(合成, 真实)→ 永远单调、
  // 永不回退;completed=100% 仍只由 endReconUmbrella 置。
  private var realProgressUnits: Int64 = 0  // 0..10000
  private var realSubtitle: String? = nil

  private func sync<T>(_ body: () -> T) -> T {
    lock.lock(); defer { lock.unlock() }; return body()
  }

  /// Register the launch handler ONCE (before the app finishes launching);
  /// registering the same identifier twice makes the system kill the app.
  func register() {
    if registered { return }
    registered = true
    // A queued request belongs to a previous process lifetime. Recovery is no
    // longer automatic at launch, so it has no user-authorized job to serve.
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: identifier,
      using: DispatchQueue.global(qos: .userInitiated)
    ) { [weak self] task in
      guard let cp = task as? BGContinuedProcessingTask else {
        task.setTaskCompleted(success: true); return
      }
      self?.runHandler(cp)
    }
  }

  /// A user-triggered finalize started. Repeating begin for the same job, or
  /// starting another finalize while one umbrella is active, never submits a
  /// second system task.
  func begin(jobID: String) {
    let key = jobID.isEmpty ? "legacy" : jobID
    let shouldSubmit = sync { () -> Bool in
      let inserted = activeJobs.insert(key).inserted
      let fresh = inserted && activeJobs.count == 1
      if fresh {
        // 新一单重建 → 清掉上一单遗留的真实进度(合成曲线从 0 重爬)。
        realProgressUnits = 0
        realSubtitle = nil
      }
      return fresh && !handlerFired
    }
    guard shouldSubmit else { return }
    submit(via: "begin")
  }

  /// 案④:Dart 阶段边界推真实进度(fraction 0..1)+ 阶段文案。只升不降
  /// (锁内 max),消费在 runHandler 的 2s tick 里(与合成爬行取 max)。
  func setRealProgress(fraction: Double, subtitle: String?) {
    let units = Int64((fraction.isFinite ? min(max(fraction, 0), 1) : 0) * 10000)
    sync {
      if units > realProgressUnits { realProgressUnits = units }
      if let s = subtitle, !s.isEmpty { realSubtitle = s }
    }
  }

  /// Complete the shared umbrella only after its final reconstruction job ends.
  func end(jobID: String) {
    let key = jobID.isEmpty ? "legacy" : jobID
    let allDone = sync { () -> Bool in
      activeJobs.remove(key)
      return activeJobs.isEmpty
    }
    if allDone {
      BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
  }

  private func submit(via: String) {
    if sync({ activeJobs.isEmpty }) { return }
    if UIApplication.shared.applicationState == .background { return }  // #1
    if Date().timeIntervalSince(lastSubmit) < 2.0 { return }
    lastSubmit = Date()
    // Do not queue a request that may surface on a later app launch with no
    // active user job. Immediate-or-fail is the only acceptable UI contract.
    _ = trySubmit(strategy: .fail, via: "\(via)/fail")
  }

  private func trySubmit(
    strategy: BGContinuedProcessingTaskRequest.SubmissionStrategy, via: String
  ) -> Bool {
    let req = BGContinuedProcessingTaskRequest(
      identifier: identifier,
      title: "PocketWorld 重建",
      subtitle: "正在生成稀疏点云…")
    req.strategy = strategy
    do {
      try BGTaskScheduler.shared.submit(req)
      return true
    } catch {
      NSLog("[ReconUmbrella] submit(\(via)) failed: \(error)")
      return false
    }
  }

  private func runHandler(_ task: BGContinuedProcessingTask) {
    sync { handlerFired = true }
    let prog = task.progress
    prog.totalUnitCount = 10000
    prog.completedUnitCount = max(prog.completedUnitCount, 100)
    var expired = false
    task.expirationHandler = { [weak self] in
      self?.sync { expired = true }
    }
    let t0 = Date()
    var appliedSubtitle: String? = nil
    // Hold the grant open, ticking MONOTONIC progress every 2s (#4). Synthetic
    // crawl: ~linear to 51% by 280s (dodge the 300s first ROP prompt), then a
    // slow creep, capped 99% — never pins, so the strict-monotonic stall
    // deadline can't trip during a genuinely long finalize.
    // 案④:真实进度(Dart 阶段边界推,setRealProgress)与合成爬行取 max
    // —— 真实值把进度往前跳,合成爬行在阶段之间兜底单调递增,永不回退。
    while !sync({ expired }) {
      if sync({ activeJobs.isEmpty }) { break }
      Thread.sleep(forTimeInterval: 2.0)
      let (real, subtitle) = sync { (realProgressUnits, realSubtitle) }
      let el = Date().timeIntervalSince(t0)
      let env = el <= 280 ? Int64(5100.0 * el / 280.0)
                          : 5100 + Int64((el - 280.0) / 6.0)
      let next = min(Int64(9900), max(prog.completedUnitCount + 40, max(env, real)))
      if next > prog.completedUnitCount { prog.completedUnitCount = next }
      // 阶段文案跟着真实进度走(灵动岛副标题);只在变化时调用。
      if let s = subtitle, s != appliedSubtitle {
        appliedSubtitle = s
        task.updateTitle("PocketWorld 重建", subtitle: s)
      }
    }
    if sync({ activeJobs.isEmpty }) {
      prog.completedUnitCount = prog.totalUnitCount
    }
    task.setTaskCompleted(success: true)  // ALWAYS YES — no tombstone card
    sync { handlerFired = false }
  }
}
