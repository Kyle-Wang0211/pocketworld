import Flutter
import SceneKit
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

  func testCaptureGlassLayoutSeparatesPointViewportAndPixelUniforms() throws {
    let layout = try XCTUnwrap(CaptureGlassLayout(
      viewBounds: CGRect(x: 0, y: 0, width: 393, height: 852),
      contentScale: 3,
      logicalRect: CGRect(x: 108.5, y: 680, width: 176, height: 52),
      guardPixels: 6
    ))

    XCTAssertEqual(layout.glassRectPixels.width, 528, accuracy: 0.001)
    XCTAssertEqual(layout.glassRectPixels.height, 156, accuracy: 0.001)
    XCTAssertEqual(layout.fullSizePixels.width, 1179, accuracy: 0.001)
    XCTAssertEqual(layout.fullSizePixels.height, 2556, accuracy: 0.001)
    XCTAssertEqual(layout.inverseFullSizePixels.width, 1 / 1179, accuracy: 0.000_001)
    XCTAssertEqual(layout.inverseFullSizePixels.height, 1 / 2556, accuracy: 0.000_001)
    XCTAssertEqual(layout.captureViewport.x, 1179, accuracy: 0.001)
    XCTAssertEqual(layout.captureViewport.y, 2556, accuracy: 0.001)
    XCTAssertEqual(layout.captureViewport.z, 1 / 1179, accuracy: 0.000_001)
    XCTAssertEqual(layout.captureViewport.w, 1 / 2556, accuracy: 0.000_001)
    XCTAssertEqual(layout.captureGlassRect.x, 589.5, accuracy: 0.001)
    XCTAssertEqual(layout.captureGlassRect.y, 2118, accuracy: 0.001)
    XCTAssertEqual(layout.captureGlassRect.z, 264, accuracy: 0.001)
    XCTAssertEqual(layout.captureGlassRect.w, 78, accuracy: 0.001)
    XCTAssertEqual(layout.captureGlassOptics.x, 60, accuracy: 0.001)
    XCTAssertEqual(layout.captureGlassOptics.y, 6, accuracy: 0.001)
    XCTAssertEqual(layout.captureGlassOptics.z, 8 / 255, accuracy: 0.000_001)
    XCTAssertEqual(layout.captureGlassOptics.w, 1, accuracy: 0.001)
    XCTAssertTrue(layout.viewportPoints.contains(
      CGRect(x: 108.5, y: 680, width: 176, height: 52)
    ))
    XCTAssertEqual(108.5 - layout.viewportPoints.minX, 2 + (0.5 / 3), accuracy: 0.001)
    XCTAssertEqual(layout.viewportPoints.maxX - 284.5, 2 + (0.5 / 3), accuracy: 0.001)
    XCTAssertEqual(layout.viewportPoints.minX * 3,
                   floor(layout.viewportPoints.minX * 3), accuracy: 0.001)
    XCTAssertEqual(layout.viewportPoints.maxX * 3,
                   ceil(layout.viewportPoints.maxX * 3), accuracy: 0.001)
  }

  func testCaptureGlassLayoutGuardClampsToViewBounds() throws {
    let layout = try XCTUnwrap(CaptureGlassLayout(
      viewBounds: CGRect(x: 0, y: 0, width: 393, height: 852),
      contentScale: 3,
      logicalRect: CGRect(x: 0.5, y: 0.5, width: 176, height: 52),
      guardPixels: 6
    ))

    XCTAssertEqual(layout.viewportPoints.minX, 0, accuracy: 0.001)
    XCTAssertEqual(layout.viewportPoints.minY, 0, accuracy: 0.001)
    XCTAssertLessThanOrEqual(layout.viewportPoints.maxX, 393)
    XCTAssertLessThanOrEqual(layout.viewportPoints.maxY, 852)
  }

  func testCaptureGlassLayoutRejectsInvalidGeometryAndScale() {
    let validBounds = CGRect(x: 0, y: 0, width: 393, height: 852)
    let validRect = CGRect(x: 108.5, y: 680, width: 176, height: 52)
    let invalidCases: [(CGRect, CGFloat, CGRect, CGFloat)] = [
      (CGRect(x: 0, y: 0, width: 0, height: 852), 3, validRect, 6),
      (CGRect(x: 0, y: 0, width: 393, height: -852), 3, validRect, 6),
      (CGRect(x: CGFloat.nan, y: 0, width: 393, height: 852), 3, validRect, 6),
      (validBounds, 0, validRect, 6),
      (validBounds, -.infinity, validRect, 6),
      (validBounds, 3, CGRect(x: 10, y: 20, width: 0, height: 52), 6),
      (validBounds, 3, CGRect(x: 10, y: 20, width: -176, height: 52), 6),
      (validBounds, 3, CGRect(x: 10, y: 20, width: 176, height: CGFloat.nan), 6),
      (validBounds, 3, CGRect(x: 500, y: 20, width: 176, height: 52), 6),
      (validBounds, 3, validRect, -1),
    ]

    for (bounds, scale, rect, guardPixels) in invalidCases {
      XCTAssertNil(CaptureGlassLayout(
        viewBounds: bounds,
        contentScale: scale,
        logicalRect: rect,
        guardPixels: guardPixels
      ))
    }
  }

  func testCaptureGlassTechniqueDictionaryIsExactlyOnePassAndNeverClears() throws {
    let dictionary = CaptureGlassTechniqueBuilder.dictionary(
      viewportPoints: CGRect(x: 100.5, y: 633.25, width: 180, height: 56)
    )

    XCTAssertEqual(Set(dictionary.keys), Set(["sequence", "passes", "symbols"]))
    XCTAssertEqual(dictionary["sequence"] as? [String], ["captureGlass"])

    let symbols = try XCTUnwrap(dictionary["symbols"] as? [String: [String: String]])
    XCTAssertEqual(Set(symbols.keys), Set([
      "captureViewport", "captureGlassRect", "captureGlassOptics",
    ]))
    for symbol in symbols.values {
      XCTAssertEqual(symbol, ["type": "vec4"])
    }

    let passes = try XCTUnwrap(dictionary["passes"] as? [String: Any])
    XCTAssertEqual(Set(passes.keys), ["captureGlass"])
    let pass = try XCTUnwrap(passes["captureGlass"] as? [String: Any])
    XCTAssertEqual(Set(pass.keys), Set([
      "draw", "metalVertexShader", "metalFragmentShader", "inputs",
      "outputs", "colorStates", "viewport",
    ]))
    XCTAssertEqual(pass["draw"] as? String, "DRAW_QUAD")
    XCTAssertEqual(pass["metalVertexShader"] as? String, "captureGlassVertex")
    XCTAssertEqual(pass["metalFragmentShader"] as? String, "captureGlassFragment")
    XCTAssertEqual(pass["inputs"] as? [String: String], [
      "sceneColor": "COLOR",
      "captureViewport": "captureViewport",
      "captureGlassRect": "captureGlassRect",
      "captureGlassOptics": "captureGlassOptics",
    ])
    XCTAssertEqual(pass["outputs"] as? [String: String], ["color": "COLOR"])
    XCTAssertEqual(pass["colorStates"] as? [String: Bool], ["clear": false])
    XCTAssertEqual(pass["viewport"] as? String, "100.5 633.25 180 56")
  }

  func testCaptureGlassTechniqueDictionaryParsesWithoutARSession() {
    let dictionary = CaptureGlassTechniqueBuilder.dictionary(
      viewportPoints: CGRect(x: 100, y: 633, width: 180, height: 56)
    )

    XCTAssertNotNil(SCNTechnique(dictionary: dictionary))
  }

}
