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
      return inserted && activeJobs.count == 1 && !handlerFired
    }
    guard shouldSubmit else { return }
    submit(via: "begin")
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
    // Hold the grant open, ticking MONOTONIC progress every 2s (#4). Synthetic
    // crawl: ~linear to 51% by 280s (dodge the 300s first ROP prompt), then a
    // slow creep, capped 99% — never pins, so the strict-monotonic stall
    // deadline can't trip during a genuinely long finalize.
    while !sync({ expired }) {
      if sync({ activeJobs.isEmpty }) { break }
      Thread.sleep(forTimeInterval: 2.0)
      let el = Date().timeIntervalSince(t0)
      let env = el <= 280 ? Int64(5100.0 * el / 280.0)
                          : 5100 + Int64((el - 280.0) / 6.0)
      let next = min(Int64(9900), max(prog.completedUnitCount + 40, env))
      if next > prog.completedUnitCount { prog.completedUnitCount = next }
    }
    if sync({ activeJobs.isEmpty }) {
      prog.completedUnitCount = prog.totalUnitCount
    }
    task.setTaskCompleted(success: true)  // ALWAYS YES — no tombstone card
    sync { handlerFired = false }
  }
}
