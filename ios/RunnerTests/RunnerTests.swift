import Foundation
import simd
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  func testARFrameAngularVelocityUsesCurrentCameraAxesAndTimeDelta() throws {
    let previous = matrix_identity_float3x3
    let current = simd_float3x3(
      simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1))
    )
    let velocity = try XCTUnwrap(
      ARFrameCaptureMetadata.angularVelocityRadPerSec(
        previousCameraToWorld: previous,
        previousTimestamp: 10,
        currentCameraToWorld: current,
        currentTimestamp: 10.5
      )
    )
    XCTAssertEqual(velocity.x, 0, accuracy: 1e-5)
    XCTAssertEqual(velocity.y, 0, accuracy: 1e-5)
    XCTAssertEqual(velocity.z, .pi, accuracy: 1e-5)
  }

  func testARFrameExifNumberFindsNestedScalarAndArrayValues() throws {
    let exif: [String: Any] = [
      "{Exif}": [
        "ExposureTime": 0.008,
        "ISOSpeedRatings": [64],
      ],
    ]
    let exposure = try XCTUnwrap(
      ARFrameCaptureMetadata.number(
        in: exif,
        matchingNormalizedKey: "exposuretime"
      )
    )
    let iso = try XCTUnwrap(
      ARFrameCaptureMetadata.number(
        in: exif,
        matchingNormalizedKey: "isospeedratings"
      )
    )
    XCTAssertEqual(exposure, 0.008, accuracy: 1e-12)
    XCTAssertEqual(iso, 64)
  }

  func testManualCaptureV2EarlyAwaitReceivesOnlyItsOwnJobOnce() throws {
    let registry = ManualCaptureV2JobRegistry()
    try register(registry, jobID: "job-a")
    try register(registry, jobID: "job-b")

    var deliveredJobID: String?
    var deliveryCount = 0
    try registry.waitForResult(jobID: "job-a") { payload in
      deliveryCount += 1
      deliveredJobID = payload["capture_job_id"] as? String
    }

    try registry.finish(
      jobID: "job-b",
      result: committedPayload(jobID: "job-b")
    )
    XCTAssertNil(deliveredJobID)
    XCTAssertEqual(deliveryCount, 0)

    try registry.finish(
      jobID: "job-a",
      result: committedPayload(jobID: "job-a")
    )
    XCTAssertEqual(deliveredJobID, "job-a")
    XCTAssertEqual(deliveryCount, 1)
  }

  func testManualCaptureV2LateAwaitReceivesCachedTerminalResultOnce() throws {
    let registry = ManualCaptureV2JobRegistry()
    try register(registry, jobID: "job-late")
    try registry.finish(
      jobID: "job-late",
      result: committedPayload(jobID: "job-late")
    )

    var deliveredPayloads: [[String: Any]] = []
    try registry.waitForResult(jobID: "job-late") { payload in
      deliveredPayloads.append(payload)
    }

    XCTAssertEqual(deliveredPayloads.count, 1)
    XCTAssertEqual(deliveredPayloads.first?["capture_job_id"] as? String, "job-late")
    XCTAssertEqual(deliveredPayloads.first?["status"] as? String, "committed")
  }

  func testManualCaptureV2MismatchedResultCannotCompleteOrPoisonJob() throws {
    let registry = ManualCaptureV2JobRegistry()
    try register(registry, jobID: "job-expected")

    var deliveredJobID: String?
    try registry.waitForResult(jobID: "job-expected") { payload in
      deliveredJobID = payload["capture_job_id"] as? String
    }

    XCTAssertThrowsError(
      try registry.finish(
        jobID: "job-expected",
        result: committedPayload(jobID: "job-other")
      )
    ) { error in
      guard let registryError = error as? ManualCaptureV2JobRegistry.RegistryError else {
        return XCTFail("unexpected error: \(error)")
      }
      guard case .mismatchedResult(let expected, let actual) = registryError else {
        return XCTFail("unexpected registry error: \(registryError)")
      }
      XCTAssertEqual(expected, "job-expected")
      XCTAssertEqual(actual, "job-other")
    }
    XCTAssertNil(deliveredJobID)

    try registry.finish(
      jobID: "job-expected",
      result: committedPayload(jobID: "job-expected")
    )
    XCTAssertEqual(deliveredJobID, "job-expected")
  }

  func testManualCaptureV2MismatchedPathCannotCompleteOrPoisonJob() throws {
    let registry = ManualCaptureV2JobRegistry()
    try register(registry, jobID: "job-paths")

    var deliveredMetadataPath: String?
    try registry.waitForResult(jobID: "job-paths") { payload in
      deliveredMetadataPath = payload["metadata_path"] as? String
    }

    var mismatched = committedPayload(jobID: "job-paths")
    mismatched["metadata_path"] = "/capture/job-other.json"
    XCTAssertThrowsError(
      try registry.finish(jobID: "job-paths", result: mismatched)
    ) { error in
      guard let registryError = error as? ManualCaptureV2JobRegistry.RegistryError else {
        return XCTFail("unexpected error: \(error)")
      }
      guard case .mismatchedPath(
        let jobID,
        let field,
        let expected,
        let actual
      ) = registryError else {
        return XCTFail("unexpected registry error: \(registryError)")
      }
      XCTAssertEqual(jobID, "job-paths")
      XCTAssertEqual(field, "metadata_path")
      XCTAssertEqual(expected, "/capture/job-paths.json")
      XCTAssertEqual(actual, "/capture/job-other.json")
    }
    XCTAssertNil(deliveredMetadataPath)

    try registry.finish(
      jobID: "job-paths",
      result: committedPayload(jobID: "job-paths")
    )
    XCTAssertEqual(deliveredMetadataPath, "/capture/job-paths.json")
  }

  func testManualCaptureV2DoubleFinishIsRejectedAndFirstResultIsRetained() throws {
    let registry = ManualCaptureV2JobRegistry()
    try register(registry, jobID: "job-once")
    try registry.finish(
      jobID: "job-once",
      result: committedPayload(jobID: "job-once")
    )

    XCTAssertThrowsError(
      try registry.finish(
        jobID: "job-once",
        result: [
          "capture_job_id": "job-once",
          "status": "failed",
          "error_code": "late_failure",
        ]
      )
    ) { error in
      guard let registryError = error as? ManualCaptureV2JobRegistry.RegistryError else {
        return XCTFail("unexpected error: \(error)")
      }
      guard case .alreadyFinished(let jobID) = registryError else {
        return XCTFail("unexpected registry error: \(registryError)")
      }
      XCTAssertEqual(jobID, "job-once")
    }

    var terminalStatus: String?
    try registry.waitForResult(jobID: "job-once") { payload in
      terminalStatus = payload["status"] as? String
    }
    XCTAssertEqual(terminalStatus, "committed")
  }

  func testManualCaptureV2DifferentJobsCannotReserveAnySameFinalPath() throws {
    let registry = ManualCaptureV2JobRegistry()
    try register(registry, jobID: "job-owner")

    let collidingPaths = ManualCaptureV2JobRegistry.ArtifactPaths(
      jpegPath: "/capture/job-owner.jpg",
      metadataPath: "/capture/job-contender.json",
      sfmGrayPath: "/capture/job-contender.sfm_gray"
    )
    XCTAssertThrowsError(
      try registry.register(jobID: "job-contender", paths: collidingPaths)
    ) { error in
      guard let registryError = error as? ManualCaptureV2JobRegistry.RegistryError else {
        return XCTFail("unexpected error: \(error)")
      }
      guard case .pathAlreadyReserved(
        let jobID,
        let path,
        let ownerJobID
      ) = registryError else {
        return XCTFail("unexpected registry error: \(registryError)")
      }
      XCTAssertEqual(jobID, "job-contender")
      XCTAssertEqual(path, "/capture/job-owner.jpg")
      XCTAssertEqual(ownerJobID, "job-owner")
    }
  }

  func testManualCaptureV2CommittedResultRequiresSfmGrayArtifact() throws {
    let registry = ManualCaptureV2JobRegistry()
    try register(registry, jobID: "job-missing-gray")

    var delivered = false
    try registry.waitForResult(jobID: "job-missing-gray") { _ in
      delivered = true
    }

    XCTAssertThrowsError(
      try registry.finish(
        jobID: "job-missing-gray",
        result: {
          var payload = committedPayload(jobID: "job-missing-gray")
          payload.removeValue(forKey: "sfm_gray_path")
          return payload
        }()
      ),
      "a committed result without durable sfm_gray must be rejected"
    )
    XCTAssertFalse(delivered)

    try registry.finish(
      jobID: "job-missing-gray",
      result: missingGrayFailurePayload(jobID: "job-missing-gray")
    )
    XCTAssertTrue(delivered)
  }

  func testManualCaptureV2MissingSfmGrayIsExplicitFailedTerminalResult() throws {
    let registry = ManualCaptureV2JobRegistry()
    try register(registry, jobID: "job-gray-failure")

    var terminalPayload: [String: Any]?
    try registry.waitForResult(jobID: "job-gray-failure") { payload in
      terminalPayload = payload
    }
    try registry.finish(
      jobID: "job-gray-failure",
      result: missingGrayFailurePayload(jobID: "job-gray-failure")
    )

    XCTAssertEqual(terminalPayload?["capture_job_id"] as? String, "job-gray-failure")
    XCTAssertEqual(terminalPayload?["status"] as? String, "failed")
    XCTAssertEqual(terminalPayload?["error_code"] as? String, "sfm_gray_unavailable")
  }

  func testManualCaptureV2AtomicPublishNeverOverwritesAnyExistingFinalPath() throws {
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: directory) }

    for filename in ["frame.jpg", "frame.json", "frame.sfm_gray"] {
      let finalURL = directory.appendingPathComponent(filename)
      let tempURL = ManualCaptureV2AtomicPublisher.temporaryURL(
        for: finalURL,
        jobID: "job-no-overwrite"
      )
      XCTAssertEqual(tempURL.deletingLastPathComponent(), directory)

      let original = Data("original-\(filename)".utf8)
      let replacement = Data("replacement-\(filename)".utf8)
      try original.write(to: finalURL, options: .withoutOverwriting)
      try replacement.write(to: tempURL, options: .withoutOverwriting)

      XCTAssertThrowsError(
        try ManualCaptureV2AtomicPublisher.publishNoReplace(
          tempURL: tempURL,
          finalURL: finalURL
        )
      )
      XCTAssertEqual(try Data(contentsOf: finalURL), original)
      XCTAssertEqual(try Data(contentsOf: tempURL), replacement)
    }
  }

  func testManualCaptureV2RegistryHandles4000ConcurrentJobs() {
    let registry = ManualCaptureV2JobRegistry()
    let recorder = ConcurrentCaptureRecorder()
    let jobCount = 4_000

    DispatchQueue.concurrentPerform(iterations: jobCount) { index in
      do {
        try self.register(registry, jobID: "job-\(index)")
      } catch {
        recorder.record(error: "register job-\(index): \(error)")
      }
    }
    XCTAssertEqual(recorder.errors, [])

    DispatchQueue.concurrentPerform(iterations: jobCount) { index in
      do {
        try registry.waitForResult(jobID: "job-\(index)") { payload in
          recorder.record(payload: payload)
        }
      } catch {
        recorder.record(error: "await job-\(index): \(error)")
      }
    }
    XCTAssertEqual(recorder.errors, [])

    DispatchQueue.concurrentPerform(iterations: jobCount) { index in
      do {
        try registry.finish(
          jobID: "job-\(index)",
          result: self.committedPayload(jobID: "job-\(index)")
        )
      } catch {
        recorder.record(error: "finish job-\(index): \(error)")
      }
    }

    XCTAssertEqual(recorder.errors, [])
    XCTAssertEqual(recorder.totalDeliveries, jobCount)
    XCTAssertEqual(recorder.uniqueDeliveredJobCount, jobCount)
    XCTAssertEqual(recorder.duplicateJobIDs, [])
  }

  func testManualCaptureV2AwaitFinishRaceDeliversEveryMatchingJobOnce() {
    let registry = ManualCaptureV2JobRegistry()
    let recorder = ConcurrentCaptureRecorder()
    let jobCount = 4_000

    for index in 0..<jobCount {
      XCTAssertNoThrow(try register(registry, jobID: "race-\(index)"))
    }

    DispatchQueue.concurrentPerform(iterations: jobCount * 2) { operation in
      let index = operation / 2
      let jobID = "race-\(index)"
      do {
        if operation.isMultiple(of: 2) {
          try registry.waitForResult(jobID: jobID) { payload in
            recorder.record(payload: payload)
          }
        } else {
          try registry.finish(
            jobID: jobID,
            result: self.committedPayload(jobID: jobID)
          )
        }
      } catch {
        recorder.record(error: "operation \(operation) for \(jobID): \(error)")
      }
    }

    XCTAssertEqual(recorder.errors, [])
    XCTAssertEqual(recorder.totalDeliveries, jobCount)
    XCTAssertEqual(recorder.uniqueDeliveredJobCount, jobCount)
    XCTAssertEqual(recorder.duplicateJobIDs, [])
  }

  private func register(
    _ registry: ManualCaptureV2JobRegistry,
    jobID: String
  ) throws {
    try registry.register(jobID: jobID, paths: artifactPaths(jobID: jobID))
  }

  private func artifactPaths(
    jobID: String
  ) -> ManualCaptureV2JobRegistry.ArtifactPaths {
    ManualCaptureV2JobRegistry.ArtifactPaths(
      jpegPath: "/capture/\(jobID).jpg",
      metadataPath: "/capture/\(jobID).json",
      sfmGrayPath: "/capture/\(jobID).sfm_gray"
    )
  }

  private func committedPayload(jobID: String) -> [String: Any] {
    [
      "capture_job_id": jobID,
      "status": "committed",
      "jpeg_path": "/capture/\(jobID).jpg",
      "metadata_path": "/capture/\(jobID).json",
      "sfm_gray_path": "/capture/\(jobID).sfm_gray",
      "sfm_gray_w": 2,
      "sfm_gray_h": 2,
    ]
  }

  private func missingGrayFailurePayload(jobID: String) -> [String: Any] {
    [
      "capture_job_id": jobID,
      "status": "failed",
      "error_code": "sfm_gray_unavailable",
      "message": "required sfm_gray could not be produced",
      "jpeg_path": "/capture/\(jobID).jpg",
      "metadata_path": "/capture/\(jobID).json",
      "sfm_gray_path": "/capture/\(jobID).sfm_gray",
    ]
  }
}

private final class ConcurrentCaptureRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedErrors: [String] = []
  private var deliveriesByJobID: [String: Int] = [:]
  private var missingJobIDDeliveries = 0

  var errors: [String] {
    withLock { storedErrors }
  }

  var totalDeliveries: Int {
    withLock {
      deliveriesByJobID.values.reduce(missingJobIDDeliveries, +)
    }
  }

  var uniqueDeliveredJobCount: Int {
    withLock { deliveriesByJobID.count }
  }

  var duplicateJobIDs: [String] {
    withLock {
      deliveriesByJobID
        .filter { $0.value != 1 }
        .map(\.key)
        .sorted()
    }
  }

  func record(error: String) {
    withLock {
      storedErrors.append(error)
    }
  }

  func record(payload: [String: Any]) {
    withLock {
      guard let jobID = payload["capture_job_id"] as? String else {
        missingJobIDDeliveries += 1
        return
      }
      deliveriesByJobID[jobID, default: 0] += 1
    }
  }

  private func withLock<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}
