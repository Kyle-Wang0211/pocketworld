import Foundation

/// Keeps a document-provider directory readable for the complete replay run.
/// URLs inside this app's own data container do not require a security scope.
final class DatasetAccessLease {
    enum AccessError: Error, Equatable {
        case securityScopeDenied
    }

    private let lock = NSLock()
    private var stopAccess: (() -> Void)?

    private init(stopAccess: (() -> Void)?) {
        self.stopAccess = stopAccess
    }

    static func acquire(
        datasetURL: URL,
        appContainerURL: URL,
        startAccess: () -> Bool,
        stopAccess: @escaping () -> Void
    ) throws -> DatasetAccessLease {
        if isInsideContainer(datasetURL, containerURL: appContainerURL) {
            return DatasetAccessLease(stopAccess: nil)
        }
        guard startAccess() else { throw AccessError.securityScopeDenied }
        return DatasetAccessLease(stopAccess: stopAccess)
    }

    static func acquire(
        datasetURL: URL,
        appContainerURL: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) throws -> DatasetAccessLease {
        try acquire(
            datasetURL: datasetURL,
            appContainerURL: appContainerURL,
            startAccess: { datasetURL.startAccessingSecurityScopedResource() },
            stopAccess: { datasetURL.stopAccessingSecurityScopedResource() }
        )
    }

    func close() {
        let action = lock.withLock { () -> (() -> Void)? in
            defer { stopAccess = nil }
            return stopAccess
        }
        action?()
    }

    deinit { close() }

    private static func isInsideContainer(_ url: URL, containerURL: URL) -> Bool {
        let child = url.standardizedFileURL.path
        let parent = containerURL.standardizedFileURL.path
        return child == parent || child.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
    }
}
