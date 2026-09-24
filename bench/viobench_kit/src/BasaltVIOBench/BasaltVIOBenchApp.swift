import SwiftUI

@main
struct BasaltVIOBenchApp: App {
    @StateObject private var model = BenchViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onAppear {
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
    }
}

