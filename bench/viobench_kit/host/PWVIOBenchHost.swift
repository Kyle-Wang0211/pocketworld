// PWVIOBenchHost.swift — bench-only glue that lets arloopbench show the old
// "VIO Replacement Bench" (com.kyle.viobench) harness inside its own process.
//
// Everything under ../src is the old harness copied verbatim from the research repo
// (pocketworld-research-benchmarks research/basalt-vio-phone-bench-20260829 @ fbe3056,
// tools/ios_basalt_vio_bench/{BasaltVIOBench,Replay,Evaluation,Schemas,XRSLAMBackend/Config,
// XRSLAMBackend/Native/XRSLAMBench.h} + experiments/basalt_vio_phone_bench_2026-08-29/contract.json).
// This file replaces only the app shell that cannot live in a framework:
//
//   D1  `@main struct BasaltVIOBenchApp` (src/BasaltVIOBench/BasaltVIOBenchApp.swift, kept in the tree
//       but not compiled). Its body is reproduced below: one BenchViewModel for the process, and the
//       same onAppear sequence (purgeRunsIfRequested → writePreflight → -PWAutoRun parse → start after
//       1.5 s). It runs once per process, as the WindowGroup's onAppear did.
//   D2  Resources (contract.json, Config/*.json, XRSLAMBackend/Config/*.yaml, Schemas/*.json) are in this
//       framework's bundle, not Bundle.main. The two lookup sites in src/ were changed to ask
//       `PWVIOBenchResources.bundle` first and Bundle.main second (BenchExperimentIdentity.swift,
//       BenchmarkRunPreparation.swift `resource(_:extension:)`); nothing else in src/ is changed.
//   D3  Engines are the prebuilt generic frameworks the old app embedded
//       (~/Developer/viobench-build/bench-dd-generic, 2026-09-20; sha256 in ../engines/SHA256SUMS.txt).
//       The GPU-front-end engine variant is not embedded: it links its own Dawn (23 Objective-C
//       classes) and arloopbench already has one Dawn; two copies of the same Objective-C classes
//       in one process is undefined behaviour.
//   D4  A bottom bar with 「返回台架菜单」 dismisses the harness. It is disabled while a run is active, so
//       a run cannot be orphaned behind the Flutter UI.
//
// Records still go to Documents/VIOBenchRuns/run-<uuid>/ (same writer, same format), now in the
// com.kyle.arloopbench container.
import SwiftUI
import UIKit

/// Resource bundle for the copied harness (D2).
enum PWVIOBenchResources {
    static let bundle = Bundle(for: PWVIOBenchHost.self)
}

@MainActor
@objc(PWVIOBenchHost)
public final class PWVIOBenchHost: NSObject {
    /// One view model per process, as the old app's `@StateObject` in its App struct.
    private static let model = BenchViewModel()
    private static var launchSequenceDone = false

    /// Called by arloopbench (PwBenchUnifiedPlugin) through the Objective-C runtime after it has
    /// loaded this framework with Bundle.load(); arloopbench does not link this framework.
    @objc public static func makeViewController() -> UIViewController {
        let holder = DismissHolder()
        let root = PWVIOBenchRoot(model: model, dismiss: { holder.controller?.dismiss(animated: true) })
        let vc = UIHostingController(rootView: root)
        holder.controller = vc
        vc.modalPresentationStyle = .fullScreen
        return vc
    }

    /// D1: the old App struct's onAppear body, once per process.
    static func runLaunchSequenceOnce() {
        if launchSequenceDone { return }
        launchSequenceDone = true
        BenchSelfTest.purgeRunsIfRequested()
        BenchSelfTest.writePreflight()
        guard let auto = BenchSelfTest.parse() else { return }
        LiveBenchmarkDuration.measurementNanoseconds =
            UInt64(auto.seconds * 1_000_000_000)
        model.selectedBackend = auto.backend
        model.mode = auto.mode
        // A beat for the camera permission prompt and the first
        // layout pass; the run itself stops on its own duration.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            model.start()
        }
    }
}

private final class DismissHolder {
    weak var controller: UIViewController?
}

struct PWVIOBenchRoot: View {
    @ObservedObject var model: BenchViewModel
    let dismiss: () -> Void

    var body: some View {
        ContentView()
            .environmentObject(model)
            .onAppear { PWVIOBenchHost.runLaunchSequenceOnce() }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Text(model.isRunning ? "运行中,结束后才能返回" : "旧 VIO 替换台架(并入 arloopbench)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("返回台架菜单", action: dismiss)
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isRunning)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
    }
}
