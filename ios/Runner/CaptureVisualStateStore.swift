import CoreGraphics
import Foundation

struct CaptureVisualSnapshot {
  let generation: UInt64
  let photoCardsVisible: Bool
  let glassEnabled: Bool
  let glassRect: CGRect?
}

final class CaptureVisualStateStore {
  private let lock = NSLock()
  private var generation: UInt64 = 0
  private var photoCardsVisible = true
  private var glassEnabled = false
  private var glassRect: CGRect?

  func snapshot() -> CaptureVisualSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return CaptureVisualSnapshot(
      generation: generation,
      photoCardsVisible: photoCardsVisible,
      glassEnabled: glassEnabled,
      glassRect: glassRect
    )
  }

  func setPhotoCardsVisible(_ visible: Bool) {
    lock.lock()
    defer { lock.unlock() }
    guard visible != photoCardsVisible else { return }
    photoCardsVisible = visible
    generation &+= 1
  }

  func setGlassEnabled(_ enabled: Bool) {
    lock.lock()
    defer { lock.unlock() }
    guard enabled != glassEnabled else { return }
    glassEnabled = enabled
    generation &+= 1
  }

  func setGlassRect(_ rect: CGRect) {
    guard Self.isValid(rect) else { return }
    lock.lock()
    defer { lock.unlock() }
    guard rect != glassRect else { return }
    glassRect = rect
    generation &+= 1
  }

  private static func isValid(_ rect: CGRect) -> Bool {
    let components = [
      rect.origin.x,
      rect.origin.y,
      rect.size.width,
      rect.size.height,
    ]
    return components.allSatisfy { $0.isFinite }
      && !rect.isNull
      && !rect.isInfinite
      && !rect.isEmpty
  }
}
