import CryptoKit
import Foundation

struct BenchmarkArtifactEntry: Codable, Equatable {
    let path: String
    let role: String
    let byteCount: Int
    let sha256: String

    private enum CodingKeys: String, CodingKey {
        case path, role, sha256
        case byteCount = "byte_count"
    }
}

struct BenchmarkArtifactManifest: Codable, Equatable {
    let schemaVersion: Int
    let runID: String
    let generatedAtUTC: String
    let artifacts: [BenchmarkArtifactEntry]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case runID = "run_id"
        case generatedAtUTC = "generated_at_utc"
        case artifacts
    }
}

enum BenchmarkArtifactFinalizerError: LocalizedError {
    case missingRequiredArtifact(String)
    case unsafeArtifactPath(String)

    var errorDescription: String? {
        switch self {
        case .missingRequiredArtifact(let path): return "缺少实验产物：\(path)"
        case .unsafeArtifactPath(let path): return "实验产物路径不安全：\(path)"
        }
    }
}

enum BenchmarkArtifactFinalizer {
    private static let manifestName = "artifact_manifest.json"
    private static let checksumsName = "SHA256SUMS"

    static func finalize(
        directoryURL: URL,
        runID: String,
        channel: RunReceiptChannel,
        fileManager: FileManager = .default
    ) throws {
        // SHA256SUMS and the artifact manifest are written by this function, so
        // they cannot also be preconditions for running it. Requiring SHA256SUMS
        // up front made every record-channel run fail unconditionally, and the
        // failure named finalize's own output as the missing artifact, which hid
        // whatever had actually gone wrong with the run.
        let excluded = Set([manifestName, checksumsName])
        for required in requiredArtifacts(for: channel)
        where !excluded.contains(required)
            && !fileManager.fileExists(
                atPath: directoryURL.appendingPathComponent(required).path
            ) {
            throw BenchmarkArtifactFinalizerError.missingRequiredArtifact(required)
        }
        let contentNames = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            !excluded.contains(url.lastPathComponent)
                && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        .map(\.lastPathComponent)
        .sorted()

        // Hash by streaming. Reading each artifact whole put the 4.7 GB frame
        // stream into memory -- twice, once here and once for the artifact
        // manifest -- and the phone killed the app for it right after a clean
        // 30 s capture, leaving the recording without its checksums.
        var checksumRows: [String] = []
        var measured: [String: (digest: String, byteCount: Int64)] = [:]
        for name in contentNames {
            try validateSafeFilename(name)
            let probed = try streamingDigest(
                of: directoryURL.appendingPathComponent(name),
                fileManager: fileManager
            )
            measured[name] = probed
            checksumRows.append("\(probed.digest)  \(name)")
        }
        let checksums = Data((checksumRows.joined(separator: "\n") + "\n").utf8)
        try checksums.write(
            to: directoryURL.appendingPathComponent(checksumsName),
            options: .atomic
        )

        measured[checksumsName] = try streamingDigest(
            of: directoryURL.appendingPathComponent(checksumsName),
            fileManager: fileManager
        )
        let artifactNames = (contentNames + [checksumsName]).sorted()
        let artifacts = try artifactNames.map { name -> BenchmarkArtifactEntry in
            try validateSafeFilename(name)
            // Reuses what the checksum pass already measured, so no artifact is
            // read twice and none is read whole.
            let probed = try measured[name] ?? streamingDigest(
                of: directoryURL.appendingPathComponent(name),
                fileManager: fileManager
            )
            return BenchmarkArtifactEntry(
                path: name,
                role: role(for: name),
                byteCount: Int(probed.byteCount),
                sha256: probed.digest
            )
        }
        let manifest = BenchmarkArtifactManifest(
            schemaVersion: 1,
            runID: runID,
            generatedAtUTC: BenchmarkRunPreparation.utcTimestamp(),
            artifacts: artifacts
        )
        try RunReceiptJSON.encoder.encode(manifest).write(
            to: directoryURL.appendingPathComponent(manifestName),
            options: .atomic
        )
    }

    /// SHA-256 and size of a file, read in chunks so an artifact of any size
    /// costs one buffer rather than its own length in memory.
    private static func streamingDigest(
        of url: URL,
        fileManager: FileManager
    ) throws -> (digest: String, byteCount: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        var reading = true
        while reading {
            // Each chunk is drained before the next is read. Without this the
            // buffers live until the loop ends, which put the whole 4.9 GB
            // stream in memory again by another route: a 30 s capture still
            // died in finalize while an 8 s one finished.
            try autoreleasepool {
                guard let chunk = try handle.read(upToCount: 4 * 1024 * 1024),
                      !chunk.isEmpty else {
                    reading = false
                    return
                }
                hasher.update(data: chunk)
                total += Int64(chunk.count)
            }
        }
        return (RunReceiptHash.hex(hasher.finalize()), total)
    }

    private static func requiredArtifacts(for channel: RunReceiptChannel) -> [String] {
        switch channel {
        case .record:
            return ["input_manifest.json", "receipt.json", "heartbeat.json", "telemetry.jsonl", "diagnostics.json", "recording_manifest.json", "SHA256SUMS"]
        case .liveSoak:
            return ["input_manifest.json", "receipt.json", "heartbeat.json", "telemetry.jsonl", "diagnostics.json"]
        case .replayDeviceRecording:
            return ["input_manifest.json", "poses.tum", "receipt.json", "heartbeat.json", "diagnostics.json"]
        case .replayPaced, .replayMax:
            return ["input_manifest.json", "poses.tum", "receipt.json", "heartbeat.json", "diagnostics.json"]
        }
    }

    private static func role(for name: String) -> String {
        switch name {
        case "input_manifest.json": return "input_manifest"
        case "poses.tum": return "poses"
        case "receipt.json": return "receipt"
        case "heartbeat.json": return "heartbeat"
        case "telemetry.jsonl": return "telemetry"
        case "diagnostics.json": return "diagnostics"
        case checksumsName: return "checksums"
        default: return "other"
        }
    }

    private static func validateSafeFilename(_ name: String) throws {
        guard !name.isEmpty,
              name != ".", name != "..",
              !name.contains("/"), !name.contains("\\") else {
            throw BenchmarkArtifactFinalizerError.unsafeArtifactPath(name)
        }
    }
}
