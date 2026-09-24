import Foundation

enum CalibrationMaterializerError: Error, Equatable {
    case invalidRoot
    case missingArray(String)
    case insufficientCameraEntries(String)
}

enum CalibrationMaterializer {
    /// Produces a deterministic cam0-only calibration from Basalt's pinned
    /// official EuRoC calibration. No numeric field is estimated or changed.
    /// Builds the calibration a device-recording replay runs on.
    ///
    /// Intrinsics and resolution come from the recording -- `ARFrame.camera.intrinsics`
    /// measured for exactly the frames about to be replayed, cross-checked at
    /// record time. Everything else is carried through from the frozen upstream
    /// calibration unchanged: the IMU-to-camera transform is a rigid mount and is
    /// resolution independent, and the IMU noise model is a property of the
    /// inertial sensor, not of image sampling.
    ///
    /// Nothing here is extrapolated. The alternative -- scaling the frozen 640x480
    /// intrinsics threefold -- is only valid if both formats share a field of
    /// view, which is why it stays a cross-check and never a source.
    /// Reads the pinhole intrinsics out of a frozen calibration so a caller can
    /// derive new ones from them rather than restating literals that would then
    /// have two sources of truth.
    static func pinholeIntrinsics(
        from frozenData: Data,
        isYAML: Bool
    ) throws -> (fx: Double, fy: Double, cx: Double, cy: Double) {
        if !isYAML {
            guard let root = try JSONSerialization.jsonObject(with: frozenData) as? [String: Any],
                  let value0 = root["value0"] as? [String: Any],
                  let intrinsicsArray = value0["intrinsics"] as? [[String: Any]],
                  let camera = intrinsicsArray.first?["intrinsics"] as? [String: Any],
                  let fx = camera["fx"] as? Double, let fy = camera["fy"] as? Double,
                  let cx = camera["cx"] as? Double, let cy = camera["cy"] as? Double else {
                throw CalibrationMaterializerError.invalidRoot
            }
            return (fx, fy, cx, cy)
        }
        // xrslam's YAML writes the camera as `intrinsics: [fx, fy, cx, cy]`,
        // which is the same line deviceRecordingYAML rewrites.
        guard let text = String(data: frozenData, encoding: .utf8) else {
            throw CalibrationMaterializerError.invalidRoot
        }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("intrinsics:") else { continue }
            let values = trimmed.drop(while: { $0 != "[" })
                .split(whereSeparator: { "[], ".contains($0) })
                .compactMap { Double($0) }
            guard values.count >= 4 else { break }
            return (values[0], values[1], values[2], values[3])
        }
        throw CalibrationMaterializerError.invalidRoot
    }

    static func deviceRecording(
        from frozenData: Data,
        intrinsics: DeviceRecordingIntrinsics,
        width: Int,
        height: Int
    ) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: frozenData) as? [String: Any],
              var value0 = root["value0"] as? [String: Any],
              var intrinsicsArray = value0["intrinsics"] as? [[String: Any]],
              !intrinsicsArray.isEmpty,
              var camera = intrinsicsArray[0]["intrinsics"] as? [String: Any] else {
            throw CalibrationMaterializerError.invalidRoot
        }
        camera["fx"] = intrinsics.fx
        camera["fy"] = intrinsics.fy
        camera["cx"] = intrinsics.cx
        camera["cy"] = intrinsics.cy
        intrinsicsArray[0]["intrinsics"] = camera
        value0["intrinsics"] = intrinsicsArray
        value0["resolution"] = [[width, height]]
        root["value0"] = value0
        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    /// The same substitution for xrslam, whose calibration is YAML rather than
    /// Basalt's JSON. Feeding the YAML to the JSON path threw before the started
    /// receipt was written, so a replay left a run directory holding nothing but
    /// its marker and no record of why -- xrslam looked like it was hanging for
    /// twenty minutes when it had already failed.
    ///
    /// Only the two lines that describe the frames are rewritten. The mount
    /// transform and the IMU noise model are carried through untouched, exactly
    /// as the JSON path does.
    static func deviceRecordingYAML(
        from frozenData: Data,
        intrinsics: DeviceRecordingIntrinsics,
        width: Int,
        height: Int
    ) throws -> Data {
        guard let text = String(data: frozenData, encoding: .utf8) else {
            throw CalibrationMaterializerError.invalidRoot
        }
        var sawResolution = false
        var sawIntrinsics = false
        let patched = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { line -> String in
                let raw = String(line)
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                let indent = String(raw.prefix(raw.count - trimmed.count))
                if trimmed.hasPrefix("resolution:") {
                    sawResolution = true
                    return "\(indent)resolution: [\(width), \(height)]"
                }
                if trimmed.hasPrefix("intrinsics:") {
                    sawIntrinsics = true
                    return "\(indent)intrinsics: [\(intrinsics.fx), \(intrinsics.fy), "
                        + "\(intrinsics.cx), \(intrinsics.cy)]"
                }
                return raw
            }
            .joined(separator: "\n")
        guard sawResolution, sawIntrinsics else {
            throw CalibrationMaterializerError.missingArray(
                sawResolution ? "intrinsics" : "resolution"
            )
        }
        return Data(patched.utf8)
    }

    static func eurocCam0Only(from stereoData: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: stereoData) as? [String: Any],
              var value = root["value0"] as? [String: Any] else {
            throw CalibrationMaterializerError.invalidRoot
        }

        for key in ["T_imu_cam", "intrinsics", "resolution", "vignette"] {
            guard let cameras = value[key] as? [Any] else {
                throw CalibrationMaterializerError.missingArray(key)
            }
            guard cameras.count >= 2 else {
                throw CalibrationMaterializerError.insufficientCameraEntries(key)
            }
            value[key] = [cameras[0]]
        }

        root["value0"] = value
        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }
}
