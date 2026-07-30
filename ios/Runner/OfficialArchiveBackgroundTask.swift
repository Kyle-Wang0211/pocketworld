import BackgroundTasks
import Flutter
import UIKit

/// iOS execution-opportunity bridge for the official cold archive.
///
/// Dart remains the only owner of eligibility, hashing, verification,
/// transaction commits, and deletion. This class persists a system wake-up
/// request, holds the granted task until Dart finishes, and forwards expiration
/// so the coordinator can pause at its existing safe boundary.
@available(iOS 13.0, *)
final class OfficialArchiveBackgroundTask {
  static let shared = OfficialArchiveBackgroundTask()
  static let taskIdentifier = "com.kyle.PocketWorld.official.archive"

  private let identifier = OfficialArchiveBackgroundTask.taskIdentifier
  private let lock = NSLock()
  private var registered = false
  private var dartReady = false
  private var channel: FlutterMethodChannel?
  private var pendingTask: BGProcessingTask?
  private var runningTask: BGProcessingTask?
  private var runningTaskExpired = false

  private func sync<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  /// Register before application launch completes so iOS can deliver a queued
  /// background task even when it launches a fresh process.
  func register(with registrar: FlutterPluginRegistrar) {
    let methodChannel = FlutterMethodChannel(
      name: "pocketworld_official_archive_background",
      binaryMessenger: registrar.messenger()
    )
    channel = methodChannel
    methodChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(
          FlutterError(
            code: "archive_bridge_unavailable",
            message: "Official archive background bridge released",
            details: nil
          )
        )
        return
      }
      switch call.method {
      case "ready":
        self.sync { self.dartReady = true }
        result(nil)
        self.startPendingTaskIfPossible()
      case "schedule":
        do {
          try self.scheduleIfNeeded()
          result(nil)
        } catch {
          result(
            FlutterError(
              code: "archive_bg_schedule_failed",
              message: "\(error)",
              details: nil
            )
          )
        }
      case "cancelScheduled":
        BGTaskScheduler.shared.cancel(
          taskRequestWithIdentifier: self.identifier
        )
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let shouldRegister = sync { () -> Bool in
      if registered { return false }
      registered = true
      return true
    }
    guard shouldRegister else { return }
    let accepted = BGTaskScheduler.shared.register(
      forTaskWithIdentifier: identifier,
      using: DispatchQueue.main
    ) { [weak self] task in
      guard
        let self,
        let processingTask = task as? BGProcessingTask
      else {
        task.setTaskCompleted(success: false)
        return
      }
      self.accept(processingTask)
    }
    if !accepted {
      NSLog("[OfficialArchiveBackgroundTask] registration rejected")
    }
  }

  private func scheduleIfNeeded() throws {
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    let request = BGProcessingTaskRequest(identifier: identifier)
    request.requiresExternalPower = false
    request.requiresNetworkConnectivity = false
    try BGTaskScheduler.shared.submit(request)
  }

  private func accept(_ task: BGProcessingTask) {
    let accepted = sync { () -> Bool in
      guard pendingTask == nil, runningTask == nil else { return false }
      pendingTask = task
      return true
    }
    guard accepted else {
      task.setTaskCompleted(success: false)
      return
    }
    task.expirationHandler = { [weak self, weak task] in
      guard let self, let task else { return }
      let running = self.sync { () -> Bool in
        if self.runningTask === task {
          self.runningTaskExpired = true
          return true
        }
        if self.pendingTask === task {
          self.pendingTask = nil
        }
        return false
      }
      self.channel?.invokeMethod("cancelColdArchive", arguments: nil)
      if !running {
        task.setTaskCompleted(success: false)
        try? self.scheduleIfNeeded()
      }
    }
    startPendingTaskIfPossible()
  }

  private func startPendingTaskIfPossible() {
    let work = sync { () -> (BGProcessingTask, FlutterMethodChannel)? in
      guard
        dartReady,
        runningTask == nil,
        let task = pendingTask,
        let channel
      else {
        return nil
      }
      pendingTask = nil
      runningTask = task
      runningTaskExpired = false
      return (task, channel)
    }
    guard let (task, methodChannel) = work else { return }

    methodChannel.invokeMethod("runColdArchive", arguments: nil) {
      [weak self, weak task] response in
      guard let self, let task else { return }
      let values = response as? [String: Any]
      let success = (values?["success"] as? NSNumber)?.boolValue ?? false
      let workRemaining =
        (values?["work_remaining"] as? NSNumber)?.boolValue ?? true
      let expired = self.sync { () -> Bool in
        let value = self.runningTaskExpired
        if self.runningTask === task {
          self.runningTask = nil
          self.runningTaskExpired = false
        }
        return value
      }
      task.setTaskCompleted(success: success && !expired)
      if workRemaining {
        try? self.scheduleIfNeeded()
      }
    }
  }
}
