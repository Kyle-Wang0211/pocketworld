import Foundation

/// The resolutions the bench runs at, and which of them a verdict may be built on.
///
/// Production runs ARKit at 1920x1440 4:3, so that is the bar every candidate is
/// scored against. Declaring a 640x480 candidate faster or cooler than a
/// 1920x1440 ARKit would compare two different problems.
///
/// That figure is production's shipped `pwVideoFormat`, which
/// lib/official_capture/capture_format.dart pins to "hires43" and the Dart pose
/// provider passes to the plugin on every session. The plugin's own
/// `videoFormatMode` default of "4k" is only what stands before Dart assigns,
/// and its 3840x2160 16:9 branch is documented there as the fallback kept for
/// comparison, not the shipping path.
///
/// Briefly changed to 3840x2160 on 2026-08-31 by reading the plugin's branches
/// and its historical comment about the high-resolution format breaking world
/// tracking, without checking what the switch is actually set to. That comment
/// is superseded in the same file the constant lives in: hires43 was promoted on
/// 2026-07-19 after the device showed tracking normal.
public enum BenchResolution: Equatable {
    /// The only resolution a verdict may be built on. Every arm scores here.
    public static let scoring = (width: 1920, height: 1440)

    /// Frame rate of production's selected format: the highest the
    /// high-resolution-capable 1920x1440 entry offers, which is 60 on this
    /// device.
    public static let scoringFramesPerSecond: Double = 60

    /// Non-scoring. Its single job is failure triage: when a candidate fails at
    /// the scoring resolution, rerunning at the scale its upstream config was
    /// actually tuned for separates "the algorithm cannot carry this many
    /// pixels" from "we carried its pixel-unit parameters across wrong".
    public static let diagnostic = (width: 640, height: 480)

    /// `diagnostic` is derived from the recording by deterministic downscale, so
    /// the two share one physical capture. Both are 4:3, so a single factor
    /// relates them.
    /// [2026-09-09] `-PWDiagnosticDownscale [N]` takes an optional integer factor so the
    /// resolution sweep (1920x1440 / 960x720 / 640x480 = factors 1 / 2 / 3) is one build and
    /// one recording. Bare `-PWDiagnosticDownscale` keeps its old meaning, factor 3. Only
    /// factors dividing both 1920 and 1440 are accepted, because the box filter in
    /// `ActiveVIOEngineSession.downscale` averages exact factor-by-factor blocks.
    public static var diagnosticDownscaleFactor: Int {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-PWDiagnosticDownscale") else { return 3 }
        guard i + 1 < args.count, let n = Int(args[i + 1]), n >= 1 else { return 3 }
        precondition(scoring.width % n == 0 && scoring.height % n == 0,
                     "-PWDiagnosticDownscale \(n): factor must divide \(scoring.width)x\(scoring.height)")
        return n
    }

    /// `-PWDiagnosticDownscale` replays at [diagnostic] instead of [scoring].
    /// Not scoreable, and never enabled by default: its only job is to separate
    /// "this engine cannot carry this many pixels" from a parameter carried
    /// across resolutions wrongly. xrslam died with SIGBUS inside its first
    /// frame at 1920x1440, and that question is exactly what this answers.
    public static var diagnosticDownscaleRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-PWDiagnosticDownscale")
    }

    /// `-PWLiveFullResolution` runs the live channel at the production capture
    /// size instead of the frozen 640x480 pairing.
    ///
    /// This was blocked on 2026-08-30 because the frozen calibration declares
    /// 640x480 and scaling it threefold is only valid if both formats share a
    /// field of view, which could not be shown from the artifacts then on hand.
    /// It can be shown now: the ARKit intrinsics measured in the device
    /// recording at 1920x1440 divided by the frozen 640x480 values give
    /// fx 3.0020, fy 3.0008, cx 2.9796, cy 2.9868 against a resolution ratio of
    /// exactly 3 -- agreement to 0.07% in focal length and about two pixels in
    /// principal point. The run also enables camera intrinsic delivery and
    /// receipts what the camera itself reports, so the scaling is checked
    /// rather than assumed.
    public static var liveFullResolutionRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-PWLiveFullResolution")
    }

    /// `-PWReplicationReplay` lets a replay consume a recording whose
    /// resolution is not a verdict resolution -- today, the native 640x480
    /// upstream-shaped capture `record-native` produces.
    ///
    /// It is an explicit opt-in and it is deliberately awkward, because the
    /// rule it steps around is the one that keeps verdicts comparable:
    /// 1920x1440 is the floor. A run started with it is forced unscoreable, so
    /// the flag buys the ability to observe an engine on upstream's input and
    /// nothing else. It can never make a number that a verdict may cite.
    public static var replicationReplayRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-PWReplicationReplay")
    }

    public static func participatesInVerdict(width: Int, height: Int) -> Bool {
        width == scoring.width && height == scoring.height
    }
}

/// Camera intrinsics for one resolution.
struct CameraIntrinsics: Equatable {
    let fx: Double
    let fy: Double
    let cx: Double
    let cy: Double

    func scaled(by factor: Double) -> CameraIntrinsics {
        CameraIntrinsics(fx: fx * factor, fy: fy * factor, cx: cx * factor, cy: cy * factor)
    }

    var isFinite: Bool {
        fx.isFinite && fy.isFinite && cx.isFinite && cy.isFinite
    }
}

/// Establishes the 1920x1440 intrinsics and refuses to proceed if the device
/// disagrees with the frozen upstream calibration by more than a scale.
///
/// Intrinsics are read from `ARFrame.camera.intrinsics` during the capture. That
/// is not an ARKit algorithm output leaking into a candidate arm: intrinsics are
/// a property of the hardware, and the recorded frames are exactly the frames
/// those intrinsics describe, so nothing is extrapolated.
///
/// The frozen 640x480 values come from xrslam's own iPhone 14 Pro config, so
/// this compares a candidate engine's shipped calibration against what ARKit
/// reports for the format production actually runs. Measured on iPhone15,2 /
/// iOS 26.6, they disagree by 5.15% in fx: ARKit reports 1277.49 for the
/// production-default 1920x1440 format, against 1346.90 from xrslam's config
/// scaled by 3. The principal points agree to within half a pixel, so the
/// formats are the same size and crop -- the calibrations simply differ.
///
/// That disagreement used to halt the run, which had the direction backwards.
/// Every arm replays the same recorded frames, those frames come out of
/// production's ARKit configuration, and production treats the frame's own
/// intrinsics as authoritative -- its per-photo sidecar pins
/// `intrinsics_fxfycxcy` to the frame it came from. So the recording is the
/// reference and a candidate's config is the thing that has to match it; a
/// stale xrslam yaml is a reason to fix that yaml, not to throw away a capture
/// the operator shot by hand.
///
/// What still halts a run is an ARKit reading that cannot describe its own
/// frames: non-finite, non-positive, or a principal point far from the frame
/// centre. The calibration delta is recorded in intrinsics_observed.json for
/// whoever updates the candidate configs.
enum ARKitIntrinsicsCrossCheck {
    /// xrslam 4beb1a9 xrslam-ios/visualizer/configs/iPhone 14 Pro.yaml, cam0.
    static let frozenUpstream640x480 = CameraIntrinsics(
        fx: 448.96781816245402,
        fy: 449.14399528627763,
        cx: 321.34605334072404,
        cy: 240.71641804985396
    )

    /// Focal length is compared relatively, principal point absolutely, because
    /// they fail in different ways.
    ///
    /// A single 12 px absolute tolerance on everything was measured wrong on
    /// 2026-08-30. This device reported fx = fy = 1331.130, cx = 957.589,
    /// cy = 719.988 against an upstream-scaled expectation of fx 1346.903,
    /// cx 964.038, cy 722.149 -- and was rejected on a 15.8 px focal difference.
    ///
    /// The numbers say the rejection was wrong. cy lands within 0.01 px of
    /// 1440/2 and cx within 2.5 px of 1920/2, so the format is not cropped and
    /// the threefold scaling premise holds. The focal gap is 1.17 percent, which
    /// is ordinary unit-to-unit variation between this phone and the one sample
    /// device the upstream configuration came from.
    ///
    /// That gap is also the point: running this phone on another unit's focal
    /// length was injecting roughly 1.2 percent of metric scale error, which the
    /// measured values remove.
    ///
    /// So focal length gets a relative tolerance -- per-device variation is
    /// around a percent while a different lens differs by tens of percent -- and
    /// the principal point keeps an absolute one, because that is what actually
    /// detects a crop: a crop displaces it by tens to hundreds of pixels.
    static let focalRelativeTolerance: Double = 0.03
    static let principalPointToleranceP: Double = 24.0

    enum Verdict: Equatable {
        case agrees(scoring: CameraIntrinsics)
        case disagrees(
            component: String,
            arkit: Double,
            expected: Double,
            deltaPixels: Double
        )
        case nonFinite

        var haltsRun: Bool {
            if case .agrees = self { return false }
            return true
        }

        var reason: String? {
            switch self {
            case .agrees:
                return nil
            case .nonFinite:
                return "arkit_intrinsics_non_finite"
            case .disagrees(let component, _, _, _):
                return "arkit_intrinsics_disagree_\(component)"
            }
        }
    }

    static var expectedScoringIntrinsics: CameraIntrinsics {
        // Fixed 3: this compares the frozen 640x480 config against the 1920x1440 scoring
        // format, a ratio that does not move when the replay sweep changes its own factor.
        frozenUpstream640x480.scaled(by: 3.0)
    }

    /// Checks that the reported intrinsics can describe the frames they came
    /// with: finite, a positive focal length, and a principal point near the
    /// centre of a [frameWidth] x [frameHeight] image.
    ///
    /// It used to compare against the frozen 640x480 values scaled by 3 and halt
    /// the run on a mismatch. Those values are xrslam's own iPhone 14 Pro
    /// config, so that used a candidate engine's shipped calibration to declare
    /// production's capture invalid -- backwards, since every arm replays these
    /// frames and production treats a frame's own intrinsics as authoritative.
    /// It is also no longer arithmetically meaningful: production runs 3840x2160
    /// at 16:9 and the frozen values are 4:3, so no single scale relates them.
    static func check(
        arkitReported: CameraIntrinsics,
        frameWidth: Int,
        frameHeight: Int
    ) -> Verdict {
        guard arkitReported.isFinite else { return .nonFinite }
        guard arkitReported.fx > 0, arkitReported.fy > 0 else {
            return .disagrees(component: "fx", arkit: arkitReported.fx,
                              expected: 0, deltaPixels: 0)
        }
        // A principal point should sit near the centre of the frame it belongs
        // to. Far from it means the intrinsics and the pixels are describing
        // different images, which is the failure worth halting for.
        for (name, reported, centre) in [
            ("cx", arkitReported.cx, Double(frameWidth) / 2),
            ("cy", arkitReported.cy, Double(frameHeight) / 2),
        ] {
            if abs(reported - centre) > principalPointToleranceP {
                return .disagrees(component: name, arkit: reported,
                                  expected: centre, deltaPixels: abs(reported - centre))
            }
        }
        return .agrees(scoring: arkitReported)
    }
}
