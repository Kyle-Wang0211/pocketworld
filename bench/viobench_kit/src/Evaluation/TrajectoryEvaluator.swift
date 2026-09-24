import Foundation

struct TrajectoryAssociation: Equatable, Sendable {
    let estimated: TimedPose
    let groundTruth: TimedPose
}

enum TrajectoryEvaluationError: Error, Equatable, CustomStringConvertible {
    case missingEstimate
    case missingGroundTruth
    case invalidConfiguration(String)
    case invalidPose(stream: String, index: Int)
    case timestampsNotStrictlyIncreasing(stream: String, index: Int)
    case insufficientGroundTruthCoverage(actual: Double, required: Double)
    case insufficientAssociations(Int)
    case noOneSecondRPEPairs

    var description: String {
        switch self {
        case .missingEstimate: "estimated trajectory is empty"
        case .missingGroundTruth: "ground-truth trajectory is empty"
        case .invalidConfiguration(let reason): "invalid trajectory evaluation configuration: \(reason)"
        case .invalidPose(let stream, let index): "non-finite or invalid pose in \(stream) at index \(index)"
        case .timestampsNotStrictlyIncreasing(let stream, let index): "timestamps are not strictly increasing in \(stream) at index \(index)"
        case .insufficientGroundTruthCoverage(let actual, let required): "ground-truth coverage \(actual) is below required \(required)"
        case .insufficientAssociations(let count): "at least two pose associations are required; got \(count)"
        case .noOneSecondRPEPairs: "no pose pairs match the configured one-second RPE horizon"
        }
    }
}

enum TrajectoryAssociator {
    /// Monotonic, one-to-one nearest-neighbor association. Equal-distance ties
    /// resolve to the earlier ground-truth timestamp.
    static func associate(
        estimated: [TimedPose],
        groundTruth: [TimedPose],
        toleranceNanoseconds: Int64
    ) throws -> [TrajectoryAssociation] {
        guard toleranceNanoseconds >= 0 else {
            throw TrajectoryEvaluationError.invalidConfiguration("association tolerance must be non-negative")
        }
        try validateTrajectory(estimated, named: "estimate")
        try validateTrajectory(groundTruth, named: "ground_truth")
        guard !estimated.isEmpty, !groundTruth.isEmpty else { return [] }

        var associations: [TrajectoryAssociation] = []
        var minimumIndex = 0
        for estimate in estimated where minimumIndex < groundTruth.count {
            var insertion = minimumIndex
            while insertion < groundTruth.count,
                  groundTruth[insertion].timestampNanoseconds < estimate.timestampNanoseconds {
                insertion += 1
            }

            var candidates: [Int] = []
            if insertion < groundTruth.count { candidates.append(insertion) }
            if insertion > minimumIndex { candidates.append(insertion - 1) }
            let best = candidates.min { lhs, rhs in
                let left = absoluteTimestampDifference(groundTruth[lhs].timestampNanoseconds, estimate.timestampNanoseconds)
                let right = absoluteTimestampDifference(groundTruth[rhs].timestampNanoseconds, estimate.timestampNanoseconds)
                if left != right { return left < right }
                return groundTruth[lhs].timestampNanoseconds < groundTruth[rhs].timestampNanoseconds
            }
            guard let best,
                  absoluteTimestampDifference(groundTruth[best].timestampNanoseconds, estimate.timestampNanoseconds) <= UInt64(toleranceNanoseconds) else {
                continue
            }
            associations.append(TrajectoryAssociation(estimated: estimate, groundTruth: groundTruth[best]))
            minimumIndex = best + 1
        }
        return associations
    }

    fileprivate static func validateTrajectory(_ poses: [TimedPose], named stream: String) throws {
        for (index, pose) in poses.enumerated() {
            guard pose.isFinite,
                  Quaternion.normalizedOrNil(w: pose.rotation.w, x: pose.rotation.x, y: pose.rotation.y, z: pose.rotation.z) != nil else {
                throw TrajectoryEvaluationError.invalidPose(stream: stream, index: index)
            }
            if index > 0, pose.timestampNanoseconds <= poses[index - 1].timestampNanoseconds {
                throw TrajectoryEvaluationError.timestampsNotStrictlyIncreasing(stream: stream, index: index)
            }
        }
    }

    private static func absoluteTimestampDifference(_ lhs: Int64, _ rhs: Int64) -> UInt64 {
        lhs >= rhs
            ? UInt64(bitPattern: lhs) &- UInt64(bitPattern: rhs)
            : UInt64(bitPattern: rhs) &- UInt64(bitPattern: lhs)
    }
}

struct TrajectoryEvaluationConfiguration: Equatable, Sendable {
    var associationToleranceNanoseconds: Int64 = 5_000_000
    var minimumGroundTruthCoverage: Double = 0.99
    var rpeHorizonNanoseconds: Int64 = 1_000_000_000
    var rpeHorizonToleranceNanoseconds: Int64 = 20_000_000
}

struct TrajectoryMetrics: Equatable, Sendable {
    let associatedPoseCount: Int
    let estimatedPoseCount: Int
    let groundTruthCoverage: Double
    let alignmentScale: Double
    let alignment: RigidTransform
    let ateRMSEMeters: Double
    let rpePairCount: Int
    let rpeTranslationRMSEMeters: Double
    let rpeRotationRMSEDegrees: Double
}

struct TrajectoryEvaluator {
    let configuration: TrajectoryEvaluationConfiguration

    init(configuration: TrajectoryEvaluationConfiguration = .init()) {
        self.configuration = configuration
    }

    func evaluate(estimated: [TimedPose], groundTruth: [TimedPose]) throws -> TrajectoryMetrics {
        guard !estimated.isEmpty else { throw TrajectoryEvaluationError.missingEstimate }
        guard !groundTruth.isEmpty else { throw TrajectoryEvaluationError.missingGroundTruth }
        try validateConfiguration()

        let matches = try TrajectoryAssociator.associate(
            estimated: estimated,
            groundTruth: groundTruth,
            toleranceNanoseconds: configuration.associationToleranceNanoseconds
        )
        let coverage = Double(matches.count) / Double(estimated.count)
        guard coverage >= configuration.minimumGroundTruthCoverage else {
            throw TrajectoryEvaluationError.insufficientGroundTruthCoverage(
                actual: coverage,
                required: configuration.minimumGroundTruthCoverage
            )
        }
        guard matches.count >= 2 else {
            throw TrajectoryEvaluationError.insufficientAssociations(matches.count)
        }

        let alignment = fixedScaleAlignment(matches)
        let squaredATE = matches.reduce(0.0) { partial, match in
            let error = alignment.applied(to: match.estimated.translation) - match.groundTruth.translation
            return partial + error.squaredNorm
        }
        let ateRMSE = sqrt(squaredATE / Double(matches.count))
        let rpe = try relativePoseErrors(matches)

        return TrajectoryMetrics(
            associatedPoseCount: matches.count,
            estimatedPoseCount: estimated.count,
            groundTruthCoverage: coverage,
            alignmentScale: 1.0,
            alignment: alignment,
            ateRMSEMeters: ateRMSE,
            rpePairCount: rpe.count,
            rpeTranslationRMSEMeters: sqrt(rpe.translationSquaredSum / Double(rpe.count)),
            rpeRotationRMSEDegrees: sqrt(rpe.rotationRadiansSquaredSum / Double(rpe.count)) * 180.0 / .pi
        )
    }

    private func validateConfiguration() throws {
        guard configuration.associationToleranceNanoseconds >= 0 else {
            throw TrajectoryEvaluationError.invalidConfiguration("association tolerance must be non-negative")
        }
        guard configuration.minimumGroundTruthCoverage >= 0,
              configuration.minimumGroundTruthCoverage <= 1 else {
            throw TrajectoryEvaluationError.invalidConfiguration("coverage must lie in [0, 1]")
        }
        guard configuration.rpeHorizonNanoseconds > 0,
              configuration.rpeHorizonToleranceNanoseconds >= 0 else {
            throw TrajectoryEvaluationError.invalidConfiguration("RPE horizon must be positive and tolerance non-negative")
        }
    }

    /// Horn's unit-quaternion absolute-orientation solution with scale fixed to 1.
    private func fixedScaleAlignment(_ matches: [TrajectoryAssociation]) -> RigidTransform {
        let count = Double(matches.count)
        let estimateCenter = matches.reduce(Vector3.zero) { $0 + $1.estimated.translation } / count
        let truthCenter = matches.reduce(Vector3.zero) { $0 + $1.groundTruth.translation } / count

        var sxx = 0.0, sxy = 0.0, sxz = 0.0
        var syx = 0.0, syy = 0.0, syz = 0.0
        var szx = 0.0, szy = 0.0, szz = 0.0
        for match in matches {
            let source = match.estimated.translation - estimateCenter
            let target = match.groundTruth.translation - truthCenter
            sxx += source.x * target.x; sxy += source.x * target.y; sxz += source.x * target.z
            syx += source.y * target.x; syy += source.y * target.y; syz += source.y * target.z
            szx += source.z * target.x; szy += source.z * target.y; szz += source.z * target.z
        }

        let trace = sxx + syy + szz
        let horn = [
            [trace, syz - szy, szx - sxz, sxy - syx],
            [syz - szy, sxx - syy - szz, sxy + syx, szx + sxz],
            [szx - sxz, sxy + syx, -sxx + syy - szz, syz + szy],
            [sxy - syx, szx + sxz, syz + szy, -sxx - syy + szz],
        ]
        let eigenvector = largestEigenvector(ofSymmetric4x4: horn)
        var rotation = Quaternion.normalizedOrNil(
            w: eigenvector[0], x: eigenvector[1], y: eigenvector[2], z: eigenvector[3]
        ) ?? .identity
        if rotation.w < 0 {
            rotation = Quaternion(w: -rotation.w, x: -rotation.x, y: -rotation.y, z: -rotation.z)
        }
        return RigidTransform(
            rotation: rotation,
            translation: truthCenter - rotation.rotated(estimateCenter)
        )
    }

    private func relativePoseErrors(_ matches: [TrajectoryAssociation]) throws -> RPEAccumulator {
        var accumulator = RPEAccumulator()
        for firstIndex in matches.indices {
            let first = matches[firstIndex]
            guard first.estimated.timestampNanoseconds <= Int64.max - configuration.rpeHorizonNanoseconds else { continue }
            let target = first.estimated.timestampNanoseconds + configuration.rpeHorizonNanoseconds
            var insertion = firstIndex + 1
            while insertion < matches.count, matches[insertion].estimated.timestampNanoseconds < target {
                insertion += 1
            }
            var candidates: [Int] = []
            if insertion < matches.count { candidates.append(insertion) }
            if insertion > firstIndex + 1 { candidates.append(insertion - 1) }
            guard let secondIndex = candidates.min(by: { lhs, rhs in
                let left = timestampDistance(matches[lhs].estimated.timestampNanoseconds, target)
                let right = timestampDistance(matches[rhs].estimated.timestampNanoseconds, target)
                if left != right { return left < right }
                return matches[lhs].estimated.timestampNanoseconds < matches[rhs].estimated.timestampNanoseconds
            }), timestampDistance(matches[secondIndex].estimated.timestampNanoseconds, target) <= UInt64(configuration.rpeHorizonToleranceNanoseconds) else {
                continue
            }

            let second = matches[secondIndex]
            let truthRelativeRotation = first.groundTruth.rotation.inverse * second.groundTruth.rotation
            let estimateRelativeRotation = first.estimated.rotation.inverse * second.estimated.rotation
            let truthRelativeTranslation = first.groundTruth.rotation.inverse.rotated(
                second.groundTruth.translation - first.groundTruth.translation
            )
            let estimateRelativeTranslation = first.estimated.rotation.inverse.rotated(
                second.estimated.translation - first.estimated.translation
            )
            let errorTranslation = truthRelativeRotation.inverse.rotated(
                estimateRelativeTranslation - truthRelativeTranslation
            )
            let errorRotation = truthRelativeRotation.inverse * estimateRelativeRotation
            accumulator.count += 1
            accumulator.translationSquaredSum += errorTranslation.squaredNorm
            let angle = errorRotation.shortestAngleRadians
            accumulator.rotationRadiansSquaredSum += angle * angle
        }
        guard accumulator.count > 0 else { throw TrajectoryEvaluationError.noOneSecondRPEPairs }
        return accumulator
    }

    private func largestEigenvector(ofSymmetric4x4 input: [[Double]]) -> [Double] {
        var matrix = input
        var vectors = Array(repeating: Array(repeating: 0.0, count: 4), count: 4)
        for index in 0..<4 { vectors[index][index] = 1 }

        for _ in 0..<64 {
            var p = 0, q = 1
            var magnitude = abs(matrix[p][q])
            for row in 0..<4 {
                for column in (row + 1)..<4 where abs(matrix[row][column]) > magnitude {
                    p = row; q = column; magnitude = abs(matrix[row][column])
                }
            }
            if magnitude < 1e-15 { break }

            let angle = 0.5 * atan2(2 * matrix[p][q], matrix[q][q] - matrix[p][p])
            let cosine = cos(angle), sine = sin(angle)
            let app = matrix[p][p], aqq = matrix[q][q], apq = matrix[p][q]
            for index in 0..<4 where index != p && index != q {
                let aip = matrix[index][p], aiq = matrix[index][q]
                matrix[index][p] = cosine * aip - sine * aiq
                matrix[p][index] = matrix[index][p]
                matrix[index][q] = sine * aip + cosine * aiq
                matrix[q][index] = matrix[index][q]
            }
            matrix[p][p] = cosine * cosine * app - 2 * sine * cosine * apq + sine * sine * aqq
            matrix[q][q] = sine * sine * app + 2 * sine * cosine * apq + cosine * cosine * aqq
            matrix[p][q] = 0
            matrix[q][p] = 0
            for row in 0..<4 {
                let vip = vectors[row][p], viq = vectors[row][q]
                vectors[row][p] = cosine * vip - sine * viq
                vectors[row][q] = sine * vip + cosine * viq
            }
        }
        var best = 0
        for index in 1..<4 where matrix[index][index] > matrix[best][best] { best = index }
        return (0..<4).map { vectors[$0][best] }
    }

    private func timestampDistance(_ lhs: Int64, _ rhs: Int64) -> UInt64 {
        lhs >= rhs
            ? UInt64(bitPattern: lhs) &- UInt64(bitPattern: rhs)
            : UInt64(bitPattern: rhs) &- UInt64(bitPattern: lhs)
    }
}

private struct RPEAccumulator {
    var count = 0
    var translationSquaredSum = 0.0
    var rotationRadiansSquaredSum = 0.0
}
