import Foundation

enum InterruptedRunRecovery {
    static func recoverAll(
        rootURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> [URL] {
        let root = try rootURL ?? fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent(BenchBackend.basalt.runDirectoryName, isDirectory: true)
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        var recovered: [URL] = []
        for directory in try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            let receiptURL = directory.appendingPathComponent("receipt.json")
            guard let receiptData = try? Data(contentsOf: receiptURL),
                  let started = try? RunReceiptJSON.decoder.decode(RunReceipt.self, from: receiptData),
                  started.state == .started else {
                continue
            }
            guard let backend = BenchBackend.allCases.first(
                where: { $0.id == started.app.engineID }
            ) else { continue }
            let writer = RunReceiptWriter(
                directoryURL: directory,
                callbackQueue: DispatchQueue(label: "\(backend.bundleID).recovery.\(started.runID)")
            )
            let heartbeatURL = directory.appendingPathComponent("heartbeat.json")
            if !fileManager.fileExists(atPath: heartbeatURL.path) {
                try awaitResult { completion in
                    writer.enqueueHeartbeat(
                        RunHeartbeat(
                            runID: started.runID,
                            sequence: 0,
                            monotonicNS: DispatchTime.now().uptimeNanoseconds,
                            writtenAtUTC: BenchmarkRunPreparation.utcTimestamp(),
                            startedReceiptSHA256: RunReceiptHash.sha256Hex(receiptData)
                        ),
                        completion: completion
                    )
                }
            }
            let diagnosticsURL = directory.appendingPathComponent("diagnostics.json")
            if !fileManager.fileExists(atPath: diagnosticsURL.path) {
                try RunDiagnosticsWriter.writeUnavailable(
                    backend: backend,
                    runID: started.runID,
                    reason: "interrupted_recovery",
                    to: directory
                )
            }
            _ = try awaitResult { completion in
                writer.enqueueInterruptedRecovery(
                    endedAtUTC: BenchmarkRunPreparation.utcTimestamp(),
                    completion: completion
                )
            } as RunReceipt?
            try BenchmarkArtifactFinalizer.finalize(
                directoryURL: directory,
                runID: started.runID,
                channel: started.channel
            )
            recovered.append(directory)
        }
        return recovered
    }

    private static func awaitResult<Value>(
        _ operation: (@escaping (Result<Value, Error>) -> Void) -> Void
    ) throws -> Value {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Value, Error>!
        operation {
            result = $0
            semaphore.signal()
        }
        semaphore.wait()
        return try result.get()
    }
}
