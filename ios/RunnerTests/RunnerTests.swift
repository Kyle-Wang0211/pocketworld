import Flutter
@testable import Runner
import UIKit
import XCTest

class RunnerTests: XCTestCase {

  func testCaptureVisualDefaultsAreStable() {
    let store = CaptureVisualStateStore()

    let initial = store.snapshot()
    let repeated = store.snapshot()

    XCTAssertTrue(initial.photoCardsVisible)
    XCTAssertFalse(initial.glassEnabled)
    XCTAssertNil(initial.glassRect)
    XCTAssertEqual(repeated.generation, initial.generation)
  }

  func testCaptureVisualGenerationIncrementsOnlyForActualChanges() {
    let store = CaptureVisualStateStore()
    let initialGeneration = store.snapshot().generation

    store.setPhotoCardsVisible(false)
    let afterCardsChange = store.snapshot().generation
    XCTAssertEqual(afterCardsChange, initialGeneration + 1)
    XCTAssertFalse(store.snapshot().photoCardsVisible)

    store.setPhotoCardsVisible(false)
    XCTAssertEqual(store.snapshot().generation, afterCardsChange)

    store.setGlassEnabled(true)
    let afterGlassChange = store.snapshot().generation
    XCTAssertEqual(afterGlassChange, afterCardsChange + 1)
    XCTAssertTrue(store.snapshot().glassEnabled)

    store.setGlassEnabled(true)
    XCTAssertEqual(store.snapshot().generation, afterGlassChange)
  }

  func testCaptureVisualRectRejectsNonFiniteAndEmptyGeometry() {
    let store = CaptureVisualStateStore()
    let invalidRects = [
      CGRect(x: CGFloat.nan, y: 10, width: 176, height: 52),
      CGRect(x: 10, y: CGFloat.infinity, width: 176, height: 52),
      CGRect(x: 10, y: 20, width: -CGFloat.infinity, height: 52),
      CGRect(x: 10, y: 20, width: 0, height: 52),
      CGRect(x: 10, y: 20, width: 176, height: 0),
      CGRect(x: 10, y: 20, width: -176, height: 52),
      CGRect(x: 10, y: 20, width: 176, height: -52),
    ]

    let initialGeneration = store.snapshot().generation
    for rect in invalidRects {
      store.setGlassRect(rect)
      XCTAssertNil(store.snapshot().glassRect)
      XCTAssertEqual(store.snapshot().generation, initialGeneration)
    }
  }

  func testCaptureVisualRectStoresValidGeometryAndIgnoresDuplicate() {
    let store = CaptureVisualStateStore()
    let valid = CGRect(x: 10, y: 20, width: 176, height: 52)
    let initialGeneration = store.snapshot().generation

    store.setGlassRect(valid)
    let updated = store.snapshot()
    XCTAssertEqual(updated.glassRect, valid)
    XCTAssertEqual(updated.generation, initialGeneration + 1)

    store.setGlassRect(valid)
    XCTAssertEqual(store.snapshot().generation, updated.generation)
  }

}
