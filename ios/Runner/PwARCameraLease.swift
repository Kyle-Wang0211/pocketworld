import Foundation

/// Process-wide ownership gate for the single physical camera used by ARKit.
///
/// This type deliberately owns no ARSession, capture, reconstruction, or
/// algorithm state. The two independently registered plugins acquire it only
/// when handling `startSession` and release it on every stop/failure path.
final class PwARCameraLease {
  static let shared = PwARCameraLease()

  private let lock = NSLock()
  private var owner: String?

  private init() {}

  /// Acquires the camera for `owner`. Re-acquiring by the same route is
  /// idempotent; a different route always fails closed.
  func acquire(owner requestedOwner: String) -> Bool {
    guard !requestedOwner.isEmpty else { return false }
    lock.lock()
    defer { lock.unlock() }
    guard owner == nil || owner == requestedOwner else { return false }
    owner = requestedOwner
    return true
  }

  /// Releases only when the caller currently owns the camera. A stale route
  /// cannot release another route's live session.
  func release(owner requestedOwner: String) {
    lock.lock()
    defer { lock.unlock() }
    if owner == requestedOwner { owner = nil }
  }

  func isOwned(by requestedOwner: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return owner == requestedOwner
  }

}
