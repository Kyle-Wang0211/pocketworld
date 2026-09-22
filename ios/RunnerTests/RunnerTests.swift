import Foundation
import CoreVideo
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

  func testManualCaptureV2ExplicitDiscardRequiresTerminalRegistryJob() throws {
    let registry = ManualCaptureV2JobRegistry()
    try register(registry, jobID: "job-discard")
    let captureRoot = URL(fileURLWithPath: "/capture")
    XCTAssertThrowsError(
      try registry.discardTerminalJobs(captureDirectory: captureRoot)
    ) { error in
      guard case ManualCaptureV2JobRegistry.RegistryError
        .discardBeforeTerminal("job-discard") = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }
    try registry.finish(
      jobID: "job-discard",
      result: committedPayload(jobID: "job-discard")
    )
    XCTAssertThrowsError(
      try registry.discardTerminalJobs(captureDirectory: URL(fileURLWithPath: "/"))
    )
    var survivedInvalidRoot = false
    try registry.waitForResult(jobID: "job-discard") { _ in
      survivedInvalidRoot = true
    }
    XCTAssertTrue(survivedInvalidRoot)
    XCTAssertEqual(
      try registry.discardTerminalJobs(captureDirectory: captureRoot),
      ["job-discard"]
    )
    XCTAssertThrowsError(
      try registry.waitForResult(jobID: "job-discard") { _ in }
    )
    // In-memory path ownership is released with the terminal entry.
    try register(registry, jobID: "job-discard")
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

  func testManualCaptureV2AckBeforeDartLedgerIsDiscoverableByCaptureScope() throws {
    let fixture = try durableFixture(jobID: "ack-before-ledger", captureName: "cap-a")
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    try fixture.store.createIntent(fixture.intent)
    try fixture.store.createPrivateStaging(intent: fixture.intent)

    // Simulates a kill immediately after native ACK and before Dart persists
    // captureJobId. Cold recovery does not need the ID: it reconciles by the
    // capture root and returns an explicit recoverable terminal state.
    let jobs = fixture.store.reconciliationJobs(
      captureDirectory: fixture.captureURL
    )
    XCTAssertEqual(jobs.count, 1)
    XCTAssertEqual(jobs[0]["capture_job_id"] as? String, "ack-before-ledger")
    XCTAssertEqual(jobs[0]["status"] as? String, "failed")
    XCTAssertEqual(
      jobs[0]["error_code"] as? String,
      "manual_capture_interrupted_recoverable"
    )
    XCTAssertEqual(jobs[0]["intent_durable"] as? Bool, true)
    XCTAssertEqual(jobs[0]["frame_identity"] as? String, "tap-1")
    XCTAssertEqual(
      (jobs[0]["artifact_receipts"] as? [[String: Any]])?.count,
      0
    )
    XCTAssertEqual(jobs[0]["commit_marker_present"] as? Bool, false)
    XCTAssertEqual(
      jobs[0]["capture_commit_receipt_present"] as? Bool,
      false
    )
    XCTAssertEqual(
      fixture.store.reconciliationJobs(
        captureDirectory: fixture.baseURL.appendingPathComponent("captures/cap-b")
      ).count,
      0,
      "capture-scoped reconciliation must never expose another capture"
    )
  }

  func testManualCaptureV2ReconciliationExceptionKeepsCanonicalDartSchema() throws {
    let fixture = try durableFixture(jobID: "reconcile-corrupt-failure")
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    try fixture.store.createIntent(fixture.intent)
    try fixture.store.createPrivateStaging(intent: fixture.intent)
    let failureURL = fixture.storeURL
      .appendingPathComponent("jobs/reconcile-corrupt-failure/failed.json")
    try Data("not-json".utf8).write(to: failureURL)

    let jobs = fixture.store.reconciliationJobs(
      captureDirectory: fixture.captureURL
    )
    let job = try XCTUnwrap(jobs.first)
    XCTAssertEqual(job["status"] as? String, "failed")
    XCTAssertEqual(
      job["error_code"] as? String,
      "manual_capture_recovery_failed"
    )
    XCTAssertEqual(job["frame_identity"] as? String, "tap-1")
    XCTAssertEqual(job["snapshot_identity"] as? String, fixture.intent.snapshotIdentity)
    XCTAssertEqual((job["artifact_receipts"] as? [[String: Any]])?.count, 0)
    XCTAssertEqual(job["commit_marker_present"] as? Bool, false)
    XCTAssertEqual(job["capture_commit_receipt_present"] as? Bool, false)
    XCTAssertEqual(job["recoverable"] as? Bool, false)
  }

  func testManualCaptureV2KillWindowsFailClosedUntilExactBundlePublished() throws {
    // No prepared receipt means there is no authority to guess a bundle.
    for phase in 0...1 {
      let fixture = try durableFixture(
        jobID: "kill-phase-\(phase)",
        captureName: "cap-kill-\(phase)"
      )
      defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
      try fixture.store.createIntent(fixture.intent)
      try fixture.store.createPrivateStaging(intent: fixture.intent)

      if phase >= 1 {
        try writeDurableStaging(fixture)
      }

      let recovery = try XCTUnwrap(
        fixture.store.recover(jobID: fixture.intent.captureJobID)
      )
      XCTAssertEqual(recovery.payload["status"] as? String, "failed")
      XCTAssertEqual(
        recovery.payload["error_code"] as? String,
        "manual_capture_interrupted_recoverable"
      )
    }

    // A sealed prepared receipt makes every 0/1/2/3-rename kill window
    // recoverable without overwriting or guessing.
    for publishedCount in 0...3 {
      let fixture = try durableFixture(
        jobID: "kill-after-\(publishedCount)-publishes",
        captureName: "cap-published-\(publishedCount)"
      )
      defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
      try fixture.store.createIntent(fixture.intent)
      try fixture.store.createPrivateStaging(intent: fixture.intent)
      try writeDurableStaging(fixture)
      let prepared = try prepareDurableFixture(fixture)
      for artifact in prepared.artifacts.prefix(publishedCount) {
        try fixture.store.publishArtifact(
          artifact,
          jobID: fixture.intent.captureJobID,
          allowExistingMatching: false
        )
      }
      let recovered = try XCTUnwrap(
        fixture.store.recover(jobID: fixture.intent.captureJobID)
      )
      XCTAssertEqual(recovered.payload["status"] as? String, "committed")
      XCTAssertEqual(recovered.payload["durable_commit"] as? Bool, true)
      for path in [
        fixture.intent.jpegPath,
        fixture.intent.metadataPath,
        fixture.intent.sfmGrayPath,
      ] {
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
      }
      let markerPath = try XCTUnwrap(fixture.intent.commitReceiptPath)
      XCTAssertTrue(FileManager.default.fileExists(atPath: markerPath))
      let jobs = fixture.store.reconciliationJobs(
        captureDirectory: fixture.captureURL
      )
      XCTAssertEqual(
        (jobs.first?["artifact_receipts"] as? [[String: Any]])?.count,
        3
      )
    }
  }

  func testManualCaptureV2CommittedLateAwaitSurvivesStoreAndRegistryRestart() throws {
    let fixture = try durableFixture(jobID: "restart-late-await")
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    try fixture.store.createIntent(fixture.intent)
    try fixture.store.createPrivateStaging(intent: fixture.intent)
    try writeDurableStaging(fixture)
    let prepared = try prepareDurableFixture(fixture)
    let original = try fixture.store.commit(intent: fixture.intent, record: prepared)

    let restartedStore = ManualCaptureV2DurableStore(rootURL: fixture.storeURL)
    let recovery = try XCTUnwrap(
      restartedStore.recover(jobID: fixture.intent.captureJobID)
    )
    let restartedRegistry = ManualCaptureV2JobRegistry()
    try restartedRegistry.register(
      jobID: recovery.intent.captureJobID,
      paths: recovery.intent.artifactPaths
    )
    try restartedRegistry.finish(
      jobID: recovery.intent.captureJobID,
      result: recovery.payload
    )
    var late: [String: Any]?
    try restartedRegistry.waitForResult(jobID: recovery.intent.captureJobID) {
      late = $0
    }
    XCTAssertEqual(late?["status"] as? String, "committed")
    XCTAssertEqual(
      late?["jpeg_sha256"] as? String,
      original["jpeg_sha256"] as? String
    )
    XCTAssertEqual(
      late?["sfm_gray_sha256"] as? String,
      original["sfm_gray_sha256"] as? String
    )
  }

  func testManualCaptureV2ReconciliationAllowsOnlyGrayQueueOwnershipTransfer() throws {
    let fixture = try durableFixture(jobID: "gray-transferred")
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    try fixture.store.createIntent(fixture.intent)
    try fixture.store.createPrivateStaging(intent: fixture.intent)
    try writeDurableStaging(fixture)
    let prepared = try prepareDurableFixture(fixture)
    _ = try fixture.store.commit(intent: fixture.intent, record: prepared)

    let queueDirectory = fixture.baseURL.appendingPathComponent(
      "durable-queue",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: queueDirectory,
      withIntermediateDirectories: true
    )
    let queuedGray = queueDirectory.appendingPathComponent("frame-0.gray")
    try FileManager.default.moveItem(
      at: URL(fileURLWithPath: fixture.intent.sfmGrayPath),
      to: queuedGray
    )

    // Native await/recover must remain strict: only Dart can prove the exact
    // queue row that took ownership of the missing final gray.
    XCTAssertThrowsError(
      try fixture.store.recover(jobID: fixture.intent.captureJobID)
    )

    let job = try XCTUnwrap(
      fixture.store.reconciliationJobs(
        captureDirectory: fixture.captureURL
      ).first
    )
    XCTAssertEqual(job["status"] as? String, "committed")
    XCTAssertEqual(job["sfm_gray_transferred_to_queue"] as? Bool, true)
    XCTAssertEqual(job["commit_marker_present"] as? Bool, true)
    XCTAssertEqual(job["capture_commit_receipt_present"] as? Bool, true)
    XCTAssertEqual((job["artifact_receipts"] as? [[String: Any]])?.count, 3)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.intent.jpegPath))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: fixture.intent.metadataPath)
    )
    XCTAssertEqual(try Data(contentsOf: queuedGray), Data([1, 2, 3, 4]))

    // The exception is exactly sfm_gray. Losing a user JPEG must still poison
    // reconciliation even though both commit markers remain present.
    try FileManager.default.removeItem(
      at: URL(fileURLWithPath: fixture.intent.jpegPath)
    )
    let missingJpeg = try XCTUnwrap(
      fixture.store.reconciliationJobs(
        captureDirectory: fixture.captureURL
      ).first
    )
    XCTAssertEqual(missingJpeg["status"] as? String, "failed")
    XCTAssertEqual(
      missingJpeg["error_code"] as? String,
      "manual_capture_recovery_failed"
    )
  }

  func testManualCaptureV2ReconciliationFinishesMissingCaptureReceiptWindow() throws {
    let fixture = try durableFixture(jobID: "missing-capture-receipt")
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    try fixture.store.createIntent(fixture.intent)
    try fixture.store.createPrivateStaging(intent: fixture.intent)
    try writeDurableStaging(fixture)
    let prepared = try prepareDurableFixture(fixture)
    _ = try fixture.store.commit(intent: fixture.intent, record: prepared)

    let receiptURL = URL(
      fileURLWithPath: try XCTUnwrap(fixture.intent.commitReceiptPath)
    )
    try FileManager.default.removeItem(at: receiptURL)
    XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL.path))

    let job = try XCTUnwrap(
      fixture.store.reconciliationJobs(
        captureDirectory: fixture.captureURL
      ).first
    )
    XCTAssertEqual(job["status"] as? String, "committed")
    XCTAssertEqual(job["sfm_gray_transferred_to_queue"] as? Bool, false)
    XCTAssertEqual(job["commit_marker_present"] as? Bool, true)
    XCTAssertEqual(job["capture_commit_receipt_present"] as? Bool, true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: receiptURL.path))

    let globalMarker = fixture.storeURL
      .appendingPathComponent("jobs/missing-capture-receipt/committed.json")
    XCTAssertEqual(
      try Data(contentsOf: receiptURL),
      try Data(contentsOf: globalMarker)
    )
  }

  func testManualCaptureV2IntentWriteFailureAndFinalCollisionFailBeforeAck() throws {
    let fixture = try durableFixture(jobID: "intent-io-failure")
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    try FileManager.default.createDirectory(
      at: fixture.baseURL,
      withIntermediateDirectories: true
    )
    let rootAsFile = fixture.baseURL.appendingPathComponent("not-a-directory")
    try Data("file".utf8).write(to: rootAsFile)
    let failingStore = ManualCaptureV2DurableStore(rootURL: rootAsFile)
    XCTAssertThrowsError(try failingStore.createIntent(fixture.intent))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.intent.jpegPath))

    let collision = try durableFixture(jobID: "final-collision")
    defer { try? FileManager.default.removeItem(at: collision.baseURL) }
    try FileManager.default.createDirectory(
      at: URL(fileURLWithPath: collision.intent.jpegPath)
        .deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let original = Data("user-photo-must-survive".utf8)
    try original.write(to: URL(fileURLWithPath: collision.intent.jpegPath))
    XCTAssertThrowsError(try collision.store.createIntent(collision.intent))
    XCTAssertEqual(
      try Data(contentsOf: URL(fileURLWithPath: collision.intent.jpegPath)),
      original
    )
  }

  func testManualCaptureV2DurableJobAndPathOwnershipCannotCross() throws {
    let fixture = try durableFixture(jobID: "durable-owner")
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    try fixture.store.createIntent(fixture.intent)
    XCTAssertNil(try fixture.store.recover(jobID: "wrong-job"))

    let contender = ManualCaptureV2DurableStore.Intent(
      schemaVersion: 1,
      captureJobID: "durable-contender",
      frameIdentity: "tap-contender",
      snapshotIdentity: "snapshot-contender",
      snapshotTimestamp: fixture.intent.snapshotTimestamp + 1,
      imageWidth: fixture.intent.imageWidth,
      imageHeight: fixture.intent.imageHeight,
      jpegPath: fixture.intent.jpegPath,
      metadataPath: fixture.captureURL.appendingPathComponent("other.json").path,
      sfmGrayPath: fixture.captureURL.appendingPathComponent("other.sfm-gray").path,
      commitReceiptPath: fixture.captureURL
        .appendingPathComponent("other.manual-v2-committed.json").path,
      createdUnixMicros: fixture.intent.createdUnixMicros + 1
    )
    XCTAssertThrowsError(try fixture.store.createIntent(contender)) { error in
      guard case ManualCaptureV2DurableStore.StoreError.pathAlreadyClaimed(
        let path,
        let owner
      ) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertEqual(path, fixture.intent.jpegPath)
      XCTAssertEqual(owner, fixture.intent.captureJobID)
    }
  }

  func testManualCaptureV2ReservationGateBounds4000CallBurstBeforeAck() {
    let gate = ManualCaptureV2ReservationGate(maximum: 2)
    XCTAssertTrue(gate.tryAcquire())
    XCTAssertTrue(gate.tryAcquire())
    let recorder = ConcurrentCaptureRecorder()
    DispatchQueue.concurrentPerform(iterations: 4_000) { index in
      if gate.tryAcquire() {
        recorder.record(error: "unexpected admission \(index)")
        gate.release()
      }
    }
    XCTAssertEqual(recorder.errors, [])
    XCTAssertEqual(gate.current, 2)
    XCTAssertEqual(gate.peak, 2)
    gate.release()
    gate.release()
    XCTAssertEqual(gate.current, 0)
  }

  func testManualCaptureV2RawSpillRoundTripsAndEnforcesDiskBudget() throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let capture = base.appendingPathComponent("captures/cap-raw/photos_highres")
    let store = ManualCaptureV2DurableStore(
      rootURL: base.appendingPathComponent("store"),
      rawSpillBudgetBytes: 64
    )
    let pixelBuffer = try makeBgraPixelBuffer(width: 4, height: 4)
    let first = rawIntent(jobID: "raw-first", captureURL: capture)
    try store.createIntent(first)
    try store.createPrivateStaging(intent: first)
    let ready = try store.spillRawSnapshot(
      intent: first,
      pixelBuffer: pixelBuffer,
      recipe: rawRecipe()
    )
    XCTAssertEqual(ready.rawByteLength, 64)
    let pendingJob = try XCTUnwrap(
      store.reconciliationJobs(captureDirectory: capture).first
    )
    XCTAssertEqual(
      pendingJob["status"] as? String,
      "raw_spill_pending",
      "a live intent→raw-ready interleaving must not be poisoned as failed"
    )
    XCTAssertEqual(pendingJob["frame_identity"] as? String, "tap-raw")
    XCTAssertEqual(
      (pendingJob["artifact_receipts"] as? [[String: Any]])?.count,
      0
    )
    XCTAssertEqual(pendingJob["commit_marker_present"] as? Bool, false)
    XCTAssertEqual(
      pendingJob["capture_commit_receipt_present"] as? Bool,
      false
    )
    XCTAssertEqual(store.pendingRawJobIDs(captureDirectory: capture), ["raw-first"])
    let loaded = try XCTUnwrap(store.loadRawSnapshot(jobID: first.captureJobID))
    XCTAssertEqual(loaded.spillByteLength, 64)
    XCTAssertEqual(
      try activeBgraBytes(loaded.pixelBuffer),
      try activeBgraBytes(pixelBuffer)
    )
    XCTAssertEqual(
      colorAttachment(loaded.pixelBuffer, key: kCVImageBufferColorPrimariesKey),
      colorAttachment(pixelBuffer, key: kCVImageBufferColorPrimariesKey)
    )
    XCTAssertEqual(
      colorAttachment(loaded.pixelBuffer, key: kCVImageBufferTransferFunctionKey),
      colorAttachment(pixelBuffer, key: kCVImageBufferTransferFunctionKey)
    )
    XCTAssertEqual(
      colorAttachment(loaded.pixelBuffer, key: kCVImageBufferYCbCrMatrixKey),
      colorAttachment(pixelBuffer, key: kCVImageBufferYCbCrMatrixKey)
    )
    let metrics = store.backlogMetrics()
    XCTAssertEqual((metrics["raw_spill_pending_bytes"] as? NSNumber)?.uint64Value, 64)
    XCTAssertEqual(metrics["raw_spill_pending_jobs"] as? Int, 1)

    let second = rawIntent(jobID: "raw-second", captureURL: capture)
    try store.createIntent(second)
    try store.createPrivateStaging(intent: second)
    XCTAssertThrowsError(
      try store.spillRawSnapshot(
        intent: second,
        pixelBuffer: pixelBuffer,
        recipe: rawRecipe()
      )
    ) { error in
      guard case ManualCaptureV2DurableStore.StoreError.rawSpillBudgetExceeded(
        let required,
        let available
      ) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertEqual(required, 64)
      XCTAssertEqual(available, 0)
    }
    store.abandonUnacknowledgedIntent(first)
    let released = store.backlogMetrics()
    XCTAssertEqual(
      (released["raw_spill_pending_bytes"] as? NSNumber)?.uint64Value,
      0,
      "pre-ACK registry failure must release its reserved raw budget"
    )
  }

  func testManualCaptureV2RecoverableRawFailureReopensWithoutLosingPixels() throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let capture = base.appendingPathComponent("captures/cap-retry/photos_highres")
    let store = ManualCaptureV2DurableStore(
      rootURL: base.appendingPathComponent("store"),
      rawSpillBudgetBytes: 1_024
    )
    let intent = rawIntent(jobID: "raw-retry", captureURL: capture)
    let pixelBuffer = try makeBgraPixelBuffer(width: 4, height: 4)
    try store.createIntent(intent)
    try store.createPrivateStaging(intent: intent)
    _ = try store.spillRawSnapshot(
      intent: intent,
      pixelBuffer: pixelBuffer,
      recipe: rawRecipe()
    )
    let failed = try store.recordFailure(
      intent: intent,
      errorCode: "transient_write",
      message: "retry me",
      recoverable: true
    )

    let registry = ManualCaptureV2JobRegistry()
    try registry.register(jobID: intent.captureJobID, paths: intent.artifactPaths)
    try registry.finish(jobID: intent.captureJobID, result: failed)
    XCTAssertTrue(try store.beginRawRetryIfPossible(jobID: intent.captureJobID))
    try registry.reopenRecoverableFailure(jobID: intent.captureJobID)
    XCTAssertEqual(
      store.reconciliationJobs(captureDirectory: capture).first?["status"]
        as? String,
      "raw_spill_pending"
    )
    let loaded = try XCTUnwrap(store.loadRawSnapshot(jobID: intent.captureJobID))
    XCTAssertEqual(
      try activeBgraBytes(loaded.pixelBuffer),
      try activeBgraBytes(pixelBuffer)
    )

    try registry.finish(
      jobID: intent.captureJobID,
      result: [
        "capture_job_id": intent.captureJobID,
        "status": "committed",
        "jpeg_path": intent.jpegPath,
        "metadata_path": intent.metadataPath,
        "sfm_gray_path": intent.sfmGrayPath,
        "sfm_gray_w": 2,
        "sfm_gray_h": 2,
      ]
    )
    var status: String?
    try registry.waitForResult(jobID: intent.captureJobID) {
      status = $0["status"] as? String
    }
    XCTAssertEqual(status, "committed")
  }

  func testManualCaptureV2CorruptColdRawBecomesExactTerminalFailure() throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let capture = base.appendingPathComponent("captures/cap-corrupt/photos_highres")
    let storeURL = base.appendingPathComponent("store")
    let store = ManualCaptureV2DurableStore(
      rootURL: storeURL,
      rawSpillBudgetBytes: 1_024
    )
    let intent = rawIntent(jobID: "raw-corrupt", captureURL: capture)
    try store.createIntent(intent)
    try store.createPrivateStaging(intent: intent)
    _ = try store.spillRawSnapshot(
      intent: intent,
      pixelBuffer: makeBgraPixelBuffer(width: 4, height: 4),
      recipe: rawRecipe()
    )
    let rawURL = storeURL.appendingPathComponent(
      "jobs/raw-corrupt/staging/raw_pixels.staged"
    )
    try Data(repeating: 0xff, count: 64).write(to: rawURL)

    do {
      _ = try store.loadRawSnapshot(jobID: intent.captureJobID)
      XCTFail("corrupt raw unexpectedly loaded")
    } catch {
      let failure = try store.recordRawRestoreFailure(
        jobID: intent.captureJobID,
        error: error
      )
      XCTAssertEqual(failure["status"] as? String, "failed")
      XCTAssertEqual(
        failure["error_code"] as? String,
        "manual_capture_raw_restore_corrupt"
      )
      XCTAssertEqual(failure["recoverable"] as? Bool, false)
    }

    let listed = try XCTUnwrap(
      store.reconciliationJobs(captureDirectory: capture).first
    )
    XCTAssertEqual(listed["status"] as? String, "failed")
    XCTAssertEqual(
      listed["error_code"] as? String,
      "manual_capture_raw_restore_corrupt"
    )
    XCTAssertEqual(
      (store.backlogMetrics()["raw_spill_pending_bytes"] as? NSNumber)?
        .uint64Value,
      0
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: rawURL.path))
  }

  func testManualCaptureV2ExplicitCaptureDiscardReleasesPrivateRawBudget() throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let captureRoot = base.appendingPathComponent(
      "captures/cap-discard",
      isDirectory: true
    )
    let photos = captureRoot.appendingPathComponent(
      "photos_highres",
      isDirectory: true
    )
    let store = ManualCaptureV2DurableStore(
      rootURL: base.appendingPathComponent("store"),
      rawSpillBudgetBytes: 1_024
    )
    let intent = rawIntent(jobID: "discard-raw", captureURL: photos)
    try store.createIntent(intent)
    try store.createPrivateStaging(intent: intent)
    _ = try store.spillRawSnapshot(
      intent: intent,
      pixelBuffer: makeBgraPixelBuffer(width: 4, height: 4),
      recipe: rawRecipe()
    )
    _ = try store.recordFailure(
      intent: intent,
      errorCode: "transient_write",
      message: "retained for retry",
      recoverable: true
    )
    XCTAssertEqual(
      (store.backlogMetrics()["raw_spill_pending_bytes"] as? NSNumber)?
        .uint64Value,
      64
    )

    // Native cleanup owns only Application Support. User/capture-root files
    // remain for Dart to remove after this exact scoped cleanup succeeds.
    try FileManager.default.createDirectory(
      at: photos,
      withIntermediateDirectories: true
    )
    let userFile = photos.appendingPathComponent("user-photo-must-survive.jpg")
    try Data("user-final".utf8).write(to: userFile)

    let result = try store.discardJobs(captureDirectory: captureRoot)
    XCTAssertEqual(
      result["schema_version"] as? String,
      "aether_manual_capture_v2_discard_v1"
    )
    XCTAssertEqual(result["discarded_job_ids"] as? [String], ["discard-raw"])
    XCTAssertEqual(
      (result["released_raw_bytes"] as? NSNumber)?.uint64Value,
      64
    )
    XCTAssertEqual(
      (store.backlogMetrics()["raw_spill_pending_bytes"] as? NSNumber)?
        .uint64Value,
      0
    )
    XCTAssertEqual(store.backlogMetrics()["raw_spill_pending_jobs"] as? Int, 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: userFile.path))
    XCTAssertTrue(
      store.reconciliationJobs(captureDirectory: captureRoot).isEmpty
    )

    // Idempotent retry after a process/call boundary removes nothing else.
    let repeated = try store.discardJobs(captureDirectory: captureRoot)
    XCTAssertEqual(repeated["discarded_job_ids"] as? [String], [])
    XCTAssertTrue(FileManager.default.fileExists(atPath: userFile.path))
  }

  func testManualCaptureV2YuvRawSpillPreservesPlanesAndColorInterpretation() throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let capture = base.appendingPathComponent("captures/cap-yuv/photos_highres")
    let store = ManualCaptureV2DurableStore(
      rootURL: base.appendingPathComponent("store"),
      rawSpillBudgetBytes: 1_024
    )
    let intent = rawIntent(jobID: "raw-yuv", captureURL: capture)
    let original = try makeYuvPixelBuffer(width: 4, height: 4)
    try store.createIntent(intent)
    try store.createPrivateStaging(intent: intent)
    let ready = try store.spillRawSnapshot(
      intent: intent,
      pixelBuffer: original,
      recipe: rawRecipe()
    )
    XCTAssertEqual(ready.rawByteLength, 24)
    let loaded = try XCTUnwrap(store.loadRawSnapshot(jobID: intent.captureJobID))
    XCTAssertEqual(try activeYuvBytes(loaded.pixelBuffer), try activeYuvBytes(original))
    for key in [
      kCVImageBufferYCbCrMatrixKey,
      kCVImageBufferColorPrimariesKey,
      kCVImageBufferTransferFunctionKey,
    ] {
      XCTAssertEqual(
        colorAttachment(loaded.pixelBuffer, key: key),
        colorAttachment(original, key: key)
      )
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

  private struct DurableFixture {
    let baseURL: URL
    let storeURL: URL
    let captureURL: URL
    let store: ManualCaptureV2DurableStore
    let intent: ManualCaptureV2DurableStore.Intent
  }

  private func durableFixture(
    jobID: String,
    captureName: String = "cap-test"
  ) throws -> DurableFixture {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storeURL = base.appendingPathComponent("durable-store", isDirectory: true)
    let captureURL = base
      .appendingPathComponent("captures", isDirectory: true)
      .appendingPathComponent(captureName, isDirectory: true)
      .appendingPathComponent("photos_highres", isDirectory: true)
    let jpegURL = captureURL.appendingPathComponent("\(jobID).jpg")
    let metadataURL = captureURL.appendingPathComponent("\(jobID).json")
    let grayURL = captureURL.appendingPathComponent("\(jobID).sfm-gray")
    let timestamp = 123.456
    let intrinsics: [Float] = [900, 900, 640, 360]
    let extrinsic: [Float] = [
      1, 0, 0, 0,
      0, 1, 0, 0,
      0, 0, 1, 0,
      0.1, 0.2, 0.3, 1,
    ]
    let intent = ManualCaptureV2DurableStore.Intent(
      schemaVersion: 1,
      captureJobID: jobID,
      frameIdentity: "tap-1",
      snapshotIdentity: ManualCaptureV2DurableStore.snapshotIdentity(
        captureJobID: jobID,
        timestamp: timestamp,
        imageWidth: 1280,
        imageHeight: 720,
        intrinsics: intrinsics,
        extrinsic: extrinsic
      ),
      snapshotTimestamp: timestamp,
      imageWidth: 1280,
      imageHeight: 720,
      jpegPath: jpegURL.path,
      metadataPath: metadataURL.path,
      sfmGrayPath: grayURL.path,
      commitReceiptPath: captureURL
        .appendingPathComponent("\(jobID).manual-v2-committed.json").path,
      createdUnixMicros: 1_720_000_000_000_000
    )
    return DurableFixture(
      baseURL: base,
      storeURL: storeURL,
      captureURL: captureURL,
      store: ManualCaptureV2DurableStore(rootURL: storeURL),
      intent: intent
    )
  }

  private func writeDurableStaging(_ fixture: DurableFixture) throws {
    let contents: [ManualCaptureV2DurableStore.ArtifactKind: Data] = [
      .jpeg: Data("jpeg-bytes".utf8),
      .metadata: Data("{\"sidecar\":true}".utf8),
      .sfmGray: Data([1, 2, 3, 4]),
    ]
    for kind in ManualCaptureV2DurableStore.ArtifactKind.allCases {
      try contents[kind]!.write(
        to: fixture.store.stagingURL(
          jobID: fixture.intent.captureJobID,
          kind: kind
        ),
        options: .withoutOverwriting
      )
    }
  }

  private func prepareDurableFixture(
    _ fixture: DurableFixture
  ) throws -> ManualCaptureV2DurableStore.PreparedRecord {
    try fixture.store.prepare(
      intent: fixture.intent,
      sfmGrayWidth: 2,
      sfmGrayHeight: 2,
      timestamp: fixture.intent.snapshotTimestamp,
      imageWidth: fixture.intent.imageWidth,
      imageHeight: fixture.intent.imageHeight,
      intrinsicsFxFyCxCy: [900, 900, 640, 360],
      extrinsic: [
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0.1, 0.2, 0.3, 1,
      ]
    )
  }

  private func rawIntent(
    jobID: String,
    captureURL: URL
  ) -> ManualCaptureV2DurableStore.Intent {
    let intrinsics: [Float] = [4, 4, 2, 2]
    let extrinsic: [Float] = [
      1, 0, 0, 0,
      0, 1, 0, 0,
      0, 0, 1, 0,
      0, 0, 0, 1,
    ]
    return ManualCaptureV2DurableStore.Intent(
      schemaVersion: 1,
      captureJobID: jobID,
      frameIdentity: "tap-raw",
      snapshotIdentity: ManualCaptureV2DurableStore.snapshotIdentity(
        captureJobID: jobID,
        timestamp: 10,
        imageWidth: 4,
        imageHeight: 4,
        intrinsics: intrinsics,
        extrinsic: extrinsic
      ),
      snapshotTimestamp: 10,
      imageWidth: 4,
      imageHeight: 4,
      jpegPath: captureURL.appendingPathComponent("\(jobID).jpg").path,
      metadataPath: captureURL.appendingPathComponent("\(jobID).json").path,
      sfmGrayPath: captureURL.appendingPathComponent("\(jobID).sfm-gray").path,
      commitReceiptPath: captureURL
        .appendingPathComponent("\(jobID).manual-v2-committed.json").path,
      createdUnixMicros: 1
    )
  }

  private func rawRecipe() -> ManualCaptureV2DurableStore.SnapshotRecipe {
    ManualCaptureV2DurableStore.SnapshotRecipe(
      metadataSchemaVersion: 1,
      jpegQuality: 0.9,
      targetTimestamp: 10,
      saveDelta: 0,
      intrinsicsFxFyCxCy: [4, 4, 2, 2],
      extrinsic: [
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
      ],
      trackingStateName: "normal",
      isTracking: true,
      anchorsWorld: [],
      anchorIDs: [],
      anchorDepthCount: 0,
      anchorDepthMinM: 0,
      anchorDepthMaxM: 0,
      anchorDepthSpanM: 0,
      reliabilityPrior: 0,
      exifExposureDurationSec: nil,
      exifISO: nil,
      cameraAngularVelocity: nil,
      cameraAngularVelocityDtSec: nil,
      dartSaveContractJSON: nil
    )
  }

  private func makeBgraPixelBuffer(
    width: Int,
    height: Int
  ) throws -> CVPixelBuffer {
    var value: CVPixelBuffer?
    XCTAssertEqual(
      CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        nil,
        &value
      ),
      kCVReturnSuccess
    )
    let pixelBuffer = try XCTUnwrap(value)
    CVBufferSetAttachment(
      pixelBuffer,
      kCVImageBufferColorPrimariesKey,
      kCVImageBufferColorPrimaries_ITU_R_709_2,
      .shouldPropagate
    )
    CVBufferSetAttachment(
      pixelBuffer,
      kCVImageBufferTransferFunctionKey,
      kCVImageBufferTransferFunction_ITU_R_709_2,
      .shouldPropagate
    )
    CVBufferSetAttachment(
      pixelBuffer,
      kCVImageBufferYCbCrMatrixKey,
      kCVImageBufferYCbCrMatrix_ITU_R_709_2,
      .shouldPropagate
    )
    XCTAssertEqual(CVPixelBufferLockBaseAddress(pixelBuffer, []), kCVReturnSuccess)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer))
    for row in 0..<height {
      for byte in 0..<(width * 4) {
        base.storeBytes(
          of: UInt8((row * width * 4 + byte) & 0xff),
          toByteOffset: row * rowBytes + byte,
          as: UInt8.self
        )
      }
    }
    return pixelBuffer
  }

  private func activeBgraBytes(_ pixelBuffer: CVPixelBuffer) throws -> Data {
    XCTAssertEqual(
      CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly),
      kCVReturnSuccess
    )
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer))
    var result = Data()
    for row in 0..<height {
      result.append(
        Data(bytes: base.advanced(by: row * rowBytes), count: width * 4)
      )
    }
    return result
  }

  private func makeYuvPixelBuffer(
    width: Int,
    height: Int
  ) throws -> CVPixelBuffer {
    var value: CVPixelBuffer?
    let attributes = [
      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
    ] as CFDictionary
    XCTAssertEqual(
      CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        attributes,
        &value
      ),
      kCVReturnSuccess
    )
    let pixelBuffer = try XCTUnwrap(value)
    CVBufferSetAttachment(
      pixelBuffer,
      kCVImageBufferColorPrimariesKey,
      kCVImageBufferColorPrimaries_ITU_R_709_2,
      .shouldPropagate
    )
    CVBufferSetAttachment(
      pixelBuffer,
      kCVImageBufferTransferFunctionKey,
      kCVImageBufferTransferFunction_ITU_R_709_2,
      .shouldPropagate
    )
    CVBufferSetAttachment(
      pixelBuffer,
      kCVImageBufferYCbCrMatrixKey,
      kCVImageBufferYCbCrMatrix_ITU_R_709_2,
      .shouldPropagate
    )
    XCTAssertEqual(CVPixelBufferLockBaseAddress(pixelBuffer, []), kCVReturnSuccess)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    XCTAssertEqual(CVPixelBufferGetPlaneCount(pixelBuffer), 2)
    for plane in 0..<2 {
      let planeWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
      let planeHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
      let active = plane == 0 ? planeWidth : planeWidth * 2
      let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
      let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane))
      for row in 0..<planeHeight {
        for byte in 0..<active {
          base.storeBytes(
            of: UInt8((plane * 100 + row * active + byte) & 0xff),
            toByteOffset: row * rowBytes + byte,
            as: UInt8.self
          )
        }
      }
    }
    return pixelBuffer
  }

  private func activeYuvBytes(_ pixelBuffer: CVPixelBuffer) throws -> Data {
    XCTAssertEqual(
      CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly),
      kCVReturnSuccess
    )
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    XCTAssertEqual(CVPixelBufferGetPlaneCount(pixelBuffer), 2)
    var result = Data()
    for plane in 0..<2 {
      let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
      let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
      let active = plane == 0 ? width : width * 2
      let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
      let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane))
      for row in 0..<height {
        result.append(
          Data(bytes: base.advanced(by: row * rowBytes), count: active)
        )
      }
    }
    return result
  }

  private func colorAttachment(
    _ pixelBuffer: CVPixelBuffer,
    key: CFString
  ) -> String? {
    CVBufferGetAttachment(pixelBuffer, key, nil)?
      .takeUnretainedValue() as? String
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
