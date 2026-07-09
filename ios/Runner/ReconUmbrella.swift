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
/// (2026-07-04, iPhone 14 Pro iOS 26.5). The four death causes it encodes:
///   1. dasd SILENTLY DROPS a submit made from the background — only submit
///      from a foreground state (begin() is called while the preview is up).
///   2. identifier MUST be the exact-case bundle-id prefix.
///   3. a foreground round-trip EXPIRES the grant ~2s after the next
///      backgrounding — on didBecomeActive we break the handler loop, complete
///      the old grant, and re-arm a fresh one.
///   4. >30s without a STRICTLY-INCREASING completedUnitCount = the system
///      kills it — the handler ticks monotonic progress every 2s.
/// Always setTaskCompleted(success: true): a NO leaves a system "task failed"
/// tombstone card the app can't remove; the umbrella being recycled ≠ failure.
@available(iOS 26.0, *)
final class ReconUmbrella {
  static let shared = ReconUmbrella()

  private let identifier = "com.kyle.PocketWorld.recon"  // exact-case bundle prefix
  private let lock = NSLock()
  private var active = false        // finalize in progress
  private var handlerFired = false  // handler currently holding a grant
  private var closeUmbrella = false // request the current grant to end (recycle)
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
    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: identifier,
      using: DispatchQueue.global(qos: .userInitiated)
    ) { [weak self] task in
      guard let cp = task as? BGContinuedProcessingTask else {
        task.setTaskCompleted(success: true); return
      }
      self?.runHandler(cp)
    }
    // Death cause #3: a true activation expired any grant taken while
    // backgrounded — break the loop (→ complete + re-arm) or arm if idle.
    NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self = self else { return }
      let (act, fired) = self.sync { (self.active, self.handlerFired) }
      if act && fired {
        self.sync { self.closeUmbrella = true }
      } else if act {
        self.submit(via: "activate")
      }
    }
  }

  /// Finalize started — arm the umbrella. MUST be called on a foreground state.
  func begin() {
    sync { active = true; closeUmbrella = false }
    submit(via: "begin")
  }

  /// Finalize + persist done — the handler loop completes the grant, and any
  /// still-pending (never-fired) request is cancelled.
  func end() {
    sync { active = false }
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
  }

  private func submit(via: String) {
    if !sync({ active }) { return }
    if UIApplication.shared.applicationState == .background { return }  // #1
    if Date().timeIntervalSince(lastSubmit) < 2.0 { return }
    lastSubmit = Date()
    // Validated recipe: try .fail first (runs NOW or errors so we see the drop),
    // fall back to .queue (run when the system is willing) if that's rejected.
    if trySubmit(strategy: .fail, via: "\(via)/fail") { return }
    _ = trySubmit(strategy: .queue, via: "\(via)/queue")
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
    sync { handlerFired = true; closeUmbrella = false }
    let prog = task.progress
    prog.totalUnitCount = 10000
    prog.completedUnitCount = max(prog.completedUnitCount, 100)
    var expired = false
    task.expirationHandler = { expired = true }
    let t0 = Date()
    // Hold the grant open, ticking MONOTONIC progress every 2s (#4). Synthetic
    // crawl: ~linear to 51% by 280s (dodge the 300s first ROP prompt), then a
    // slow creep, capped 99% — never pins, so the strict-monotonic stall
    // deadline can't trip during a genuinely long finalize.
    while !expired {
      let (done, recycle) = sync { (!active, closeUmbrella) }
      if done || recycle { break }
      Thread.sleep(forTimeInterval: 2.0)
      let el = Date().timeIntervalSince(t0)
      let env = el <= 280 ? Int64(5100.0 * el / 280.0)
                          : 5100 + Int64((el - 280.0) / 6.0)
      let next = min(Int64(9900), max(prog.completedUnitCount + 40, env))
      if next > prog.completedUnitCount { prog.completedUnitCount = next }
    }
    let recycled = sync { active && closeUmbrella && !expired }
    if sync({ !active }) { prog.completedUnitCount = prog.totalUnitCount }
    task.setTaskCompleted(success: true)  // ALWAYS YES — no tombstone card
    sync { handlerFired = false; closeUmbrella = false }
    if recycled {
      DispatchQueue.main.async { [weak self] in self?.submit(via: "recycle") }
    }
  }
}
