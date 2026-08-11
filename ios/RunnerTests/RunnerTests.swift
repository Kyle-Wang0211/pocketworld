import Flutter
import simd
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  func testLiveCloudAnchorSeverityBoundariesAreObservationOnly() {
    XCTAssertEqual(
      LiveCloudAnchorDiagnostics.severity(translationMeters: 0.049999),
      "normal"
    )
    XCTAssertEqual(
      LiveCloudAnchorDiagnostics.severity(translationMeters: 0.05),
      "warning"
    )
    XCTAssertEqual(
      LiveCloudAnchorDiagnostics.severity(translationMeters: 0.099999),
      "warning"
    )
    XCTAssertEqual(
      LiveCloudAnchorDiagnostics.severity(translationMeters: 0.10),
      "severe"
    )
  }

  func testLiveCloudAnchorDeltaReportsTranslationAndRotation() {
    var lock = simd_float4x4(
      simd_quatf(angle: .pi / 3, axis: simd_normalize(SIMD3<Float>(1, 2, 3)))
    )
    lock.columns.3 = SIMD4<Float>(1.2, -0.7, 2.4, 1)
    var expectedRelative = simd_float4x4(
      simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))
    )
    expectedRelative.columns.3 = SIMD4<Float>(0.10, -0.02, 0.03, 1)
    let current = lock * expectedRelative

    let delta = LiveCloudAnchorDiagnostics.delta(lock: lock, current: current)
    XCTAssertEqual(delta.translation.x, 0.10, accuracy: 1e-5)
    XCTAssertEqual(delta.translation.y, -0.02, accuracy: 1e-5)
    XCTAssertEqual(delta.translation.z, 0.03, accuracy: 1e-5)
    XCTAssertEqual(delta.translationMeters, sqrt(0.0100 + 0.0004 + 0.0009), accuracy: 1e-5)
    XCTAssertEqual(delta.rotationDegrees, 90, accuracy: 1e-4)
  }

  override func tearDown() {
    PwARCameraLease.shared.release(
      owner: SelfDevelopedARKitIdentifiers.cameraOwner
    )
    PwARCameraLease.shared.release(owner: OfficialARKitIdentifiers.cameraOwner)
    super.tearDown()
  }

  func testOfficialARKitTransportIdentifiersAreIndependent() {
    XCTAssertEqual(
      OfficialARKitIdentifiers.methodChannel,
      "pocketworld_official_arkit"
    )
    XCTAssertEqual(
      OfficialARKitIdentifiers.poseEventChannel,
      "pocketworld_official_arkit/pose_stream"
    )
    XCTAssertEqual(
      OfficialARKitIdentifiers.previewView,
      "pocketworld_official_arkit_preview"
    )
    XCTAssertEqual(
      Set([
        OfficialARKitIdentifiers.methodChannel,
        OfficialARKitIdentifiers.poseEventChannel,
        OfficialARKitIdentifiers.previewView,
      ]).count,
      3
    )
    XCTAssertNotEqual(
      SelfDevelopedARKitIdentifiers.cameraOwner,
      OfficialARKitIdentifiers.cameraOwner
    )
  }

  @available(iOS 26.0, *)
  func testOfficialReconUsesIndependentBackgroundTaskIdentifier() {
    XCTAssertEqual(
      OfficialReconUmbrella.taskIdentifier,
      "com.kyle.PocketWorld.official.recon"
    )
  }

  func testCameraLeaseFailsClosedAcrossPipelineOwners() {
    let lease = PwARCameraLease.shared
    XCTAssertTrue(lease.acquire(owner: "self"))
    XCTAssertFalse(lease.acquire(owner: "official"))
    XCTAssertTrue(lease.isOwned(by: "self"))
    lease.release(owner: "official")
    XCTAssertTrue(lease.isOwned(by: "self"))
    lease.release(owner: "self")
    XCTAssertTrue(lease.acquire(owner: "official"))
  }

  func testCameraLeaseAllowsIdempotentAcquireBySameOwner() {
    let lease = PwARCameraLease.shared
    XCTAssertTrue(lease.acquire(owner: "official"))
    XCTAssertTrue(lease.acquire(owner: "official"))
    lease.release(owner: "official")
    XCTAssertFalse(lease.isOwned(by: "official"))
  }

  func testHighResolutionMetadataDropsOnlyNonFiniteAnchorPairs() {
    let sanitized = PWJSONSafety.finitePointPairs(
      [
        [1, 2, 3],
        [4, .nan, 6],
        [7, 8, 9],
        [.infinity, 11, 12],
      ],
      identifiers: [101, 102, 103, 104]
    )

    XCTAssertEqual(sanitized.points, [[1, 2, 3], [7, 8, 9]])
    XCTAssertEqual(sanitized.identifiers, [101, 103])
  }

  func testHighResolutionMetadataKeepsAnchorPairingWhenCountsDiffer() {
    let sanitized = PWJSONSafety.finitePointPairs(
      [[1, 2, 3], [4, 5, 6]],
      identifiers: [201]
    )

    XCTAssertEqual(sanitized.points, [[1, 2, 3]])
    XCTAssertEqual(sanitized.identifiers, [201])
  }

  func testHighResolutionMetadataRejectsNonFiniteRequiredGeometry() {
    XCTAssertThrowsError(
      try PWJSONSafety.requireFinite(
        [1, .nan, 3],
        field: "extrinsic"
      )
    )
    XCTAssertNoThrow(
      try PWJSONSafety.requireFinite(
        [1, 2, 3],
        field: "intrinsics_fxfycxcy"
      )
    )
  }

  func testHighResolutionMetadataRejectsInvalidNestedJSONBeforeSerialization() {
    XCTAssertThrowsError(
      try PWJSONSafety.data(
        withJSONObject: ["anchors_world": [[Float.nan, 0, 1]]]
      )
    )

    let data = try? PWJSONSafety.data(
      withJSONObject: ["anchors_world": [[Float(1), 2, 3]]]
    )
    XCTAssertNotNil(data)
  }

}
