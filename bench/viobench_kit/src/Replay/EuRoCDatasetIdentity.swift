import CryptoKit
import Foundation

enum EuRoCDatasetIdentity {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Hashes the semantic manifest header and ordered, content-addressed file records.
    /// The loader verifies every per-file digest against its bytes before trusting this
    /// identity. Length-prefixed fields prevent concatenation ambiguity.
    static func compute(rootURL _: URL, manifest: EuRoCOrderedManifest) throws -> String {
        var hasher = SHA256()
        update(&hasher, bytes: Data("euroc-ordered-dataset-v1\0".utf8))
        update(&hasher, integer: Int64(manifest.schemaVersion))
        update(&hasher, string: manifest.datasetName)
        update(&hasher, integer: Int64(manifest.inputCameraCount))

        for record in manifest.files {
            update(&hasher, string: record.role.rawValue)
            update(&hasher, string: record.relativePath)
            update(&hasher, integer: record.byteCount)
            update(&hasher, string: record.sha256)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func resolvedPayloadURL(rootURL: URL, relativePath: String) throws -> URL {
        guard isSafeRelativePath(relativePath) else {
            throw EuRoCReplayError.unsafeRelativePath(relativePath)
        }
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = rootURL.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(prefix) else {
            throw EuRoCReplayError.unsafeRelativePath(relativePath)
        }
        return candidate
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func update(_ hasher: inout SHA256, string: String) {
        update(&hasher, bytes: Data(string.utf8))
    }

    private static func update(_ hasher: inout SHA256, bytes: Data) {
        update(&hasher, integer: Int64(bytes.count))
        hasher.update(data: bytes)
    }

    private static func update(_ hasher: inout SHA256, integer: Int64) {
        var value = UInt64(bitPattern: integer).bigEndian
        withUnsafeBytes(of: &value) { hasher.update(data: Data($0)) }
    }
}
