import AVFoundation
import CoreGraphics
import Foundation
import UIKit

@MainActor
final class BenchViewModel: ObservableObject {
    @Published var selectedBackend: BenchBackend = .basalt
    /// Selecting `record` moves the engine to ARKit rather than leaving an
    /// unstartable pairing on screen.
    ///
    /// On 2026-08-30 a full 300 s capture was made with Basalt live-soak
    /// selected instead, producing no recording at all. `record` requires the
    /// ARKit arm because iOS grants the rear camera to one session and the
    /// recording is of the frames ARKit is tracking on -- so there is exactly
    /// one valid engine for it, and asking the operator to also pick it is a
    /// trap, not a choice.
    @Published var mode: BenchMode = .liveSoak {
        didSet {
            if mode == .record { selectedBackend = .arkit }
            if mode.hasExternalGroundTruth || mode == .replayDeviceRecording,
               selectedBackend == .arkit {
                selectedBackend = .basalt
            }
        }
    }

    /// One line stating exactly what pressing Start will do, so a mis-selection
    /// is visible before five minutes are spent on it.
    /// Shows the projection before Start, so a refusal is never the first time
    /// the operator learns how much space the chosen duration needs.
    var storageNote: String? {
        guard mode == .record else { return nil }
        var format = DeviceRecordingCameraFormat.scoring
        format.nominalFPS = BenchResolution.scoringFramesPerSecond
        // Matches the coordinator's preflight, depth included, so the number on
        // screen is the number the refusal will use.
        let need = DeviceRecordingWriter.projectedByteCount(
            seconds: Double(measurementSeconds), format: format, includingDepth: true
        ) + DeviceRecordingWriter.freeSpaceHeadroomBytes
        let values = try? URL.documentsDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        let have = Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
        let g = 1_073_741_824.0
        let line = String(
            format: "需要 %.1f GiB · 可用 %.1f GiB", Double(need) / g, Double(have) / g
        )
        return have >= need ? line : "⚠ " + line
    }

    var plannedRunSummary: String {
        switch mode {
        case .record:
            return "将录制一次:ARKit 实时跑 + 存下它看到的帧,\(measurementSeconds) 秒后自动停止"
        case .recordNative:
            return "将录制一次:自建相机 640×480 官方档(32BGRA→OpenCV 灰度),"
                + "\(selectedBackend.displayName) 同时实时跑,\(measurementSeconds) 秒后自动停止。"
                + "⚠ 不计分:640×480 不是判决分辨率"
        case .liveSoak:
            return "将用 \(selectedBackend.displayName) 实时采集,\(measurementSeconds) 秒或手动中止"
        case .replayDeviceRecording:
            return "将把本机录制回放给 \(selectedBackend.displayName)"
        case .replayPaced, .replayMax:
            return "将把 EuRoC 回放给 \(selectedBackend.displayName)"
        }
    }
    @Published private(set) var phase: BenchPhase = .idle
    @Published private(set) var snapshot = LiveSnapshot()
    @Published private(set) var blockingMessage: String?
    @Published private(set) var lastReceiptURL: URL?
    @Published var isImportingDataset = false

    /// Drives both the run length and the space projection. It used to always be
    /// 300 s, so a 30 s capture was refused for lacking 48.3 GiB it would never
    /// have used.
    @Published var measurementSeconds: Int = 300 {
        didSet {
            LiveBenchmarkDuration.measurementNanoseconds =
                UInt64(measurementSeconds) * 1_000_000_000
        }
    }

    /// Display-only. Publishing a preview source never starts or stops capture.
    @Published private(set) var previewSource: BenchPreviewSource = .none
    @Published private(set) var previewFrame: CGImage?

    @Published private(set) var recordings: [URL] = []
    private(set) var datasetURL: URL?
    private var coordinator: BenchmarkCoordinator?

    init() {
        Task.detached(priority: .utility) {
            _ = try? InterruptedRunRecovery.recoverAll()
        }
    }

    /// Mirrors the coordinator's guard so the UI cannot offer a run that will
    /// be refused. The coordinator stays authoritative.
    var modeBackendConflict: String? {
        mode == .record && selectedBackend != .arkit
            ? "录制模式由 ARKit 臂持有相机,请把引擎切到 ARKit"
            : nil
    }

    var isRunning: Bool {
        [.preparing, .warmup, .measuring, .draining].contains(phase)
    }

    var datasetLabel: String? { datasetURL?.lastPathComponent }

    var canStart: Bool {
        guard !isRunning, modeBackendConflict == nil else { return false }
        switch mode {
        case .record:
            // ARKit owns the camera and the recording is of its frames.
            return selectedBackend == .arkit
        case .recordNative:
            // The bench's own AVCaptureSession owns the camera, so ARKit cannot
            // be the arm -- the two cannot hold the rear camera at once.
            return selectedBackend != .arkit
        case .liveSoak:
            return true
        case .replayDeviceRecording, .replayPaced, .replayMax:
            // ARKit cannot be fed a recording, and a replay needs one.
            return selectedBackend != .arkit && datasetURL != nil
        }
    }

    func requestDatasetImport() { isImportingDataset = true }

    /// Device recordings live inside this app's own container, so the app lists
    /// them itself. Relying on the Files app would need UIFileSharingEnabled,
    /// which Xcode's generated Info.plist silently drops -- a recording could be
    /// captured and then never be selectable for replay.
    func refreshRecordings() {
        let root = URL.documentsDirectory.appendingPathComponent("VIOBenchRuns")
        let found = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        recordings = found
            .filter {
                FileManager.default.fileExists(
                    atPath: $0.appendingPathComponent("recording_manifest.json").path
                )
            }
            .sorted {
                let l = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let r = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return l > r
            }
        // `-PWDatasetPath <dir>` points a headless run at a dataset directly,
        // which is how xrslam's own EuRoC data gets through the same wrapper as
        // a device recording -- the discriminator for whether a failure belongs
        // to the integration or to what the bench feeds it.
        if let flag = ProcessInfo.processInfo.arguments.firstIndex(of: "-PWDatasetPath"),
           flag + 1 < ProcessInfo.processInfo.arguments.count {
            let given = ProcessInfo.processInfo.arguments[flag + 1]
            datasetURL = given.hasPrefix("/")
                ? URL(fileURLWithPath: given)
                : URL.documentsDirectory.appendingPathComponent(given)
            return
        }
        if datasetURL == nil { datasetURL = recordings.first }
    }

    func selectRecording(_ url: URL) { datasetURL = url }

    func acceptDatasetImport(_ result: Result<[URL], Error>) {
        do {
            datasetURL = try result.get().first
            blockingMessage = nil
            objectWillChange.send()
        } catch {
            blockingMessage = "数据集选择失败：\(error.localizedDescription)"
        }
    }

    func start() {
        guard canStart else { return }
        if !mode.isReplay,
           let reason = LiveCalibrationGate.rejectionReason(for: .current()) {
            blockingMessage = reason
            phase = .failed
            return
        }
        if !mode.isReplay {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                break
            case .notDetermined:
                blockingMessage = nil
                phase = .preparing
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    Task { @MainActor in
                        guard let self else { return }
                        if granted {
                            self.startAuthorizedRun()
                        } else {
                            self.blockingMessage = "相机权限被拒绝，实时 \(self.selectedBackend.displayName) bench 无法运行。"
                            self.phase = .failed
                        }
                    }
                }
                return
            default:
                blockingMessage = "相机权限不可用，实时 \(selectedBackend.displayName) bench 无法运行。"
                phase = .failed
                return
            }
        }
        startAuthorizedRun()
    }

    private func startAuthorizedRun() {
        blockingMessage = nil
        lastReceiptURL = nil
        snapshot = LiveSnapshot()
        phase = .preparing
        UIApplication.shared.isIdleTimerDisabled = true

        let coordinator = BenchmarkCoordinator(
            backend: selectedBackend,
            mode: mode,
            datasetURL: datasetURL,
            onPhase: { [weak self] phase in Task { @MainActor in self?.phase = phase } },
            onSnapshot: { [weak self] value in Task { @MainActor in self?.snapshot = value } },
            onPreview: { [weak self] source in
                Task { @MainActor in
                    self?.previewSource = source
                    if case .none = source { self?.previewFrame = nil }
                }
            },
            onPreviewFrame: { [weak self] image in
                Task { @MainActor in self?.previewFrame = image }
            },
            onFinish: { [weak self] result in
                Task { @MainActor in
                    UIApplication.shared.isIdleTimerDisabled = false
                    switch result {
                    case .success(let url):
                        self?.lastReceiptURL = url
                        self?.phase = .completed
                    case .failure(let error):
                        self?.blockingMessage = error.localizedDescription
                        self?.phase = .failed
                    }
                    self?.coordinator = nil
                }
            }
        )
        self.coordinator = coordinator
        coordinator.start()
    }

    func abort() {
        coordinator?.abort()
    }
}
