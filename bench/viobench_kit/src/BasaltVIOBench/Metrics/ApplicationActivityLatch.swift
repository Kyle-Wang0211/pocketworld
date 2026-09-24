import Foundation
import UIKit

/// Lossless run-scope foreground evidence. One-hertz telemetry remains useful
/// for receipts, but it cannot prove that no short inactive/background interval
/// occurred between samples.
final class ApplicationActivityLatch {
    struct Snapshot: Equatable {
        let violationCount: UInt64
    }

    private let center: NotificationCenter
    private let willResignActiveName: Notification.Name
    private let didEnterBackgroundName: Notification.Name
    private let lock = NSLock()
    private var tokens: [NSObjectProtocol] = []
    private var active = false
    private var violationCount: UInt64 = 0

    init(
        center: NotificationCenter = .default,
        willResignActiveName: Notification.Name = UIApplication.willResignActiveNotification,
        didEnterBackgroundName: Notification.Name = UIApplication.didEnterBackgroundNotification
    ) {
        self.center = center
        self.willResignActiveName = willResignActiveName
        self.didEnterBackgroundName = didEnterBackgroundName
    }

    func start(initiallyActive: Bool) {
        lock.withLock {
            guard !active else { return }
            active = true
            if !initiallyActive {
                violationCount += 1
            }
            tokens = [willResignActiveName, didEnterBackgroundName].map { name in
                center.addObserver(forName: name, object: nil, queue: nil) {
                    [weak self] _ in
                    self?.recordViolation()
                }
            }
        }
    }

    func stop() {
        let removed: [NSObjectProtocol] = lock.withLock {
            guard active else { return [] }
            active = false
            let removed = tokens
            tokens.removeAll(keepingCapacity: false)
            return removed
        }
        removed.forEach(center.removeObserver)
    }

    func snapshot() -> Snapshot {
        lock.withLock { Snapshot(violationCount: violationCount) }
    }

    private func recordViolation() {
        lock.withLock {
            guard active else { return }
            violationCount += 1
        }
    }

    deinit {
        stop()
    }
}
