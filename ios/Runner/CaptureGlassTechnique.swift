import ARKit
import Metal
import SceneKit
import UIKit

struct CaptureGlassLayout: Equatable {
  let viewportPoints: CGRect
  let glassRectPixels: CGRect
  let fullSizePixels: CGSize
  let inverseFullSizePixels: CGSize
  let contentScale: CGFloat

  init?(
    viewBounds: CGRect,
    contentScale: CGFloat,
    logicalRect: CGRect,
    guardPixels: CGFloat = 6
  ) {
    guard Self.isFinitePositiveRect(viewBounds),
          Self.isFinitePositiveRect(logicalRect),
          contentScale.isFinite,
          contentScale > 0,
          guardPixels.isFinite,
          guardPixels >= 0 else {
      return nil
    }

    let clippedGlass = logicalRect.intersection(viewBounds)
    guard Self.isFinitePositiveRect(clippedGlass) else { return nil }

    let fullWidthPixels = viewBounds.width * contentScale
    let fullHeightPixels = viewBounds.height * contentScale
    guard fullWidthPixels.isFinite,
          fullHeightPixels.isFinite,
          fullWidthPixels > 0,
          fullHeightPixels > 0,
          fullWidthPixels <= CGFloat(Float.greatestFiniteMagnitude),
          fullHeightPixels <= CGFloat(Float.greatestFiniteMagnitude) else {
      return nil
    }

    let glassMinX = (clippedGlass.minX - viewBounds.minX) * contentScale
    let glassMinY = (clippedGlass.minY - viewBounds.minY) * contentScale
    let glassMaxX = (clippedGlass.maxX - viewBounds.minX) * contentScale
    let glassMaxY = (clippedGlass.maxY - viewBounds.minY) * contentScale
    let pixelValues = [glassMinX, glassMinY, glassMaxX, glassMaxY]
    guard pixelValues.allSatisfy(\.isFinite) else { return nil }

    let viewportMinX = max(0, floor(glassMinX - guardPixels))
    let viewportMinY = max(0, floor(glassMinY - guardPixels))
    let viewportMaxX = min(fullWidthPixels, ceil(glassMaxX + guardPixels))
    let viewportMaxY = min(fullHeightPixels, ceil(glassMaxY + guardPixels))
    guard viewportMaxX > viewportMinX, viewportMaxY > viewportMinY else {
      return nil
    }

    viewportPoints = CGRect(
      x: viewBounds.minX + viewportMinX / contentScale,
      y: viewBounds.minY + viewportMinY / contentScale,
      width: (viewportMaxX - viewportMinX) / contentScale,
      height: (viewportMaxY - viewportMinY) / contentScale
    )
    glassRectPixels = CGRect(
      x: glassMinX,
      y: glassMinY,
      width: glassMaxX - glassMinX,
      height: glassMaxY - glassMinY
    )
    fullSizePixels = CGSize(width: fullWidthPixels, height: fullHeightPixels)
    inverseFullSizePixels = CGSize(
      width: 1 / fullWidthPixels,
      height: 1 / fullHeightPixels
    )
    self.contentScale = contentScale
  }

  var captureViewport: SCNVector4 {
    SCNVector4(
      Float(fullSizePixels.width),
      Float(fullSizePixels.height),
      Float(inverseFullSizePixels.width),
      Float(inverseFullSizePixels.height)
    )
  }

  var captureGlassRect: SCNVector4 {
    SCNVector4(
      Float(glassRectPixels.midX),
      Float(glassRectPixels.midY),
      Float(glassRectPixels.width / 2),
      Float(glassRectPixels.height / 2)
    )
  }

  var captureGlassOptics: SCNVector4 {
    SCNVector4(
      Float(20 * contentScale),
      Float(2 * contentScale),
      Float(8.0 / 255.0),
      1
    )
  }

  private static func isFinitePositiveRect(_ rect: CGRect) -> Bool {
    rect.origin.x.isFinite
      && rect.origin.y.isFinite
      && rect.width.isFinite
      && rect.height.isFinite
      && rect.width > 0
      && rect.height > 0
      && !rect.isNull
      && !rect.isInfinite
  }
}

enum CaptureGlassTechniqueBuilder {
  static let passName = "captureGlass"
  static let vertexFunctionName = "captureGlassVertex"
  static let fragmentFunctionName = "captureGlassFragment"

  static func dictionary(viewportPoints: CGRect) -> [String: Any] {
    [
      "sequence": [passName],
      "passes": [
        passName: [
          "draw": "DRAW_QUAD",
          "metalVertexShader": vertexFunctionName,
          "metalFragmentShader": fragmentFunctionName,
          "inputs": [
            "sceneColor": "COLOR",
            "captureViewport": "captureViewport",
            "captureGlassRect": "captureGlassRect",
            "captureGlassOptics": "captureGlassOptics",
          ],
          "outputs": ["color": "COLOR"],
          "colorStates": ["clear": false],
          "viewport": viewportString(viewportPoints),
        ],
      ],
      "symbols": [
        "captureViewport": ["type": "vec4"],
        "captureGlassRect": ["type": "vec4"],
        "captureGlassOptics": ["type": "vec4"],
      ],
    ]
  }

  static func makeTechnique(
    viewportPoints: CGRect,
    device: MTLDevice? = MTLCreateSystemDefaultDevice(),
    bundle: Bundle = .main
  ) -> SCNTechnique? {
    guard let device,
          let library = try? device.makeDefaultLibrary(bundle: bundle),
          library.makeFunction(name: vertexFunctionName) != nil,
          library.makeFunction(name: fragmentFunctionName) != nil,
          let technique = SCNTechnique(
            dictionary: dictionary(viewportPoints: viewportPoints)
          ) else {
      return nil
    }
    technique.library = library
    return technique
  }

  private static func viewportString(_ rect: CGRect) -> String {
    [rect.minX, rect.minY, rect.width, rect.height]
      .map {
        String(
          format: "%.9g",
          locale: Locale(identifier: "en_US_POSIX"),
          Double($0)
        )
      }
      .joined(separator: " ")
  }
}

final class CaptureGlassTechniqueController {
  private weak var view: ARSCNView?
  private var installedLayout: CaptureGlassLayout?

  init(view: ARSCNView) {
    self.view = view
  }

  func apply(globalRect: CGRect?, enabled: Bool) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let view else { return }
    view.rendersCameraGrain = false

    guard enabled,
          let globalRect,
          let window = view.window else {
      remove()
      return
    }

    let localRect = view.convert(globalRect, from: window)
    guard let layout = CaptureGlassLayout(
      viewBounds: view.bounds,
      contentScale: view.contentScaleFactor,
      logicalRect: localRect
    ) else {
      remove()
      return
    }

    if installedLayout == layout, view.technique != nil {
      return
    }

    guard let technique = CaptureGlassTechniqueBuilder.makeTechnique(
      viewportPoints: layout.viewportPoints
    ) else {
      remove()
      return
    }

    view.technique = technique
    guard let installedTechnique = view.technique else {
      installedLayout = nil
      return
    }
    installedTechnique.setValue(
      layout.captureViewport,
      forKey: "captureViewport"
    )
    installedTechnique.setValue(
      layout.captureGlassRect,
      forKey: "captureGlassRect"
    )
    installedTechnique.setValue(
      layout.captureGlassOptics,
      forKey: "captureGlassOptics"
    )
    installedLayout = layout
  }

  func remove() {
    dispatchPrecondition(condition: .onQueue(.main))
    view?.technique = nil
    installedLayout = nil
  }
}

final class CaptureGlassARSCNView: ARSCNView {
  var captureGlassLayoutDidChange: (() -> Void)?

  override func layoutSubviews() {
    super.layoutSubviews()
    captureGlassLayoutDidChange?()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    captureGlassLayoutDidChange?()
  }
}
