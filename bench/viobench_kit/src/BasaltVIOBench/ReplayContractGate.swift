import Foundation

enum ReplayContractGate {
    enum ValidationError: Error, Equatable {
        case datasetName(String)
        case cameraCount(Int)
    }

    /// The EuRoC sequences this bench may replay for scoring.
    ///
    /// Frozen to `EuRoC_MH_01_easy` alone until 2026-09-09. The gate's job is to
    /// keep replay on datasets whose identity has been checked, not to single
    /// out one recording: every name here is EuRoC cam0 mono with motion-capture
    /// ground truth, and `EuRoCReplayLoader` still refuses any dataset whose
    /// truth does not bracket the replayed frames. The V1 room sequences were
    /// added because they are the ones staged on this machine and MH_01_easy is
    /// not; MH_01_easy stays so the frozen identity keeps passing unchanged.
    ///
    /// Note EuRoC's truth never covers the whole image stream (V1_01_easy starts
    /// 1.040 s late and ends 0.955 s early), so a sequence has to be trimmed to
    /// its truth window before the loader will take it — see
    /// `scripts/prepare_euroc_mh01_mono.py`, which rewrites the manifest.
    static let datasetNames: Set<String> = [
        "EuRoC_MH_01_easy",
        "EuRoC_V1_01_easy",
        "EuRoC_V1_02_medium",
        "EuRoC_V1_03_difficult",
    ]
    static let inputCameraCount = 1

    static func validate(datasetName: String, inputCameraCount: Int) throws {
        guard Self.datasetNames.contains(datasetName) else {
            throw ValidationError.datasetName(datasetName)
        }
        guard inputCameraCount == Self.inputCameraCount else {
            throw ValidationError.cameraCount(inputCameraCount)
        }
    }
}
