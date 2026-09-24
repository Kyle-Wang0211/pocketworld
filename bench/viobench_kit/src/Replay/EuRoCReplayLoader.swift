import CryptoKit
import Foundation

struct EuRoCReplayLoader {
    let groundTruthBoundaryToleranceNanoseconds: Int64

    init(groundTruthBoundaryToleranceNanoseconds: Int64 = 5_000_000) {
        self.groundTruthBoundaryToleranceNanoseconds = groundTruthBoundaryToleranceNanoseconds
    }

    func load(manifestURL: URL) throws -> EuRoCReplayDataset {
        let decoder = JSONDecoder()
        let manifest: EuRoCOrderedManifest
        do {
            manifest = try decoder.decode(EuRoCOrderedManifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            throw EuRoCReplayError.malformedCSV(path: manifestURL.lastPathComponent, line: 0, reason: "invalid JSON manifest: \(error)")
        }
        try validateManifestShape(manifest)

        let rootURL = manifestURL.deletingLastPathComponent()
        try verifyFiles(rootURL: rootURL, records: manifest.files)
        let actualIdentity = try EuRoCDatasetIdentity.compute(rootURL: rootURL, manifest: manifest)
        guard actualIdentity == manifest.datasetSHA256 else {
            throw EuRoCReplayError.datasetIdentityMismatch(expected: manifest.datasetSHA256, actual: actualIdentity)
        }

        let byRole = Dictionary(grouping: manifest.files, by: \.role)
        let camera0Record = try uniqueRecord(.camera0Index, in: byRole)
        let imuRecord = try uniqueRecord(.imuIndex, in: byRole)
        let groundTruthRecord = try uniqueRecord(.groundTruth, in: byRole)
        _ = try uniqueRecord(.camera0Calibration, in: byRole)
        _ = try uniqueRecord(.imuCalibration, in: byRole)

        let camera0 = try parseCameraIndex(record: camera0Record, rootURL: rootURL)
        let declaredImages = Set((byRole[.cameraImage] ?? []).map(\.relativePath))
        var cameraEvents: [ReplayEvent] = []
        cameraEvents.reserveCapacity(camera0.count)
        if manifest.inputCameraCount == 1 {
            try rejectRole(.camera1Index, in: byRole, inputCameraCount: 1)
            try rejectRole(.camera1Calibration, in: byRole, inputCameraCount: 1)
            for frame in camera0 {
                guard declaredImages.contains(frame.imageRelativePath) else {
                    throw EuRoCReplayError.imageNotDeclared(frame.imageRelativePath)
                }
                cameraEvents.append(.camera(EuRoCCameraFrame(
                    timestampNanoseconds: frame.timestamp,
                    camera0ImageURL: try EuRoCDatasetIdentity.resolvedPayloadURL(rootURL: rootURL, relativePath: frame.imageRelativePath),
                    camera1ImageURL: nil
                )))
            }
        } else {
            let camera1Record = try uniqueRecord(.camera1Index, in: byRole)
            _ = try uniqueRecord(.camera1Calibration, in: byRole)
            let camera1 = try parseCameraIndex(record: camera1Record, rootURL: rootURL)
            guard camera0.count == camera1.count else {
                throw EuRoCReplayError.stereoFrameCountMismatch(camera0: camera0.count, camera1: camera1.count)
            }
            for (left, right) in zip(camera0, camera1) {
                guard left.timestamp == right.timestamp else {
                    throw EuRoCReplayError.stereoTimestampMismatch(camera0: left.timestamp, camera1: right.timestamp)
                }
                guard declaredImages.contains(left.imageRelativePath) else {
                    throw EuRoCReplayError.imageNotDeclared(left.imageRelativePath)
                }
                guard declaredImages.contains(right.imageRelativePath) else {
                    throw EuRoCReplayError.imageNotDeclared(right.imageRelativePath)
                }
                cameraEvents.append(.camera(EuRoCCameraFrame(
                    timestampNanoseconds: left.timestamp,
                    camera0ImageURL: try EuRoCDatasetIdentity.resolvedPayloadURL(rootURL: rootURL, relativePath: left.imageRelativePath),
                    camera1ImageURL: try EuRoCDatasetIdentity.resolvedPayloadURL(rootURL: rootURL, relativePath: right.imageRelativePath)
                )))
            }
        }

        let imuEvents = try parseIMU(record: imuRecord, rootURL: rootURL).map(ReplayEvent.imu)
        let groundTruth = try parseGroundTruth(record: groundTruthRecord, rootURL: rootURL)
        let events = (imuEvents + cameraEvents).sorted {
            if $0.timestampNanoseconds != $1.timestampNanoseconds {
                return $0.timestampNanoseconds < $1.timestampNanoseconds
            }
            return $0.kind.rawValue < $1.kind.rawValue
        }
        guard !events.isEmpty, let firstCamera = cameraEvents.first, let lastCamera = cameraEvents.last else {
            throw EuRoCReplayError.emptyReplay
        }
        guard let firstTruth = groundTruth.first, let lastTruth = groundTruth.last,
              firstTruth.timestampNanoseconds <= firstCamera.timestampNanoseconds + groundTruthBoundaryToleranceNanoseconds,
              lastTruth.timestampNanoseconds >= lastCamera.timestampNanoseconds - groundTruthBoundaryToleranceNanoseconds else {
            throw EuRoCReplayError.groundTruthDoesNotCoverReplay
        }

        return EuRoCReplayDataset(
            datasetName: manifest.datasetName,
            inputCameraCount: manifest.inputCameraCount,
            datasetSHA256: manifest.datasetSHA256,
            events: events,
            groundTruth: groundTruth
        )
    }

    private func validateManifestShape(_ manifest: EuRoCOrderedManifest) throws {
        guard manifest.schemaVersion == 1 else {
            throw EuRoCReplayError.unsupportedSchemaVersion(manifest.schemaVersion)
        }
        guard !manifest.datasetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EuRoCReplayError.invalidDatasetName
        }
        guard manifest.inputCameraCount == 1 || manifest.inputCameraCount == 2 else {
            throw EuRoCReplayError.invalidInputCameraCount(manifest.inputCameraCount)
        }
        guard isLowercaseSHA256(manifest.datasetSHA256) else {
            throw EuRoCReplayError.invalidDatasetIdentity
        }
        guard zip(manifest.files, manifest.files.dropFirst()).allSatisfy({ $0.relativePath < $1.relativePath }) else {
            throw EuRoCReplayError.manifestFilesNotStrictlySorted
        }
        for record in manifest.files {
            guard EuRoCDatasetIdentity.isSafeRelativePath(record.relativePath) else {
                throw EuRoCReplayError.unsafeRelativePath(record.relativePath)
            }
            guard record.byteCount >= 0, isLowercaseSHA256(record.sha256) else {
                throw EuRoCReplayError.fileHashMismatch(path: record.relativePath, expected: record.sha256, actual: "invalid declaration")
            }
        }
    }

    private func verifyFiles(rootURL: URL, records: [EuRoCManifestFile]) throws {
        for record in records {
            let url = try EuRoCDatasetIdentity.resolvedPayloadURL(rootURL: rootURL, relativePath: record.relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw EuRoCReplayError.missingFile(record.relativePath)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let actualSize = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            guard actualSize == record.byteCount else {
                throw EuRoCReplayError.fileSizeMismatch(path: record.relativePath, expected: record.byteCount, actual: actualSize)
            }
            let actualHash = try fileSHA256(url)
            guard actualHash == record.sha256 else {
                throw EuRoCReplayError.fileHashMismatch(path: record.relativePath, expected: record.sha256, actual: actualHash)
            }
        }
    }

    private func uniqueRecord(
        _ role: EuRoCFileRole,
        in records: [EuRoCFileRole: [EuRoCManifestFile]]
    ) throws -> EuRoCManifestFile {
        guard let matches = records[role], !matches.isEmpty else {
            throw EuRoCReplayError.missingRequiredRole(role)
        }
        guard matches.count == 1 else {
            throw EuRoCReplayError.duplicateRequiredRole(role)
        }
        return matches[0]
    }

    private func rejectRole(
        _ role: EuRoCFileRole,
        in records: [EuRoCFileRole: [EuRoCManifestFile]],
        inputCameraCount: Int
    ) throws {
        guard records[role, default: []].isEmpty else {
            throw EuRoCReplayError.roleNotAllowedForInputCameraCount(
                role: role,
                inputCameraCount: inputCameraCount
            )
        }
    }

    private func fileSHA256(_ url: URL) throws -> String {
        var hasher = CryptoKit.SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func parseCameraIndex(record: EuRoCManifestFile, rootURL: URL) throws -> [CameraRow] {
        let rows = try csvRows(record: record, rootURL: rootURL)
        NSLog("[VIOBench] parseCameraIndex %@ rows=%d first=%@",
              record.relativePath, rows.count,
              rows.first.map { $0.fields.joined(separator: "|") } ?? "<none>")
        let cameraDirectory = (record.relativePath as NSString).deletingLastPathComponent
        var result: [CameraRow] = []
        var previous: Int64?
        for row in rows {
            guard row.fields.count == 2, let timestamp = Int64(row.fields[0]), timestamp >= 0 else {
                throw EuRoCReplayError.malformedCSV(path: record.relativePath, line: row.line, reason: "expected timestamp,filename")
            }
            if let previous, timestamp <= previous {
                throw EuRoCReplayError.timestampRegression(path: record.relativePath, previous: previous, current: timestamp)
            }
            let filename = row.fields[1]
            guard !filename.isEmpty, !filename.contains("/"), EuRoCDatasetIdentity.isSafeRelativePath(filename) else {
                throw EuRoCReplayError.malformedCSV(path: record.relativePath, line: row.line, reason: "unsafe camera filename")
            }
            result.append(CameraRow(
                timestamp: timestamp,
                imageRelativePath: "\(cameraDirectory)/data/\(filename)"
            ))
            previous = timestamp
        }
        guard !result.isEmpty else {
            throw EuRoCReplayError.malformedCSV(path: record.relativePath, line: 0, reason: "camera index is empty")
        }
        return result
    }

    private func parseIMU(record: EuRoCManifestFile, rootURL: URL) throws -> [EuRoCIMUSample] {
        let rows = try csvRows(record: record, rootURL: rootURL)
        var result: [EuRoCIMUSample] = []
        var previous: Int64?
        for row in rows {
            guard row.fields.count == 7, let timestamp = Int64(row.fields[0]), timestamp >= 0,
                  let wx = finiteDouble(row.fields[1]), let wy = finiteDouble(row.fields[2]), let wz = finiteDouble(row.fields[3]),
                  let ax = finiteDouble(row.fields[4]), let ay = finiteDouble(row.fields[5]), let az = finiteDouble(row.fields[6]) else {
                throw EuRoCReplayError.malformedCSV(path: record.relativePath, line: row.line, reason: "expected timestamp,3 gyro,3 acceleration values")
            }
            if let previous, timestamp <= previous {
                throw EuRoCReplayError.timestampRegression(path: record.relativePath, previous: previous, current: timestamp)
            }
            result.append(EuRoCIMUSample(
                timestampNanoseconds: timestamp,
                gyroscopeRadiansPerSecond: Vector3(x: wx, y: wy, z: wz),
                accelerationMetersPerSecondSquared: Vector3(x: ax, y: ay, z: az)
            ))
            previous = timestamp
        }
        guard !result.isEmpty else {
            throw EuRoCReplayError.malformedCSV(path: record.relativePath, line: 0, reason: "IMU index is empty")
        }
        return result
    }

    private func parseGroundTruth(record: EuRoCManifestFile, rootURL: URL) throws -> [TimedPose] {
        let rows = try csvRows(record: record, rootURL: rootURL)
        var result: [TimedPose] = []
        var previous: Int64?
        for row in rows {
            guard row.fields.count >= 8, let timestamp = Int64(row.fields[0]), timestamp >= 0,
                  let px = finiteDouble(row.fields[1]), let py = finiteDouble(row.fields[2]), let pz = finiteDouble(row.fields[3]),
                  let qw = finiteDouble(row.fields[4]), let qx = finiteDouble(row.fields[5]),
                  let qy = finiteDouble(row.fields[6]), let qz = finiteDouble(row.fields[7]),
                  let quaternion = Quaternion.normalizedOrNil(w: qw, x: qx, y: qy, z: qz) else {
                throw EuRoCReplayError.malformedCSV(path: record.relativePath, line: row.line, reason: "expected timestamp,position,unit quaternion")
            }
            if let previous, timestamp <= previous {
                throw EuRoCReplayError.timestampRegression(path: record.relativePath, previous: previous, current: timestamp)
            }
            result.append(TimedPose(
                timestampNanoseconds: timestamp,
                translation: Vector3(x: px, y: py, z: pz),
                rotation: quaternion
            ))
            previous = timestamp
        }
        guard result.count >= 2 else {
            throw EuRoCReplayError.malformedCSV(path: record.relativePath, line: 0, reason: "ground truth is missing or partial")
        }
        return result
    }

    private func csvRows(record: EuRoCManifestFile, rootURL: URL) throws -> [CSVRow] {
        let url = try EuRoCDatasetIdentity.resolvedPayloadURL(rootURL: rootURL, relativePath: record.relativePath)
        guard let text = String(data: try Data(contentsOf: url), encoding: .utf8) else {
            throw EuRoCReplayError.malformedCSV(path: record.relativePath, line: 0, reason: "file is not UTF-8")
        }
        // Temporary: a trimmed dataset was rejected as an empty camera index
        // while the file it names parses by hand, so what actually gets read
        // has to be visible.
        NSLog("[VIOBench] csv %@ -> %d bytes, first: %@",
              record.relativePath, text.utf8.count,
              String(text.prefix(60)).replacingOccurrences(of: "\n", with: "\\n"))
        // Split on any newline, not on the character "\n". Swift strings iterate
        // by grapheme cluster and CRLF is a single cluster, so splitting on "\n"
        // finds no separator in a CRLF file and hands back the whole file as one
        // line. EuRoC ships CRLF: its camera index came back as a single
        // commented-out line and the dataset was refused as empty.
        return text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated().compactMap { index, rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            return CSVRow(line: index + 1, fields: line.split(separator: ",", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            })
        }
    }

    private func finiteDouble(_ value: String) -> Double? {
        guard let parsed = Double(value), parsed.isFinite else { return nil }
        return parsed
    }

    private func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }
}

private struct CameraRow {
    let timestamp: Int64
    let imageRelativePath: String
}

private struct CSVRow {
    let line: Int
    let fields: [String]
}
