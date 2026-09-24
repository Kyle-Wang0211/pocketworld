import Foundation

struct PreparedBenchmarkRun {
    let backend: BenchBackend
    let runID: String
    let directoryURL: URL
    let configURL: URL
    let calibrationURL: URL
    let inputCameraCount: Int
    let imageWidth: Int
    let imageHeight: Int
    let replayDataset: EuRoCReplayDataset?
    /// Set only for `replay-device-recording`. Carries the events the candidates
    /// replay and the ARKit trajectory measured over the identical frames.
    let deviceRecording: DeviceRecordingDataset?

    /// The events to replay, whichever channel supplied them. One scheduler
    /// drives both, so pacing and ordering cannot drift between channels.
    var replayEvents: [ReplayEvent]? {
        deviceRecording?.events ?? replayDataset?.events
    }
    let startedReceipt: RunReceipt
    let startedReceiptSHA256: String
    let receiptWriter: RunReceiptWriter
}

struct EngineResourcePlan: Equatable {
    let config: String
    let calibration: String

    static func forRun(backend: BenchBackend, mode: BenchMode) -> EngineResourcePlan {
        if backend == .arkit {
            return EngineResourcePlan(
                config: "arkit_production_reference.json",
                calibration: "arkit_runtime_calibration.json"
            )
        }
        if backend == .xrslam {
            switch mode {
            case .record, .recordNative, .liveSoak, .replayDeviceRecording:
            return EngineResourcePlan(
                config: "xrslam_ios_vio.yaml",
                calibration: "xrslam_iphone_14_pro.yaml"
            )
            case .replayPaced, .replayMax:
            return EngineResourcePlan(
                config: "xrslam_euroc_vio.yaml",
                calibration: "xrslam_euroc_sensor.yaml"
            )
            }
        }
        switch mode {
        case .record, .recordNative, .liveSoak, .replayDeviceRecording:
            return EngineResourcePlan(
                config: "euroc_config.json",
                calibration: "iphone_14_pro_640x480_calib.json"
            )
        case .replayPaced, .replayMax:
            return EngineResourcePlan(
                config: "euroc_config.json",
                calibration: "euroc_eucm_calib.json"
            )
        }
    }
}

enum BenchmarkRunPreparationError: LocalizedError {
    case missingResource(String)
    case replayDatasetRequired
    case replayMustBeMono(Int)
    case arkitReplayUnsupported
    case executableUnavailable
    case engineArtifactUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .missingResource(let name): return "Bench 构建缺少冻结资源：\(name)"
        case .replayDatasetRequired: return "必须选择带 input_manifest.json 的 EuRoC 目录。"
        case .replayMustBeMono(let count): return "正式手机精度通道只接受 cam0 单目，清单声明了 \(count) 个相机。"
        case .arkitReplayUnsupported: return "ARKit 参考臂不接受 EuRoC 回放；它只运行独立真机参考会话。"
        case .executableUnavailable: return "无法读取当前 bench 可执行文件身份。"
        case .engineArtifactUnavailable(let name): return "无法读取所选引擎工件身份：\(name)"
        }
    }
}

enum BenchmarkRunPreparation {
    static func prepare(
        backend: BenchBackend,
        mode: BenchMode,
        datasetURL: URL?
    ) throws -> PreparedBenchmarkRun {
        // ARKit cannot be fed any recording, but it does run live for both
        // `liveSoak` and `record`.
        if backend == .arkit, mode.isReplay {
            throw BenchmarkRunPreparationError.arkitReplayUnsupported
        }
        let runID = UUID().uuidString.lowercased()
        let fileManager = FileManager.default
        let root = try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent(backend.runDirectoryName, isDirectory: true)
        let directory = root.appendingPathComponent("run-\(runID)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        // Only a self-test launch marks its run disposable. Without the marker
        // the purge leaves the directory alone, which is what protects a capture
        // the operator shot by hand.
        BenchSelfTest.markSelfTestRunIfNeeded(directoryURL: directory, mode: mode)
        // [2026-09-03] A throw anywhere in the rest of preparation used to leave a
        // run directory holding only the self-test marker and no statement of what
        // failed (the ARKit live-soak arm did exactly that, and the catch in the
        // coordinator only writes a terminal receipt once preparation has
        // succeeded). Keep the failure with the directory.
        do {
            return try prepareInDirectory(
                directory: directory, runID: runID, backend: backend, mode: mode, datasetURL: datasetURL
            )
        } catch {
            let note: [String: String] = [
                "error": String(describing: error), "backend": backend.id, "mode": mode.rawValue,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: note, options: [.prettyPrinted]) {
                try? data.write(to: directory.appendingPathComponent("failure.json"))
            }
            throw error
        }
    }

    private static func prepareInDirectory(
        directory: URL, runID: String, backend: BenchBackend, mode: BenchMode, datasetURL: URL?
    ) throws -> PreparedBenchmarkRun {
        let fileManager = FileManager.default

        let resourcePlan = EngineResourcePlan.forRun(
            backend: backend,
            mode: mode
        )
        let configSource = try resourceFile(resourcePlan.config)
        let calibrationSource = try resourceFile(resourcePlan.calibration)
        let contractSource = try resource("contract", extension: "json")
        let metricDefinitionsSource = try resource("metric_definitions.v1", extension: "json")
        // `sliding_window.tracker_frequent` is upstream's own knob for how
        // often the feature tracker re-detects corners; upstream's default is 1,
        // meaning every frame. Detection is 20.3 of the 27.9 ms this engine
        // spends per frame at the production resolution, so the knob is the
        // largest lever there is -- and it is upstream's, not an invention.
        // `-PWTrackerFrequent N` sweeps it. The receipt hashes the config that
        // actually ran, so each point on the curve names its own setting.
        var configData = try Data(contentsOf: configSource)
        // [2026-09-03] `-PWYamlOverride <section>.<key>=<value>` (repeatable) rewrites one
        // existing scalar key of the frozen xrslam YAML, restricted to the
        // `feature_tracker` and `sliding_window` sections. Upstream's own keys only;
        // the receipt's config_sha256 changes with it, so every run declares what it ran.
        if configSource.pathExtension == "yaml",
           var text = String(data: configData, encoding: .utf8) {
            let args = ProcessInfo.processInfo.arguments
            var i = 0
            while i < args.count {
                if args[i] == "-PWYamlOverride", i + 1 < args.count,
                   let eq = args[i + 1].firstIndex(of: "="),
                   let dot = args[i + 1].firstIndex(of: ".") , dot < eq {
                    let section = String(args[i + 1][..<dot])
                    let key = String(args[i + 1][args[i + 1].index(after: dot)..<eq])
                    let value = String(args[i + 1][args[i + 1].index(after: eq)...])
                    // [2026-09-16] `solver` joins the list. Upstream ships two iPhone profiles
                    // whose solver budgets differ by four orders of magnitude --
                    // configs/iphone_slam.yaml is 1.0e6 s / 30 iterations (offline), while
                    // xrslam-ios/visualizer/configs/slam_params.yaml, the one the on-device
                    // app and production both use, is 0.1 s / 10. The bench runs the offline
                    // profile on every channel, so the budget has to be sweepable to price
                    // what that costs.
                    // [2026-09-17] `initializer`, `rotation` and `parsac` join the
                    // list. All three hold knobs where upstream's own two iPhone
                    // profiles, or upstream and the paper's author, disagree:
                    //   - initializer.min_triangulation: 20 in configs/iphone_slam.yaml,
                    //     configs/euroc_slam.yaml and the author's own ADVIO config,
                    //     but 50 from config.cpp when a profile omits it, which is
                    //     what production ends up running.
                    //   - rotation.misalignment_threshold: 0.02 offline against 0.1
                    //     on device; it gates RD-VIO's pure-rotation frame handling.
                    //   - parsac.parsac_flag: false in every shipped config including
                    //     the author's, even though IMU-PARSAC is the paper's headline
                    //     contribution -- so what it costs has never been measured.
                    // Sweeping these needed a rebuild until now. The receipt's
                    // config_sha256 still changes with every override, so a run
                    // cannot hide which values it used.
                    if ["feature_tracker", "sliding_window", "solver",
                        "initializer", "rotation", "parsac"].contains(section) {
                        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
                        var inSection = false; var replaced = false
                        for (n, line) in lines.enumerated() {
                            let trimmed = line.trimmingCharacters(in: .whitespaces)
                            if !line.hasPrefix(" ") && trimmed.hasSuffix(":") { inSection = (trimmed == section + ":") ; continue }
                            if inSection, trimmed.hasPrefix(key + ":") {
                                let indent = String(line.prefix(line.count - line.drop(while: { $0 == " " }).count))
                                lines[n] = "\(indent)\(key): \(value)"; replaced = true; break
                            }
                        }
                        precondition(replaced, "-PWYamlOverride: \(section).\(key) not found in frozen YAML")
                        text = lines.joined(separator: "\n")
                    } else {
                        preconditionFailure("-PWYamlOverride: section \(section) not allowed")
                    }
                    i += 2
                } else { i += 1 }
            }
            configData = Data(text.utf8)
        }
        if configSource.pathExtension == "yaml",
           let index = ProcessInfo.processInfo.arguments
               .firstIndex(of: "-PWTrackerFrequent"),
           index + 1 < ProcessInfo.processInfo.arguments.count,
           let frequent = Int(ProcessInfo.processInfo.arguments[index + 1]),
           frequent >= 1,
           let text = String(data: configData, encoding: .utf8) {
            var lines = text.split(omittingEmptySubsequences: false,
                                   whereSeparator: \.isNewline).map(String.init)
            lines.removeAll { $0.trimmingCharacters(in: .whitespaces)
                .hasPrefix("tracker_frequent:") }
            if let anchor = lines.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("sliding_window:")
            }) {
                lines.insert("  tracker_frequent: \(frequent)", at: anchor + 1)
                configData = Data(lines.joined(separator: "\n").utf8)
            }
        }
        let contractData = try Data(contentsOf: contractSource)
        let metricData = try Data(contentsOf: metricDefinitionsSource)

        let replayDataset: EuRoCReplayDataset?
        let calibrationData: Data
        let inputDefinitionData: Data
        let inputCameraCount: Int
        let imageWidth: Int
        let imageHeight: Int
        let channel: RunReceiptChannel
        let accuracy: RunAccuracyEvidence
        let deviceRecording: DeviceRecordingDataset?

        switch mode {
        case .replayDeviceRecording:
            guard let datasetURL else {
                throw BenchmarkRunPreparationError.replayDatasetRequired
            }
            let recording = try DeviceRecordingLoader().load(
                manifestURL: datasetURL.appendingPathComponent("recording_manifest.json"),
                purpose: BenchResolution.replicationReplayRequested
                    ? .replication
                    : .verdict
            )
            // The calibration comes from the recording's measured intrinsics, not
            // from the frozen 640x480 file, which is why this channel can score
            // at 1920x1440 while a live candidate run cannot.
            // xrslam's calibration is YAML and Basalt's is JSON, so the
            // substitution has to match the file it is editing.
            // The diagnostic replay feeds downscaled frames, so the calibration
            // it runs on has to describe those frames, not the recording's.
            let scale = BenchResolution.diagnosticDownscaleRequested
                ? BenchResolution.diagnosticDownscaleFactor : 1
            let calWidth = recording.camera.width / scale
            let calHeight = recording.camera.height / scale
            let calIntrinsics = scale == 1 ? recording.intrinsics
                : DeviceRecordingIntrinsics(
                    fx: recording.intrinsics.fx / Double(scale),
                    fy: recording.intrinsics.fy / Double(scale),
                    cx: recording.intrinsics.cx / Double(scale),
                    cy: recording.intrinsics.cy / Double(scale),
                    source: recording.intrinsics.source,
                    crossCheckPassed: recording.intrinsics.crossCheckPassed
                )
            // [2026-09-17] `-PWCalibrationFocal <fx>` replaces fx and fy in the
            // materialised calibration. It is a measuring instrument, not a
            // design choice: this recording's own per-frame intrinsics span
            // 426.842 to 476.037 over 120 s (3591 frames, 2951 distinct
            // values, median 457.766), and the value the replay otherwise runs
            // on is `recording.intrinsics` -- the FIRST frame that reported,
            // captured while autofocus was still settling, which lands 4.5%
            // below the median. Pricing that needs fx sweepable on one fixed
            // recording, with nothing else moving. The receipt's
            // calibration_sha256 changes with it, so a run cannot hide the
            // value it used.
            let focalOverride: Double? = {
                let args = ProcessInfo.processInfo.arguments
                guard let i = args.firstIndex(of: "-PWCalibrationFocal"),
                      i + 1 < args.count, let v = Double(args[i + 1]), v > 0
                else { return nil }
                return v
            }()
            let effectiveIntrinsics = focalOverride.map {
                DeviceRecordingIntrinsics(
                    fx: $0, fy: $0,
                    cx: calIntrinsics.cx, cy: calIntrinsics.cy,
                    source: calIntrinsics.source + "+pw_focal_override",
                    crossCheckPassed: calIntrinsics.crossCheckPassed
                )
            } ?? calIntrinsics
            let frozenCalibration = try Data(contentsOf: calibrationSource)
            calibrationData = calibrationSource.pathExtension == "yaml"
                ? try CalibrationMaterializer.deviceRecordingYAML(
                    from: frozenCalibration,
                    intrinsics: effectiveIntrinsics,
                    width: calWidth,
                    height: calHeight
                )
                : try CalibrationMaterializer.deviceRecording(
                from: frozenCalibration,
                intrinsics: effectiveIntrinsics,
                width: calWidth,
                height: calHeight
            )
            var recordingDefinition: [String: Any] = [
                "camera": "mono_\(recording.camera.width)x\(recording.camera.height)_from_device_recording",
                "engine": backend.id,
                "imu": IMUDeliveryMode.forBackend(backend).rawValue,
                "config_sha256": RunReceiptHash.sha256Hex(configData),
                "calibration_sha256": RunReceiptHash.sha256Hex(calibrationData),
                "device_model": LiveCalibrationGate.frozenModelIdentifier,
                "uses_arkit": false,
                "recording_id": recording.recordingID,
                "intrinsics_source": recording.intrinsics.source,
                "scoring_resolution": [
                    BenchResolution.scoring.width, BenchResolution.scoring.height,
                ],
                "configured_resolution": [recording.camera.width, recording.camera.height],
                "participates_in_verdict": BenchResolution.participatesInVerdict(
                    width: recording.camera.width,
                    height: recording.camera.height
                ),
            ]
            recordingDefinition["arkit_reference_pose_count"] = recording.arkitReference.count
            inputDefinitionData = try JSONSerialization.data(
                withJSONObject: recordingDefinition,
                options: [.prettyPrinted, .sortedKeys]
            )
            inputCameraCount = recording.inputCameraCount
            // The engine is created for the frames it will actually receive,
            // which the diagnostic replay downscales.
            imageWidth = calWidth
            imageHeight = calHeight
            replayDataset = nil
            deviceRecording = recording
            channel = .replayDeviceRecording
            // Identical input makes the arms mutually comparable; it is not
            // ground truth, so this channel may never state absolute accuracy.
            accuracy = RunAccuracyEvidence(status: .notEvaluable, groundTruth: .none)

        case .record, .recordNative, .liveSoak:
            // Declare what the capture is actually configured to deliver, never
            // the resolution the contract aspires to. Writing the scoring
            // constant here produced a receipt claiming 1920x1440 while
            // SensorTransportConfiguration still opened the camera at 640x480 --
            // a receipt that disagrees with its own diagnostics is worse than no
            // receipt, because it is the artifact every later verdict cites.
            let configured = SensorTransportConfiguration.live
            let frozenLiveCalibration = try Data(contentsOf: calibrationSource)
            // [2026-09-03] ARKit owns its calibration; arkit_runtime_calibration.json is a
            // descriptor (calibration_owner / intrinsics_source / pose_frame / status), not
            // a Basalt-layout file. Rewriting it here threw invalidRoot before the started
            // receipt, which is why the ARKit live-soak arm never ran.
            if BenchResolution.liveFullResolutionRequested, backend != .arkit {
                // The frozen calibration describes 640x480. Both arms need one
                // that describes the frames they will actually receive, and the
                // two formats were shown to share a field of view (see
                // BenchResolution.liveFullResolutionRequested), so the frozen
                // values are scaled by the exact resolution ratio rather than
                // invented. The run also receipts the intrinsics the camera
                // itself reports, so this scaling is checked, not assumed.
                // The camera reports the intrinsics it measured for the format
                // it selected, so there is no need to scale the frozen 640x480
                // values and hope the fields of view match. Measured on device
                // for this format: fx = fy = 1306.991, cx = 958.158,
                // cy = 718.993. The principal point agrees with both the frozen
                // 640x480 calibration scaled threefold and with the ARKit
                // intrinsics in the device recording to within a pixel, but the
                // focal length does not -- 1306.99 against 1347.79 -- so the
                // two formats are not a pure scale of each other and the scaled
                // values would have been wrong by 3%.
                let scaled = DeviceRecordingIntrinsics(
                    fx: 1306.991, fy: 1306.991, cx: 958.158, cy: 718.993,
                    source: "avcapture_reported_intrinsics_1920x1440",
                    crossCheckPassed: true
                )
                calibrationData = calibrationSource.pathExtension == "yaml"
                    ? try CalibrationMaterializer.deviceRecordingYAML(
                        from: frozenLiveCalibration, intrinsics: scaled,
                        width: BenchResolution.scoring.width,
                        height: BenchResolution.scoring.height)
                    : try CalibrationMaterializer.deviceRecording(
                        from: frozenLiveCalibration, intrinsics: scaled,
                        width: BenchResolution.scoring.width,
                        height: BenchResolution.scoring.height)
            } else {
                calibrationData = frozenLiveCalibration
            }
            var definition: [String: Any] = [
                // Every arm scores at the production resolution. The candidates
                // reach it by replaying the luma plane of the same
                // ARFrame.capturedImage stream the ARKit arm produced.
                "camera": backend == .arkit
                    ? "arkit_production_runtime_selected_format_1920x1440"
                    : "mono_1920x1440_30hz_from_device_recording",
                "engine": backend.id,
                "imu": backend == .arkit
                    ? "arkit_internal_sensor_fusion_no_raw_sensor_export"
                    : IMUDeliveryMode.forBackend(backend).rawValue,
                "config_sha256": RunReceiptHash.sha256Hex(configData),
                "calibration_sha256": RunReceiptHash.sha256Hex(calibrationData),
                "device_model": LiveCalibrationGate.frozenModelIdentifier,
                "uses_arkit": backend.usesARKit,
            ]
            if backend == .basalt {
                let provenance = try resource(
                    "iphone_14_pro_640x480_calib.provenance",
                    extension: "json"
                )
                definition["calibration_provenance_sha256"] = RunReceiptHash.sha256Hex(
                    try Data(contentsOf: provenance)
                )
            } else if backend == .xrslam {
                definition["visual_localization_enabled"] = false
                definition["camera_imu_time_offset_status"] = "upstream_nominal_unverified"
            } else {
                definition["reference_scope"] = "live_performance_tracking_and_world_stability_only"
                definition["external_ground_truth"] = "none"
            }
            inputDefinitionData = try JSONSerialization.data(withJSONObject: definition, options: [.prettyPrinted, .sortedKeys])
            definition["scoring_resolution"] = [
                BenchResolution.scoring.width, BenchResolution.scoring.height,
            ]
            definition["configured_resolution"] = [
                Int(configured.cameraWidth), Int(configured.cameraHeight),
            ]
            definition["participates_in_verdict"] =
                BenchResolution.participatesInVerdict(
                    width: Int(configured.cameraWidth),
                    height: Int(configured.cameraHeight)
                )
            inputCameraCount = 1
            imageWidth = Int(configured.cameraWidth)
            imageHeight = Int(configured.cameraHeight)
            replayDataset = nil
            deviceRecording = nil
            channel = mode == .record ? .record : .liveSoak
            // No external ground truth on this device, in any of these modes.
            accuracy = RunAccuracyEvidence(status: .notEvaluable, groundTruth: .none)
        case .replayPaced, .replayMax:
            guard let datasetURL else { throw BenchmarkRunPreparationError.replayDatasetRequired }
            let manifestURL = datasetURL.appendingPathComponent("input_manifest.json")
            let dataset = try EuRoCReplayLoader().load(manifestURL: manifestURL)
            try ReplayContractGate.validate(
                datasetName: dataset.datasetName,
                inputCameraCount: dataset.inputCameraCount
            )
            guard dataset.inputCameraCount == 1 else {
                throw BenchmarkRunPreparationError.replayMustBeMono(dataset.inputCameraCount)
            }
            if backend == .basalt {
                calibrationData = try CalibrationMaterializer.eurocCam0Only(
                    from: Data(contentsOf: calibrationSource)
                )
            } else {
                calibrationData = try Data(contentsOf: calibrationSource)
            }
            inputDefinitionData = try Data(contentsOf: manifestURL)
            inputCameraCount = dataset.inputCameraCount
            imageWidth = 752
            imageHeight = 480
            replayDataset = dataset
            deviceRecording = nil
            channel = mode == .replayPaced ? .replayPaced : .replayMax
            accuracy = RunAccuracyEvidence(status: .evaluable, groundTruth: .euroc)
        }

        let configURL = directory.appendingPathComponent("config.json")
        let calibrationURL = directory.appendingPathComponent("calibration.json")
        let inputDefinitionURL = directory.appendingPathComponent("input_manifest.json")
        try configData.write(to: configURL, options: .atomic)
        try calibrationData.write(to: calibrationURL, options: .atomic)
        try inputDefinitionData.write(to: inputDefinitionURL, options: .atomic)

        switch mode {
        case .record, .recordNative, .liveSoak:
            try Data().write(to: directory.appendingPathComponent("telemetry.jsonl"), options: .atomic)
        case .replayDeviceRecording, .replayPaced, .replayMax:
            try Data().write(to: directory.appendingPathComponent("poses.tum"), options: .atomic)
        }

        guard let executableURL = Bundle.main.executableURL else {
            throw BenchmarkRunPreparationError.executableUnavailable
        }
        let binaryData = try Data(contentsOf: executableURL)
        let engineArtifactData = try selectedEngineArtifactData(backend: backend)
        let combinedConfigIdentity = configData + calibrationData
        let receipt = RunReceipt(
            runID: runID,
            state: .started,
            channel: channel,
            inputCameraCount: inputCameraCount,
            startedAtUTC: utcTimestamp(),
            app: RunAppIdentity(
                bundleID: Bundle.main.bundleIdentifier ?? "",
                usesARKit: backend.usesARKit,
                backend: backend == .arkit ? "apple_arkit"
                    : (ProcessInfo.processInfo.arguments.contains("-PWXrslamGpuFrontend") ? "gpu_frontend" : "cpu"),
                algorithmMode: backend.algorithmMode,
                engineID: backend.id,
                upstreamRevision: backend.upstreamRevision,
                openCVVersion: backend.openCVVersion
            ),
            device: .current(),
            identities: RunSHA256Identities(
                contractSHA256: RunReceiptHash.sha256Hex(contractData),
                appBinarySHA256: RunReceiptHash.sha256Hex(binaryData),
                engineArtifactSHA256: RunReceiptHash.sha256Hex(engineArtifactData),
                configSHA256: RunReceiptHash.sha256Hex(combinedConfigIdentity),
                inputDefinitionSHA256: RunReceiptHash.sha256Hex(inputDefinitionData),
                metricDefinitionsSHA256: RunReceiptHash.sha256Hex(metricData)
            ),
            power: RunPowerEvidence(),
            accuracy: accuracy
        )
        try receipt.validate()
        let writer = RunReceiptWriter(
            directoryURL: directory,
            callbackQueue: DispatchQueue(label: "\(backend.bundleID).receipt-callback.\(runID)")
        )
        let startedReceiptData = try RunReceiptJSON.encoder.encode(receipt)
        return PreparedBenchmarkRun(
            backend: backend,
            runID: runID,
            directoryURL: directory,
            configURL: configURL,
            calibrationURL: calibrationURL,
            inputCameraCount: inputCameraCount,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            replayDataset: replayDataset,
            deviceRecording: deviceRecording,
            startedReceipt: receipt,
            startedReceiptSHA256: RunReceiptHash.sha256Hex(startedReceiptData),
            receiptWriter: writer
        )
    }

    static func utcTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private static func resource(_ name: String, extension fileExtension: String) throws -> URL {
        if let url = Bundle.main.url(forResource: name, withExtension: fileExtension) {
            return url
        }
        throw BenchmarkRunPreparationError.missingResource("\(name).\(fileExtension)")
    }

    private static func resourceFile(_ filename: String) throws -> URL {
        let value = filename as NSString
        return try resource(value.deletingPathExtension, extension: value.pathExtension)
    }

    private static func selectedEngineArtifactData(
        backend: BenchBackend
    ) throws -> Data {
        if backend == .arkit {
            return Data(
                "system_framework=ARKit|os=\(ProcessInfo.processInfo.operatingSystemVersionString)|sdk_identity=\(backend.upstreamRevision)"
                    .utf8
            )
        }
        let executableName = backend == .basalt ? "PWBasaltEngine" : "PWXRSLAMEngine"
        guard let frameworks = Bundle.main.privateFrameworksURL else {
            throw BenchmarkRunPreparationError.engineArtifactUnavailable(executableName)
        }
        let executable = frameworks
            .appendingPathComponent("\(executableName).framework", isDirectory: true)
            .appendingPathComponent(executableName)
        guard FileManager.default.fileExists(atPath: executable.path) else {
            throw BenchmarkRunPreparationError.engineArtifactUnavailable(executableName)
        }
        return try Data(contentsOf: executable)
    }
}
