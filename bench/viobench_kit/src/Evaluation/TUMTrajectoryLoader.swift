import Foundation

enum TUMTrajectoryError: Error, Equatable, CustomStringConvertible {
    case unreadableFile(String)
    case malformedLine(line: Int, reason: String)
    case timestampsNotStrictlyIncreasing(line: Int)
    case emptyTrajectory

    var description: String {
        switch self {
        case .unreadableFile(let path): "cannot read TUM trajectory: \(path)"
        case .malformedLine(let line, let reason): "malformed TUM trajectory line \(line): \(reason)"
        case .timestampsNotStrictlyIncreasing(let line): "TUM timestamps are not strictly increasing at line \(line)"
        case .emptyTrajectory: "TUM trajectory is empty"
        }
    }
}

/// Strict reader for `timestamp tx ty tz qx qy qz qw` pose artifacts.
/// Decimal timestamps are converted to integer nanoseconds without binary-float rounding.
struct TUMTrajectoryLoader {
    func load(url: URL) throws -> [TimedPose] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw TUMTrajectoryError.unreadableFile(url.path)
        }
        var poses: [TimedPose] = []
        var previousTimestamp: Int64?
        for (offset, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let lineNumber = offset + 1
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count == 8, let timestamp = parseNanoseconds(fields[0]),
                  let tx = finiteDouble(fields[1]), let ty = finiteDouble(fields[2]), let tz = finiteDouble(fields[3]),
                  let qx = finiteDouble(fields[4]), let qy = finiteDouble(fields[5]),
                  let qz = finiteDouble(fields[6]), let qw = finiteDouble(fields[7]),
                  let rotation = Quaternion.normalizedOrNil(w: qw, x: qx, y: qy, z: qz) else {
                throw TUMTrajectoryError.malformedLine(
                    line: lineNumber,
                    reason: "expected timestamp tx ty tz qx qy qz qw with at most 9 fractional timestamp digits"
                )
            }
            if let previousTimestamp, timestamp <= previousTimestamp {
                throw TUMTrajectoryError.timestampsNotStrictlyIncreasing(line: lineNumber)
            }
            poses.append(TimedPose(
                timestampNanoseconds: timestamp,
                translation: Vector3(x: tx, y: ty, z: tz),
                rotation: rotation
            ))
            previousTimestamp = timestamp
        }
        guard !poses.isEmpty else { throw TUMTrajectoryError.emptyTrajectory }
        return poses
    }

    private func parseNanoseconds(_ timestamp: String) -> Int64? {
        guard !timestamp.isEmpty, !timestamp.hasPrefix("-"), !timestamp.hasPrefix("+") else { return nil }
        let parts = timestamp.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, let seconds = Int64(parts[0]), seconds >= 0,
              seconds <= Int64.max / 1_000_000_000 else { return nil }
        var fractionalNanoseconds: Int64 = 0
        if parts.count == 2 {
            let fraction = String(parts[1])
            guard !fraction.isEmpty, fraction.utf8.count <= 9,
                  fraction.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let digits = Int64(fraction) else { return nil }
            fractionalNanoseconds = digits
            for _ in fraction.utf8.count..<9 { fractionalNanoseconds *= 10 }
        }
        let whole = seconds * 1_000_000_000
        guard whole <= Int64.max - fractionalNanoseconds else { return nil }
        return whole + fractionalNanoseconds
    }

    private func finiteDouble(_ value: String) -> Double? {
        guard let parsed = Double(value), parsed.isFinite else { return nil }
        return parsed
    }
}
