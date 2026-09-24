import Foundation

struct Vector3: Equatable, Sendable {
    let x: Double
    let y: Double
    let z: Double

    static let zero = Vector3(x: 0, y: 0, z: 0)

    static func + (lhs: Vector3, rhs: Vector3) -> Vector3 {
        Vector3(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
    }

    static func - (lhs: Vector3, rhs: Vector3) -> Vector3 {
        Vector3(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    static prefix func - (value: Vector3) -> Vector3 {
        Vector3(x: -value.x, y: -value.y, z: -value.z)
    }

    static func * (lhs: Double, rhs: Vector3) -> Vector3 {
        Vector3(x: lhs * rhs.x, y: lhs * rhs.y, z: lhs * rhs.z)
    }

    static func * (lhs: Vector3, rhs: Double) -> Vector3 { rhs * lhs }

    static func / (lhs: Vector3, rhs: Double) -> Vector3 {
        Vector3(x: lhs.x / rhs, y: lhs.y / rhs, z: lhs.z / rhs)
    }

    func dot(_ other: Vector3) -> Double {
        x * other.x + y * other.y + z * other.z
    }

    func cross(_ other: Vector3) -> Vector3 {
        Vector3(
            x: y * other.z - z * other.y,
            y: z * other.x - x * other.z,
            z: x * other.y - y * other.x
        )
    }

    var squaredNorm: Double { dot(self) }
    var norm: Double { sqrt(squaredNorm) }
    var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}

struct Quaternion: Equatable, Sendable {
    let w: Double
    let x: Double
    let y: Double
    let z: Double

    static let identity = Quaternion(w: 1, x: 0, y: 0, z: 0)

    static func normalizedOrNil(w: Double, x: Double, y: Double, z: Double) -> Quaternion? {
        guard w.isFinite, x.isFinite, y.isFinite, z.isFinite else { return nil }
        let norm = sqrt(w * w + x * x + y * y + z * z)
        guard norm > 1e-15 else { return nil }
        return Quaternion(w: w / norm, x: x / norm, y: y / norm, z: z / norm)
    }

    static func angleAxis(radians: Double, axis: Vector3) -> Quaternion {
        let axisNorm = axis.norm
        precondition(axisNorm > 0 && radians.isFinite)
        let half = radians / 2
        let scale = sin(half) / axisNorm
        return Quaternion(w: cos(half), x: axis.x * scale, y: axis.y * scale, z: axis.z * scale)
    }

    static func * (lhs: Quaternion, rhs: Quaternion) -> Quaternion {
        Quaternion(
            w: lhs.w * rhs.w - lhs.x * rhs.x - lhs.y * rhs.y - lhs.z * rhs.z,
            x: lhs.w * rhs.x + lhs.x * rhs.w + lhs.y * rhs.z - lhs.z * rhs.y,
            y: lhs.w * rhs.y - lhs.x * rhs.z + lhs.y * rhs.w + lhs.z * rhs.x,
            z: lhs.w * rhs.z + lhs.x * rhs.y - lhs.y * rhs.x + lhs.z * rhs.w
        ).normalized
    }

    var normalized: Quaternion {
        Quaternion.normalizedOrNil(w: w, x: x, y: y, z: z) ?? .identity
    }

    var inverse: Quaternion {
        let q = normalized
        return Quaternion(w: q.w, x: -q.x, y: -q.y, z: -q.z)
    }

    func rotated(_ vector: Vector3) -> Vector3 {
        let q = normalized
        let u = Vector3(x: q.x, y: q.y, z: q.z)
        return 2 * u.dot(vector) * u
            + (q.w * q.w - u.dot(u)) * vector
            + 2 * q.w * u.cross(vector)
    }

    var shortestAngleRadians: Double {
        let scalar = min(1.0, max(0.0, abs(normalized.w)))
        return 2.0 * acos(scalar)
    }
}

struct TimedPose: Equatable, Sendable {
    let timestampNanoseconds: Int64
    let translation: Vector3
    let rotation: Quaternion

    var isFinite: Bool {
        translation.isFinite
            && rotation.w.isFinite && rotation.x.isFinite
            && rotation.y.isFinite && rotation.z.isFinite
    }
}

struct RigidTransform: Equatable, Sendable {
    let rotation: Quaternion
    let translation: Vector3

    static let identity = RigidTransform(rotation: .identity, translation: .zero)

    func applied(to point: Vector3) -> Vector3 {
        rotation.rotated(point) + translation
    }

    func applied(to pose: TimedPose) -> TimedPose {
        TimedPose(
            timestampNanoseconds: pose.timestampNanoseconds,
            translation: applied(to: pose.translation),
            rotation: rotation * pose.rotation
        )
    }
}
