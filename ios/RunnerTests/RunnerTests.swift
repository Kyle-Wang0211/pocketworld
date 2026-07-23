import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

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

}
