import Foundation

protocol AtomicDataWriting {
    func writeAtomically(_ data: Data, to destinationURL: URL) throws
}

struct FoundationAtomicDataWriter: AtomicDataWriting {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func writeAtomically(_ data: Data, to destinationURL: URL) throws {
        let directoryURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let temporaryURL = directoryURL.appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporaryURL, options: [])
            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }
}

final class RunReceiptWriter {
    typealias Completion<Value> = (Result<Value, Error>) -> Void

    private let receiptURL: URL
    private let heartbeatURL: URL
    private let ioQueue: DispatchQueue
    private let callbackQueue: DispatchQueue
    private let atomicWriter: AtomicDataWriting

    init(
        directoryURL: URL,
        callbackQueue: DispatchQueue = .main,
        atomicWriter: AtomicDataWriting = FoundationAtomicDataWriter()
    ) {
        receiptURL = directoryURL.appendingPathComponent("receipt.json")
        heartbeatURL = directoryURL.appendingPathComponent("heartbeat.json")
        ioQueue = DispatchQueue(label: "com.kyle.viobench.receipts.\(UUID().uuidString)", qos: .utility)
        self.callbackQueue = callbackQueue
        self.atomicWriter = atomicWriter
    }

    /// Must complete before sensor capture starts. Disk work occurs only on ioQueue.
    func enqueueStarted(_ receipt: RunReceipt, completion: @escaping Completion<Void>) {
        ioQueue.async {
            do {
                try RunReceiptStateMachine.validateTransition(from: nil, to: receipt)
                guard !FileManager.default.fileExists(atPath: self.receiptURL.path) else {
                    throw RunReceiptValidationError.invalid("receipt.json already exists")
                }
                try self.atomicWriter.writeAtomically(RunReceiptJSON.encoder.encode(receipt), to: self.receiptURL)
                self.complete(.success(()), completion)
            } catch {
                self.complete(.failure(error), completion)
            }
        }
    }

    /// Sensor/metric callers only enqueue; this method never performs synchronous file I/O.
    func enqueueHeartbeat(_ heartbeat: RunHeartbeat, completion: @escaping Completion<Void>) {
        ioQueue.async {
            do {
                try heartbeat.validate()
                let startedData = try Data(contentsOf: self.receiptURL)
                let started = try RunReceiptJSON.decoder.decode(RunReceipt.self, from: startedData)
                guard started.state == .started,
                      started.runID == heartbeat.runID,
                      RunReceiptHash.sha256Hex(startedData) == heartbeat.startedReceiptSHA256 else {
                    throw RunReceiptValidationError.invalid("heartbeat does not identify the active started receipt")
                }
                if FileManager.default.fileExists(atPath: self.heartbeatURL.path) {
                    let previous = try RunReceiptJSON.decoder.decode(
                        RunHeartbeat.self,
                        from: Data(contentsOf: self.heartbeatURL)
                    )
                    guard previous.runID == heartbeat.runID,
                          previous.sequence < heartbeat.sequence,
                          previous.monotonicNS <= heartbeat.monotonicNS else {
                        throw RunReceiptValidationError.invalid("heartbeat sequence regressed")
                    }
                }
                try self.atomicWriter.writeAtomically(RunReceiptJSON.encoder.encode(heartbeat), to: self.heartbeatURL)
                self.complete(.success(()), completion)
            } catch {
                self.complete(.failure(error), completion)
            }
        }
    }

    /// Call only after inputs are sealed and accepted work and artifacts are drained.
    func enqueueTerminal(_ receipt: RunReceipt, completion: @escaping Completion<Void>) {
        ioQueue.async {
            do {
                let previous = try self.readReceipt()
                try RunReceiptStateMachine.validateTransition(from: previous, to: receipt)
                try self.atomicWriter.writeAtomically(RunReceiptJSON.encoder.encode(receipt), to: self.receiptURL)
                self.complete(.success(()), completion)
            } catch {
                self.complete(.failure(error), completion)
            }
        }
    }

    /// On launch, converts a surviving started receipt into explicit aborted evidence.
    func enqueueInterruptedRecovery(endedAtUTC: String, completion: @escaping Completion<RunReceipt?>) {
        ioQueue.async {
            do {
                guard var previous = try self.readReceiptIfPresent(), previous.state == .started else {
                    self.complete(.success(nil), completion)
                    return
                }
                previous.state = .aborted
                previous.endedAtUTC = endedAtUTC
                previous.termination = RunTermination(
                    reasonCode: "interrupted_recovery",
                    recoveredFromInterruption: true
                )
                let started = try self.readReceipt()
                try RunReceiptStateMachine.validateTransition(from: started, to: previous)
                try self.atomicWriter.writeAtomically(RunReceiptJSON.encoder.encode(previous), to: self.receiptURL)
                self.complete(.success(previous), completion)
            } catch {
                self.complete(.failure(error), completion)
            }
        }
    }

    private func readReceipt() throws -> RunReceipt {
        try RunReceiptJSON.decoder.decode(RunReceipt.self, from: Data(contentsOf: receiptURL))
    }

    private func readReceiptIfPresent() throws -> RunReceipt? {
        guard FileManager.default.fileExists(atPath: receiptURL.path) else { return nil }
        return try readReceipt()
    }

    private func complete<Value>(_ result: Result<Value, Error>, _ completion: @escaping Completion<Value>) {
        callbackQueue.async { completion(result) }
    }
}
